# frozen_string_literal: true

module Turnstile
  # Static analysis of controllers and routes. Identifies
  # routable actions where authorization is not structurally
  # guaranteed — meaning the action relies on a manual
  # +authorize+ call rather than automatic +before_action+
  # loading and authorization.
  #
  # This does NOT prove authorization is missing; it flags
  # actions that need human review or test coverage.
  #
  # == Usage
  #
  #   report = Turnstile::Audit.run
  #   report.each { |entry| puts entry }
  #
  # Or via Rake:
  #
  #   rake turnstile:audit
  #
  module Audit
    # One entry in the audit report.
    Entry = Data.define(
      :controller, :action, :status, :reason
    ) do
      def to_s
        format("%-40s %-12s %s (%s)", "#{controller}##{action}", status, (status == :ok) ? "covered" : "UNVERIFIED",
          reason)
      end
    end

    class << self
      # Run the audit. Returns an array of Entry objects.
      #
      # @return [Array<Entry>]
      def run
        entries = []
        each_turnstile_route do |ctrl_class, action|
          entries << analyze(ctrl_class, action)
        end
        entries.sort_by { |e| [e.controller, e.action] }
      end

      # Print a formatted report to the given IO.
      #
      # @param io [IO] output stream (default: $stdout)
      # @return [Boolean] true when all actions are covered
      def report(io: $stdout)
        entries = run

        if entries.empty?
          io.puts "No Turnstile controllers found " \
                  "in routes."
          return true
        end

        ok = entries.select { |e| e.status == :ok }
        warn = entries.reject { |e| e.status == :ok }

        io.puts "Turnstile Authorization Audit"
        io.puts "=" * 50
        io.puts

        unless warn.empty?
          io.puts "UNVERIFIED (#{warn.size}):"
          io.puts "-" * 50
          warn.each { |e| io.puts "  #{e}" }
          io.puts
        end

        unless ok.empty?
          io.puts "OK (#{ok.size}):"
          io.puts "-" * 50
          ok.each { |e| io.puts "  #{e}" }
          io.puts
        end

        io.puts "#{entries.size} actions, " \
                "#{ok.size} covered, " \
                "#{warn.size} unverified"

        warn.empty?
      end

      private

      # Yields [controller_class, action_symbol] for every
      # routable action on a Turnstile controller.
      def each_turnstile_route
        routes = Rails.application.routes.routes
        seen = Set.new

        routes.each do |route|
          defaults = route.defaults
          next unless defaults[:controller] &&
            defaults[:action]

          ctrl_name = "#{defaults[:controller]
            .camelize}Controller"
          action = defaults[:action].to_sym

          # Deduplicate (multiple HTTP verbs for same
          # controller#action).
          key = "#{ctrl_name}##{action}"
          next if seen.include?(key)

          seen << key

          ctrl_class = ctrl_name.safe_constantize
          next unless ctrl_class
          next unless turnstile_controller?(ctrl_class)

          yield ctrl_class, action
        end
      end

      def turnstile_controller?(ctrl_class)
        ctrl_class < Turnstile::Controller
      rescue TypeError
        false
      end

      def analyze(ctrl_class, action)
        # 1. Skip-auth declared at the class level?
        if ctrl_class.turnstile_skip_auth_actions
            .include?(action)
          return Entry.new(
            controller: ctrl_class.name,
            action: action,
            status: :ok,
            reason: "skip_authorization declared"
          )
        end

        # 2. Action loads a resource automatically?
        if auto_loaded?(ctrl_class, action)
          return Entry.new(
            controller: ctrl_class.name,
            action: action,
            status: :ok,
            reason: "auto-loaded and authorized"
          )
        end

        # 3. Custom loader registered?
        if ctrl_class.turnstile_config
            .custom_loaders.key?(action)
          return Entry.new(
            controller: ctrl_class.name,
            action: action,
            status: :ok,
            reason: "custom loader registered"
          )
        end

        # 4. Not auto-loaded, no skip — needs manual
        #    authorize call.
        Entry.new(
          controller: ctrl_class.name,
          action: action,
          status: :unverified,
          reason: "no auto-load; needs manual authorize"
        )
      end

      # Does the loader automatically load a resource for
      # this action? If so, turnstile_authorize_resource
      # will handle authorization.
      def auto_loaded?(ctrl_class, action)
        config = ctrl_class.turnstile_config
        explicit = config.action_modes[action]

        # Explicit mode set by DSL.
        return false if explicit == :skip
        return true if %i[singular plural].include?(explicit)

        # Fall back to built-in defaults.
        return false if Loading::Loader::SKIP_ACTIONS
          .include?(action)

        Loading::Loader::SINGULAR_ACTIONS
          .include?(action) ||
          Loading::Loader::PLURAL_ACTIONS
            .include?(action)
      end
    end
  end
end
