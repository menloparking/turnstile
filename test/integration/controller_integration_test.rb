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

  create_table :widgets, force: true do |t|
    t.string :label
    t.text :description
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

  # Test-only routes for presentation verification.
  get "articles/:id/present_info",
    to: "article_present#show",
    as: :article_present_info
  get "articles_present_index",
    to: "article_present#index",
    as: :article_present_index
  get "articles/:id/present_lenient",
    to: "article_present#lenient",
    as: :article_present_lenient
  get "articles/:id/present_skip",
    to: "article_present_skip#show",
    as: :article_present_skip
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
# Presentation integration tests.
# These verify that the auto-presentation step wraps
# resources in Presented/PresentedCollection for read
# actions, and that write actions receive raw AR records.
# ==========================================================

# Controller that exposes presentation internals through
# the response body for test inspection.
class ArticlePresentController < ApplicationController
  include Turnstile::Controller

  resource_class Article
  skip_authorization :show, :index, :lenient
  skip_loading :lenient

  def show
    lines = []
    lines << "class:#{@article.class.name}"
    lines << "presented:#{@article.is_a?(Turnstile::Presented)}"
    lines << "title:#{@article.title}"

    # In strict mode (default), accessing a denied
    # attribute raises; rescue it to report the denial.
    begin
      body_val = @article.body
      lines << "body:#{body_val}"
    rescue Turnstile::AttributeDeniedError
      lines << "body:DENIED"
    end

    begin
      author_val = @article.author_id
      lines << "author_id:#{author_val}"
    rescue Turnstile::AttributeDeniedError
      lines << "author_id:DENIED"
    end

    lines << "unwrap:#{@article.respond_to?(:unwrap)}"
    render plain: lines.join("\n")
  end

  def index
    lines = []
    first = @articles.first
    lines << "collection:#{@articles.class.name}"
    lines << "presented_collection:" \
      "#{@articles.is_a?(Turnstile::PresentedCollection)}"
    if first
      lines << "element_presented:" \
        "#{first.is_a?(Turnstile::Presented)}"
      lines << "first_title:#{first.title}"
    end
    lines << "size:#{@articles.size}"
    render plain: lines.join("\n")
  end

  def lenient
    # Switch to lenient mode for this request.
    Turnstile.configuration.presented_mode = :lenient

    @article = Turnstile::Presented.new(
      Article.find(params[:id]),
      current_user
    )

    lines = []
    lines << "title:#{@article.title}"
    lines << "body:#{@article.body.inspect}"
    lines << "author_id:#{@article.author_id.inspect}"
    render plain: lines.join("\n")
  ensure
    Turnstile.configuration.presented_mode = :strict
  end
end

# Controller that skips presentation to verify the
# skip_presentation DSL.
class ArticlePresentSkipController < ApplicationController
  include Turnstile::Controller

  resource_class Article
  skip_authorization :show
  skip_presentation :show

  def show
    lines = []
    lines << "class:#{@article.class.name}"
    lines << "presented:#{@article.is_a?(Turnstile::Presented)}"
    lines << "title:#{@article.title}"
    lines << "body:#{@article.body}"
    render plain: lines.join("\n")
  end
end

