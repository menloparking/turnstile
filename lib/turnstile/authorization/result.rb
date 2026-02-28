# frozen_string_literal: true

module Turnstile
  module Authorization
    # Value object returned by policy query methods. Carries
    # both the boolean verdict and an optional human-readable
    # reason explaining the denial. Policies return these from
    # permission methods rather than bare booleans, so that
    # callers may inspect the reason for rejection.
    #
    #   result = policy.update?
    #   result.allowed?          # => false
    #   result.denied?           # => true
    #   result.reason            # => "account is suspended"
    #
    class Result
      # @return [Boolean]
      attr_reader :allowed

      # @return [String, nil] explanation when denied
      attr_reader :reason

      # @return [Symbol] the permission that was evaluated
      attr_reader :permission

      def initialize(allowed, permission:, reason: nil)
        @allowed = !!allowed
        @permission = permission
        @reason = reason
        freeze
      end

      def allowed? = @allowed

      def denied? = !@allowed

      # Truthiness: a Result is truthy when allowed, so that
      # `if policy.show?` reads naturally.
      def !
        !@allowed
      end

      def to_s
        if @allowed
          "allowed:#{@permission}"
        else
          msg = "denied:#{@permission}"
          msg += " (#{@reason})" if @reason
          msg
        end
      end

      def inspect
        "#<#{self.class} #{self}>"
      end
    end
  end
end
