# frozen_string_literal: true

module Turnstile
  # A decorator that wraps an ActiveRecord record and its
  # resolved ViewPolicy. Attribute reads are guarded by the
  # policy: denied attributes raise AttributeDeniedError in
  # strict mode or return nil in lenient mode.
  #
  # The wrapper delegates Rails identity methods (to_param,
  # to_key, to_model, model_name, persisted?, id, etc.) so
  # that form builders, link helpers, and Phlex components
  # work without ceremony.
  #
  # Associations that have their own ViewPolicy are wrapped
  # recursively (deep presentation).
  #
  # == Usage
  #
  #   presented = Turnstile::Presented.new(article, user)
  #   presented.title      # => "On Hobbits" (allowed)
  #   presented.body       # => raises AttributeDeniedError
  #   presented.unwrap     # => the raw Article record
  #
  class Presented
    # Methods that must pass through to the record unchanged
    # for Rails compatibility. These are never guarded.
    PASSTHROUGH_METHODS = %i[
      class
      id
      is_a?
      kind_of?
      instance_of?
      model_name
      persisted?
      new_record?
      destroyed?
      to_key
      to_model
      to_param
      to_partial_path
      errors
      valid?
      invalid?
      frozen?
      hash
      respond_to?
    ].freeze

    # @return [Object] the wrapped ActiveRecord record
    attr_reader :__record__

    # @return [Turnstile::Authorization::ViewPolicy, nil]
    attr_reader :__view_policy__

    # @return [Object, nil] the user for policy evaluation
    attr_reader :__user__

    def initialize(record, user, view_policy: nil)
      @__record__ = record
      @__user__ = user
      @__view_policy__ = view_policy || resolve_view_policy
    end

    # Escape hatch: return the raw, unguarded record.
    def unwrap
      @__record__
    end

    # Support == comparison with the underlying record or
    # another Presented wrapping the same record.
    def ==(other)
      __record__ == case other
      when Presented
        other.__record__
      else
        other
      end
    end

    # Identity: delegate to the record so Rails collections
    # and caching see the right object.
    def eql?(other)
      self == other
    end

    # Delegate hash to the record for Set/Hash membership.
    def hash
      __record__.hash
    end

    # Rails form builders call to_model; return self so the
    # presented object stays in play.
    def to_model
      self
    end

    # Rails identity methods that pass straight through.
    def to_param
      __record__.to_param
    end

    def to_key
      __record__.to_key
    end

    def to_partial_path
      __record__.to_partial_path
    end

    def model_name
      __record__.model_name
    end

    def persisted?
      __record__.persisted?
    end

    def new_record?
      __record__.new_record?
    end

    def destroyed?
      __record__.destroyed?
    end

    def errors
      __record__.errors
    end

    def valid?(...)
      __record__.valid?(...)
    end

    def invalid?(...)
      __record__.invalid?(...)
    end

    def id
      __record__.id
    end

    # Type checks delegate to the record so that
    # `presented.is_a?(Article)` returns true.
    def is_a?(klass)
      __record__.is_a?(klass) || super
    end
    alias_method :kind_of?, :is_a?

    def instance_of?(klass)
      __record__.instance_of?(klass) || super
    end

    # The presented class reports as the record's class so
    # that polymorphic routing and views work.
    def class
      __record__.class
    end

    def respond_to?(method_name, include_private = false)
      PASSTHROUGH_METHODS.include?(method_name.to_sym) ||
        __record__.respond_to?(method_name, include_private) ||
        super
    end

    def inspect
      "#<Turnstile::Presented(#{__record__.class.name}) " \
        "id: #{__record__.id.inspect}>"
    end

    private

    def resolve_view_policy
      klass = Authorization::Resolver.resolve(
        __record__, type: :view
      )
      return nil unless klass

      klass.new(__user__, __record__)
    end

    # The heart of the guard. All attribute access routes
    # through method_missing. If the record responds to the
    # method, we check the view policy before delegating.
    #
    # In lenient mode, guard_attribute throws
    # :turnstile_denied to short-circuit and return nil
    # without raising. The catch block here absorbs that.
    def method_missing(method_name, *args, &block)
      if __record__.respond_to?(method_name)
        if guarded_attribute?(method_name)
          caught = catch(:turnstile_denied) do
            guard_attribute(method_name)
            :passed
          end
          return nil unless caught == :passed
        end
        result = __record__.public_send(
          method_name, *args, &block
        )
        maybe_present_association(method_name, result)
      else
        super
      end
    end

    def respond_to_missing?(method_name,
      include_private = false)
      __record__.respond_to?(method_name, include_private) ||
        super
    end

    # An attribute is guarded when the view policy has an
    # attribute rule for it. Methods that aren't declared
    # attributes pass through unguarded (e.g. custom query
    # methods, scopes called on the record, etc.).
    def guarded_attribute?(method_name)
      return false unless __view_policy__

      rules = __view_policy__.class.attribute_rules
      rules.key?(method_name.to_sym)
    end

    # Check the policy and raise or return nil on denial.
    def guard_attribute(attr_name)
      result = __view_policy__.visible_attribute?(
        attr_name.to_sym
      )
      return if result.allowed?

      if Turnstile.configuration.presented_mode == :strict
        raise AttributeDeniedError.new(
          attribute: attr_name.to_sym,
          record: __record__,
          reason: result.reason
        )
      end
      # In lenient mode, throw a symbol that
      # method_missing catches to return nil.
      throw :turnstile_denied
    end

    # Deep presentation: if the return value is an AR record
    # that has its own ViewPolicy, wrap it. If it's a
    # collection (has_many), wrap it as a PresentedCollection.
    def maybe_present_association(_method_name, value)
      return value unless value

      if value.is_a?(ActiveRecord::Base)
        vp_klass = Authorization::Resolver.resolve(
          value, type: :view
        )
        return value unless vp_klass

        self.class.new(value, __user__)
      elsif value.is_a?(ActiveRecord::Relation)
        vp_klass = Authorization::Resolver.resolve(
          value.klass, type: :view
        )
        return value unless vp_klass

        PresentedCollection.new(value, __user__)
      else
        value
      end
    end
  end
end
