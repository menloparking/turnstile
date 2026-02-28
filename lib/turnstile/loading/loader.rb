# frozen_string_literal: true

module Turnstile
  module Loading
    # Infers and loads ActiveRecord resources for controller
    # actions. Guesses the model class from the controller name,
    # determines whether to load a singular record or a
    # collection, and sets the appropriate instance variable.
    #
    # The Loader does not act on its own — it is invoked by the
    # Controller concern's before_action hook, and respects the
    # DSL configuration set on the controller class.
    class Loader
      # Actions that load a collection by default.
      PLURAL_ACTIONS = %i[index].freeze

      # Actions that load a single record by default.
      SINGULAR_ACTIONS = %i[show edit update destroy].freeze

      # Actions that load nothing by default.
      SKIP_ACTIONS = %i[new create].freeze

      # @return [Class] the controller class (for DSL config)
      attr_reader :controller_class

      # @return [Symbol] the current action name
      attr_reader :action_name

      # @return [ActionController::Parameters, Hash]
      attr_reader :params

      # @return [Object, nil] the current user
      attr_reader :current_user

      def initialize(controller_class:, action_name:,
        params:, current_user:)
        @controller_class = controller_class
        @action_name = action_name.to_sym
        @params = params
        @current_user = current_user
      end

      # Execute the load. Returns a hash of instance variable
      # assignments: { :@article => <record>, ... } or
      # { :@articles => <collection> }.
      #
      # Returns an empty hash if the action is configured to
      # skip loading.
      #
      # @return [Hash{Symbol => Object}]
      def load
        return {} if skip_action?

        if plural_action?
          load_collection
        elsif singular_action?
          load_singular
        else
          {}
        end
      end

      private

      def config
        controller_class.turnstile_config
      end

      def resource_class
        config.resource_class || infer_resource_class
      end

      def infer_resource_class
        name = controller_class.name
          &.sub(/Controller\z/, "")
          &.demodulize
          &.singularize
        return nil unless name

        name.safe_constantize
      end

      def id_param
        config.id_param || :id
      end

      def singular_name
        resource_class&.model_name&.singular ||
          resource_class&.name&.demodulize&.underscore
      end

      def plural_name
        resource_class&.model_name&.plural ||
          singular_name&.pluralize
      end

      def skip_action?
        explicit = config.action_modes[@action_name]
        return true if explicit == :skip

        return false unless explicit.nil?

        SKIP_ACTIONS.include?(@action_name)
      end

      def plural_action?
        explicit = config.action_modes[@action_name]
        return true if explicit == :plural

        return false unless explicit.nil?

        PLURAL_ACTIONS.include?(@action_name)
      end

      def singular_action?
        explicit = config.action_modes[@action_name]
        return true if explicit == :singular

        return false unless explicit.nil?

        SINGULAR_ACTIONS.include?(@action_name)
      end

      # Load a collection, applying the policy scope to filter
      # records the user may access.
      def load_collection
        klass = resource_class
        return {} unless klass

        scope = apply_policy_scope(klass)
        {"@#{plural_name}": scope}
      end

      # Load a single record, scoped through the policy scope
      # so that a user cannot even discover records outside
      # their access.
      def load_singular
        klass = resource_class
        return {} unless klass

        scope = apply_policy_scope(klass)
        record_id = params[id_param]

        record = scope.find_by(id: record_id)
        raise ResourceNotFoundError.new(klass, record_id) unless record

        {"@#{singular_name}": record}
      end

      def apply_policy_scope(klass)
        policy_class = Authorization::Resolver.resolve(
          klass, type: :general
        )
        if policy_class&.const_defined?(:Scope, false)
          scope_class = policy_class.const_get(:Scope)
          scope_class.new(@current_user, klass).resolve
        else
          klass.all
        end
      end
    end
  end
end
