# frozen_string_literal: true

module Turnstile
  # Base error for all Turnstile exceptions.
  class Error < StandardError; end

  # Raised when a policy denies access. Carries the denial reason
  # set by the policy, if one was provided — a herald's message
  # rather than a slammed gate.
  class NotAuthorizedError < Error
    # @return [Object, nil] the user who was denied
    attr_reader :user

    # @return [Object, nil] the record that was guarded
    attr_reader :record

    # @return [Symbol, nil] the permission that was tested
    attr_reader :permission

    # @return [Class, nil] the policy class that rendered judgment
    attr_reader :policy

    # @return [String, nil] a human-readable reason supplied by
    #   the policy explaining why access was denied
    attr_reader :reason

    def initialize(message = nil, user: nil, record: nil,
      permission: nil, policy: nil, reason: nil)
      @user = user
      @record = record
      @permission = permission
      @policy = policy
      @reason = reason
      super(message || default_message)
    end

    private

    def default_message
      parts = ["not authorized"]
      parts << "to #{permission}" if permission
      parts << "on #{record.class}" if record
      parts << "(#{reason})" if reason
      parts.join(" ")
    end
  end

  # Raised when no policy class can be found for a record.
  class PolicyNotFoundError < Error
    # @return [Object] the record for which lookup failed
    attr_reader :record

    def initialize(record)
      @record = record
      super("no policy found for #{record.inspect}")
    end
  end

  # Raised when a controller neglects to authorize.
  class AuthorizationNotPerformedError < Error
    def initialize
      super(
        "authorization was not performed for this action; " \
        "call authorize, skip_authorization, or configure " \
        "the action to bypass authorization"
      )
    end
  end

  # Raised when a presented record's attribute is accessed
  # but the view policy denies visibility. Only raised in
  # strict mode (the default).
  class AttributeDeniedError < Error
    # @return [Symbol] the attribute that was denied
    attr_reader :attribute

    # @return [Object] the record whose attribute was guarded
    attr_reader :record

    # @return [String, nil] reason from the view policy
    attr_reader :reason

    def initialize(attribute:, record:, reason: nil)
      @attribute = attribute
      @record = record
      @reason = reason
      super(default_message)
    end

    private

    def default_message
      msg = "attribute #{attribute} on #{record.class}"
      msg << " is not visible"
      msg << " (#{reason})" if reason
      msg
    end
  end

  # Raised when resource loading fails.
  class ResourceNotFoundError < Error
    # @return [Class] the model class that was queried
    attr_reader :resource_class

    # @return [Object] the identifier that was sought
    attr_reader :resource_id

    def initialize(resource_class, resource_id)
      @resource_class = resource_class
      @resource_id = resource_id
      super(
        "#{resource_class} with id #{resource_id.inspect} " \
        "not found"
      )
    end
  end
end
