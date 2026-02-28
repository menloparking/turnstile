# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# Require turnstile after Rails so the Railtie is detected.
# When turnstile was already loaded before Rails (e.g. from
# test_helper.rb), the conditional guard in turnstile.rb will
# have skipped the railtie, so require it explicitly here.
require "turnstile"
require "turnstile/railtie"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.hosts.clear
    config.secret_key_base = "test-secret-key-base-for-turnstile"
    config.logger = Logger.new(File::NULL)
    config.active_support.deprecation = :stderr
  end
end
