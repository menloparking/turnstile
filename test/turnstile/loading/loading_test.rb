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

      # --- Explicit parent resource ---

      def test_explicit_parent_loads_parent_and_child
        author = User.create!(
          name: "Boromir", role: "editor"
        )
        article = Article.create!(
          title: "Nested",
          published: true,
          author_id: author.id
        )
        klass = controller_class(parent_class: User)
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {user_id: author.id, id: article.id},
          current_user: @admin
        )
        result = loader.load
        assert_equal author, result[:@user]
        assert_equal article, result[:@article]
      end

      def test_explicit_parent_scopes_child_collection
        author = User.create!(
          name: "Legolas", role: "editor"
        )
        own = Article.create!(
          title: "Own",
          published: true,
          author_id: author.id
        )
        Article.create!(
          title: "Other",
          published: true,
          author_id: nil
        )
        klass = controller_class(parent_class: User)
        loader = Loader.new(
          controller_class: klass,
          action_name: :index,
          params: {user_id: author.id},
          current_user: @admin
        )
        result = loader.load
        assert_equal author, result[:@user]
        articles = result[:@articles]
        assert_equal [own], articles.to_a
      end

      def test_explicit_parent_with_custom_id_param
        author = User.create!(
          name: "Gimli", role: "editor"
        )
        article = Article.create!(
          title: "Axe",
          published: true,
          author_id: author.id
        )
        klass = controller_class
        klass.turnstile_config.parent_class = User
        klass.turnstile_config.parent_id_param = :author_id
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {author_id: author.id, id: article.id},
          current_user: @admin
        )
        result = loader.load
        assert_equal author, result[:@user]
        assert_equal article, result[:@article]
      end

      def test_explicit_parent_raises_when_parent_not_found
        klass = controller_class(parent_class: User)
        assert_raises(ResourceNotFoundError) do
          Loader.new(
            controller_class: klass,
            action_name: :show,
            params: {user_id: 999_999, id: 1},
            current_user: @admin
          ).load
        end
      end

      def test_explicit_parent_child_not_in_scope_raises
        author = User.create!(
          name: "Aragorn", role: "editor"
        )
        # Article belongs to a different author.
        article = Article.create!(
          title: "Orphan",
          published: true,
          author_id: nil
        )
        klass = controller_class(parent_class: User)
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {
            user_id: author.id,
            id: article.id
          },
          current_user: @admin
        )
        # The child is scoped through parent's association,
        # so the orphan article is not found.
        assert_raises(ResourceNotFoundError) do
          loader.load
        end
      end

      # --- Auto parent detection ---

      def test_auto_parent_detects_from_params
        author = User.create!(
          name: "Faramir", role: "editor"
        )
        article = Article.create!(
          title: "Auto",
          published: true,
          author_id: author.id
        )
        klass = controller_class(parent_auto: true)
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {user_id: author.id, id: article.id},
          current_user: @admin
        )
        result = loader.load
        assert_equal author, result[:@user]
        assert_equal article, result[:@article]
      end

      def test_auto_parent_ignores_nonexistent_models
        # A param key that doesn't map to a model should
        # be silently skipped; loading proceeds without
        # a parent.
        klass = controller_class(parent_auto: true)
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {
            shire_id: 42,
            id: @published.id
          },
          current_user: @admin
        )
        result = loader.load
        refute result.key?(:@shire)
        assert_equal @published, result[:@article]
      end

      def test_no_parent_when_disabled
        # Without parent_class or parent_auto, *_id params
        # are ignored.
        klass = controller_class
        loader = Loader.new(
          controller_class: klass,
          action_name: :show,
          params: {user_id: 1, id: @published.id},
          current_user: @admin
        )
        result = loader.load
        refute result.key?(:@user)
        assert_equal @published, result[:@article]
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

      # --- Parent resource DSL ---

      def test_auto_parent_sets_flag
        klass = build_controller_class
        klass.auto_parent
        assert klass.turnstile_config.parent_auto
      end

      def test_parent_resource_sets_class
        klass = build_controller_class
        klass.parent_resource User
        cfg = klass.turnstile_config
        assert_equal User, cfg.parent_class
        assert_nil cfg.parent_id_param
      end

      def test_parent_resource_with_id_param
        klass = build_controller_class
        klass.parent_resource User, id_param: :author_id
        cfg = klass.turnstile_config
        assert_equal User, cfg.parent_class
        assert_equal :author_id, cfg.parent_id_param
      end

      def test_parent_config_inherits_via_dup
        parent_ctrl = build_controller_class
        parent_ctrl.parent_resource User
        child_ctrl = Class.new(parent_ctrl)
        child_ctrl.include Dsl

        assert_equal User,
          child_ctrl.turnstile_config.parent_class

        # Override in child does not pollute parent.
        child_ctrl.parent_resource Page
        assert_equal User,
          parent_ctrl.turnstile_config.parent_class
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
