# frozen_string_literal: true

require_relative "../../test_helper"

module Turnstile
  class QueryBudgetExceededTest < Minitest::Test
    def test_attributes
      err = QueryBudget::Exceeded.new(
        "show?", 3, 1,
        ["SELECT 1", "SELECT 2", "SELECT 3"]
      )
      assert_equal "show?", err.method_name
      assert_equal 3, err.query_count
      assert_equal 1, err.budget
      assert_equal 3, err.queries.size
    end

    def test_message_includes_method_name
      err = QueryBudget::Exceeded.new(
        "can?", 2, 1, ["SELECT 1", "SELECT 2"]
      )
      assert_includes err.message, "can?"
    end

    def test_message_includes_counts
      err = QueryBudget::Exceeded.new(
        "can?", 2, 1, ["SELECT 1", "SELECT 2"]
      )
      assert_includes err.message, "2 queries"
      assert_includes err.message, "(budget: 1)"
    end

    def test_message_singular_query_noun
      err = QueryBudget::Exceeded.new(
        "can?", 1, 0, ["SELECT 1"]
      )
      assert_includes err.message, "1 query"
      refute_includes err.message, "queries"
    end

    def test_message_lists_sql
      err = QueryBudget::Exceeded.new(
        "can?", 2, 1, ["SELECT a", "SELECT b"]
      )
      assert_includes err.message, "1. SELECT a"
      assert_includes err.message, "2. SELECT b"
    end

    def test_inherits_from_turnstile_error
      err = QueryBudget::Exceeded.new("x", 1, 0, ["q"])
      assert_kind_of Turnstile::Error, err
    end
  end

  class QueryBudgetCounterTest < Minitest::Test
    include TurnstileTestSetup

    def test_captures_real_queries
      counter = QueryBudget::Counter.new
      counter.track do
        Article.where(title: "nonexistent").to_a
      end
      assert_operator counter.count, :>=, 1
      assert(counter.queries.any? do |q|
        q.include?("articles")
      end)
    end

    def test_ignores_cached_queries
      # Warm the cache, then measure.
      Article.where(title: "warm").to_a

      counter = QueryBudget::Counter.new
      counter.track do
        # Fire a notification with cached: true by
        # instrumenting manually.
        ActiveSupport::Notifications.instrument(
          "sql.active_record",
          sql: "SELECT cached", name: "Article Load",
          cached: true
        )
      end
      refute counter.queries.include?("SELECT cached")
    end

    def test_ignores_schema_queries
      counter = QueryBudget::Counter.new
      counter.track do
        ActiveSupport::Notifications.instrument(
          "sql.active_record",
          sql: "PRAGMA table_info", name: "SCHEMA",
          cached: false
        )
      end
      assert_equal 0, counter.count
    end

    def test_ignores_explain_queries
      counter = QueryBudget::Counter.new
      counter.track do
        ActiveSupport::Notifications.instrument(
          "sql.active_record",
          sql: "EXPLAIN SELECT 1", name: "EXPLAIN",
          cached: false
        )
      end
      assert_equal 0, counter.count
    end

    def test_count_returns_query_count
      counter = QueryBudget::Counter.new
      counter.track do
        Article.where(title: "a").to_a
        Article.where(title: "b").to_a
      end
      assert_operator counter.count, :>=, 2
    end

    def test_empty_block_records_nothing
      counter = QueryBudget::Counter.new
      counter.track { nil }
      assert_equal 0, counter.count
      assert_empty counter.queries
    end

    def test_returns_block_value
      counter = QueryBudget::Counter.new
      result = counter.track { 42 }
      assert_equal 42, result
    end

    def test_unsubscribes_after_block
      counter = QueryBudget::Counter.new
      counter.track { Article.where(title: "inside").to_a }
      before = counter.count

      # Queries outside the block should not be recorded.
      Article.where(title: "outside").to_a
      assert_equal before, counter.count
    end

    def test_unsubscribes_on_exception
      counter = QueryBudget::Counter.new
      assert_raises(RuntimeError) do
        counter.track { raise "boom" }
      end
      # After the exception, no further capture.
      Article.where(title: "after").to_a
      assert_equal 0, counter.count
    end
  end

  class QueryBudgetEnforceTest < Minitest::Test
    include TurnstileTestSetup

    def test_off_mode_returns_block_value
      result = QueryBudget.enforce("x", mode: :off) do
        Article.where(title: "test").to_a
        :ok
      end
      assert_equal :ok, result
    end

    def test_off_mode_does_not_track
      # :off should skip Counter entirely; even many queries
      # must not raise or warn.
      result = QueryBudget.enforce(
        "x", mode: :off, budget: 0
      ) do
        Article.where(title: "a").to_a
        Article.where(title: "b").to_a
        :fine
      end
      assert_equal :fine, result
    end

    def test_raise_mode_raises_when_exceeded
      err = assert_raises(QueryBudget::Exceeded) do
        QueryBudget.enforce(
          "resolve", mode: :raise, budget: 0
        ) do
          Article.where(title: "x").to_a
        end
      end
      assert_equal "resolve", err.method_name
      assert_operator err.query_count, :>=, 1
      assert_equal 0, err.budget
    end

    def test_raise_mode_returns_value_when_within_budget
      result = QueryBudget.enforce(
        "check", mode: :raise, budget: 100
      ) do
        Article.where(title: "x").to_a
        :ok
      end
      assert_equal :ok, result
    end

    def test_warn_mode_logs_warning
      log_output = StringIO.new
      Turnstile.logger = Logger.new(log_output)

      QueryBudget.enforce(
        "scope_resolve", mode: :warn, budget: 0
      ) do
        Article.where(title: "x").to_a
      end

      log_output.rewind
      output = log_output.read
      assert_includes output, "Query budget exceeded"
      assert_includes output, "scope_resolve"
    end

    def test_warn_mode_returns_value
      log_output = StringIO.new
      Turnstile.logger = Logger.new(log_output)

      result = QueryBudget.enforce(
        "x", mode: :warn, budget: 0
      ) do
        Article.where(title: "x").to_a
        :ok
      end
      assert_equal :ok, result
    end

    def test_warn_mode_does_not_raise
      log_output = StringIO.new
      Turnstile.logger = Logger.new(log_output)

      # Should not raise, even though budget is exceeded.
      QueryBudget.enforce(
        "x", mode: :warn, budget: 0
      ) do
        Article.where(title: "x").to_a
      end
    end

    def test_exactly_at_budget_does_not_trigger
      # Budget of 1, one query — should not raise.
      result = QueryBudget.enforce(
        "check", mode: :raise, budget: 1
      ) do
        Article.where(title: "x").to_a
        :ok
      end
      assert_equal :ok, result
    end

    def test_zero_queries_within_any_budget
      result = QueryBudget.enforce(
        "x", mode: :raise, budget: 0
      ) do
        :ok
      end
      assert_equal :ok, result
    end
  end

  class QueryBudgetConfigTest < Minitest::Test
    include TurnstileTestSetup

    def test_default_mode_is_off
      assert_equal :off,
        Turnstile.configuration.query_budget_mode
    end

    def test_default_budget_is_one
      assert_equal 1,
        Turnstile.configuration.query_budget
    end

    def test_configure_mode
      Turnstile.configure do |c|
        c.query_budget_mode = :raise
      end
      assert_equal :raise,
        Turnstile.configuration.query_budget_mode
    end

    def test_configure_budget
      Turnstile.configure { |c| c.query_budget = 5 }
      assert_equal 5,
        Turnstile.configuration.query_budget
    end

    def test_reset_restores_defaults
      Turnstile.configure do |c|
        c.query_budget_mode = :raise
        c.query_budget = 10
      end
      Turnstile.reset_configuration!
      assert_equal :off,
        Turnstile.configuration.query_budget_mode
      assert_equal 1,
        Turnstile.configuration.query_budget
    end
  end
end
