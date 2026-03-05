# frozen_string_literal: true

module Turnstile
  # A decorator that wraps an ActiveRecord record and its
  # resolved general policy. Attribute reads are guarded by
  # the policy's `_allowed?` methods: denied attributes raise
  # AttributeDeniedError in strict mode or return nil in
  # lenient mode.
  #
  # The wrapper delegates Rails identity methods (to_param,
  # to_key, to_model, model_name, persisted?, id, etc.) so
  # that form builders, link helpers, and Phlex components
  # work without ceremony.
  #
  # Associations that have their own policy are wrapped
  # recursively (deep presentation).
  #
  # Attribute visibility follows the `_allowed?` convention
  # on the general policy. If no `<attr>_allowed?` method
  # exists, the attribute is denied by default (DenyAll).
  #
  # == Usage
  #
  #   presented = Turnstile::Presented.new(article, user)
  #   presented.title      # => "On Hobbits" (allowed)
  #   presented.body       # => raises AttributeDeniedError
  #   presented.unwrap     # => the raw Article record
  #   presented.allowed?(:title)      # => true
  #   presented[:title]               # => "On Hobbits"
  #   presented.fetch(:body) { "—" }  # => "—" (denied)
  #   presented.policy                # => ArticlePolicy
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

    # @return [Turnstile::Authorization::Policy, nil]
    attr_reader :__policy__

    # @return [Object, nil] the user for policy evaluation
    attr_reader :__user__

    def initialize(record, user)
      @__record__ = record
      @__user__ = user
      @__policy__ = resolve_policy
    end

    # Escape hatch: return the raw, unguarded record.
    def unwrap
      @__record__
    end

    # The resolved general policy instance. Useful for
    # direct queries like `presented.policy.touch_allowed?`.
    def policy
      @__policy__
    end

    # --- Rich attribute access API ---

    # Predicate: is the attribute allowed for this user?
    def allowed?(attr)
      attr = attr.to_sym
      return true unless __policy__

      method_name = :"#{attr}_allowed?"
      return false unless __policy__.respond_to?(method_name)

      result = __policy__.public_send(method_name)
      result.respond_to?(:allowed?) ? result.allowed? : !!result
    end

    # Block guard: yields the attribute value only if
    # allowed. Returns an IfAllowedResult that supports
    # `.else { fallback }` chaining.
    #
    #   presented.if_allowed(:body) { |v| render(v) }
    #     .else { render("Restricted") }
    #
    def if_allowed(attr)
      attr = attr.to_sym
      if allowed?(attr)
        value = __record__.public_send(attr)
        yield value if block_given?
        IfAllowedResult.new(true, value)
      else
        IfAllowedResult.new(false, nil)
      end
    end

    # Returns the attribute value if allowed, nil if denied.
    def allowed(attr)
      allowed?(attr) ? __record__.public_send(attr) : nil
    end

    # Hash-like access. Returns value if allowed, nil if
    # denied.
    def [](attr)
      allowed(attr)
    end

    # Returns the attribute value if allowed, otherwise
    # yields to the fallback block (or returns nil).
    def fetch(attr, &block)
      attr = attr.to_sym
      if allowed?(attr)
        __record__.public_send(attr)
      elsif block
        block.call
      end
    end

    # Pattern matching support. Denied attributes are
    # absent from the returned hash.
    def deconstruct_keys(keys)
      keys = keys&.map(&:to_sym)
      result = {}
      (keys || column_names).each do |key|
        next unless allowed?(key)
        next unless __record__.respond_to?(key)

        result[key] = __record__.public_send(key)
      end
      result
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

    # Value object returned by if_allowed, supporting
    # `.else { ... }` chaining.
    class IfAllowedResult
      def initialize(allowed, value)
        @allowed = allowed
        @value = value
      end

      # Chain an else block for when the attribute was
      # denied. Returns the original value if allowed,
      # otherwise yields the else block.
      def else
        if @allowed
          @value
        elsif block_given?
          yield
        end
      end
    end

    private

    def resolve_policy
      klass = Authorization::Resolver.resolve(
        __record__, type: :general
      )
      return nil unless klass

      klass.new(__user__, __record__)
    end

    # The heart of the guard. All attribute access routes
    # through method_missing. If the record responds to the
    # method, we check the policy's `_allowed?` method
    # before delegating.
    #
    # DenyAll: if no `<attr>_allowed?` method exists on the
    # policy, the attribute is denied by default.
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

    # An attribute is guarded when the policy exists and
    # the record has the attribute as a column or the
    # policy has an `_allowed?` method for it. All column
    # attributes are guarded; non-column methods pass
    # through unguarded.
    def guarded_attribute?(method_name)
      return false unless __policy__

      sym = method_name.to_sym
      column_names.include?(sym)
    end

    # Check the policy and raise or return nil on denial.
    def guard_attribute(attr_name)
      sym = attr_name.to_sym
      allowed_method = :"#{sym}_allowed?"

      # DenyAll: if no _allowed? method exists, deny.
      unless __policy__.respond_to?(allowed_method)
        if Turnstile.configuration.presented_mode == :strict
          raise AttributeDeniedError.new(
            attribute: sym,
            record: __record__,
            reason: "no #{allowed_method} defined"
          )
        end
        throw :turnstile_denied
      end

      result = __policy__.public_send(allowed_method)
      is_allowed = if result.respond_to?(:allowed?)
        result.allowed?
      else
        !!result
      end
      return if is_allowed

      if Turnstile.configuration.presented_mode == :strict
        reason = (result.reason if result.respond_to?(:reason))
        raise AttributeDeniedError.new(
          attribute: sym,
          record: __record__,
          reason: reason
        )
      end
      # In lenient mode, throw a symbol that
      # method_missing catches to return nil.
      throw :turnstile_denied
    end

    # Deep presentation: if the return value is an AR
    # record that has its own policy, wrap it. If it's a
    # collection (has_many), wrap as PresentedCollection.
    def maybe_present_association(_method_name, value)
      return value unless value

      if value.is_a?(ActiveRecord::Base)
        p_klass = Authorization::Resolver.resolve(
          value, type: :general
        )
        return value unless p_klass

        self.class.new(value, __user__)
      elsif value.is_a?(ActiveRecord::Relation)
        p_klass = Authorization::Resolver.resolve(
          value.klass, type: :general
        )
        return value unless p_klass

        PresentedCollection.new(value, __user__)
      else
        value
      end
    end

    # Memoized list of column attribute names as symbols.
    def column_names
      @column_names ||= if __record__.class.respond_to?(
        :column_names
      )
        __record__.class.column_names.map(&:to_sym).freeze
      else
        [].freeze
      end
    end
  end
end
