# frozen_string_literal: true

module Turnstile
  module Loading
    # Holds per-controller resource loading configuration,
    # populated by the DSL methods on the controller class.
    class Config
      # @return [Class, nil] explicit model class override
      attr_accessor :resource_class

      # @return [Symbol, nil] param key for record ID
      attr_accessor :id_param

      # @return [Hash{Symbol => Symbol}] action => mode
      #   (:singular, :plural, :skip)
      attr_reader :action_modes

      # @return [Hash{Symbol => Proc}] action => custom loader
      attr_reader :custom_loaders

      def initialize
        @resource_class = nil
        @id_param = nil
        @action_modes = {}
        @custom_loaders = {}
      end

      # Deep-copy for inheritance: subclass controllers get
      # their own copy of the parent's config.
      def dup
        copy = super
        copy.instance_variable_set(
          :@action_modes, @action_modes.dup
        )
        copy.instance_variable_set(
          :@custom_loaders, @custom_loaders.dup
        )
        copy
      end
    end
  end
end
