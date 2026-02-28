# frozen_string_literal: true

module Turnstile
  module Authorization
    # View policies answer visibility questions: which fields,
    # sections, or UI elements should be shown to a given user
    # for a given record. They are distinct from model policies
    # (which gate mutations) and context policies (which
    # inspect the request).
    #
    # Two complementary facets live here:
    #
    # 1. *Permissions* — coarse-grained section/element gates.
    #    "May this user see the admin panel?"
    #
    # 2. *Attribute visibility* — fine-grained per-attribute
    #    control. "May this user see the salary column?"
    #
    # Views are expected to query the policy explicitly before
    # rendering protected content.
    #
    # == Section / element permissions
    #
    #   class ArticleViewPolicy < ViewPolicy
    #     permission :show_admin_panel,
    #       description: "see admin controls"
    #
    #     def show_admin_panel?
    #       user&.admin? ? allow(:show_admin_panel)
    #         : deny(:show_admin_panel)
    #     end
    #   end
    #
    # == Attribute visibility
    #
    #   class EmployeeViewPolicy < ViewPolicy
    #     # All attributes hidden unless listed.
    #     attribute :name,   default: :visible
    #     attribute :email,  default: :visible
    #     attribute :salary, default: :hidden
    #
    #     def salary_visible?
    #       user&.hr? ? allow_attr(:salary)
    #         : deny_attr(:salary, reason: "HR only")
    #     end
    #   end
    #
    #   # In a Phlex component:
    #   vp = view_policy(@employee)
    #   p { @employee.name }
    #   if vp.visible_attribute?(:salary).allowed?
    #     p { @employee.salary }
    #   end
    #
    class ViewPolicy < Policy
      # View policies strip the default CRUD permissions — they
      # are not about mutation. Clear inherited ones and let
      # subclasses declare their own visibility permissions.
      @own_permissions = {}

      class << self
        # Override the ancestor walk so that permissions declared
        # on Policy (CRUD) do not bleed into view policies. We
        # collect only from ViewPolicy and its descendants,
        # stopping before Policy's own_permissions are merged.
        def permissions
          ancestors
            .take_while { |a| a != Policy }
            .select { |a| a.respond_to?(:own_permissions, true) }
            .reverse
            .each_with_object({}) do |a, h|
              h.merge!(a.own_permissions)
            end
        end

        # Declare that this policy governs an attribute.
        #
        # @param name [Symbol] the attribute name
        # @param default [:visible, :hidden] the fallback when
        #   no <name>_visible? method is defined
        def attribute(name, default: :visible)
          name = name.to_sym
          unless %i[visible hidden].include?(default)
            raise ArgumentError,
              "default must be :visible or :hidden, " \
              "got #{default.inspect}"
          end
          own_attribute_rules[name] = default
        end

        # Merged attribute rules across the ancestor chain,
        # stopping before Policy (same cut-off as permissions).
        #
        # @return [Hash{Symbol => Symbol}]
        def attribute_rules
          ancestors
            .take_while { |a| a != Policy }
            .select do |a|
              a.respond_to?(:own_attribute_rules, true)
            end
            .reverse
            .each_with_object({}) do |a, h|
              h.merge!(a.own_attribute_rules)
            end
        end

        # Attribute rules declared directly on this class.
        #
        # @return [Hash{Symbol => Symbol}]
        def own_attribute_rules
          @own_attribute_rules ||= {}
        end

        protected :own_attribute_rules
      end

      # ---------------------------------------------------
      # Section / element visibility (existing API)
      # ---------------------------------------------------

      # Test multiple visibility permissions at once.
      #
      #   policy.visibility(:show_salary, :show_admin_panel)
      #   # => { show_salary: true, show_admin_panel: false }
      #
      def visibility(*permission_names)
        permission_names.each_with_object({}) do |name, hash|
          result = public_send(:"#{name}?")
          hash[name] = result.allowed?
        end
      end

      # ---------------------------------------------------
      # Attribute visibility
      # ---------------------------------------------------

      # Query whether a single attribute is visible to the
      # current user.
      #
      # Resolution order:
      # 1. A method <name>_visible? on the policy instance.
      # 2. The declared default (:visible / :hidden).
      # 3. If the attribute was never declared, deny.
      #
      # @param name [Symbol]
      # @return [Result]
      def visible_attribute?(name)
        name = name.to_sym
        method = :"#{name}_visible?"

        return public_send(method) if respond_to?(method, true)

        rules = self.class.attribute_rules
        if rules.key?(name)
          if rules[name] == :visible
            allow_attr(name)
          else
            deny_attr(name,
              reason: "#{name} is hidden by default")
          end
        else
          deny_attr(name,
            reason: "#{name} is not a declared attribute")
        end
      end

      # All attributes the current user may see.
      #
      # @return [Array<Symbol>]
      def visible_attributes
        self.class.attribute_rules.keys.select do |name|
          visible_attribute?(name).allowed?
        end
      end

      # All declared attributes the current user may not see.
      #
      # @return [Array<Symbol>]
      def hidden_attributes
        self.class.attribute_rules.keys.reject do |name|
          visible_attribute?(name).allowed?
        end
      end

      # Strip hidden attributes from a hash or record. Returns
      # a plain Hash containing only the visible key/value
      # pairs — useful for serialization or API responses.
      #
      # @param source [Hash, #attributes] a hash or AR record
      # @return [Hash{Symbol => Object}]
      def filter_attributes(source)
        attrs = if source.respond_to?(:attributes)
          source.attributes.symbolize_keys
        else
          source.transform_keys(&:to_sym)
        end

        allowed = visible_attributes
        attrs.slice(*allowed)
      end

      # A view policy that permits everything. All declared
      # permissions allow, all declared attributes are visible,
      # and undeclared attribute queries also allow. Useful
      # during development or for public-facing records.
      class PermitAll < ViewPolicy
        # Any undeclared permission query allows.
        def method_missing(method_name, *args)
          if method_name.end_with?("?") && args.empty?
            perm = method_name.to_s.chomp("?").to_sym
            allow(perm)
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          method_name.end_with?("?") || super
        end

        # Override: every declared attribute is visible, and
        # undeclared attributes are also visible.
        def visible_attribute?(name)
          allow_attr(name.to_sym)
        end
      end

      private

      # Build an allowing Result for an attribute check.
      def allow_attr(attr_name)
        Result.new(true,
          permission: :"#{attr_name}_visible")
      end

      # Build a denying Result for an attribute check.
      def deny_attr(attr_name, reason: nil)
        Result.new(false,
          permission: :"#{attr_name}_visible",
          reason: reason)
      end
    end
  end
end
