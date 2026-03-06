# frozen_string_literal: true

module Turnstile
  module Authorization
    # A policy that raises on every unoverridden permission.
    # Libraries and engines ship MustImplement policies so the
    # host application must consciously override each permission
    # — no silent denials and no accidental permits.
    #
    #   class Admin::RolePolicy < Turnstile::Authorization::MustImplement
    #     permission :assign, description: "assign a role"
    #
    #     def index? = allow           # explicitly implemented
    #     # assign? is NOT overridden — calling it raises
    #   end
    #
    class MustImplement < Policy
      # Raised when a MustImplement permission is called
      # without an explicit override. Subclass of Ruby's own
      # NotImplementedError so bare `rescue` does not swallow
      # it accidentally.
      class NotImplementedError < ::NotImplementedError
        def initialize(policy_class, permission)
          super(
            "#{policy_class.name}##{permission}? must be " \
            "overridden — the base policy requires an " \
            "explicit implementation"
          )
        end
      end

      # Scope that raises on resolve. Subclasses must provide
      # their own Scope with an explicit resolve method.
      class Scope < Policy::Scope
        def resolve
          raise NotImplementedError.new(
            self.class, :resolve
          )
        end
      end

      private

      # Intercept unoverridden permission queries and raise.
      def method_missing(method_name, *args, &block)
        if method_name.end_with?("?") && args.empty?
          perm = method_name.to_s.chomp("?").to_sym
          if self.class.permissions.key?(perm)
            raise NotImplementedError.new(
              self.class, perm
            )
          end
        end
        super
      end

      def respond_to_missing?(method_name,
        include_private = false)
        if method_name.end_with?("?")
          perm = method_name.to_s.chomp("?").to_sym
          return true if self.class.permissions.key?(perm)
        end
        super
      end
    end
  end
end
