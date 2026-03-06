# frozen_string_literal: true

module Turnstile
  module Loading
    # Infers and loads ActiveRecord resources for controller
    # actions. Guesses the model class from the controller name,
    # determines whether to load a singular record or a
    # collection, and sets the appropriate instance variable.
    #
    # When a parent resource is configured (or auto-detected
    # from *_id params), loads the parent first, discovers the
    # ActiveRecord association linking parent to child, and
    # scopes the child through that association.
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
      # When a parent is detected, the hash includes both the
      # parent (e.g. :@user) and the child.
      #
      # Returns an empty hash if the action is configured to
      # skip loading.
      #
      # @return [Hash{Symbol => Object}]
      def load
        return {} if skip_action?

        assignments = {}

        # Attempt parent loading when configured or when
        # auto-detection is enabled.
        parent = load_parent
        if parent
          name = parent.class.model_name.singular
          assignments[:"@#{name}"] = parent
        end

        child_scope = parent ? parent_child_scope(parent) : nil

        if plural_action?
          assignments.merge!(
            load_collection(base_scope: child_scope)
          )
        elsif singular_action?
          assignments.merge!(
            load_singular(base_scope: child_scope)
          )
        end

        assignments
      end

      private

      def config
        controller_class.turnstile_config
      end

      # --- Parent resource detection and loading ---

      # Detect and load the parent resource, returning the
      # AR record or nil when no parent applies.
      def load_parent
        parent_klass, param_key = resolve_parent
        return nil unless parent_klass && params[param_key]

        scope = apply_policy_scope(parent_klass)
        record = scope.find_by(id: params[param_key])
        unless record
          raise ResourceNotFoundError.new(
            parent_klass, params[param_key]
          )
        end
        record
      end

      # Resolve parent class and param key from explicit
      # config or auto-detection.
      #
      # @return [Array(Class, Symbol), Array(nil, nil)]
      def resolve_parent
        if config.parent_class
          klass = config.parent_class
          param = config.parent_id_param ||
            :"#{klass.model_name.singular}_id"
          [klass, param]
        elsif config.parent_auto
          detect_parent_from_params
        else
          [nil, nil]
        end
      end

      # Scan params for keys matching *_id (excluding :id
      # itself) and try to constantize the prefix as a model.
      #
      # @return [Array(Class, Symbol), Array(nil, nil)]
      def detect_parent_from_params
        params.each_key do |key|
          key = key.to_s
          next unless key.end_with?("_id") && key != "id"

          model_name = key.sub(/_id\z/, "").classify
          klass = model_name.safe_constantize
          next unless klass &&
            klass < ActiveRecord::Base

          return [klass, key.to_sym]
        end
        [nil, nil]
      end

      # Discover the association on the parent that points to
      # the child model and return the scoped relation.
      # Falls back to a policy-scoped query on the child class
      # when no association is found.
      def parent_child_scope(parent)
        child_klass = resource_class
        return nil unless child_klass

        assoc = find_association(parent.class, child_klass)
        if assoc
          parent.public_send(assoc.name)
        else
          apply_policy_scope(child_klass)
        end
      end

      # Walk the parent's reflections to find a has_many or
      # has_one that targets the child model.
      #
      # @return [ActiveRecord::Reflection, nil]
      def find_association(parent_klass, child_klass)
        parent_klass.reflect_on_all_associations.detect do |r|
          r.klass == child_klass
        rescue NameError
          # The association's class_name may not resolve
          # (e.g. polymorphic). Skip it.
          false
        end
      end

      # --- Child resource inference ---

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
      # records the user may access. When a parent-scoped
      # base is provided, builds on top of it.
      def load_collection(base_scope: nil)
        klass = resource_class
        return {} unless klass

        scope = base_scope || apply_policy_scope(klass)
        {"@#{plural_name}": scope}
      end

      # Load a single record, scoped through the policy scope
      # (or a parent association) so that a user cannot even
      # discover records outside their access.
      def load_singular(base_scope: nil)
        klass = resource_class
        return {} unless klass

        scope = base_scope || apply_policy_scope(klass)
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
