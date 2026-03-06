# frozen_string_literal: true

module Turnstile
  # Monitors how many ActiveRecord queries are executed during
  # a block and warns or raises when the count exceeds a budget.
  #
  # Designed for wrapping permission checks (can?, has_role?,
  # policy scope resolve) to enforce the design invariant that
  # each check maps to a bounded number of SQL queries.
  #
  # Three modes:
  #   :off   — no monitoring, zero overhead
  #   :warn  — logs a warning with the query list
  #   :raise — raises QueryBudget::Exceeded
  module QueryBudget
    # Raised when query count exceeds the budget in :raise mode.
    class Exceeded < Turnstile::Error
      # @return [String] the name of the method that exceeded
      attr_reader :method_name

      # @return [Integer] how many queries were executed
      attr_reader :query_count

      # @return [Integer] the configured budget
      attr_reader :budget

      # @return [Array<String>] the SQL strings that fired
      attr_reader :queries

      def initialize(method_name, query_count, budget,
        queries)
        @method_name = method_name
        @query_count = query_count
        @budget = budget
        @queries = queries
        super(default_message)
      end

      private

      def default_message
        noun = (query_count == 1) ? "query" : "queries"
        lines = queries.map.with_index(1) do |q, i|
          "  #{i}. #{q}"
        end
        "#{method_name} executed #{query_count} #{noun} " \
          "(budget: #{budget})\n#{lines.join("\n")}"
      end
    end

    # Subscribes to sql.active_record for the duration of a
    # block and records every non-cached, non-schema query.
    class Counter
      # @return [Array<String>] SQL strings captured
      attr_reader :queries

      def initialize
        @queries = []
      end

      # Yields the block while recording SQL queries.
      #
      # @return [Object] the block's return value
      def track
        subscriber = ActiveSupport::Notifications
          .subscribe("sql.active_record") do |event|
            payload = event.payload
            next if payload[:name] == "SCHEMA"
            next if payload[:name] == "EXPLAIN"
            next if payload[:cached]

            @queries << payload[:sql]
        end

        yield
      ensure
        ActiveSupport::Notifications
          .unsubscribe(subscriber)
      end

      # @return [Integer] number of queries recorded
      def count
        queries.size
      end
    end

    class << self
      # Wraps a block with query budget enforcement.
      #
      # @param method_name [String] label for error messages
      # @param mode [:off, :warn, :raise] enforcement mode
      # @param budget [Integer] max allowed queries
      # @return [Object] the block's return value
      def enforce(method_name, mode: :off, budget: 1, &block)
        return yield if mode == :off

        counter = Counter.new
        result = counter.track(&block)

        if counter.count > budget
          handle_exceeded(
            method_name, counter, budget, mode
          )
        end

        result
      end

      private

      def handle_exceeded(method_name, counter, budget, mode)
        case mode
        when :warn
          warn_exceeded(method_name, counter, budget)
        when :raise
          raise Exceeded.new(
            method_name, counter.count,
            budget, counter.queries
          )
        end
      end

      def warn_exceeded(method_name, counter, budget)
        noun = (counter.count == 1) ? "query" : "queries"
        Turnstile.logger&.warn(
          "[Turnstile] Query budget exceeded: " \
          "#{method_name} executed " \
          "#{counter.count} #{noun} " \
          "(budget: #{budget})"
        )
        counter.queries.each_with_index do |q, i|
          Turnstile.logger&.warn("  #{i + 1}. #{q}")
        end
      end
    end
  end
end
