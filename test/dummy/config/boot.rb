# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)

# Do NOT require turnstile here. Rails must be loaded first
# so the Railtie guard (defined?(Rails::Railtie)) fires
# correctly. The application.rb requires turnstile after
# Rails.
