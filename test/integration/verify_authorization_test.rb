# frozen_string_literal: true

# Integration tests for verify_authorization — the opt-in
# after_action that raises AuthorizationNotPerformedError
# when a controller action completes without calling
# authorize, skip_authorization, or being listed in
# skip_authorization at the class level.

require_relative "../test_helper"
require_relative "../dummy/config/environment"

require "rails/test_help"

# Re-create tables (the dummy env opens a fresh :memory: DB).
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
  File.expand_path(
    "../dummy/app/policies/**/*.rb", __dir__
  )
].each { |f| require f }

# A controller that opts in to verify_authorization.
# Auto-loaded actions (show, index) are covered by the
# before_action, but create (skip_loading) needs manual
# authorize.
class VerifiedArticlesController < ApplicationController
  include Turnstile::Controller

  resource_class Article
  verify_authorization

  skip_loading :create, :forgot, :health, :manual_skip
  skip_authorization :health

  def index
    render plain: @articles.map(&:title).join(", ")
  end

  def show
    render plain: @article.title
  end

  def create
    article = Article.new(title: "New")
    authorize(article, :create)
    render plain: "created", status: :created
  end

  # Forgets to call authorize — should raise.
  def forgot
    render plain: "oops"
  end

  # Class-level skip_authorization bypasses verify.
  def health
    render plain: "ok"
  end

  # Instance-level skip_authorization bypasses verify.
  def manual_skip
    skip_authorization
    render plain: "skipped"
  end
end

# A controller WITHOUT verify_authorization — forgetting
# to authorize should NOT raise.
class UnverifiedArticlesController < ApplicationController
  include Turnstile::Controller

  skip_loading :forgot

  def forgot
    render plain: "no error"
  end
end

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
  post "test_sign_in", to: "test_sessions#create"

  # Presentation test routes (from controller_integration).
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

  # Nested routes for parent resource tests.
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

  # Routes for verify_authorization tests. Custom member-
  # style routes must precede the resources block so that
  # /verified_articles/forgot is not swallowed by :show.
  scope "/verified" do
    get "verified_articles/forgot",
      to: "verified_articles#forgot",
      as: :verified_articles_forgot
    get "verified_articles/health",
      to: "verified_articles#health",
      as: :verified_articles_health
    get "verified_articles/manual_skip",
      to: "verified_articles#manual_skip",
      as: :verified_articles_manual_skip
    resources :verified_articles, only: %i[index show create]
  end

  scope "/unverified" do
    get "unverified_articles/forgot",
      to: "unverified_articles#forgot",
      as: :unverified_articles_forgot
  end
end

# Tiny controller for session setup in integration tests.
class TestSessionsController < ApplicationController
  skip_before_action :turnstile_load_and_authorize,
    raise: false

  def create
    session[:user_id] = params[:user_id]
    render plain: "signed in", status: :ok
  end
end

class VerifyAuthorizationTest <
  ActionDispatch::IntegrationTest
  def setup
    Turnstile.reset_configuration!
    @admin = User.create!(name: "Gandalf", role: "admin")
    @article = Article.create!(
      title: "On Hobbits",
      body: "A discourse.",
      published: true,
      author_id: @admin.id
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
  # Actions with automatic authorization pass
  # ===================================================

  def test_auto_loaded_show_passes_verification
    sign_in(@admin)
    get "/verified/verified_articles/#{@article.id}"
    assert_response :ok
    assert_equal "On Hobbits", response.body
  end

  def test_auto_loaded_index_passes_verification
    sign_in(@admin)
    get "/verified/verified_articles"
    assert_response :ok
    assert_includes response.body, "On Hobbits"
  end

  # ===================================================
  # Manual authorize passes verification
  # ===================================================

  def test_manual_authorize_passes_verification
    sign_in(@admin)
    post "/verified/verified_articles",
      params: {article: {title: "New", body: "Content"}}
    assert_response :created
    assert_equal "created", response.body
  end

  # ===================================================
  # Forgetting to authorize raises
  # ===================================================

  def test_forgot_authorize_raises_error
    sign_in(@admin)
    get "/verified/verified_articles/forgot"

    # The after_action raises AuthorizationNotPerformedError.
    # show_exceptions is :all in the dummy test env, so
    # Rails catches it and returns 500 instead of re-raising.
    assert_response :internal_server_error
  end

  # ===================================================
  # Class-level skip_authorization bypasses verify
  # ===================================================

  def test_class_skip_authorization_bypasses_verify
    sign_in(@admin)
    get "/verified/verified_articles/health"
    assert_response :ok
    assert_equal "ok", response.body
  end

  # ===================================================
  # Instance skip_authorization bypasses verify
  # ===================================================

  def test_instance_skip_authorization_bypasses_verify
    sign_in(@admin)
    get "/verified/verified_articles/manual_skip"
    assert_response :ok
    assert_equal "skipped", response.body
  end

  # ===================================================
  # Controller without verify_authorization is silent
  # ===================================================

  def test_unverified_controller_does_not_raise
    sign_in(@admin)
    get "/unverified/unverified_articles/forgot"
    assert_response :ok
    assert_equal "no error", response.body
  end
end
