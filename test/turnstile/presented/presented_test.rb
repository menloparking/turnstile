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

    def test_resolves_policy_automatically
      p = Presented.new(@published, @reader)
      assert_instance_of ArticlePolicy, p.__policy__
    end

    def test_nil_policy_for_unresolvable_record
      p = Presented.new(@reader, @admin)
      assert_nil p.__policy__
    end

    # --- Unwrap ---

    def test_unwrap_returns_raw_record
      p = Presented.new(@published, @reader)
      assert_same @published, p.unwrap
    end

    # --- policy accessor ---

    def test_policy_returns_resolved_policy
      p = Presented.new(@published, @reader)
      assert_instance_of ArticlePolicy, p.policy
      assert_same p.__policy__, p.policy
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

    # --- DenyAll: attribute with no _allowed? method ---

    def test_deny_all_for_attribute_without_allowed_method
      # WidgetPolicy < Policy defines no _allowed? methods,
      # so every column attribute is denied by default.
      widget = ::Widget.create!(label: "Test")
      p = Presented.new(widget, @reader)
      assert_raises(AttributeDeniedError) { p.label }
    ensure
      ::Widget.delete_all
    end

    def test_deny_all_lenient_returns_nil
      Turnstile.configure { |c| c.presented_mode = :lenient }
      widget = ::Widget.create!(label: "Test")
      p = Presented.new(widget, @reader)
      assert_nil p.label
    ensure
      ::Widget.delete_all
    end

    # --- Unguarded methods pass through ---

    def test_non_attribute_methods_pass_through
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

    # --- No policy: everything passes through ---

    def test_no_policy_passes_through
      # User has no UserPolicy
      p = Presented.new(@reader, @admin)
      assert_equal "Frodo", p.name
    end

    # --- allowed? predicate ---

    def test_allowed_predicate_true_for_visible_attr
      p = Presented.new(@published, @reader)
      assert p.allowed?(:title)
    end

    def test_allowed_predicate_false_for_denied_attr
      p = Presented.new(@draft, @reader)
      refute p.allowed?(:body)
    end

    def test_allowed_predicate_false_for_missing_method
      widget = ::Widget.create!(label: "X")
      p = Presented.new(widget, @reader)
      refute p.allowed?(:label)
    ensure
      ::Widget.delete_all
    end

    def test_allowed_predicate_true_without_policy
      p = Presented.new(@reader, @admin)
      assert p.allowed?(:name)
    end

    # --- if_allowed block guard ---

    def test_if_allowed_yields_when_allowed
      p = Presented.new(@published, @reader)
      yielded = nil
      p.if_allowed(:title) { |v| yielded = v }
      assert_equal "The Fall of Gondolin", yielded
    end

    def test_if_allowed_does_not_yield_when_denied
      p = Presented.new(@draft, @reader)
      yielded = :not_called
      p.if_allowed(:body) { |v| yielded = v }
      assert_equal :not_called, yielded
    end

    def test_if_allowed_else_returns_value_when_allowed
      p = Presented.new(@published, @reader)
      result = p.if_allowed(:title) { |v| v.upcase }
        .else { "fallback" }
      assert_equal "The Fall of Gondolin", result
    end

    def test_if_allowed_else_yields_fallback_when_denied
      p = Presented.new(@draft, @reader)
      result = p.if_allowed(:body) { |v| v }
        .else { "redacted" }
      assert_equal "redacted", result
    end

    # --- allowed(attr) ---

    def test_allowed_returns_value_when_permitted
      p = Presented.new(@published, @reader)
      assert_equal "The Fall of Gondolin",
        p.allowed(:title)
    end

    def test_allowed_returns_nil_when_denied
      p = Presented.new(@draft, @reader)
      assert_nil p.allowed(:body)
    end

    # --- [] hash-like access ---

    def test_bracket_returns_value_when_permitted
      p = Presented.new(@published, @reader)
      assert_equal "The Fall of Gondolin", p[:title]
    end

    def test_bracket_returns_nil_when_denied
      p = Presented.new(@draft, @reader)
      assert_nil p[:body]
    end

    # --- fetch with fallback ---

    def test_fetch_returns_value_when_permitted
      p = Presented.new(@published, @reader)
      assert_equal "The Fall of Gondolin",
        p.fetch(:title) { "fallback" }
    end

    def test_fetch_returns_fallback_when_denied
      p = Presented.new(@draft, @reader)
      result = p.fetch(:body) { "redacted" }
      assert_equal "redacted", result
    end

    def test_fetch_returns_nil_when_denied_no_block
      p = Presented.new(@draft, @reader)
      assert_nil p.fetch(:body)
    end

    # --- deconstruct_keys (pattern matching) ---

    def test_deconstruct_keys_includes_allowed_attrs
      p = Presented.new(@published, @reader)
      h = p.deconstruct_keys(%i[title body])
      assert_equal "The Fall of Gondolin", h[:title]
      # body is allowed on published article for reader
      assert_equal "A tale of hidden cities", h[:body]
    end

    def test_deconstruct_keys_omits_denied_attrs
      p = Presented.new(@draft, @reader)
      h = p.deconstruct_keys(%i[title body author_id])
      assert_equal "Secret Lore", h[:title]
      refute h.key?(:body)
      refute h.key?(:author_id)
    end

    def test_deconstruct_keys_nil_returns_all_allowed
      p = Presented.new(@published, @admin)
      h = p.deconstruct_keys(nil)
      assert h.key?(:title)
      assert h.key?(:body)
      assert h.key?(:author_id)
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
