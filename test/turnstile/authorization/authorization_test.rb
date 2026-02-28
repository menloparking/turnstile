# frozen_string_literal: true

require_relative "../../test_helper"

module Turnstile
  module Authorization
    class PolicyTest < Minitest::Test
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
        @article = Article.create!(
          title: "The Fall of Gondolin",
          body: "A tale of hidden cities",
          published: true,
          author_id: @editor.id
        )
      end

      def teardown
        Article.delete_all
        User.delete_all
      end

      # --- DenyAll base behaviour ---

      def test_base_policy_denies_all_by_default
        policy = Policy.new(@reader, @article)
        %i[create destroy index show update].each do |perm|
          result = policy.public_send(:"#{perm}?")
          assert result.denied?,
            "expected #{perm} to be denied by base Policy"
        end
      end

      def test_base_scope_returns_none
        scope = Policy::Scope.new(@reader, Article)
        assert_equal 0, scope.resolve.count
      end

      # --- PermitAll ---

      def test_permit_all_allows_everything
        policy = PermitAll.new(@reader, @article)
        %i[create destroy index show update].each do |perm|
          result = policy.public_send(:"#{perm}?")
          assert result.allowed?,
            "expected #{perm} to be allowed by PermitAll"
        end
      end

      def test_permit_all_handles_unknown_permissions
        policy = PermitAll.new(@reader, @article)
        result = policy.publish?
        assert result.allowed?
        assert_equal :publish, result.permission
      end

      def test_permit_all_responds_to_any_query
        policy = PermitAll.new(@reader, @article)
        assert policy.respond_to?(:frobnicate?)
      end

      # --- ArticlePolicy (concrete general policy) ---

      def test_admin_can_do_everything
        policy = ArticlePolicy.new(@admin, @article)
        %i[create update destroy publish].each do |perm|
          result = policy.public_send(:"#{perm}?")
          assert result.allowed?,
            "expected admin to be allowed #{perm}"
        end
      end

      def test_editor_can_create
        policy = ArticlePolicy.new(@editor, @article)
        assert policy.create?.allowed?
      end

      def test_editor_can_update_own_article
        policy = ArticlePolicy.new(@editor, @article)
        assert policy.update?.allowed?
      end

      def test_editor_cannot_update_others_article
        other = Article.create!(
          title: "Other", author_id: @admin.id
        )
        policy = ArticlePolicy.new(@editor, other)
        result = policy.update?
        assert result.denied?
        assert_equal "you do not own this article",
          result.reason
      end

      def test_reader_cannot_create
        policy = ArticlePolicy.new(@reader, @article)
        result = policy.create?
        assert result.denied?
        assert_includes result.reason, "admins and editors"
      end

      def test_archive_always_denied_with_reason
        policy = ArticlePolicy.new(@admin, @article)
        result = policy.archive?
        assert result.denied?
        assert_equal "archiving disabled", result.reason
      end

      def test_denial_reason_propagates_to_error
        err = assert_raises(NotAuthorizedError) do
          Turnstile::Authorization.authorize(
            @reader, @article, :destroy
          )
        end
        assert_equal :destroy, err.permission
        assert_equal @reader, err.user
        assert_equal @article, err.record
        assert_equal ArticlePolicy, err.policy
        assert_includes err.reason,
          "only admins may destroy"
        assert_includes err.message,
          "only admins may destroy"
      end

      def test_authorize_returns_result_on_success
        result = Turnstile::Authorization.authorize(
          @admin, @article, :show
        )
        assert result.allowed?
      end

      def test_authorize_with_bang_false_returns_denied
        result = Turnstile::Authorization.authorize(
          @reader, @article, :destroy, bang: false
        )
        assert result.denied?
      end

      # --- Scope ---

      def test_scope_filters_for_non_admin
        Article.create!(title: "Draft", published: false)
        scope = ArticlePolicy::Scope.new(
          @reader, Article
        ).resolve
        assert(scope.all? { |a| a.published? })
      end

      def test_scope_returns_all_for_admin
        Article.create!(title: "Draft", published: false)
        scope = ArticlePolicy::Scope.new(
          @admin, Article
        ).resolve
        assert_equal Article.count, scope.count
      end

      # --- Nil user ---

      def test_nil_user_denied
        policy = ArticlePolicy.new(nil, @article)
        assert policy.create?.denied?
        assert policy.update?.denied?
        assert policy.destroy?.denied?
      end
    end

    class ReflectionTest < Minitest::Test
      include TurnstileTestSetup

      def test_base_policy_has_crud_permissions
        names = Policy.permission_names
        %i[create destroy index show update].each do |p|
          assert_includes names, p
        end
      end

      def test_article_policy_includes_custom_permissions
        names = ArticlePolicy.permission_names
        assert_includes names, :publish
        assert_includes names, :archive
      end

      def test_permission_info_has_description
        info = ArticlePolicy.permissions[:publish]
        assert_equal "publish an article", info.description
      end

      def test_context_free_permissions_excludes_contextual
        free = ArticlePolicy.context_free_permissions
        free.each_value do |info|
          refute info.contextual?
        end
      end

      def test_view_policy_has_own_permissions
        names = ArticleViewPolicy.permission_names
        assert_includes names, :show_author
        assert_includes names, :show_body
        # Should NOT inherit CRUD from base Policy.
        refute_includes names, :create
      end

      def test_context_policy_merges_general_permissions
        all = ArticleContextPolicy.permissions
        # Has general ones from ArticlePolicy.
        assert all.key?(:show)
        assert all.key?(:create)
        # Has its own contextual override.
        assert all[:update].contextual?
      end

      def test_contextual_permissions_reported
        ctx = ArticleContextPolicy.contextual_permissions
        assert ctx.key?(:update)
        assert_equal [:changed_attributes],
          ctx[:update].parameters
      end
    end

    class ContextPolicyTest < Minitest::Test
      include TurnstileTestSetup

      def setup
        super
        @admin = User.create!(name: "Elrond", role: "admin")
        @editor = User.create!(
          name: "Glorfindel", role: "editor"
        )
        @article = Article.create!(
          title: "Noldor History",
          author_id: @editor.id
        )
      end

      def teardown
        Article.delete_all
        User.delete_all
      end

      def test_editor_can_update_safe_attributes
        ctx = RequestContext.new(
          request: nil,
          params: {article: {title: "New Title"}},
          action_name: :update
        )
        policy = ArticleContextPolicy.new(
          @editor, @article, ctx
        )
        assert policy.update?.allowed?
      end

      def test_editor_cannot_update_forbidden_attributes
        ctx = RequestContext.new(
          request: nil,
          params: {
            article: {title: "X", author_id: "999"}
          },
          action_name: :update
        )
        policy = ArticleContextPolicy.new(
          @editor, @article, ctx
        )
        result = policy.update?
        assert result.denied?
        assert_includes result.reason, "author_id"
      end

      def test_admin_can_update_any_attributes
        ctx = RequestContext.new(
          request: nil,
          params: {
            article: {
              author_id: "999", published: "true"
            }
          },
          action_name: :update
        )
        policy = ArticleContextPolicy.new(
          @admin, @article, ctx
        )
        assert policy.update?.allowed?
      end

      def test_authorize_in_context_module_method
        ctx = RequestContext.new(
          request: nil,
          params: {article: {title: "Safe"}},
          action_name: :update
        )
        result = Turnstile::Authorization
          .authorize_in_context(
            @editor, @article, :update, ctx
          )
        assert result.allowed?
      end

      def test_authorize_in_context_falls_back_to_general
        # UserPolicy doesn't exist as a context policy;
        # should fall back to general. We use Article since
        # ArticlePolicy exists.
        ctx = RequestContext.new(
          request: nil,
          params: {},
          action_name: :show
        )
        result = Turnstile::Authorization
          .authorize_in_context(
            @admin, @article, :show, ctx
          )
        assert result.allowed?
      end
    end

    class ViewPolicyTest < Minitest::Test
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
          title: "Published", body: "Full text",
          published: true, author_id: @editor.id
        )
        @draft = Article.create!(
          title: "Draft", body: "Secret text",
          published: false
        )
      end

      def teardown
        Article.delete_all
        User.delete_all
      end

      # --- Section permissions (existing) ---

      def test_admin_sees_author
        policy = ArticleViewPolicy.new(@admin, @published)
        assert policy.show_author?.allowed?
      end

      def test_reader_cannot_see_author
        policy = ArticleViewPolicy.new(@reader, @published)
        result = policy.show_author?
        assert result.denied?
        assert_equal "restricted to staff", result.reason
      end

      def test_reader_sees_body_of_published
        policy = ArticleViewPolicy.new(@reader, @published)
        assert policy.show_body?.allowed?
      end

      def test_reader_cannot_see_body_of_draft
        policy = ArticleViewPolicy.new(@reader, @draft)
        result = policy.show_body?
        assert result.denied?
        assert_includes result.reason, "not yet published"
      end

      def test_visibility_batch_query
        policy = ArticleViewPolicy.new(@admin, @published)
        vis = policy.visibility(:show_author, :show_body)
        assert_equal true, vis[:show_author]
        assert_equal true, vis[:show_body]
      end

      def test_view_policy_resolved_by_type
        klass = Resolver.resolve(Article.new, type: :view)
        assert_equal ArticleViewPolicy, klass
      end

      # --- Attribute DSL class-level ---

      def test_attribute_rules_declared
        rules = ArticleViewPolicy.attribute_rules
        assert_equal :visible, rules[:title]
        assert_equal :hidden, rules[:body]
        assert_equal :visible, rules[:published]
        assert_equal :hidden, rules[:author_id]
      end

      def test_attribute_rules_do_not_inherit_from_policy
        # ViewPolicy itself declares no attributes; Policy
        # should not leak anything.
        assert_empty(
          Turnstile::Authorization::ViewPolicy.attribute_rules
        )
      end

      def test_attribute_default_must_be_visible_or_hidden
        assert_raises(ArgumentError) do
          Class.new(Turnstile::Authorization::ViewPolicy) do
            attribute :bad, default: :maybe
          end
        end
      end

      # --- visible_attribute? ---

      def test_default_visible_attribute_allows
        policy = ArticleViewPolicy.new(@reader, @published)
        result = policy.visible_attribute?(:title)
        assert result.allowed?
        assert_equal :title_visible, result.permission
      end

      def test_default_hidden_attribute_denies
        # body is default :hidden, but body_visible? delegates
        # to show_body? — so test a fresh policy class
        # without overrides instead.
        klass = Class.new(
          Turnstile::Authorization::ViewPolicy
        ) do
          attribute :secret, default: :hidden
        end
        policy = klass.new(@reader, @published)
        result = policy.visible_attribute?(:secret)
        assert result.denied?
        assert_includes result.reason, "hidden by default"
      end

      def test_undeclared_attribute_denies
        policy = ArticleViewPolicy.new(@reader, @published)
        result = policy.visible_attribute?(:nonexistent)
        assert result.denied?
        assert_includes result.reason, "not a declared"
      end

      def test_override_method_takes_precedence
        # body is default :hidden but body_visible? delegates
        # to show_body? which allows for published articles.
        policy = ArticleViewPolicy.new(@reader, @published)
        assert policy.visible_attribute?(:body).allowed?
      end

      def test_override_method_can_deny
        # body_visible? denies for drafts (unpublished).
        policy = ArticleViewPolicy.new(@reader, @draft)
        assert policy.visible_attribute?(:body).denied?
      end

      def test_author_id_visible_to_staff
        policy = ArticleViewPolicy.new(@editor, @published)
        assert policy.visible_attribute?(:author_id).allowed?
      end

      def test_author_id_hidden_from_reader
        policy = ArticleViewPolicy.new(@reader, @published)
        assert policy.visible_attribute?(:author_id).denied?
      end

      # --- visible_attributes / hidden_attributes ---

      def test_admin_visible_attributes_for_published
        policy = ArticleViewPolicy.new(@admin, @published)
        visible = policy.visible_attributes
        %i[title body published author_id
          created_at updated_at].each do |attr|
          assert_includes visible, attr,
            "expected #{attr} visible for admin"
        end
      end

      def test_reader_hidden_attributes_for_draft
        policy = ArticleViewPolicy.new(@reader, @draft)
        hidden = policy.hidden_attributes
        assert_includes hidden, :body
        assert_includes hidden, :author_id
      end

      def test_reader_visible_attributes_for_published
        policy = ArticleViewPolicy.new(@reader, @published)
        visible = policy.visible_attributes
        assert_includes visible, :title
        assert_includes visible, :body # published => allowed
        assert_includes visible, :published
        refute_includes visible, :author_id
      end

      # --- filter_attributes ---

      def test_filter_attributes_from_record
        policy = ArticleViewPolicy.new(@reader, @published)
        filtered = policy.filter_attributes(@published)
        assert filtered.key?(:title)
        assert filtered.key?(:body)  # published
        refute filtered.key?(:author_id)
      end

      def test_filter_attributes_from_hash
        policy = ArticleViewPolicy.new(@reader, @draft)
        hash = {title: "X", body: "Y", author_id: 1}
        filtered = policy.filter_attributes(hash)
        assert filtered.key?(:title)
        refute filtered.key?(:body)  # draft => hidden
        refute filtered.key?(:author_id)
      end

      # --- view_policy_for module method ---

      def test_view_policy_for_returns_policy
        policy = Turnstile::Authorization.view_policy_for(
          @admin, @published
        )
        assert_instance_of ArticleViewPolicy, policy
      end

      def test_view_policy_for_returns_nil_without_policy
        policy = Turnstile::Authorization.view_policy_for(
          @admin, @admin # User has no view policy
        )
        assert_nil policy
      end
    end

    class ViewPolicyPermitAllTest < Minitest::Test
      include TurnstileTestSetup

      def setup
        super
        @user = User.create!(name: "Samwise", role: "reader")
        @article = Article.create!(
          title: "Concerning Hobbits",
          published: true
        )
      end

      def teardown
        Article.delete_all
        User.delete_all
      end

      def test_permits_any_permission_query
        policy = ViewPolicy::PermitAll.new(@user, @article)
        assert policy.frobnicate?.allowed?
      end

      def test_responds_to_any_query
        policy = ViewPolicy::PermitAll.new(@user, @article)
        assert policy.respond_to?(:anything?)
      end

      def test_visible_attribute_always_allows
        policy = ViewPolicy::PermitAll.new(@user, @article)
        assert policy.visible_attribute?(:salary).allowed?
        assert policy.visible_attribute?(:ssn).allowed?
      end

      def test_visible_attributes_includes_all_declared
        klass = Class.new(ViewPolicy::PermitAll) do
          attribute :name
          attribute :secret, default: :hidden
        end
        policy = klass.new(@user, @article)
        # PermitAll overrides visible_attribute? to always
        # allow, so even :hidden defaults are visible.
        assert policy.visible_attribute?(:secret).allowed?
      end
    end

    class ResolverTest < Minitest::Test
      include TurnstileTestSetup

      def test_resolves_general_from_instance
        klass = Resolver.resolve(Article.new)
        assert_equal ArticlePolicy, klass
      end

      def test_resolves_general_from_class
        klass = Resolver.resolve(Article)
        assert_equal ArticlePolicy, klass
      end

      def test_resolves_context_policy
        klass = Resolver.resolve(
          Article.new, type: :context
        )
        assert_equal ArticleContextPolicy, klass
      end

      def test_resolves_view_policy
        klass = Resolver.resolve(
          Article.new, type: :view
        )
        assert_equal ArticleViewPolicy, klass
      end

      def test_returns_nil_for_unknown
        klass = Resolver.resolve(:nonexistent)
        assert_nil klass
      end

      def test_resolve_bang_raises_for_unknown
        assert_raises(PolicyNotFoundError) do
          Resolver.resolve!(:nonexistent)
        end
      end

      def test_resolves_from_symbol
        klass = Resolver.resolve(:article)
        assert_equal ArticlePolicy, klass
      end

      def test_respects_policy_namespace
        Turnstile.configure do |c|
          c.policy_namespace = "Admin"
        end
        # No Admin::ArticlePolicy exists, so falls back.
        klass = Resolver.resolve(Article.new)
        assert_equal ArticlePolicy, klass
      end
    end

    class ResultTest < Minitest::Test
      def test_allowed_result
        r = Result.new(true, permission: :show)
        assert r.allowed?
        refute r.denied?
        assert_nil r.reason
        assert_includes r.to_s, "allowed:show"
      end

      def test_denied_result_with_reason
        r = Result.new(
          false, permission: :update,
          reason: "nope"
        )
        refute r.allowed?
        assert r.denied?
        assert_equal "nope", r.reason
        assert_includes r.to_s, "denied:update"
        assert_includes r.to_s, "nope"
      end

      def test_result_is_frozen
        r = Result.new(true, permission: :show)
        assert r.frozen?
      end
    end
  end
end
