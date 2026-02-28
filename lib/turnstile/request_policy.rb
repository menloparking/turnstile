# frozen_string_literal: true

require_relative "request_policy/base"
require_relative "request_policy/middleware"
require_relative "request_policy/permit_all"

module Turnstile
  # The RequestPolicy subsystem provides a Rack-level gate that
  # runs before Rails and the rest of the middleware stack.
  # Unlike the three-tier authorization policies that operate on
  # users and ActiveRecord resources, request policies inspect
  # the raw Rack request and decide whether to admit or refuse
  # it at the outermost wall.
  #
  # Typical uses: IP allowlisting, geographic blocks, maintenance
  # mode, rate-limit checks, API-key validation on specific
  # paths, or any filtering that needs no knowledge of the
  # application's models or sessions.
  #
  # Configure via:
  #
  #   Turnstile.configure do |c|
  #     c.request_policy = MyRequestPolicy
  #   end
  #
  # The Railtie will insert the middleware automatically when a
  # policy is configured. Without a configured policy, no
  # middleware is added.
  module RequestPolicy
  end
end
