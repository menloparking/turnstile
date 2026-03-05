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

  create_table :widgets, force: true do |t|
    t.string :label
    t.text :description
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

class Page < ActiveRecord::Base; end

class Widget < ActiveRecord::Base; end

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

  # Attribute visibility via _allowed? convention.
  # DenyAll: attributes without an _allowed? method are
  # hidden by default in Presented.

  def title_allowed? = allow(:title_allowed)

  def published_allowed? = allow(:published_allowed)

  def created_at_allowed? = allow(:created_at_allowed)

  def updated_at_allowed? = allow(:updated_at_allowed)

  def body_allowed?
    if record.respond_to?(:published?) && record.published? ||
        user&.admin?
      allow(:body_allowed)
    else
      deny(:body_allowed,
        reason: "article not yet published")
    end
  end

  def author_id_allowed?
    if user&.admin? || user&.editor?
      allow(:author_id_allowed)
    else
      deny(:author_id_allowed,
        reason: "restricted to staff")
    end
  end

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

# WidgetPolicy inherits from Policy (not PermitAll), with
# no _allowed? methods. Every column attribute is denied by
# default in Presented — pure DenyAll. Used to test the
# DenyAll behavior for attributes without _allowed? methods.
class WidgetPolicy < Turnstile::Authorization::Policy; end

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

# Reset configuration before each test.
module TurnstileTestSetup
  def setup
    super
    Turnstile.reset_configuration!
  end
end
