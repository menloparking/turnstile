# frozen_string_literal: true

module Turnstile
  module Authorization
    # The base policy class. Every query method denies by default
    # — DenyAll in spirit. Application policies inherit from this
    # and override only the permissions they wish to grant.
    #
    # All policies receive the current user and the record under
    # judgment. The user is whatever the host application provides
    # (typically a Devise-backed model, but we require nothing of
    # it beyond presence).
    #
    # == Usage
    #
    #   class ArticlePolicy < Turnstile::Authorization::Policy
    #     permission :show,    description: "view an article"
    #     permission :create,  description: "create an article"
    #     permission :update,  description: "edit an article"
    #     permission :destroy, description: "delete an article"
    #
    #     def show?
    #       allow
    #     end
    #
    #     def create?
    #       user&.admin? ? allow : deny(
    #         reason: "only administrators may create articles")
    #     end
    #   end
    #
    class Policy
      include Reflection

      # Standard CRUD permissions declared on every policy.
      # Subclasses inherit these and may add more.
      permission :create, description: "create a record"
      permission :destroy, description: "destroy a record"
      permission :index, description: "list records"
      permission :show, description: "view a record"
      permission :update, description: "update a record"

      # @return [Object, nil] the current user
      attr_reader :user

      # @return [Object, nil] the record or model class
      attr_reader :record

      def initialize(user, record)
        @user = user
        @record = record
      end

      # Scope class for collection-level filtering. Subclasses
      # should define their own Scope inheriting from this.
      #
      #   class ArticlePolicy < Policy
      #     class Scope < Policy::Scope
      #       def resolve
      #         if user&.admin?
      #           scope.all
      #         else
      #           scope.where(published: true)
      #         end
      #       end
      #     end
      #   end
      #
      class Scope
        # @return [Object, nil] the current user
        attr_reader :user

        # @return [ActiveRecord::Relation] the base scope
        attr_reader :scope

        def initialize(user, scope)
          @user = user
          @scope = scope
        end

        # Subclasses must override. The default returns nothing
        # — deny all.
        def resolve
          scope.none
        end
      end

      private

      # Build an allowing Result. When called without a name,
      # infers the permission from the calling method:
      # `def update?` → `:update`.
      def allow(permission_name = nil)
        permission_name ||= infer_permission
        Result.new(true, permission: permission_name)
      end

      # Build a denying Result with an optional reason. When
      # called without a name, infers the permission from the
      # calling method: `def update?` → `:update`.
      def deny(permission_name = nil, reason: nil)
        permission_name ||= infer_permission
        Result.new(false, permission: permission_name,
          reason: reason)
      end

      # Derive the permission name from the method that called
      # allow/deny. `def update?` → `:update`,
      # `def title_allowed?` → `:title_allowed`.
      def infer_permission
        name = caller_locations(2, 1)&.first&.base_label.to_s
        name.delete_suffix("?").to_sym
      end

      # Catch permission query methods (ending in ?) that
      # correspond to a registered permission but have no
      # explicit implementation. The default is deny — true
      # to the DenyAll principle.
      def method_missing(method_name, *args, &block)
        if method_name.end_with?("?") && args.empty?
          perm = method_name.to_s.chomp("?").to_sym
          return deny(perm) if self.class.permissions.key?(perm)
        end
        super
      end

      def respond_to_missing?(method_name, include_private = false)
        if method_name.end_with?("?")
          perm = method_name.to_s.chomp("?").to_sym
          return true if self.class.permissions.key?(perm)
        end
        super
      end

      # Convenience: log an authorization decision. Policies may
      # call this to record their reasoning in the common sink.
      def log(message, level: :debug)
        Turnstile.logger.public_send(level, message)
      end
    end
  end
end
