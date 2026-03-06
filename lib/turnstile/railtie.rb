# frozen_string_literal: true

require "rails/railtie"

module Turnstile
  # Hooks Turnstile into the Rails boot process:
  #
  # 1. Sets the logger to Rails.logger once Rails initializes.
  # 2. Inserts the RequestPolicy middleware at the very front
  #    of the middleware stack when a request policy class has
  #    been configured. This ensures the gate stands before
  #    sessions, cookies, or any Rails-specific middleware.
  class Railtie < Rails::Railtie
    rake_tasks do
      load "turnstile/tasks/audit.rake"
    end

    initializer "turnstile.configure_logger" do
      Turnstile.configure do |c|
        c.logger = Rails.logger if Rails.logger
      end
    end

    initializer "turnstile.request_policy_middleware" do |app|
      # The middleware is always inserted but acts as a
      # pass-through when no request_policy is configured.
      # This allows runtime reconfiguration (e.g. toggling
      # maintenance mode) without restarting.
      app.middleware.insert_before 0,
        Turnstile::RequestPolicy::Middleware
    end
  end
end
