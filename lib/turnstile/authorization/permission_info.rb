# frozen_string_literal: true

module Turnstile
  module Authorization
    # Metadata about a single declared permission on a policy.
    # Exposed through the reflection API so that callers may
    # enumerate what a policy governs without instantiating it.
    class PermissionInfo
      # @return [Symbol] the permission name (e.g. :show, :update)
      attr_reader :name

      # @return [String, nil] human description of what this
      #   permission guards
      attr_reader :description

      # @return [Boolean] whether this permission requires request
      #   context to evaluate (true only on context policies)
      attr_reader :contextual

      # @return [Array<Symbol>] parameter names the permission
      #   method accepts beyond the standard (user, record) pair
      attr_reader :parameters

      def initialize(name, description: nil, contextual: false,
        parameters: [])
        @name = name.to_sym
        @description = description
        @contextual = contextual
        @parameters = Array(parameters).map(&:to_sym).freeze
        freeze
      end

      def contextual? = @contextual

      def to_s = @name.to_s

      def inspect
        parts = ["#<#{self.class} #{@name}"]
        parts << " contextual" if @contextual
        parts << " params=#{@parameters}" if @parameters.any?
        parts << " #{@description.inspect}" if @description
        parts << ">"
        parts.join
      end
    end
  end
end
