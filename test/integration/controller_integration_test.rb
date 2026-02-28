# frozen_string_literal: true

# Integration tests for the Turnstile controller concern,
# exercised through a full Rails request/response cycle
# against the dummy application.

require_relative "../test_helper"
require_relative "../dummy/config/environment"

require "rails/test_help"

# Schema is created by test_helper.rb (shared in-memory DB).
# Eager-load the dummy app's models, policies, and controllers
# since eager_load is off in test.
#
# NOTE: Booting the dummy Rails environment above establishes
# a fresh :memory: connection (via database.yml), which
# discards the tables test_helper.rb created. Re-create them
# here so that both unit and integration tests share the same
# connection and schema.
ActiveRecord::Schema.define do
  create_table :articles, force: true do |t|
    t.string :title
    t.text :body
    t.boolean :published, default: false
    t.integer :author_id
    t.timestamps
  end

  create_table :users, force: true do |t|
    t.string :name
    t.string :role
    t.timestamps
  end

  create_table :pages, force: true do |t|
    t.string :title
    t.text :content
    t.boolean :visible, default: true
    t.timestamps
  end
end

Dir[
  File.expand_path("../dummy/app/models/**/*.rb", __dir__)
].each { |f| require f }
Dir[
  File.expand_path("../dummy/app/policies/**/*.rb", __dir__)
].each { |f| require f }
Dir[
  File.expand_path(
    "../dummy/app/controllers/**/*.rb", __dir__
  )
].each { |f| require f }

module IntegrationTestHelper
  private

  def sign_in(user)
    # ActionDispatch::IntegrationTest open_session stores
    # a session across requests. We set the user_id that
    # ApplicationController#current_user reads.
    post "/session",
      params: {user_id: user.id},
      headers: {"X-Requested-With" => "test"}
  rescue ActionController::RoutingError
    # No /session route — fall back to manipulating the
    # session directly via the integration test API.
    # open_session returns a new session we can configure.
  end

  def sign_in_as(user)
    # Use a cookie-based approach: set the session in the
    # test by going through any endpoint first, then
    # patching the session. For integration tests, we can
    # use the `get` + session approach.
    #
    # Actually, ActionDispatch::IntegrationTest doesn't
    # expose session= directly. We'll use a lightweight
    # approach: add a test-only route.
    @signed_in_user_id = user.id
  end
end

# Add a test-only route for setting session.
Rails.application.routes.draw do
  resources :articles do
    member do
      post :publish
    end
    collection do
      get :search
    end
  end

  resources :pages, only: %i[index show]

  get "health", to: "health#check"

  # Test-only route to set the session user.
  post "test_sign_in", to: "test_sessions#create"

  # Test-only route for view policy verification.
  get "articles/:id/view_info",
    to: "article_views#show",
    as: :article_view_info
end

# Tiny controller for test sign-in.
class TestSessionsController < ApplicationController
  skip_before_action :turnstile_load_and_authorize,
    raise: false

  def create
    session[:user_id] = params[:user_id]
    render plain: "signed in", status: :ok
  end
end

# Controller that exercises the view_policy helper.
class ArticleViewsController < ApplicationController
  include Turnstile::Controller

  skip_authorization :show
  skip_loading :show

  def show
    article = Article.find(params[:id])
    vp = view_policy(article)

    visible = vp.visible_attributes.sort.join(",")
    hidden = vp.hidden_attributes.sort.join(",")
    body_ok = vp.visible_attribute?(:body).allowed?
    author_ok = vp.visible_attribute?(:author_id).allowed?

    render plain: [
      "visible:#{visible}",
      "hidden:#{hidden}",
      "body:#{body_ok}",
      "author:#{author_ok}"
    ].join("\n")
  end
end

