# frozen_string_literal: true

module Turnstile
  # Holds gem-wide settings. Obtain the singleton through
  # Turnstile.configuration; mutate it through
  # Turnstile.configure { |c| ... }.
  class Configuration
    # @return [Logger] the active logger instance
    attr_accessor :logger

    # @return [Symbol] the controller method that returns the
    #   current user. Defaults to :current_user so Devise works
    #   out of the box, but any authentication system that exposes
    #   a method of this name will suffice.
    attr_accessor :current_user_method

    # @return [String, nil] namespace prefix appended when
    #   resolving policy classes. nil means no prefix.
    attr_accessor :policy_namespace

    # @return [Class, nil] a Turnstile::RequestPolicy::Base
    #   subclass to evaluate against every incoming Rack
    #   request. nil means no request-level policy is active
    #   and the middleware becomes a pass-through.
    attr_accessor :request_policy

    # @return [Integer, nil] HTTP status code returned when the
    #   request policy denies. Defaults to 403 in the
    #   middleware if nil.
    attr_accessor :request_policy_status

    # @return [String, Proc, nil] response body (or a callable
    #   receiving the Result) returned on denial. Defaults to
    #   "Forbidden" in the middleware if nil.
    attr_accessor :request_policy_body

    # @return [Symbol] :strict or :lenient. In strict mode,
    #   accessing a denied attribute on a Presented record
    #   raises AttributeDeniedError. In lenient mode it
    #   returns nil. Defaults to :strict (DenyAll).
    attr_accessor :presented_mode

    # @return [Symbol] :off, :warn, or :raise. Controls
    #   query budget enforcement for permission checks.
    #   :off disables monitoring (zero overhead).
    #   :warn logs when the budget is exceeded.
    #   :raise raises QueryBudget::Exceeded.
    attr_accessor :query_budget_mode

    # @return [Integer] maximum SQL queries allowed per
    #   permission check. Defaults to 1.
    attr_accessor :query_budget

    def initialize
      @current_user_method = :current_user
      @logger = Logging.default_logger
      @policy_namespace = nil
      @presented_mode = :strict
      @query_budget = 1
      @query_budget_mode = :off
      @request_policy = nil
      @request_policy_body = nil
      @request_policy_status = nil
    end
  end
end
