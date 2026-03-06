# frozen_string_literal: true

require "active_support/concern"

module Turnstile
  # Controller concern that weaves together resource loading and
  # layered authorization. Include this in your
  # ApplicationController (or specific controllers) to gain
  # automatic resource loading, authorization hooks, and the
  # DSL for customizing both.
  #
  # == Minimal usage
  #
  #   class ArticlesController < ApplicationController
  #     include Turnstile::Controller
  #   end
  #
  # This will:
  # - Infer the model class as Article
  # - Auto-load @article for show/edit/update/destroy
  # - Auto-load @articles for index (via policy scope)
  # - Authorize each loaded resource against the action
  # - Skip loading for new/create
  #
  # == Customization
  #
  #   class ArticlesController < ApplicationController
  #     include Turnstile::Controller
  #
  #     resource_class BlogPost
  #     resource_id_param :slug
  #     load_singular :publish, :archive
  #     skip_loading  :dashboard
  #     skip_authorization :health_check
  #   end
  #
  module Controller
    extend ActiveSupport::Concern

    included do
      include Loading::Dsl

      before_action :turnstile_load_and_authorize
      attr_writer :turnstile_authorization_performed

      helper_method :policy
    end

    # Instance methods mixed into every controller that
    # includes this concern.

    # Manually authorize a record. Use when you need to
    # authorize outside the automatic before_action flow
    # (e.g. in create, where the record does not exist yet).
    def authorize(record, permission = nil, **opts)
      permission ||= action_name.to_sym
      ctx = build_request_context
      result = Authorization.authorize_in_context(
        turnstile_user, record, permission, ctx, **opts
      )
      self.turnstile_authorization_performed = true
      result
    end

    # Authorize using only the general (context-free) policy.
    def authorize_without_context(record, permission = nil,
      **opts)
      permission ||= action_name.to_sym
      result = Authorization.authorize(
        turnstile_user, record, permission, **opts
      )
      self.turnstile_authorization_performed = true
      result
    end

    # Get an instantiated general policy for ad-hoc queries.
    def policy(record)
      Authorization.policy_for(turnstile_user, record)
    end

    # Apply a policy scope to a relation.
    def policy_scope(scope)
      Authorization.policy_scope(turnstile_user, scope)
    end

    # Mark that authorization was intentionally skipped for
    # this action.
    def skip_authorization
      self.turnstile_authorization_performed = true
    end

    private

    def turnstile_user
      public_send(
        Turnstile.configuration.current_user_method
      )
    end

    # The main before_action: load resources, then authorize,
    # then wrap loaded records in Presented decorators for
    # read actions so that view templates receive guarded
    # attribute access automatically.
    def turnstile_load_and_authorize
      turnstile_load_resource
      turnstile_authorize_resource
      turnstile_present_resource
    end

    def turnstile_load_resource
      config = self.class.turnstile_config

      # Custom loader takes full precedence.
      custom = config.custom_loaders[action_name.to_sym]
      if custom
        result = custom.call(self)
        # If the block returns a hash, treat keys as ivar
        # names; otherwise do nothing (the block handled it).
        result.each { |k, v| instance_variable_set(k, v) } if result.is_a?(Hash)
        return
      end

      loader = Loading::Loader.new(
        controller_class: self.class,
        action_name: action_name,
        params: params,
        current_user: turnstile_user
      )
      assignments = loader.load
      assignments.each { |k, v| instance_variable_set(k, v) }
    end

    def turnstile_authorize_resource
      return if self.class.turnstile_skip_auth_actions
        .include?(action_name.to_sym)

      record = turnstile_loaded_record
      return unless record

      ctx = build_request_context
      if record.respond_to?(:each)
        # Collection — already scoped; authorize the class.
        klass = record.respond_to?(:klass) ? record.klass : nil
        if klass
          Authorization.authorize_in_context(
            turnstile_user, klass, action_name.to_sym, ctx
          )
        end
      else
        Authorization.authorize_in_context(
          turnstile_user, record, action_name.to_sym, ctx
        )
      end
      self.turnstile_authorization_performed = true
    end

    # Find the record that was loaded by the loader so we
    # can authorize it.
    def turnstile_loaded_record
      config = self.class.turnstile_config
      klass = config.resource_class || infer_resource_class
      return nil unless klass

      singular = klass.model_name.singular
      plural = klass.model_name.plural

      instance_variable_get(:"@#{singular}") ||
        instance_variable_get(:"@#{plural}")
    end

    def infer_resource_class
      name = self.class.name
        &.sub(/Controller\z/, "")
        &.demodulize
        &.singularize
      name&.safe_constantize
    end

    def build_request_context
      Authorization::RequestContext.new(
        request: request,
        params: params,
        action_name: action_name,
        controller_name: controller_name
      )
    end

    # Wrap loaded resources in Presented/PresentedCollection
    # for read actions. Write actions (create, update,
    # destroy) need the raw record for mutation, so
    # presentation is skipped.
    def turnstile_present_resource
      return if self.class.turnstile_skip_present_actions
        .include?(action_name.to_sym)
      return if turnstile_write_action?

      record = turnstile_loaded_record
      return unless record

      if record.respond_to?(:each)
        presented = PresentedCollection.new(
          record, turnstile_user
        )
        ivar = :"@#{turnstile_plural_name}"
      else
        presented = Presented.new(record, turnstile_user)
        ivar = :"@#{turnstile_singular_name}"
      end

      instance_variable_set(ivar, presented)
    end

    def turnstile_authorization_performed?
      !!@turnstile_authorization_performed
    end

    # Actions that mutate records; presentation is skipped.
    WRITE_ACTIONS = %i[create destroy update].freeze

    def turnstile_write_action?
      WRITE_ACTIONS.include?(action_name.to_sym)
    end

    def turnstile_singular_name
      klass = self.class.turnstile_config.resource_class ||
        infer_resource_class
      return nil unless klass

      klass.model_name.singular
    end

    def turnstile_plural_name
      klass = self.class.turnstile_config.resource_class ||
        infer_resource_class
      return nil unless klass

      klass.model_name.plural
    end

    # After-action guard registered by +verify_authorization+.
    # Raises when no authorization path was taken.
    def turnstile_verify_authorized
      return if self.class.turnstile_skip_auth_actions
        .include?(action_name.to_sym)
      return if turnstile_authorization_performed?

      raise AuthorizationNotPerformedError
    end

    # Class methods for the controller.
    module ClassMethods
      # Declare actions that should skip authorization.
      def skip_authorization(*actions)
        actions.each do |a|
          turnstile_skip_auth_actions << a.to_sym
        end
      end

      # Set of actions that skip authorization.
      def turnstile_skip_auth_actions
        @turnstile_skip_auth_actions ||= if superclass
            .respond_to?(:turnstile_skip_auth_actions)
          superclass.turnstile_skip_auth_actions.dup
        else
          Set.new
        end
      end

      # Declare actions that should skip auto-presentation
      # (i.e. resources stay as raw AR records).
      def skip_presentation(*actions)
        actions.each do |a|
          turnstile_skip_present_actions << a.to_sym
        end
      end

      # Set of actions that skip presentation.
      def turnstile_skip_present_actions
        @turnstile_skip_present_actions ||= if superclass
            .respond_to?(:turnstile_skip_present_actions)
          superclass.turnstile_skip_present_actions.dup
        else
          Set.new
        end
      end

      # Enable after-action verification that authorization
      # was performed. When active, any action that completes
      # without calling +authorize+, +skip_authorization+, or
      # being listed in +skip_authorization+ will raise
      # +AuthorizationNotPerformedError+.
      #
      #   class ApplicationController < ActionController::Base
      #     include Turnstile::Controller
      #     verify_authorization
      #   end
      #
      def verify_authorization
        after_action :turnstile_verify_authorized
      end
    end
  end
end
