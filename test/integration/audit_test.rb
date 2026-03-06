# frozen_string_literal: true

# Integration tests for Turnstile::Audit — the static
# analysis module that inspects routes and controllers to
# report authorization coverage.

require_relative "../test_helper"
require_relative "../dummy/config/environment"

require "rails/test_help"
require "turnstile/audit"

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

# --- Stub controllers for audit testing ---

# A fully-covered controller: every action is either
# auto-loaded, custom-loaded, or skip-authorized.
class AuditFullController < ApplicationController
  include Turnstile::Controller

  resource_class Article
  skip_loading :create, :dashboard
  skip_authorization :dashboard

  load_resource(:transfer) { |_c| {"@article": nil} }

  def index = head(:ok)

  def show = head(:ok)

  def create = head(:ok)

  def dashboard = head(:ok)

  def transfer = head(:ok)
end

# A controller with a gap: the custom action "forgot"
# is skip-loaded but has no skip_authorization and no
# custom loader — the audit should flag it.
class AuditGapController < ApplicationController
  include Turnstile::Controller

  resource_class Article
  skip_loading :forgot

  def index = head(:ok)

  def show = head(:ok)

  def forgot = head(:ok)
end

# A non-Turnstile controller. The audit must ignore it.
class AuditPlainController < ApplicationController
  def index = head(:ok)
end

