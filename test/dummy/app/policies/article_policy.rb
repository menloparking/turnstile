# frozen_string_literal: true

class ArticlePolicy < Turnstile::Authorization::Policy
  permission :archive, description: "archive an article"
  permission :publish, description: "publish an article"

  def index? = allow(:index)

  def search? = allow(:search)

  def show? = allow(:show)

  def create?
    if user&.admin? || user&.editor?
      allow(:create)
    else
      deny(:create, reason: "only admins and editors may create")
    end
  end

  def update?
    if user&.admin?
      allow(:update)
    elsif user&.editor? &&
        record.respond_to?(:author_id) &&
        record.author_id == user.id
      allow(:update)
    else
      deny(:update, reason: "you do not own this article")
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
