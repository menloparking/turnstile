# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.active_support.deprecation = :stderr
end