class AuditTest < ActionDispatch::IntegrationTest
  def setup
    Turnstile.reset_configuration!
    draw_audit_routes
  end

  def teardown
    Turnstile.reset_configuration!
    restore_canonical_routes
  end

  # ===================================================
  # Audit.run — entry analysis
  # ===================================================

  def test_run_returns_sorted_entries
    entries = Turnstile::Audit.run
    names = entries.map { |e|
      "#{e.controller}##{e.action}"
    }
    assert_equal names, names.sort
  end

  def test_run_excludes_non_turnstile_controllers
    entries = Turnstile::Audit.run
    controllers = entries.map(&:controller).uniq
    refute_includes controllers, "AuditPlainController"
  end

  def test_run_includes_turnstile_controllers
    entries = Turnstile::Audit.run
    controllers = entries.map(&:controller).uniq
    assert_includes controllers, "AuditFullController"
    assert_includes controllers, "AuditGapController"
  end

  # ===================================================
  # Covered actions: auto-loaded
  # ===================================================

  def test_auto_loaded_show_is_ok
    entry = find_entry("AuditFullController", :show)
    assert_equal :ok, entry.status
    assert_includes entry.reason, "auto-loaded"
  end

  def test_auto_loaded_index_is_ok
    entry = find_entry("AuditFullController", :index)
    assert_equal :ok, entry.status
    assert_includes entry.reason, "auto-loaded"
  end

  # ===================================================
  # Covered actions: skip_authorization declared
  # ===================================================

  def test_skip_authorization_action_is_ok
    entry = find_entry("AuditFullController", :dashboard)
    assert_equal :ok, entry.status
    assert_includes entry.reason, "skip_authorization"
  end

  # ===================================================
  # Covered actions: custom loader registered
  # ===================================================

  def test_custom_loader_action_is_ok
    entry = find_entry("AuditFullController", :transfer)
    assert_equal :ok, entry.status
    assert_includes entry.reason, "custom loader"
  end

  # ===================================================
  # Unverified: skip-loaded without skip_authorization
  # ===================================================

  def test_create_without_skip_auth_is_unverified
    entry = find_entry("AuditFullController", :create)
    assert_equal :unverified, entry.status
    assert_includes entry.reason, "manual authorize"
  end

  def test_gap_action_is_unverified
    entry = find_entry("AuditGapController", :forgot)
    assert_equal :unverified, entry.status
    assert_includes entry.reason, "manual authorize"
  end

  # ===================================================
  # Deduplication: multiple HTTP verbs for one action
  # ===================================================

  def test_no_duplicate_entries
    entries = Turnstile::Audit.run
    keys = entries.map { |e|
      "#{e.controller}##{e.action}"
    }
    assert_equal keys, keys.uniq
  end

  # ===================================================
  # Entry#to_s formatting
  # ===================================================

  def test_entry_to_s_ok_format
    entry = Turnstile::Audit::Entry.new(
      controller: "FooController",
      action: :index,
      status: :ok,
      reason: "auto-loaded and authorized"
    )
    str = entry.to_s
    assert_includes str, "FooController#index"
    assert_includes str, "covered"
    assert_includes str, "auto-loaded"
  end

  def test_entry_to_s_unverified_format
    entry = Turnstile::Audit::Entry.new(
      controller: "FooController",
      action: :create,
      status: :unverified,
      reason: "no auto-load; needs manual authorize"
    )
    str = entry.to_s
    assert_includes str, "FooController#create"
    assert_includes str, "UNVERIFIED"
    assert_includes str, "manual authorize"
  end

  # ===================================================
  # Audit.report — formatted output
  # ===================================================

  def test_report_returns_false_when_unverified_exist
    io = StringIO.new
    result = Turnstile::Audit.report(io: io)
    refute result
  end

  def test_report_prints_header
    io = StringIO.new
    Turnstile::Audit.report(io: io)
    output = io.string
    assert_includes output,
      "Turnstile Authorization Audit"
  end

  def test_report_lists_unverified_actions
    io = StringIO.new
    Turnstile::Audit.report(io: io)
    output = io.string
    assert_includes output, "UNVERIFIED"
    assert_includes output, "AuditGapController#forgot"
  end

  def test_report_lists_ok_actions
    io = StringIO.new
    Turnstile::Audit.report(io: io)
    output = io.string
    assert_includes output, "OK"
    assert_includes output, "AuditFullController#show"
  end

  def test_report_prints_summary_line
    io = StringIO.new
    Turnstile::Audit.report(io: io)
    output = io.string
    assert_match(/\d+ actions.*\d+ covered.*\d+ unverified/,
      output)
  end

  def test_report_returns_true_when_all_covered
    # Draw routes with only the fully-covered controller,
    # minus the create action which is unverified.
    Rails.application.routes.draw do
      resources :audit_full, only: %i[index show] do
        member { get :transfer }
      end
      get "audit_full/dashboard",
        to: "audit_full#dashboard"
    end

    io = StringIO.new
    result = Turnstile::Audit.report(io: io)
    assert result
  ensure
    draw_audit_routes
  end

  def test_report_handles_no_turnstile_controllers
    Rails.application.routes.draw do
      resources :audit_plain, only: [:index]
    end

    io = StringIO.new
    result = Turnstile::Audit.report(io: io)
    assert result
    assert_includes io.string, "No Turnstile controllers"
  ensure
    draw_audit_routes
  end

  private

  def draw_audit_routes
    Rails.application.routes.draw do
      resources :audit_full, only: %i[index show create] do
        member do
          get :transfer
        end
      end
      get "audit_full/dashboard",
        to: "audit_full#dashboard"

      resources :audit_gap, only: %i[index show]
      get "audit_gap/forgot",
        to: "audit_gap#forgot"

      resources :audit_plain, only: [:index]
    end
  end

  def find_entry(controller, action)
    entries = Turnstile::Audit.run
    entry = entries.find { |e|
      e.controller == controller &&
        e.action == action
    }
    assert entry,
      "expected entry for #{controller}##{action}"
    entry
  end

  # Redraw the canonical superset of routes so that other
  # integration test classes (loaded from different files)
  # still have their routes available after audit tests.
  def restore_canonical_routes
    Rails.application.routes.draw do
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
        resources :verified_articles,
          only: %i[index show create]
      end

      scope "/unverified" do
        get "unverified_articles/forgot",
          to: "unverified_articles#forgot",
          as: :unverified_articles_forgot
      end
    end
  end
end
