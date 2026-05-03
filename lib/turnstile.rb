# frozen_string_literal: true

require_relative "turnstile/version"
require_relative "turnstile/logging"
require_relative "turnstile/configuration"
require_relative "turnstile/errors"
require_relative "turnstile/query_budget"
require_relative "turnstile/authorization"
require_relative "turnstile/request_policy"
require_relative "turnstile/composite"
require_relative "turnstile/loading"
require_relative "turnstile/presented"
require_relative "turnstile/presented_collection"
require_relative "turnstile/api_controller"
require_relative "turnstile/controller"
require_relative "turnstile/railtie" if defined?(Rails::Railtie)

module Turnstile
  class << self
    # @return [Configuration] the current configuration
    def configuration
      @configuration ||= Configuration.new
    end

    # Yields the configuration for mutation.
    #
    #   Turnstile.configure do |c|
    #     c.logger = Rails.logger
    #     c.current_user_method = :authenticated_user
    #   end
    def configure
      yield configuration
    end

    # Convenience accessor — every subsystem logs through here.
    #
    # @return [Logger]
    def logger
      configuration.logger
    end

    # Replace the logger outright.
    def logger=(new_logger)
      configuration.logger = new_logger
    end

    # Reset configuration to defaults. Primarily useful in tests.
    def reset_configuration!
      @configuration = Configuration.new
    end

    # Compose policies with AND logic. All must allow.
    #
    #   Turnstile.all_of(MaintenancePolicy, IpPolicy)
    #
    # @param policies [Array<Class>] policy classes
    # @return [Class] a composite policy class
    def all_of(*policies)
      if request_policies?(policies)
        Composite::Request::AllOf.build(*policies)
      else
        Composite::General::AllOf.build(*policies)
      end
    end

    # Compose policies with OR logic. Any may allow.
    #
    #   Turnstile.any_of(VpnPolicy, InternalPolicy)
    #
    # @param policies [Array<Class>] policy classes
    # @return [Class] a composite policy class
    def any_of(*policies)
      if request_policies?(policies)
        Composite::Request::AnyOf.build(*policies)
      else
        Composite::General::AnyOf.build(*policies)
      end
    end

    # Compose policies with NOT logic. All must deny for
    # the composite to allow.
    #
    #   Turnstile.none_of(BlockedIpPolicy)
    #
    # @param policies [Array<Class>] policy classes
    # @return [Class] a composite policy class
    def none_of(*policies)
      if request_policies?(policies)
        Composite::Request::NoneOf.build(*policies)
      else
        Composite::General::NoneOf.build(*policies)
      end
    end

    private

    def request_policies?(policies)
      policies.all? { |p| p <= RequestPolicy::Base }
    end
  end
end
