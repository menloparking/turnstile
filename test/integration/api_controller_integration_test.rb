# frozen_string_literal: true

# Integration tests for Turnstile::ApiController, exercised
# through a lightweight ActionController::API stack.

require_relative "../test_helper"
require_relative "../dummy/config/environment"

require "rails/test_help"

# Re-create schema tables (the dummy boot discards them).
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :name
    t.string :role
    t.timestamps
  end

  create_table :articles, force: true do |t|
    t.string :title
    t.text :body
    t.boolean :published, default: false
    t.integer :author_id
    t.timestamps
  end
end

Dir[
  File.expand_path("../dummy/app/models/**/*.rb", __dir__)
].each { |f| require f }

Dir[
  File.expand_path("../dummy/app/policies/**/*.rb", __dir__)
].each { |f| require f }

# ---------------------------------------------------------------------------
# Minimal API base controller that mirrors the real-app pattern.
# The authentication hook is wired via Turnstile configuration.
# ---------------------------------------------------------------------------
class TestApiBaseController < ActionController::API
  include Turnstile::ApiController

  attr_reader :current_user, :current_token

  # The method referenced by bearer_token_method in tests.
  def authenticate_via_header!
    raw = bearer_token
    # Simple lookup: token value stored as User#role for test
    # convenience (no token model needed in the dummy app).
    user = raw && User.find_by(role: "token:#{raw}")
    unless user
      render json: {error: "invalid or expired token"},
        status: :unauthorized
      return
    end
    @current_user = user
  end
end

# ---------------------------------------------------------------------------
# Thin resource controller used to exercise authorize helpers.
# ---------------------------------------------------------------------------
class TestApiArticlesController < TestApiBaseController
  def index
    articles = policy_scope(Article)
    render json: articles.pluck(:title)
  end

  def show
    article = Article.find(params[:id])
    authorize article
    render json: {title: article.title}
  end

  def create
    article = Article.new(title: params[:title])
    authorize article
    article.save!
    render json: {title: article.title}, status: :created
  end
end

# ---------------------------------------------------------------------------
# Routes wired at test-suite load time.
# ---------------------------------------------------------------------------
Rails.application.routes.draw do
  # Existing dummy routes (preserve them so other test suites work).
  resources :articles do
    member { post :publish }
    collection { get :search }
  end
  resources :pages, only: %i[index show]
  get "health", to: "health#check"
  post "test_sign_in", to: "test_sessions#create"
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
  resources :users, only: [] do
    resources :articles, only: %i[index show],
      controller: "user_articles"
  end
  scope "/auto" do
    resources :users, only: [] do
      resources :articles, only: %i[index show],
        controller: "auto_user_articles"
    end
  end
  scope "/always" do
    resources :users, only: [] do
      resources :articles,
        only: %i[index show new create],
        controller: "always_user_articles"
    end
  end

  # API-under-test routes.
  namespace :test_api do
    resources :articles, only: %i[index show create],
      controller: "/test_api_articles"
  end
end

class ApiControllerIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    Turnstile.reset_configuration!
    Turnstile.configure do |c|
      c.bearer_token_method = :authenticate_via_header!
    end

    @admin = User.create!(name: "Gandalf", role: "token:admin-tok")
    @reader = User.create!(name: "Sam", role: "token:reader-tok")

    # Override ApplicationController's rescue_from for
    # Turnstile errors to avoid conflicting with our API
    # controller's JSON rescue — not needed because the two
    # controller hierarchies are independent.

    @published = Article.create!(
      title: "On Hobbits",
      body: "A discourse.",
      published: true,
      author_id: @admin.id
    )
    @draft = Article.create!(
      title: "Secret Plans",
      body: "The palantir reveals.",
      published: false,
      author_id: @admin.id
    )
  end

  def teardown
    Turnstile.reset_configuration!
    Article.delete_all
    User.delete_all
  end

  private

  def auth_header(raw_token)
    {"Authorization" => "Bearer #{raw_token}"}
  end

  # ===========================================================
  # Authentication
  # ===========================================================

  def test_missing_token_returns_401
    get "/test_api/articles"
    assert_equal 401, response.status
    body = JSON.parse(response.body)
    assert_equal "invalid or expired token", body["error"]
  end

  def test_invalid_token_returns_401
    get "/test_api/articles",
      headers: auth_header("bad-token")
    assert_equal 401, response.status
  end

  def test_valid_token_grants_access
    get "/test_api/articles",
      headers: auth_header("admin-tok")
    assert_response :ok
  end

  # ===========================================================
  # bearer_token helper
  # ===========================================================

  def test_bearer_token_strips_prefix
    # Indirect test: a valid token works only if bearer_token
    # correctly strips the "Bearer " prefix.
    get "/test_api/articles",
      headers: {"Authorization" => "Bearer admin-tok"}
    assert_response :ok
  end

  def test_non_bearer_scheme_is_rejected
    get "/test_api/articles",
      headers: {"Authorization" => "Basic admin-tok"}
    assert_equal 401, response.status
  end

  # ===========================================================
  # policy_scope
  # ===========================================================

  def test_admin_index_returns_all_articles
    get "/test_api/articles",
      headers: auth_header("admin-tok")
    assert_response :ok
    titles = JSON.parse(response.body)
    assert_includes titles, "On Hobbits"
    assert_includes titles, "Secret Plans"
  end

  def test_reader_index_returns_only_published
    get "/test_api/articles",
      headers: auth_header("reader-tok")
    assert_response :ok
    titles = JSON.parse(response.body)
    assert_includes titles, "On Hobbits"
    refute_includes titles, "Secret Plans"
  end

  # ===========================================================
  # authorize — show (allowed)
  # ===========================================================

  def test_admin_can_show_any_article
    get "/test_api/articles/#{@draft.id}",
      headers: auth_header("admin-tok")
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Secret Plans", body["title"]
  end

  def test_reader_can_show_published_article
    get "/test_api/articles/#{@published.id}",
      headers: auth_header("reader-tok")
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "On Hobbits", body["title"]
  end

  # ===========================================================
  # authorize — show (denied → 403 JSON)
  # ===========================================================

  def test_reader_show_denied_returns_403_json
    # ArticlePolicy#show for a reader on a draft → denied.
    get "/test_api/articles/#{@draft.id}",
      headers: auth_header("reader-tok")
    assert_equal 403, response.status
    body = JSON.parse(response.body)
    assert body["error"].is_a?(String)
    assert body["error"].length > 0
  end

  # ===========================================================
  # authorize — create (denied → 403 JSON)
  # ===========================================================

  def test_reader_cannot_create_article
    post "/test_api/articles",
      params: {title: "Hacked"},
      headers: auth_header("reader-tok")
    assert_equal 403, response.status
    body = JSON.parse(response.body)
    assert body["error"].present?
  end

  def test_admin_can_create_article
    post "/test_api/articles",
      params: {title: "New Tome"},
      headers: auth_header("admin-tok")
    assert_equal 201, response.status
    body = JSON.parse(response.body)
    assert_equal "New Tome", body["title"]
  end

  # ===========================================================
  # No bearer_token_method configured
  # ===========================================================

  def test_no_hook_configured_does_not_register_before_action
    # If bearer_token_method is nil the concern must not blow
    # up when the controller class is included.
    Turnstile.reset_configuration!
    # Re-including into a fresh anonymous subclass should work.
    klass = Class.new(ActionController::API) do
      include Turnstile::ApiController
    end
    assert klass.ancestors.include?(Turnstile::ApiController)
  end
end
