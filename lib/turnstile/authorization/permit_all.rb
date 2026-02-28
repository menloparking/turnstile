# frozen_string_literal: true

module Turnstile
  module Authorization
    # A policy that permits everything. Useful as a stand-in
    # during development or for truly public resources. Override
    # individual permissions to tighten as needed.
    #
    #   class PublicPagePolicy < Turnstile::Authorization::PermitAll
    #     # everything allowed by default; lock down destroy:
    #     def destroy?
    #       deny(:destroy, reason: "pages are immutable")
    #     end
    #   end
    #
    class PermitAll < Policy
      def create? = allow(:create)

      def destroy? = allow(:destroy)

      def index? = allow(:index)

      def show? = allow(:show)

      def update? = allow(:update)

      # Scope that returns everything.
      class Scope < Policy::Scope
        def resolve = scope.all
      end

      # Override method_missing so that any undeclared permission
      # query (e.g. publish?, archive?) also permits.
      def method_missing(method_name, *args)
        if method_name.end_with?("?") && args.empty?
          allow(method_name.to_s.chomp("?").to_sym)
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        method_name.end_with?("?") || super
      end
    end
  end
end
