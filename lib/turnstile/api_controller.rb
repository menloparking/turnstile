# frozen_string_literal: true

require "active_support/concern"

module Turnstile
  # Controller concern for API controllers that authenticate
  # via Bearer token instead of a session.
  #
  # Include this in your API base controller to gain:
  # - Bearer token extraction from the Authorization header
  # - Configurable token authentication via a hook method
  # - NotAuthorizedError rescue → 403 JSON
  # - The same authorize / policy / policy_scope helpers as
  #   Turnstile::Controller, but without resource auto-loading
  #   or presentation (APIs return raw data, not view objects)
  #
  # == Minimal usage
  #
  #   class Api::BaseController < ActionController::API
  #     include Turnstile::ApiController
  #   end
  #
  # You must configure the authentication hook:
  #
  #   Turnstile.configure do |c|
  #     c.bearer_token_method = :authenticate_bearer!
  #   end
  #
  # The method named by +bearer_token_method+ is called as a
  # before_action.  It is responsible for setting whatever
  # current-user ivar your app uses (e.g. @current_user) and
  # for halting the filter chain (render + return) when the
  # token is invalid or absent.  The concern does not impose
  # a particular authentication strategy; it only wires the
  # hook and provides +bearer_token+ as a convenience.
  #
  # If +bearer_token_method+ is nil (the default), no
  # authentication before_action is registered and you must
  # wire your own.
  #
  # == Authorization helpers
  #
  # The same +authorize+, +authorize_without_context+,
  # +policy+, and +policy_scope+ helpers from
  # Turnstile::Controller are available.  They call
  # +turnstile_user+, which delegates to
  # +current_user_method+ (default :current_user).
  #
  # == Error handling
  #
  #   rescue_from Turnstile::NotAuthorizedError,
  #     with: :turnstile_api_not_authorized
  #
  # renders { error: "..." } with status 403.  Override
  # +turnstile_api_not_authorized+ in your controller if you
  # need a different shape.
  #
  module ApiController
    extend ActiveSupport::Concern

    included do
      cfg = Turnstile.configuration
      if cfg.bearer_token_method
        before_action cfg.bearer_token_method
      end

      rescue_from Turnstile::NotAuthorizedError,
        with: :turnstile_api_not_authorized
    end

    # Manually authorize a record.  Permission defaults to
    # the current action name.
    def authorize(record, permission = nil, **opts)
      permission ||= action_name.to_sym
      ctx = build_request_context
      Authorization.authorize_in_context(
        turnstile_user, record, permission, ctx, **opts
      )
    end

    # Authorize without request context.
    def authorize_without_context(record, permission = nil,
      **opts)
      permission ||= action_name.to_sym
      Authorization.authorize(
        turnstile_user, record, permission, **opts
      )
    end

    # Instantiate a policy for ad-hoc queries.
    def policy(record)
      Authorization.policy_for(turnstile_user, record)
    end

    # Apply a policy scope to a relation.
    def policy_scope(scope)
      Authorization.policy_scope(turnstile_user, scope)
    end

    # Extract the raw Bearer token from the Authorization
    # header, or nil if absent or malformed.
    def bearer_token
      header = request.headers["Authorization"]
      header&.start_with?("Bearer ") ?
        header.delete_prefix("Bearer ") : nil
    end

    private

    def turnstile_user
      public_send(
        Turnstile.configuration.current_user_method
      )
    end

    def build_request_context
      Authorization::RequestContext.new(
        request: request,
        params: params,
        action_name: action_name,
        controller_name: controller_name
      )
    end

    # Default 403 handler for NotAuthorizedError.
    # Override in your controller for a custom response shape.
    def turnstile_api_not_authorized(err)
      render json: {error: err.message}, status: :forbidden
    end

    module ClassMethods
    end
  end
end