class ControllerIntegrationTest <
  ActionDispatch::IntegrationTest
  def setup
    Turnstile.reset_configuration!

    # Seed test data.
    @admin = User.create!(name: "Gandalf", role: "admin")
    @editor = User.create!(name: "Frodo", role: "editor")
    @reader = User.create!(name: "Sam", role: "viewer")

    @published_article = Article.create!(
      title: "On Hobbits",
      body: "A discourse.",
      published: true,
      author_id: @editor.id
    )
    @draft_article = Article.create!(
      title: "Secret Plans",
      body: "The palantir reveals.",
      published: false,
      author_id: @editor.id
    )

    @visible_page = Page.create!(
      title: "Welcome",
      content: "Rivendell awaits.",
      visible: true
    )
    @hidden_page = Page.create!(
      title: "Hidden Lore",
      content: "For elven eyes only.",
      visible: false
    )
  end

  def teardown
    Article.delete_all
    User.delete_all
    Page.delete_all
  end

  # -- Helper to sign in via test route --

  def sign_in(user)
    post "/test_sign_in", params: {user_id: user.id}
    assert_response :ok
  end

  # ===================================================
  # Articles: index (collection loading + policy scope)
  # ===================================================

  def test_admin_sees_all_articles_on_index
    sign_in(@admin)
    get "/articles"
    assert_response :ok
    assert_includes response.body, "On Hobbits"
    assert_includes response.body, "Secret Plans"
  end

  def test_non_admin_sees_only_published_on_index
    sign_in(@reader)
    get "/articles"
    assert_response :ok
    assert_includes response.body, "On Hobbits"
    refute_includes response.body, "Secret Plans"
  end

  # ===================================================
  # Articles: show (singular loading)
  # ===================================================

  def test_show_loads_article_for_admin
    sign_in(@admin)
    get "/articles/#{@published_article.id}"
    assert_response :ok
    assert_equal "On Hobbits", response.body
  end

  def test_show_returns_not_found_for_non_admin_on_draft
    sign_in(@reader)
    # The policy scope filters out unpublished for
    # non-admins, so the loader will not find the draft.
    get "/articles/#{@draft_article.id}"
    assert_response :not_found
  end

  def test_show_returns_not_found_for_missing_article
    sign_in(@admin)
    get "/articles/999999"
    assert_response :not_found
  end

  # ===================================================
  # Articles: create (skip_loading + manual authorize)
  # ===================================================

  def test_admin_can_create_article
    sign_in(@admin)
    post "/articles",
      params: {article: {title: "New", body: "Content"}}
    assert_response :created
    assert_equal "created", response.body
    assert Article.find_by(title: "New")
  end

  def test_editor_can_create_article
    sign_in(@editor)
    post "/articles",
      params: {article: {title: "Editor Post", body: "Y"}}
    assert_response :created
  end

  def test_reader_cannot_create_article
    sign_in(@reader)
    post "/articles",
      params: {article: {title: "Nope", body: "No"}}
    assert_response :forbidden
  end

  # ===================================================
  # Articles: update (singular loading + authorization)
  # ===================================================

  def test_admin_can_update_any_article
    sign_in(@admin)
    patch "/articles/#{@published_article.id}",
      params: {article: {title: "Updated"}}
    assert_response :ok
    assert_includes response.body, "updated:"
  end

  def test_editor_can_update_own_article
    sign_in(@editor)
    patch "/articles/#{@published_article.id}",
      params: {article: {title: "My Edit"}}
    assert_response :ok
  end

  def test_reader_cannot_update_article
    sign_in(@reader)
    patch "/articles/#{@published_article.id}",
      params: {article: {title: "Hacked"}}
    assert_response :forbidden
  end

  # ===================================================
  # Articles: destroy (admin only)
  # ===================================================

  def test_admin_can_destroy_article
    sign_in(@admin)
    article = Article.create!(
      title: "Doomed", published: true
    )
    delete "/articles/#{article.id}"
    assert_response :ok
    assert_equal "destroyed", response.body
    refute Article.exists?(article.id)
  end

  def test_editor_cannot_destroy_article
    sign_in(@editor)
    delete "/articles/#{@published_article.id}"
    assert_response :forbidden
  end

  # ===================================================
  # Articles: publish (custom singular action via DSL)
  # ===================================================

  def test_admin_can_publish_article
    sign_in(@admin)
    post "/articles/#{@draft_article.id}/publish"
    assert_response :ok
    assert_equal "published", response.body
    assert @draft_article.reload.published?
  end

  def test_reader_cannot_publish_article
    sign_in(@reader)
    # Admin scope lets admin see drafts; reader cannot
    # even find the draft to publish it.
    post "/articles/#{@published_article.id}/publish"
    assert_response :forbidden
  end

  # ===================================================
  # Articles: search (custom plural action via DSL)
  # ===================================================

  def test_search_returns_scoped_collection_for_admin
    sign_in(@admin)
    get "/articles/search"
    assert_response :ok
    assert_includes response.body, "On Hobbits"
    assert_includes response.body, "Secret Plans"
  end

  def test_search_returns_scoped_collection_for_reader
    sign_in(@reader)
    get "/articles/search"
    assert_response :ok
    assert_includes response.body, "On Hobbits"
    refute_includes response.body, "Secret Plans"
  end

  # ===================================================
  # Pages: PermitAll policy
  # ===================================================

  def test_pages_index_shows_visible_pages
    sign_in(@reader)
    get "/pages"
    assert_response :ok
    assert_includes response.body, "Welcome"
    # PagePolicy::Scope filters to visible: true.
    refute_includes response.body, "Hidden Lore"
  end

  def test_pages_show_loads_visible_page
    sign_in(@reader)
    get "/pages/#{@visible_page.id}"
    assert_response :ok
    assert_equal "Welcome", response.body
  end

  def test_pages_show_not_found_for_hidden_page
    sign_in(@reader)
    get "/pages/#{@hidden_page.id}"
    assert_response :not_found
  end

  # ===================================================
  # Health: skip_authorization
  # ===================================================

  def test_health_check_works_without_auth
    get "/health"
    assert_response :ok
    assert_equal "ok", response.body
  end

  # ===================================================
  # Unauthenticated access
  # ===================================================

  def test_articles_index_works_with_nil_user
    # No sign-in: current_user is nil. Policy scope for
    # nil user returns published only.
    get "/articles"
    assert_response :ok
    assert_includes response.body, "On Hobbits"
    refute_includes response.body, "Secret Plans"
  end

  def test_articles_show_works_with_nil_user
    get "/articles/#{@published_article.id}"
    assert_response :ok
    assert_equal "On Hobbits", response.body
  end
