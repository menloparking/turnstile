# frozen_string_literal: true

module Turnstile
  # Wraps an ActiveRecord::Relation (or any Enumerable of
  # records) so that each element is lazily presented through
  # a Presented decorator when enumerated. The collection
  # itself delegates size/count queries to the underlying
  # relation without triggering presentation, keeping SQL
  # aggregations efficient.
  #
  # == Usage
  #
  #   articles = Article.where(published: true)
  #   collection = PresentedCollection.new(articles, user)
  #   collection.each { |p| p.title }  # each p is Presented
  #   collection.size                   # delegates to relation
  #
  class PresentedCollection
    include Enumerable

    # @return [Object] the underlying relation or array
    attr_reader :__relation__

    # @return [Object, nil] the user for policy evaluation
    attr_reader :__user__

    def initialize(relation, user)
      @__relation__ = relation
      @__user__ = user
    end

    # Core Enumerable implementation — wrap each record in
    # a Presented as it is yielded. This is the lazy seam:
    # records are only wrapped when iterated.
    def each(&block)
      return enum_for(:each) unless block

      __relation__.each do |record|
        block.call(Presented.new(record, __user__))
      end
    end

    # --- Delegation for count / size queries ---
    # These hit the relation directly (SQL COUNT) without
    # loading or presenting records.

    def count(...)
      __relation__.count(...)
    end

    def empty?
      __relation__.empty?
    end

    def length
      __relation__.length
    end

    def size
      __relation__.size
    end

    # --- Rails compatibility ---

    # ActionView collection rendering and partial lookups
    # call model_name on the collection's klass.
    def klass
      __relation__.respond_to?(:klass) ? __relation__.klass : nil
    end

    def model_name
      klass&.model_name
    end

    # Some helpers call to_ary to test "is this an array?"
    # We deliberately do NOT implement to_ary so that the
    # collection is not silently coerced into an Array in
    # argument splatting. If explicit conversion is needed,
    # callers should use to_a (inherited from Enumerable).

    # Provide a useful inspect.
    def inspect
      klass_name = klass&.name || "Unknown"
      "#<Turnstile::PresentedCollection" \
        "(#{klass_name}) size: #{size}>"
    end

    # Unwrap back to the raw relation.
    def unwrap
      __relation__
    end
  end
end
