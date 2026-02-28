# frozen_string_literal: true

require_relative "authorization/result"
require_relative "authorization/permission_info"
require_relative "authorization/reflection"
require_relative "authorization/policy"
require_relative "authorization/permit_all"
require_relative "authorization/request_context"
require_relative "authorization/context_policy"
require_relative "authorization/view_policy"
require_relative "authorization/resolver"

module Turnstile
  # The Authorization subsystem provides three tiers of policy:
  #
  # 1. *General policies* (Policy) — context-free, model-level
  #    authorization. "Can user X do Y to record Z?"
  # 2. *Context policies* (ContextPolicy) — request-aware
  #    refinements. "Given this HTTP request, can user X do Y
  #    to record Z with these parameters?"
  # 3. *View policies* (ViewPolicy) — visibility decisions.
  #    "Should user X see field F of record Z?"
  #
  # All policies default to deny-all and expose a reflection
  # API for enumerating their permissions and metadata.
  module Authorization
    module_function

    # Authorize a user against a record using the general
    # policy. Returns the Result; raises on denial when
    # bang: true.
    def authorize(user, record, permission, bang: true)
      klass = Resolver.resolve!(record, type: :general)
      policy = klass.new(user, record)
      result = policy.public_send(:"#{permission}?")
      handle_result(result, user, record, permission, klass,
        bang: bang)
    end

    # Authorize with request context using the context policy.
    # Falls back to the general policy if no context policy
    # exists.
    def authorize_in_context(user, record, permission,
      context, bang: true)
      klass = Resolver.resolve(record, type: :context)
      if klass
        policy = klass.new(user, record, context)
      else
        klass = Resolver.resolve!(record, type: :general)
        policy = klass.new(user, record)
      end
      result = policy.public_send(:"#{permission}?")
      handle_result(result, user, record, permission, klass,
        bang: bang)
    end

    # Query a view policy. Returns the Result.
    def authorize_view(user, record, permission, bang: false)
      klass = Resolver.resolve(record, type: :view)
      return nil unless klass

      policy = klass.new(user, record)
      result = policy.public_send(:"#{permission}?")
      handle_result(result, user, record, permission, klass,
        bang: bang)
    end

    # Return an instantiated general policy for ad-hoc use.
    def policy_for(user, record)
      klass = Resolver.resolve!(record, type: :general)
      klass.new(user, record)
    end

    # Return an instantiated view policy for ad-hoc use.
    # Returns nil when no view policy is defined for the
    # record's class.
    def view_policy_for(user, record)
      klass = Resolver.resolve(record, type: :view)
      return nil unless klass

      klass.new(user, record)
    end

    # Return a resolved scope.
    def policy_scope(user, scope)
      klass = Resolver.resolve!(scope, type: :general)
      scope_klass = klass.const_get(:Scope)
      scope_klass.new(user, scope).resolve
    end

    # @api private
    def handle_result(result, user, record, permission,
      policy_class, bang: true)
      if result.denied?
        Turnstile.logger.info(
          "[Turnstile] denied #{permission} on " \
          "#{record.class} for #{user.class}" \
          "#{": #{result.reason}" if result.reason}"
        )
        if bang
          raise NotAuthorizedError.new(
            user: user,
            record: record,
            permission: permission,
            policy: policy_class,
            reason: result.reason
          )
        end
      else
        Turnstile.logger.debug(
          "[Turnstile] allowed #{permission} on " \
          "#{record.class} for #{user.class}"
        )
      end
      result
    end
  end
end