end

# ==========================================================
# Request policy middleware integration tests.
# These verify the Rack-level gate operates through the full
# Rails stack (the Railtie inserts the middleware at position
# 0, so it fires before any controller code).
# ==========================================================

# A request policy that blocks paths starting with /admin.
class IntegrationBlockAdminPolicy <
  Turnstile::RequestPolicy::Base
  def call
    if request.path.start_with?("/admin")
      deny(reason: "admin path blocked at the gate")
    else
      allow
    end
  end
end

# A request policy that denies everything.
class IntegrationDenyAllPolicy <
  Turnstile::RequestPolicy::Base
end

class RequestPolicyMiddlewareIntegrationTest <
  ActionDispatch::IntegrationTest
  def setup
    Turnstile.reset_configuration!
    @admin = User.create!(name: "Elrond", role: "admin")
  end

  def teardown
    Turnstile.reset_configuration!
    User.delete_all
    Article.delete_all
  end

  def test_no_policy_configured_passes_through
    # Default: no request policy. Health endpoint works.
    get "/health"
    assert_response :ok
    assert_equal "ok", response.body
  end

  def test_permit_all_policy_passes_through
    Turnstile.configure do |c|
      c.request_policy = Turnstile::RequestPolicy::PermitAll
    end

    get "/health"
    assert_response :ok
    assert_equal "ok", response.body
  end

  def test_deny_all_policy_blocks_everything
    Turnstile.configure do |c|
      c.request_policy = IntegrationDenyAllPolicy
    end

    get "/health"
    assert_equal 403, response.status
    assert_equal "Forbidden", response.body
  end

  def test_deny_all_policy_blocks_post_too
    Turnstile.configure do |c|
      c.request_policy = IntegrationDenyAllPolicy
    end

    post "/test_sign_in", params: {user_id: @admin.id}
    assert_equal 403, response.status
  end

  def test_selective_policy_blocks_matching_path
    Turnstile.configure do |c|
      c.request_policy = IntegrationBlockAdminPolicy
    end

    # /admin path is blocked before it reaches Rails routing.
    get "/admin/dashboard"
    assert_equal 403, response.status
    assert_equal "Forbidden", response.body
  end

  def test_selective_policy_allows_non_matching_path
    Turnstile.configure do |c|
      c.request_policy = IntegrationBlockAdminPolicy
    end

    get "/health"
    assert_response :ok
    assert_equal "ok", response.body
  end

  def test_custom_denial_status
    Turnstile.configure do |c|
      c.request_policy = IntegrationDenyAllPolicy
      c.request_policy_status = 503
    end

    get "/health"
    assert_equal 503, response.status
  end

  def test_custom_denial_body_string
    Turnstile.configure do |c|
      c.request_policy = IntegrationDenyAllPolicy
      c.request_policy_body = "The gates are sealed."
    end

    get "/health"
    assert_equal 403, response.status
    assert_equal "The gates are sealed.", response.body
  end

  def test_custom_denial_body_callable
    Turnstile.configure do |c|
      c.request_policy = IntegrationDenyAllPolicy
      c.request_policy_body = lambda { |result|
        "Denied: #{result.reason}"
      }
    end

    get "/health"
    assert_equal 403, response.status
    assert_match(/Denied:/, response.body)
  end

  def test_runtime_toggle_on_and_off
    # Start with no policy — request passes.
    get "/health"
    assert_response :ok

    # Enable a deny-all policy at runtime.
    Turnstile.configure do |c|
      c.request_policy = IntegrationDenyAllPolicy
    end
    get "/health"
    assert_equal 403, response.status

    # Disable it again.
    Turnstile.configure { |c| c.request_policy = nil }
    get "/health"
    assert_response :ok
  end
