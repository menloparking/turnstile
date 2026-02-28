# frozen_string_literal: true

require_relative "../../test_helper"

module Turnstile
  class PresentedTest < Minitest::Test
    include TurnstileTestSetup

    def setup
      super
      @admin = User.create!(name: "Elrond", role: "admin")
      @editor = User.create!(
        name: "Glorfindel", role: "editor"
      )
      @reader = User.create!(
        name: "Frodo", role: "reader"
      )
      @published = Article.create!(
        title: "The Fall of Gondolin",
        body: "A tale of hidden cities",
        published: true,
        author_id: @editor.id
      )
      @draft = Article.create!(
        title: "Secret Lore",
        body: "Eyes only",
        published: false,
        author_id: @editor.id
      )
    end

    def teardown
      Article.delete_all
      User.delete_all
    end

    # --- Construction ---

    def test_wraps_record_and_user
      p = Presented.new(@published, @reader)
      assert_equal @published, p.__record__
      assert_equal @reader, p.__user__
    end

    def test_resolves_view_policy_automatically
      p = Presented.new(@published, @reader)
      assert_instance_of ArticleViewPolicy,
        p.__view_policy__
    end

    def test_accepts_explicit_view_policy
      vp = ArticleViewPolicy.new(@admin, @published)
      p = Presented.new(@published, @admin, view_policy: vp)
      assert_equal vp, p.__view_policy__
    end

    def test_nil_view_policy_for_unresolvable_record
      p = Presented.new(@reader, @admin)
      assert_nil p.__view_policy__
    end

    # --- Unwrap ---

    def test_unwrap_returns_raw_record
      p = Presented.new(@published, @reader)
      assert_same @published, p.unwrap
    end

    # --- Rails identity methods ---

    def test_id_delegates
      p = Presented.new(@published, @reader)
      assert_equal @published.id, p.id
    end

    def test_to_param_delegates
      p = Presented.new(@published, @reader)
      assert_equal @published.to_param, p.to_param
    end

    def test_to_key_delegates
      p = Presented.new(@published, @reader)
      assert_equal @published.to_key, p.to_key
    end

    def test_to_model_returns_self
      p = Presented.new(@published, @reader)
      assert_same p, p.to_model
    end

    def test_model_name_delegates
      p = Presented.new(@published, @reader)
      assert_equal @published.model_name, p.model_name
    end

    def test_persisted_delegates
      p = Presented.new(@published, @reader)
      assert p.persisted?
    end

    def test_new_record_delegates
      article = Article.new(title: "Unsaved")
      p = Presented.new(article, @reader)
      assert p.new_record?
    end

    # --- Type checks ---

    def test_is_a_article
      p = Presented.new(@published, @reader)
      assert p.is_a?(Article)
    end

    def test_kind_of_article
      p = Presented.new(@published, @reader)
      assert p.kind_of?(Article) # rubocop:disable Style/ClassCheck
    end

    def test_instance_of_article
      p = Presented.new(@published, @reader)
      assert p.instance_of?(Article)
    end

    def test_class_reports_record_class
      p = Presented.new(@published, @reader)
      assert_equal Article, p.class
    end

    # --- Equality ---

    def test_equals_underlying_record
      p = Presented.new(@published, @reader)
      assert_equal @published, p
    end

    def test_equals_another_presented_wrapping_same_record
      a = Presented.new(@published, @reader)
      b = Presented.new(@published, @admin)
      assert_equal a, b
    end

    def test_hash_matches_record
      p = Presented.new(@published, @reader)
      assert_equal @published.hash, p.hash
    end

    # --- respond_to? ---

    def test_responds_to_record_methods
      p = Presented.new(@published, @reader)
      assert p.respond_to?(:title)
      assert p.respond_to?(:body)
    end

    def test_responds_to_passthrough_methods
      p = Presented.new(@published, @reader)
      assert p.respond_to?(:id)
      assert p.respond_to?(:persisted?)
    end

    def test_does_not_respond_to_nonsense
      p = Presented.new(@published, @reader)
      refute p.respond_to?(:frobnicate_the_widgets)
    end

    # --- Strict mode (default) ---

    def test_allows_visible_attribute
      p = Presented.new(@published, @reader)
      assert_equal "The Fall of Gondolin", p.title
    end

    def test_allows_visible_published_attribute
      p = Presented.new(@published, @reader)
      assert_equal true, p.published
    end

    def test_denies_hidden_attribute_strict
      p = Presented.new(@draft, @reader)
      err = assert_raises(AttributeDeniedError) do
        p.body
      end
      assert_equal :body, err.attribute
      assert_equal @draft, err.record
    end

    def test_denies_author_id_for_reader
      p = Presented.new(@published, @reader)
      assert_raises(AttributeDeniedError) { p.author_id }
    end

    def test_admin_sees_all_attributes
      p = Presented.new(@draft, @admin)
      assert_equal "Eyes only", p.body
      assert_equal @editor.id, p.author_id
    end

    def test_editor_sees_author_id
      p = Presented.new(@published, @editor)
      assert_equal @editor.id, p.author_id
    end

    # --- Lenient mode ---

    def test_lenient_returns_nil_for_denied
      Turnstile.configure { |c| c.presented_mode = :lenient }
      p = Presented.new(@draft, @reader)
      assert_nil p.body
    end

    def test_lenient_allows_visible
      Turnstile.configure { |c| c.presented_mode = :lenient }
      p = Presented.new(@published, @reader)
      assert_equal "The Fall of Gondolin", p.title
    end

    # --- Unguarded methods pass through ---

    def test_non_attribute_methods_pass_through
      # created_at is a declared attribute (default: visible),
      # so it passes. But let's call a method not in the
      # attribute rules at all — e.g. valid?
      p = Presented.new(@published, @reader)
      assert p.valid?
    end

    # --- Inspect ---

    def test_inspect_includes_class_and_id
      p = Presented.new(@published, @reader)
      assert_includes p.inspect, "Turnstile::Presented"
      assert_includes p.inspect, "Article"
      assert_includes p.inspect, @published.id.to_s
    end

    # --- No view policy: everything passes through ---

    def test_no_view_policy_passes_through
      # User has no ViewPolicy
      p = Presented.new(@reader, @admin)
      assert_equal "Frodo", p.name
    end
  end

  class PresentedCollectionTest < Minitest::Test
    include TurnstileTestSetup

    def setup
      super
      @admin = User.create!(name: "Elrond", role: "admin")
      @reader = User.create!(
        name: "Frodo", role: "reader"
      )
      Article.create!(
        title: "First", body: "Body 1",
        published: true
      )
      Article.create!(
        title: "Second", body: "Body 2",
        published: true
      )
      Article.create!(
        title: "Draft", body: "Secret",
        published: false
      )
    end

    def teardown
      Article.delete_all
      User.delete_all
    end

    def test_iterates_as_presented
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      coll.each do |item|
        assert_instance_of Presented, item
      end
    end

    def test_count_delegates_to_relation
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      assert_equal 2, coll.count
    end

    def test_size_delegates_to_relation
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      assert_equal 2, coll.size
    end

    def test_empty_delegates
      relation = Article.where(title: "Nonexistent")
      coll = PresentedCollection.new(relation, @reader)
      assert coll.empty?
    end

    def test_not_empty
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      refute coll.empty?
    end

    def test_enumerable_map
      relation = Article.where(published: true)
        .order(:title)
      coll = PresentedCollection.new(relation, @reader)
      titles = coll.map(&:title)
      assert_equal %w[First Second], titles
    end

    def test_presented_items_guard_attributes
      relation = Article.where(published: false)
      coll = PresentedCollection.new(relation, @reader)
      coll.each do |item|
        # title is visible; body is hidden for drafts
        assert item.title
        assert_raises(AttributeDeniedError) { item.body }
      end
    end

    def test_admin_sees_everything
      relation = Article.where(published: false)
      coll = PresentedCollection.new(relation, @admin)
      coll.each do |item|
        assert item.title
        assert item.body
      end
    end

    def test_klass_delegates
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      assert_equal Article, coll.klass
    end

    def test_model_name_delegates
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      assert_equal Article.model_name, coll.model_name
    end

    def test_unwrap_returns_raw_relation
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      assert_same relation, coll.unwrap
    end

    def test_inspect_includes_class_and_size
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      assert_includes coll.inspect,
        "PresentedCollection"
      assert_includes coll.inspect, "Article"
    end

    def test_to_a_returns_presented_array
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      arr = coll.to_a
      assert_instance_of Array, arr
      arr.each do |item|
        assert_instance_of Presented, item
      end
    end

    def test_enum_for_without_block
      relation = Article.where(published: true)
      coll = PresentedCollection.new(relation, @reader)
      enum = coll.each
      assert_instance_of Enumerator, enum
    end
  end
end
