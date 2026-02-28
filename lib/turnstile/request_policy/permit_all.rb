# frozen_string_literal: true

module Turnstile
  module RequestPolicy
    # A request policy that permits everything. Useful as a
    # stand-in during development, or as a base class when you
    # want deny-by-exception rather than deny-by-default.
    class PermitAll < Base
      def call
        allow
      end
    end
  end
end