class PresentationIntegrationTest <
  ActionDispatch::IntegrationTest
  def setup
    Turnstile.reset_configuration!

    @admin = User.create!(name: "Gandalf", role: "admin")
    @editor = User.create!(name: "Frodo", role: "editor")
    @reader = User.create!(name: "Sam", role: "viewer")

    @published = Article.create!(
      title: "On Hobbits",
      body: "A discourse on halflings.",
      published: true,
      author_id: @editor.id
    )
    @draft = Article.create!(
      title: "Secret Plans",
      body: "The palantir reveals.",
      published: false,
      author_id: @editor.id
    )
  end

  def teardown
    Turnstile.reset_configuration!
    Article.delete_all
    User.delete_all
  end

  def sign_in(user)
    post "/test_sign_in", params: {user_id: user.id}
    assert_response :ok
  end

  # ===================================================
  # show: Presented wrapping on singular records
  # ===================================================

  def test_show_wraps_record_in_presented
    sign_in(@admin)
    get "/articles/#{@published.id}/present_info"
    assert_response :ok

    # The record reports its native class for polymorphic
    # compatibility, but is_a?(Presented) is true too.
    assert_includes response.body, "presented:true"
    assert_includes response.body, "unwrap:true"
    assert_includes response.body, "title:On Hobbits"
  end

  def test_show_guards_hidden_attributes_for_reader
    sign_in(@reader)
    # Reader can load published articles (scope filters
    # out drafts). author_id is hidden for non-staff.
    get "/articles/#{@published.id}/present_info"
    assert_response :ok

    # body is visible on published articles.
    assert_includes response.body,
      "body:A discourse on halflings."
    # author_id is hidden for non-staff.
    assert_includes response.body, "author_id:DENIED"
    # title is visible by default.
    assert_includes response.body, "title:On Hobbits"
  end

  def test_show_allows_hidden_attributes_for_admin
    sign_in(@admin)
    get "/articles/#{@draft.id}/present_info"
    assert_response :ok

    # Admin sees everything.
    assert_includes response.body,
      "body:The palantir reveals."
    assert_includes response.body,
      "author_id:#{@editor.id}"
  end

  def test_show_allows_body_on_published_for_reader
    sign_in(@reader)
    get "/articles/#{@published.id}/present_info"
    assert_response :ok

    # body is visible when the article is published.
    assert_includes response.body,
      "body:A discourse on halflings."
    # author_id is still hidden for non-staff.
    assert_includes response.body, "author_id:DENIED"
  end

  # ===================================================
  # index: PresentedCollection wrapping
  # ===================================================

  def test_index_wraps_collection_in_presented_collection
    sign_in(@admin)
    get "/articles_present_index"
    assert_response :ok

    assert_includes response.body,
      "presented_collection:true"
    assert_includes response.body,
      "element_presented:true"
  end

  def test_index_collection_size_delegates_to_relation
    sign_in(@admin)
    get "/articles_present_index"
    assert_response :ok

    # Admin sees both published and draft.
    assert_includes response.body, "size:2"
  end

  def test_index_collection_scoped_for_reader
    sign_in(@reader)
    get "/articles_present_index"
    assert_response :ok

    # Policy scope filters to published only.
    assert_includes response.body, "size:1"
    assert_includes response.body,
      "first_title:On Hobbits"
  end

  # ===================================================
  # Write actions: NO presentation wrapping
  # ===================================================

  def test_update_receives_raw_record_not_presented
    sign_in(@admin)
    # The normal articles#update gets the raw record
    # because update is a write action.
    patch "/articles/#{@published.id}",
      params: {article: {title: "Updated"}}
    assert_response :ok
    # If the record were Presented and body was denied,
    # the response would fail. The raw record renders
    # fine.
    assert_includes response.body, "updated:"
  end

  def test_destroy_receives_raw_record
    sign_in(@admin)
    article = Article.create!(
      title: "Doomed", published: true
    )
    delete "/articles/#{article.id}"
    assert_response :ok
    assert_equal "destroyed", response.body
  end

  # ===================================================
  # skip_presentation DSL
  # ===================================================

  def test_skip_presentation_delivers_raw_record
    sign_in(@reader)
    get "/articles/#{@published.id}/present_skip"
    assert_response :ok

    # Not wrapped, so presented is false and body is
    # accessible without policy guard.
    assert_includes response.body, "presented:false"
    assert_includes response.body,
      "body:A discourse on halflings."
  end

  # ===================================================
  # Lenient mode: nil instead of raising
  # ===================================================

  def test_lenient_mode_returns_nil_for_denied_attrs
    sign_in(@reader)
    get "/articles/#{@draft.id}/present_lenient"
    assert_response :ok

    # title is visible.
    assert_includes response.body,
      "title:Secret Plans"
    # body and author_id denied: nil in lenient mode.
    assert_includes response.body, "body:nil"
    assert_includes response.body, "author_id:nil"
  end

  # ===================================================
  # Unauthenticated (nil user) presentation
  # ===================================================

  def test_nil_user_gets_presented_with_guarding
    # No sign-in: current_user is nil. Nil user can
    # only load published articles (scope filters drafts).
    # author_id is hidden for nil users.
    get "/articles/#{@published.id}/present_info"
    assert_response :ok

    assert_includes response.body, "presented:true"
    # body is visible on published articles.
    assert_includes response.body,
      "body:A discourse on halflings."
    # author_id is hidden for non-staff.
    assert_includes response.body, "author_id:DENIED"
    assert_includes response.body, "title:On Hobbits"
  end

  def test_nil_user_sees_body_on_published
    get "/articles/#{@published.id}/present_info"
    assert_response :ok

    assert_includes response.body,
      "body:A discourse on halflings."
    assert_includes response.body, "author_id:DENIED"
  end
end
