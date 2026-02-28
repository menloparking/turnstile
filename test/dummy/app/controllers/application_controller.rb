# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Disable CSRF for the test dummy app. Integration tests
  # do not carry authenticity tokens.
  skip_forgery_protection

  # Simulate a current_user method. Integration tests set
  # the user id in the session; we look it up here.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = (User.find_by(id: session[:user_id]) if session[:user_id])
  end

  helper_method :current_user

  rescue_from Turnstile::NotAuthorizedError do |e|
    render plain: e.message, status: :forbidden
  end

  rescue_from Turnstile::ResourceNotFoundError do |e|
    render plain: e.message, status: :not_found
  end
end