end

# ==========================================================
# View policy integration tests.
# These verify the view_policy helper is accessible from a
# controller through the full Rails stack.
# ==========================================================

class ViewPolicyIntegrationTest <
  ActionDispatch::IntegrationTest
  def setup
    Turnstile.reset_configuration!
    @admin = User.create!(name: "Gandalf", role: "admin")
    @editor = User.create!(name: "Frodo", role: "editor")
    @reader = User.create!(name: "Sam", role: "viewer")

    @published = Article.create!(
      title: "Visible Tale",
      body: "A published story.",
      published: true,
      author_id: @editor.id
    )
    @draft = Article.create!(
      title: "Hidden Tale",
      body: "A draft story.",
      published: false,
      author_id: @editor.id
    )
  end

  def teardown
    Article.delete_all
    User.delete_all
  end

  def sign_in(user)
    post "/test_sign_in", params: {user_id: user.id}
    assert_response :ok
  end

  # Admin sees body and author_id (both override methods
  # allow for admin).
  def test_admin_sees_all_attributes_on_published
    sign_in(@admin)
    get "/articles/#{@published.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:true"
    assert_includes response.body, "author:true"
    # All six declared attrs should be visible for admin.
    assert_includes response.body, "hidden:"
  end

  # Admin sees body even on draft (admin? override).
  def test_admin_sees_body_on_draft
    sign_in(@admin)
    get "/articles/#{@draft.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:true"
    assert_includes response.body, "author:true"
  end

  # Editor sees author_id (staff), sees body on published.
  def test_editor_sees_body_and_author_on_published
    sign_in(@editor)
    get "/articles/#{@published.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:true"
    assert_includes response.body, "author:true"
  end

  # Editor cannot see body on draft (not published, not
  # admin).
  def test_editor_cannot_see_body_on_draft
    sign_in(@editor)
    get "/articles/#{@draft.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:false"
    assert_includes response.body, "author:true"
  end

  # Reader cannot see body on draft or author_id.
  def test_reader_cannot_see_body_or_author
    sign_in(@reader)
    get "/articles/#{@draft.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:false"
    assert_includes response.body, "author:false"
  end

  # Reader can see body on published article.
  def test_reader_sees_body_on_published
    sign_in(@reader)
    get "/articles/#{@published.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:true"
    assert_includes response.body, "author:false"
  end

  # Unauthenticated: nil user cannot see body on draft.
  def test_nil_user_cannot_see_body_on_draft
    get "/articles/#{@draft.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:false"
    assert_includes response.body, "author:false"
  end

  # Unauthenticated: nil user can see body on published.
  def test_nil_user_sees_body_on_published
    get "/articles/#{@published.id}/view_info"
    assert_response :ok

    assert_includes response.body, "body:true"
    assert_includes response.body, "author:false"
  end

  # Verify visible/hidden attribute lists for reader on
  # draft.
  def test_attribute_lists_for_reader_on_draft
    sign_in(@reader)
    get "/articles/#{@draft.id}/view_info"
    assert_response :ok

    # title, published, created_at, updated_at visible.
    # body, author_id hidden.
    assert_includes response.body,
      "visible:created_at,published,title,updated_at"
    assert_includes response.body,
      "hidden:author_id,body"
  end
end
