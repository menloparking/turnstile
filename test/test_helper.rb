# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "active_record"
require "action_controller"
require "action_dispatch"
require "minitest/autorun"
require "turnstile"

# In-memory SQLite database for tests.
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

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

# Minimal models.
class Article < ActiveRecord::Base
  belongs_to :author, class_name: "User", optional: true
end

class User < ActiveRecord::Base
  def admin? = role == "admin"

  def editor? = role == "editor"

  def hr? = role == "hr"
end

# --- Policies used across tests ---

class ArticlePolicy < Turnstile::Authorization::Policy
  permission :publish,
    description: "publish an article"
  permission :archive,
    description: "archive an article"

  def index? = allow(:index)

  def show? = allow(:show)

  def create?
    if user&.admin? || user&.editor?
      allow(:create)
    else
      deny(:create,
        reason: "only admins and editors may create")
    end
  end

  def update?
    if user&.admin?
      allow(:update)
    elsif user&.editor? && record.respond_to?(:author_id) &&
        record.author_id == user.id
      allow(:update)
    else
      deny(:update,
        reason: "you do not own this article")
    end
  end

  def destroy?
    if user&.admin?
      allow(:destroy)
    else
      deny(:destroy,
        reason: "only admins may destroy articles")
    end
  end

  def publish?
    if user&.admin? || user&.editor?
      allow(:publish)
    else
      deny(:publish, reason: "insufficient role")
    end
  end

  def archive? = deny(:archive, reason: "archiving disabled")

  class Scope < Turnstile::Authorization::Policy::Scope
    def resolve
      if user&.admin?
        scope.all
      else
        scope.where(published: true)
      end
    end
  end
end

class ArticleContextPolicy <
  Turnstile::Authorization::ContextPolicy
  general_policy ArticlePolicy

  permission :update, contextual: true,
    description: "edit with attribute restrictions",
    parameters: [:changed_attributes]

  def update?
    base_policy = ArticlePolicy.new(user, record)
    base_result = base_policy.update?
    return base_result if base_result.denied?

    changed = context.params.fetch(:article, {}).keys
      .map(&:to_sym)
    forbidden = changed & %i[published author_id]

    if forbidden.any? && !user&.admin?
      deny(:update,
        reason: "cannot modify #{forbidden.join(", ")}")
    else
      allow(:update)
    end
  end
end

class ArticleViewPolicy <
  Turnstile::Authorization::ViewPolicy
  permission :show_author,
    description: "see author details"
  permission :show_body,
    description: "see full article body"

  # Attribute visibility declarations.
  attribute :title, default: :visible
  attribute :body, default: :hidden
  attribute :published, default: :visible
  attribute :author_id, default: :hidden
  attribute :created_at, default: :visible
  attribute :updated_at, default: :visible

  def show_author?
    if user&.admin? || user&.editor?
      allow(:show_author)
    else
      deny(:show_author,
        reason: "restricted to staff")
    end
  end

  def show_body?
    if record.respond_to?(:published?) && record.published? ||
        user&.admin?
      allow(:show_body)
    else
      deny(:show_body,
        reason: "article not yet published")
    end
  end

  # Override the default-hidden body attribute: same rule
  # as show_body? permission.
  def body_visible?
    show_body?
  end

  # Override author_id: visible to staff.
  def author_id_visible?
    show_author?
  end
end

# Reset configuration before each test.
module TurnstileTestSetup
  def setup
    super
    Turnstile.reset_configuration!
  end
end
