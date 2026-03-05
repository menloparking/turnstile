# frozen_string_literal: true

module Turnstile
  module Authorization
    # A refinement of Policy that additionally receives a
    # RequestContext. Context policies inherit from a base
    # general policy and may override permission methods to
    # make decisions that depend on the HTTP request, params,
    # or other environmental factors.
    #
    # Permissions declared with `contextual: true` in the
    # reflection metadata signal to static analysis tools
    # that these cannot be evaluated without a live request.
    #
    # == Usage
    #
    #   class ArticleContextPolicy < ContextPolicy
    #     general_policy ArticlePolicy
    #
    #     permission :update, contextual: true,
    #       description: "edit with attribute restrictions",
    #       parameters: [:changed_attributes]
    #
    #     def update?
    #       base = general_policy_for_record.update?
    #       return base if base.denied?
    #
    #       changed = context.params.fetch(:article, {}).keys
    #         .map(&:to_sym)
    #       forbidden = changed & [:published_at, :author_id]
    #       if forbidden.any? && !user&.admin?
    #         deny(
    #           reason: "cannot modify #{forbidden.join(", ")}")
    #       else
    #         allow
    #       end
    #     end
    #   end
    #
    class ContextPolicy < Policy
      # @return [RequestContext] the current request environment
      attr_reader :context

      def initialize(user, record, context)
        super(user, record)
        @context = context
      end

      class << self
        # Declare which general policy this context policy
        # refines. Permission queries that the subclass does
        # not explicitly define are delegated to the general
        # policy at runtime via method_missing.
        def general_policy(klass = nil)
          @general_policy = klass if klass
          @general_policy
        end

        # Merge permissions from the general policy into our
        # own reflection, marking inherited ones as
        # non-contextual.
        def permissions
          base = general_policy&.permissions || {}
          base.merge(super)
        end
      end

      # Delegate unoverridden permission queries to the linked
      # general policy. This overrides Policy's method_missing
      # (which denies by default) so that, for example,
      # ArticleContextPolicy#show? delegates to
      # ArticlePolicy#show? rather than blindly denying.
      def method_missing(method_name, *args, &block)
        gp = self.class.general_policy
        if gp && method_name.end_with?("?") && args.empty?
          gp.new(user, record).public_send(method_name)
        else
          super
        end
      end

      def respond_to_missing?(method_name,
        include_private = false)
        gp = self.class.general_policy
        if gp && method_name.end_with?("?")
          gp.method_defined?(method_name) || super
        else
          super
        end
      end

      # Scope that also receives context.
      class Scope < Policy::Scope
        attr_reader :context

        def initialize(user, scope, context)
          super(user, scope)
          @context = context
        end
      end

      private

      # Convenience: instantiate the linked general policy for
      # the current user and record. Useful in subclass methods
      # that need to check the base permission before applying
      # contextual refinements.
      def general_policy_for_record
        gp = self.class.general_policy
        raise "no general_policy declared" unless gp

        gp.new(user, record)
      end
    end
  end
end
