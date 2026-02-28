# frozen_string_literal: true

require_relative "turnstile/version"
require_relative "turnstile/logging"
require_relative "turnstile/configuration"
require_relative "turnstile/errors"
require_relative "turnstile/authorization"
require_relative "turnstile/request_policy"
require_relative "turnstile/loading"
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
  end
end
