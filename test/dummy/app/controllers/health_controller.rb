# frozen_string_literal: true

class HealthController < ApplicationController
  include Turnstile::Controller

  skip_authorization :check
  skip_loading :check

  def check
    render plain: "ok"
  end
end
