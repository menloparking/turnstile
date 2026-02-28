# frozen_string_literal: true

module Turnstile
  module Authorization
    # Wraps the Rails request environment into an immutable
    # value object that context policies may inspect. This
    # separates the "what is happening" from the "who is
    # asking" and "what are they asking about."
    class RequestContext
      # @return [ActionDispatch::Request, nil]
      attr_reader :request

      # @return [ActionController::Parameters, Hash]
      attr_reader :params

      # @return [Symbol, String] the controller action name
      attr_reader :action_name

      # @return [String, nil] the controller name
      attr_reader :controller_name

      def initialize(request:, params:, action_name:,
        controller_name: nil)
        @request = request
        @params = params
        @action_name = action_name.to_sym
        @controller_name = controller_name
        freeze
      end

      # Convenience readers for common request properties.
      def ip = request&.remote_ip

      def method = request&.method

      def content_type = request&.content_type

      def headers = request&.headers

      def xhr? = !!request&.xhr?
    end
  end
end
