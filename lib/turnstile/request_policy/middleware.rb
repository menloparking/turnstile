# frozen_string_literal: true

require "rack"

module Turnstile
  module RequestPolicy
    # Rack middleware that evaluates the configured request
    # policy before handing the request to the inner
    # application. If the policy denies, the middleware
    # short-circuits with an HTTP error response and never
    # reaches Rails.
    #
    # Insert manually or let the Railtie handle it:
    #
    #   # Manual insertion (config.ru or application.rb):
    #   use Turnstile::RequestPolicy::Middleware
    #
    #   # Automatic via Railtie — just configure a policy:
    #   Turnstile.configure do |c|
    #     c.request_policy = IpAllowlistPolicy
    #   end
    #
    class Middleware
      # Default denial body — terse, revealing nothing.
      DEFAULT_BODY = "Forbidden"
      DEFAULT_STATUS = 403
      DEFAULT_CONTENT_TYPE = "text/plain"

      def initialize(app)
        @app = app
      end

      def call(env)
        policy_class = Turnstile.configuration.request_policy
        return @app.call(env) unless policy_class

        request = ::Rack::Request.new(env)
        result = policy_class.new(request).call

        if result.allowed?
          log_allowed(request)
          @app.call(env)
        else
          log_denied(request, result)
          deny_response(result)
        end
      end

      private

      def deny_response(result)
        config = Turnstile.configuration
        status = config.request_policy_status || DEFAULT_STATUS
        body = config.request_policy_body || DEFAULT_BODY

        # Allow the body to be a callable (proc/lambda) that
        # receives the Result, for dynamic denial pages.
        body = body.call(result) if body.respond_to?(:call)

        [
          status,
          {"content-type" => DEFAULT_CONTENT_TYPE},
          [body.to_s]
        ]
      end

      def log_allowed(request)
        Turnstile.logger.debug(
          "[Turnstile::RequestPolicy] allowed " \
          "#{request.request_method} #{request.path} " \
          "from #{request.ip}"
        )
      end

      def log_denied(request, result)
        Turnstile.logger.info(
          "[Turnstile::RequestPolicy] denied " \
          "#{request.request_method} #{request.path} " \
          "from #{request.ip}" \
          "#{": #{result.reason}" if result.reason}"
        )
      end
    end
  end
end
