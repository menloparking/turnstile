# frozen_string_literal: true

module Turnstile
  module Authorization
    # Mixin providing the class-level DSL for declaring
    # permissions on a policy, and the reflection API for
    # enumerating them. Include this module into any policy
    # base class.
    #
    # == Declaring permissions
    #
    #   class ArticlePolicy < Turnstile::Authorization::Policy
    #     permission :show, description: "view an article"
    #     permission :update, description: "edit an article"
    #   end
    #
    # == Reflection
    #
    #   ArticlePolicy.permissions
    #   # => { show: #<PermissionInfo ...>, update: #<PermissionInfo ...> }
    #
    #   ArticlePolicy.permission_names
    #   # => [:show, :update]
    #
    #   ArticlePolicy.contextual_permissions
    #   # => [] (none, unless a ContextPolicy declares them)
    #
    module Reflection
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Class-level DSL and introspection.
      module ClassMethods
        # Declare a permission that this policy governs.
        # Generates a query method (<name>?) that returns a
        # Result. Subclasses override the generated method to
        # implement real logic; the default denies.
        #
        # @param name [Symbol]
        # @param description [String, nil]
        # @param contextual [Boolean]
        # @param parameters [Array<Symbol>]
        def permission(name, description: nil, contextual: false,
          parameters: [])
          name = name.to_sym
          info = PermissionInfo.new(
            name,
            description: description,
            contextual: contextual,
            parameters: parameters
          )
          own_permissions[name] = info

          # We intentionally do NOT define a default deny method
          # here. Policy#method_missing handles undeclared query
          # methods by returning deny for any registered
          # permission. This avoids redefinition warnings when
          # subclasses override the method in their class body.
        end

        # All permissions declared on this class and its
        # ancestors, merged with descendant overrides winning.
        #
        # @return [Hash{Symbol => PermissionInfo}]
        def permissions
          ancestors
            .select { |a| a.respond_to?(:own_permissions, true) }
            .reverse
            .each_with_object({}) { |a, h| h.merge!(a.own_permissions) }
        end

        # @return [Array<Symbol>]
        def permission_names
          permissions.keys.sort
        end

        # Permissions that require request context.
        #
        # @return [Hash{Symbol => PermissionInfo}]
        def contextual_permissions
          permissions.select { |_, v| v.contextual? }
        end

        # Permissions that can be evaluated without request
        # context — suitable for static analysis.
        #
        # @return [Hash{Symbol => PermissionInfo}]
        def context_free_permissions
          permissions.reject { |_, v| v.contextual? }
        end

        # Permissions declared directly on this class (not
        # inherited). Used internally for the merge walk.
        #
        # @return [Hash{Symbol => PermissionInfo}]
        def own_permissions
          @own_permissions ||= {}
        end

        protected :own_permissions
      end
    end
  end
end
