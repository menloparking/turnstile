# frozen_string_literal: true

class PagePolicy < Turnstile::Authorization::PermitAll
  class Scope < Turnstile::Authorization::Policy::Scope
    def resolve = scope.where(visible: true)
  end
end
