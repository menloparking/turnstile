# frozen_string_literal: true

class ArticleContextPolicy < Turnstile::Authorization::ContextPolicy
  general_policy ArticlePolicy

  permission :update, contextual: true,
    description: "edit with attribute restrictions",
    parameters: [:changed_attributes]

  def update?
    base_result = general_policy_for_record.update?
    return base_result if base_result.denied?

    changed = context.params
      .fetch(:article, {}).keys.map(&:to_sym)
    forbidden = changed & %i[published author_id]

    if forbidden.any? && !user&.admin?
      deny(:update,
        reason: "cannot modify #{forbidden.join(", ")}")
    else
      allow(:update)
    end
  end
end
