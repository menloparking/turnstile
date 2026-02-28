# frozen_string_literal: true

require_relative "../../test_helper"

module Turnstile
  module Loading
    class LoaderTest < Minitest::Test
      include TurnstileTestSetup

      def setup
        super
        @admin = User.create!(name: "Elrond", role: "admin")
        @reader = User.create!(
          name: "Frodo", role: "reader"
        )
        @published = Article.create!(
          title: "Published", published: true
        )
        @draft = Article.create!(
          title: "Draft", published: false
        )
      end

      def teardown
        Article.delete_all
        User.delete_all
      end

      # A stub controller class with turnstile config.
      def controller_class(overrides = {})
        klass = Class.new do
          def self.name = "ArticlesController"

          def self.turnstile_config
            @turnstile_config ||= Config.new
          end
        end
        overrides.each do |k, v|
          klass.turnstile_config.public_send(:"#{k}=", v)
        end
        klass
      end

      # --- Plural (index) ---

      def test_index_loads_collection_for_admin
        loader = Loader.new(
          controller_class: controller_class,
          action_name: :index,
          params: {},
          current_user: @admin
        )
        result = loader.load
        articles = result[:@articles]
        assert_kind_of ActiveRecord::Relation, articles
        assert_equal Article.count, articles.count
      end

      def test_index_loads_scoped_collection_for_reader
        loader = Loader.new(
          controller_class: controller_class,
          action_name: :index,
          params: {},
          current_user: @reader
        )
        result = loader.load
        articles = result[:@articles]
        assert articles.all?(&:published?)
      end

      # --- Singular (show) ---

      def test_show_loads_singular_record
        loader = Loader.new(
          controller_class: controller_class,
          action_name: :show,
          params: {id: @published.id},
          current_user: @admin
        )
        result = loader.load
        assert_equal @published, result[:@article]
      end

      def test_show_raises_when_not_found
        assert_raises(ResourceNotFoundError) do
          Loader.new(
            controller_class: controller_class,
            action_name: :show,
            params: {id: 999_999},
            current_user: @admin
          ).load
        end
      end

      def test_show_respects_scope_for_reader
        # Reader cannot see drafts via scope.
        assert_raises(ResourceNotFoundError) do
          Loader.new(
            controller_class: controller_class,
            action_name: :show,
            params: {id: @draft.id},
            current_user: @reader
          ).load
        end
      end

      # --- Skip actions ---

      def test_new_skips_loading
        loader = Loader.new(
          controller_class: controller_class,
          action_name: :new,
          params: {},
          current_user: @admin
        )
        assert_equal({}, loader.load)
      end

      def test_create_skips_loading
        loader = Loader.new(
          controller_class: controller_class,
          action_name: :create,
          params: {},
          current_user: @admin
        )
        assert_equal({}, loader.load)
      end

      # --- Custom action modes ---

      def test_custom_plural_action
        klass = controller_class
        klass.turnstile_config.action_modes[:search] =
          :plural
        loader = Loader.new(
          controller_class: klass,
          action_name: :search,
          params: {},
          current_user: @admin
        )
        result = loader.load
        assert result.key?(:@articles)
      end

      def test_custom_singular_action
        klass = controller_class
        klass.turnstile_config.action_modes[:publish] =
          :singular
        loader = Loader.new(
          controller_class: klass,
          action_name: :publish,
          params: {id: @published.id},
          current_user: @admin
        )
        result = loader.load
        assert_equal @published, result[:@article]
      end

      def test_skip_loading_override
        klass = controller_class
        klass.turnstile_config.action_modes[:show] = :skip
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {id: @published.id},
          current_user: @admin
        )
        assert_equal({}, loader.load)
      end

      # --- Custom ID param ---

      def test_custom_id_param
        klass = controller_class(id_param: :article_id)
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {article_id: @published.id},
          current_user: @admin
        )
        result = loader.load
        assert_equal @published, result[:@article]
      end

      # --- Unknown action loads nothing ---

      def test_unknown_action_loads_nothing
        loader = Loader.new(
          controller_class: controller_class,
          action_name: :dashboard,
          params: {},
          current_user: @admin
        )
        assert_equal({}, loader.load)
      end
    end

    class DslTest < Minitest::Test
      include TurnstileTestSetup

      def test_resource_class_override
        klass = build_controller_class
        klass.resource_class User
        assert_equal User,
          klass.turnstile_config.resource_class
      end

      def test_resource_id_param
        klass = build_controller_class
        klass.resource_id_param :slug
        assert_equal :slug,
          klass.turnstile_config.id_param
      end

      def test_load_singular_sets_mode
        klass = build_controller_class
        klass.load_singular :publish, :archive
        modes = klass.turnstile_config.action_modes
        assert_equal :singular, modes[:publish]
        assert_equal :singular, modes[:archive]
      end

      def test_load_plural_sets_mode
        klass = build_controller_class
        klass.load_plural :search
        modes = klass.turnstile_config.action_modes
        assert_equal :plural, modes[:search]
      end

      def test_skip_loading_sets_mode
        klass = build_controller_class
        klass.skip_loading :dashboard
        modes = klass.turnstile_config.action_modes
        assert_equal :skip, modes[:dashboard]
      end

      def test_load_resource_registers_block
        klass = build_controller_class
        klass.load_resource(:transfer) { |_c| "custom" }
        block = klass.turnstile_config
          .custom_loaders[:transfer]
        assert_equal "custom", block.call(nil)
      end

      def test_config_inherits_via_dup
        parent = build_controller_class
        parent.load_singular :publish
        child = Class.new(parent)
        child.include Dsl

        # Child inherits parent's config.
        assert_equal :singular,
          child.turnstile_config.action_modes[:publish]

        # Child override does not pollute parent.
        child.load_plural :search
        refute parent.turnstile_config
          .action_modes.key?(:search)
      end

      private

      def build_controller_class
        klass = Class.new do
          def self.name = "TestController"
        end
        klass.include Dsl
        klass
      end
    end
  end
end
