# frozen_string_literal: true

class ArticleViewPolicy < Turnstile::Authorization::ViewPolicy
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
      deny(:show_author, reason: "restricted to staff")
    end
  end

  def show_body?
    if record.respond_to?(:published?) && record.published? ||
        user&.admin?
      allow(:show_body)
    else
      deny(:show_body, reason: "article not yet published")
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
