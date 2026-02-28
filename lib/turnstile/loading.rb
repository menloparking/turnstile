# frozen_string_literal: true

require_relative "loading/config"
require_relative "loading/dsl"
require_relative "loading/loader"

module Turnstile
  # The Loading subsystem automatically loads ActiveRecord
  # resources in controller before_action hooks, using naming
  # conventions (controller name -> model class) and policy
  # scopes for security.
  module Loading
  end
end
