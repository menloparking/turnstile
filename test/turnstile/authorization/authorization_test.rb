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
