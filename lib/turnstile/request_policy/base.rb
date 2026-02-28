# frozen_string_literal: true

module Turnstile
  module RequestPolicy
    # Base class for request-level policies. These operate on a
    # raw Rack::Request — no user, no record, no ActiveRecord.
    # They stand at the outermost gate, judging whether a request
    # may even enter the halls of the application.
    #
    # Like its sibling Policy, the base class denies all by
    # default. Subclass and override +call+ to implement your
    # admission logic.
    #
    # == Usage
    #
    #   class IpAllowlistPolicy < Turnstile::RequestPolicy::Base
    #     ALLOWED = IPAddr.new("10.0.0.0/8")
    #
    #     def call
    #       ip = IPAddr.new(request.ip)
    #       if ALLOWED.include?(ip)
    #         allow
    #       else
    #         deny(reason: "IP #{request.ip} not in allowlist")
    #       end
    #     end
    #   end
    #
    class Base
      # @return [Rack::Request] the incoming request
      attr_reader :request

      def initialize(request)
        @request = request
      end

      # Subclasses must override. The default denies all — true
      # to the DenyAll principle. Return the value of +allow+
      # or +deny+.
      #
      # @return [Result]
      def call
        deny(reason: "no request policy rules defined")
      end

      private

      # Build an allowing Result.
      #
      # @return [Authorization::Result]
      def allow
        Authorization::Result.new(
          true, permission: :request
        )
      end

      # Build a denying Result with an optional reason.
      #
      # @param reason [String, nil]
      # @return [Authorization::Result]
      def deny(reason: nil)
        Authorization::Result.new(
          false,
          permission: :request,
          reason: reason
        )
      end
    end
  end
end
