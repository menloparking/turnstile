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

      # --- Parent resource settings ---

      # @return [Class, nil] explicit parent model class
      attr_accessor :parent_class

      # @return [Symbol, nil] param key for parent record ID
      #   (e.g. :user_id). Inferred from parent_class if nil.
      attr_accessor :parent_id_param

      # @return [Boolean] when true, infer parent from *_id
      #   params even without an explicit parent_class.
      attr_accessor :parent_auto

      # @return [Boolean] when true, load the parent resource
      #   even for actions that skip child loading (new,
      #   create, index). Useful for nested controllers where
      #   the parent scopes the child but the child record
      #   does not yet exist (new/create) or is a collection
      #   (index).
      attr_accessor :parent_always

      def initialize
        @resource_class = nil
        @id_param = nil
        @action_modes = {}
        @custom_loaders = {}
        @parent_class = nil
        @parent_id_param = nil
        @parent_auto = false
        @parent_always = false
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
