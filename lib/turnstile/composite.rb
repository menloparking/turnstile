# frozen_string_literal: true

module Turnstile
  # Composite policy support. Allows combining policy classes
  # with boolean logic: all-of (AND), any-of (OR), none-of
  # (NOT). Works for both request policies and general
  # (authorization) policies.
  #
  # == Three forms
  #
  # Module helpers:
  #
  #   Turnstile.all_of(PolicyA, PolicyB)
  #   Turnstile.any_of(PolicyA, PolicyB)
  #   Turnstile.none_of(PolicyA)
  #
  # Operator syntax on policy classes:
  #
  #   PolicyA & PolicyB          # all_of
  #   PolicyA | PolicyB          # any_of
  #   ~PolicyA                   # none_of
  #
  # Composites nest freely:
  #
  #   Turnstile.all_of(
  #     MaintenancePolicy,
  #     Turnstile.any_of(VpnPolicy, InternalPolicy)
  #   )
  #
  #   (MaintenancePolicy & (VpnPolicy | InternalPolicy))
  #
  module Composite
    # --- Request policy composites ---------------------------

    module RequestOperators
      # PolicyA & PolicyB — all must allow.
      def &(other)
        Request::AllOf.build(self, other)
      end

      # PolicyA | PolicyB — any may allow.
      def |(other)
        Request::AnyOf.build(self, other)
      end

      # ~PolicyA — inverts the result.
      def ~
        Request::NoneOf.build(self)
      end
    end

    # Composite request policies. Each is a subclass of
    # RequestPolicy::Base, so it can be used anywhere a
    # request policy class is expected.
    module Request
      # All child policies must allow.
      class AllOf < ::Turnstile::RequestPolicy::Base
        class << self
          attr_reader :policies

          def build(*policy_classes)
            klass = Class.new(self)
            klass.instance_variable_set(
              :@policies, policy_classes.flatten.freeze
            )
            klass
          end
        end

        def call
          self.class.policies.each do |klass|
            result = klass.new(request).call
            return result if result.denied?
          end
          allow
        end
      end

      # At least one child policy must allow.
      class AnyOf < ::Turnstile::RequestPolicy::Base
        class << self
          attr_reader :policies

          def build(*policy_classes)
            klass = Class.new(self)
            klass.instance_variable_set(
              :@policies, policy_classes.flatten.freeze
            )
            klass
          end
        end

        def call
          last_result = nil
          self.class.policies.each do |klass|
            result = klass.new(request).call
            return result if result.allowed?

            last_result = result
          end
          last_result || deny(reason: "no policies to evaluate")
        end
      end

      # Inverts: all child policies must deny for this to
      # allow. Equivalent to NOT(any child allows).
      class NoneOf < ::Turnstile::RequestPolicy::Base
        class << self
          attr_reader :policies

          def build(*policy_classes)
            klass = Class.new(self)
            klass.instance_variable_set(
              :@policies, policy_classes.flatten.freeze
            )
            klass
          end
        end

        def call
          self.class.policies.each do |klass|
            result = klass.new(request).call
            if result.allowed?
              return deny(
                reason: "#{klass.name || "policy"} allowed"
              )
            end
          end
          allow
        end
      end
    end

    # --- General policy composites ---------------------------

    module PolicyOperators
      # PolicyA & PolicyB — all must allow.
      def &(other)
        General::AllOf.build(self, other)
      end

      # PolicyA | PolicyB — any may allow.
      def |(other)
        General::AnyOf.build(self, other)
      end

      # ~PolicyA — inverts the result.
      def ~
        General::NoneOf.build(self)
      end
    end

    # Composite general policies. Each is a subclass of
    # Authorization::Policy, so it can be used anywhere a
    # general policy class is expected.
    #
    # Permission queries (methods ending in ?) are dispatched
    # to child policies and combined with the appropriate
    # boolean logic.
    module General
      # All child policies must allow the permission.
      class AllOf < ::Turnstile::Authorization::Policy
        class << self
          attr_reader :policies

          def build(*policy_classes)
            klass = Class.new(self)
            klass.instance_variable_set(
              :@policies, policy_classes.flatten.freeze
            )
            klass
          end
        end

        private

        def method_missing(method_name, *args, &block)
          if method_name.end_with?("?") && args.empty?
            evaluate_all(method_name)
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          method_name.end_with?("?") || super
        end

        def evaluate_all(method_name)
          self.class.policies.each do |klass|
            result = klass.new(user, record)
              .public_send(method_name)
            return result if result.denied?
          end
          allow
        end
      end

      # At least one child policy must allow the permission.
      class AnyOf < ::Turnstile::Authorization::Policy
        class << self
          attr_reader :policies

          def build(*policy_classes)
            klass = Class.new(self)
            klass.instance_variable_set(
              :@policies, policy_classes.flatten.freeze
            )
            klass
          end
        end

        private

        def method_missing(method_name, *args, &block)
          if method_name.end_with?("?") && args.empty?
            evaluate_any(method_name)
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          method_name.end_with?("?") || super
        end

        def evaluate_any(method_name)
          last_result = nil
          self.class.policies.each do |klass|
            result = klass.new(user, record)
              .public_send(method_name)
            return result if result.allowed?

            last_result = result
          end
          last_result || deny
        end
      end

      # Inverts: all child policies must deny for this to
      # allow. Equivalent to NOT(any child allows).
      class NoneOf < ::Turnstile::Authorization::Policy
        class << self
          attr_reader :policies

          def build(*policy_classes)
            klass = Class.new(self)
            klass.instance_variable_set(
              :@policies, policy_classes.flatten.freeze
            )
            klass
          end
        end

        private

        def method_missing(method_name, *args, &block)
          if method_name.end_with?("?") && args.empty?
            evaluate_none(method_name)
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          method_name.end_with?("?") || super
        end

        def evaluate_none(method_name)
          self.class.policies.each do |klass|
            result = klass.new(user, record)
              .public_send(method_name)
            if result.allowed?
              return deny(
                reason: "#{klass.name || "policy"} allowed"
              )
            end
          end
          allow
        end
      end
    end
  end

  # Wire the operators into the base policy classes so that
  # the & | ~ syntax works on any subclass.
  RequestPolicy::Base.extend(Composite::RequestOperators)
  Authorization::Policy.extend(Composite::PolicyOperators)
end
