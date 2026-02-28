# frozen_string_literal: true

require "logger"

module Turnstile
  # A common logging sink for the entire gem. Falls back to the
  # Rails logger when Rails is present, or to a silent null logger
  # when it is not. Host applications may replace the logger at
  # any time via Turnstile.configure or direct assignment.
  module Logging
    # A logger that swallows all output — the silence of an
    # empty hall when no council is in session.
    class NullLogger < ::Logger
      def initialize
        super(File::NULL)
        self.level = ::Logger::FATAL
      end

      def add(*_args, &_block) = nil
    end

    module_function

    # Resolve the most appropriate default logger. Rails takes
    # precedence; absent that, silence.
    def default_logger
      if defined?(::Rails) && ::Rails.respond_to?(:logger) &&
          ::Rails.logger
        ::Rails.logger
      else
        NullLogger.new
      end
    end
  end
end
