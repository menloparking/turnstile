# frozen_string_literal: true

module Turnstile
  module Authorization
    # Resolves policy classes from records, model classes, or
    # symbols using naming conventions. The resolver is the
    # bridge between a controller saying "authorize this" and
    # the correct policy class being instantiated.
    #
    # Convention: a model `Article` resolves to
    # `ArticlePolicy` or `ArticleContextPolicy` depending
    # on the policy type requested.
    #
    # The host application may set a namespace prefix via
    # configuration (e.g. "Admin" -> Admin::ArticlePolicy).
    module Resolver
      SUFFIXES = {
        general: "Policy",
        context: "ContextPolicy"
      }.freeze

      module_function

      # Resolve a policy class for the given record.
      #
      # @param record [Object, Symbol, String, Class]
      # @param type [:general, :context]
      # @return [Class, nil]
      def resolve(record, type: :general)
        base_name = model_name_for(record)
        return nil unless base_name

        suffix = SUFFIXES.fetch(type)
        candidates = policy_class_candidates(base_name, suffix)

        candidates.each do |candidate|
          klass = safe_constantize(candidate)
          return klass if klass
        end

        nil
      end

      # Resolve or raise.
      #
      # @param record [Object, Symbol, String, Class]
      # @param type [:general, :context]
      # @return [Class]
      # @raise [PolicyNotFoundError]
      def resolve!(record, type: :general)
        resolve(record, type: type) ||
          raise(PolicyNotFoundError.new(record))
      end

      # Extract a base model name string from various inputs.
      #
      # @param record [Object, Symbol, String, Class]
      # @return [String, nil]
      def model_name_for(record)
        case record
        when Symbol
          record.to_s.camelize
        when String
          record.camelize
        when Class
          record.name
        else
          if record.class.respond_to?(:model_name)
            record.class.model_name.name
          else
            record.class.name
          end
        end
      end

      # Build candidate class name strings, optionally
      # including the configured namespace.
      def policy_class_candidates(base_name, suffix)
        ns = Turnstile.configuration.policy_namespace
        candidates = []
        candidates << "#{ns}::#{base_name}#{suffix}" if ns
        candidates << "#{base_name}#{suffix}"
        candidates
      end

      # Constant lookup that does not raise.
      def safe_constantize(name)
        name.safe_constantize
      rescue NameError
        nil
      end
    end
  end
end
