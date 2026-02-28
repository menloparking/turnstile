# frozen_string_literal: true

require_relative "../test_helper"

module Turnstile
  class ConfigurationTest < Minitest::Test
    include TurnstileTestSetup

    def test_default_current_user_method
      assert_equal :current_user,
        Turnstile.configuration.current_user_method
    end

    def test_configure_block
      Turnstile.configure do |c|
        c.current_user_method = :authenticated_user
      end
      assert_equal :authenticated_user,
        Turnstile.configuration.current_user_method
    end

    def test_default_logger_when_no_rails
      # After reset, the logger should be a usable logging
      # object — either a stdlib Logger (when Rails is not
      # loaded) or Rails.logger (which may be a
      # BroadcastLogger in Rails 8+).
      Turnstile.reset_configuration!
      logger = Turnstile.logger
      assert_respond_to logger, :info
      assert_respond_to logger, :debug
      assert_respond_to logger, :warn
      assert_respond_to logger, :error
    end

    def test_logger_assignment
      custom = Logger.new($stdout)
      Turnstile.logger = custom
      assert_equal custom, Turnstile.logger
    end

    def test_reset_configuration
      Turnstile.configure do |c|
        c.current_user_method = :special_user
      end
      Turnstile.reset_configuration!
      assert_equal :current_user,
        Turnstile.configuration.current_user_method
    end
  end

  class ErrorsTest < Minitest::Test
    def test_not_authorized_error_attributes
      err = NotAuthorizedError.new(
        user: "gandalf",
        record: "article",
        permission: :update,
        policy: ArticlePolicy,
        reason: "you shall not pass"
      )
      assert_equal "gandalf", err.user
      assert_equal "article", err.record
      assert_equal :update, err.permission
      assert_equal ArticlePolicy, err.policy
      assert_equal "you shall not pass", err.reason
      assert_includes err.message, "you shall not pass"
      assert_includes err.message, "update"
    end

    def test_not_authorized_default_message
      err = NotAuthorizedError.new
      assert_includes err.message, "not authorized"
    end

    def test_policy_not_found_error
      err = PolicyNotFoundError.new(:widget)
      assert_equal :widget, err.record
      assert_includes err.message, "widget"
    end

    def test_resource_not_found_error
      err = ResourceNotFoundError.new(Article, 42)
      assert_equal Article, err.resource_class
      assert_equal 42, err.resource_id
      assert_includes err.message, "Article"
      assert_includes err.message, "42"
    end

    def test_authorization_not_performed_error
      err = AuthorizationNotPerformedError.new
      assert_includes err.message, "authorization"
    end
  end

  class LoggingTest < Minitest::Test
    include TurnstileTestSetup

    def test_null_logger_swallows_output
      logger = Logging::NullLogger.new
      # Should not raise.
      assert_nil logger.info("test")
      assert_nil logger.debug("test")
      assert_nil logger.warn("test")
    end

    def test_authorization_logs_denial
      User.create!(name: "Elrond", role: "admin")
      reader = User.create!(name: "Frodo", role: "reader")
      article = Article.create!(title: "Test")

      log_output = StringIO.new
      Turnstile.logger = Logger.new(log_output)

      Turnstile::Authorization.authorize(
        reader, article, :destroy, bang: false
      )

      log_output.rewind
      output = log_output.read
      assert_includes output, "denied"
      assert_includes output, "destroy"
    ensure
      Article.delete_all
      User.delete_all
    end

    def test_authorization_logs_allowance_at_debug
      admin = User.create!(name: "Elrond", role: "admin")
      article = Article.create!(title: "Test")

      log_output = StringIO.new
      logger = Logger.new(log_output)
      logger.level = Logger::DEBUG
      Turnstile.logger = logger

      Turnstile::Authorization.authorize(
        admin, article, :show, bang: false
      )

      log_output.rewind
      output = log_output.read
      assert_includes output, "allowed"
    ensure
      Article.delete_all
      User.delete_all
    end
  end
end
