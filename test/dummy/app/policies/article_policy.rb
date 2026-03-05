# frozen_string_literal: true

class ArticlePolicy < Turnstile::Authorization::Policy
  permission :archive, description: "archive an article"
  permission :publish, description: "publish an article"

  def index? = allow

  def search? = allow

  def show? = allow

  def create?
    if user&.admin? || user&.editor?
      allow
    else
      deny(reason: "only admins and editors may create")
    end
  end

  def update?
    if user&.admin?
      allow
    elsif user&.editor? &&
        record.respond_to?(:author_id) &&
        record.author_id == user.id
      allow
    else
      deny(reason: "you do not own this article")
    end
  end

  def destroy?
    if user&.admin?
      allow
    else
      deny(
        reason: "only admins may destroy articles"
      )
    end
  end

  def publish?
    if user&.admin? || user&.editor?
      allow
    else
      deny(reason: "insufficient role")
    end
  end

  def archive? = deny(reason: "archiving disabled")

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
