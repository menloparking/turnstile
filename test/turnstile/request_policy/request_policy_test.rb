# frozen_string_literal: true

require_relative "../../test_helper"
require "rack"
require "rack/test"

# --- Test policy subclasses --------------------------------

# Denies everything (the default Base behaviour).
class DenyAllRequestPolicy < Turnstile::RequestPolicy::Base
end

# Allows only requests from 127.0.0.1.
class LoopbackOnlyPolicy < Turnstile::RequestPolicy::Base
  def call
    if request.ip == "127.0.0.1"
      allow
    else
      deny(reason: "IP #{request.ip} not permitted")
    end
  end
end

# Allows only GET requests.
class GetOnlyPolicy < Turnstile::RequestPolicy::Base
  def call
    if request.get?
      allow
    else
      deny(reason: "only GET requests accepted")
    end
  end
end

# Blocks a specific path prefix.
class BlockAdminPathPolicy < Turnstile::RequestPolicy::Base
  def call
    if request.path.start_with?("/admin")
      deny(reason: "admin path blocked")
    else
      allow
    end
  end
end

# --- Base class tests --------------------------------------

class RequestPolicyBaseTest < Minitest::Test
  include TurnstileTestSetup

  def test_base_denies_by_default
    env = Rack::MockRequest.env_for("/")
    request = Rack::Request.new(env)
    policy = Turnstile::RequestPolicy::Base.new(request)
    result = policy.call

    assert result.denied?
    assert_equal :request, result.permission
    assert_match(/no request policy rules/, result.reason)
  end

  def test_permit_all_allows_everything
    env = Rack::MockRequest.env_for("/")
    request = Rack::Request.new(env)
    policy = Turnstile::RequestPolicy::PermitAll.new(request)
    result = policy.call

    assert result.allowed?
    assert_equal :request, result.permission
  end

  def test_request_attribute_accessible
    env = Rack::MockRequest.env_for(
      "/some/path",
      :method => "POST",
      "REMOTE_ADDR" => "10.0.0.42"
    )
    request = Rack::Request.new(env)
    policy = Turnstile::RequestPolicy::Base.new(request)

    assert_equal "/some/path", policy.request.path
    assert_equal "POST", policy.request.request_method
    assert_equal "10.0.0.42", policy.request.ip
  end
end

# --- Custom policy tests -----------------------------------

class RequestPolicyCustomTest < Minitest::Test
  include TurnstileTestSetup

  def test_loopback_policy_allows_localhost
    env = Rack::MockRequest.env_for(
      "/", "REMOTE_ADDR" => "127.0.0.1"
    )
    request = Rack::Request.new(env)
    result = LoopbackOnlyPolicy.new(request).call

    assert result.allowed?
  end

  def test_loopback_policy_denies_other_ips
    env = Rack::MockRequest.env_for(
      "/", "REMOTE_ADDR" => "192.168.1.1"
    )
    request = Rack::Request.new(env)
    result = LoopbackOnlyPolicy.new(request).call

    assert result.denied?
    assert_match(/192\.168\.1\.1/, result.reason)
  end

  def test_get_only_policy_allows_get
    env = Rack::MockRequest.env_for("/", method: "GET")
    request = Rack::Request.new(env)
    result = GetOnlyPolicy.new(request).call

    assert result.allowed?
  end

  def test_get_only_policy_denies_post
    env = Rack::MockRequest.env_for("/", method: "POST")
    request = Rack::Request.new(env)
    result = GetOnlyPolicy.new(request).call

    assert result.denied?
    assert_equal "only GET requests accepted", result.reason
  end

  def test_block_admin_path_denies_admin
    env = Rack::MockRequest.env_for("/admin/users")
    request = Rack::Request.new(env)
    result = BlockAdminPathPolicy.new(request).call

    assert result.denied?
    assert_equal "admin path blocked", result.reason
  end

  def test_block_admin_path_allows_other
    env = Rack::MockRequest.env_for("/articles")
    request = Rack::Request.new(env)
    result = BlockAdminPathPolicy.new(request).call

    assert result.allowed?
  end
end

# --- Middleware tests --------------------------------------

class RequestPolicyMiddlewareTest < Minitest::Test
  include TurnstileTestSetup

  # A minimal Rack app that returns 200.
  INNER_APP = ->(_env) { [200, {"content-type" => "text/plain"}, ["OK"]] }

  def test_passes_through_when_no_policy_configured
    Turnstile.configuration.request_policy = nil
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )
    env = Rack::MockRequest.env_for("/")
    status, _headers, body = middleware.call(env)

    assert_equal 200, status
    assert_equal "OK", body.first
  end

  def test_passes_through_when_policy_allows
    Turnstile.configuration.request_policy =
      Turnstile::RequestPolicy::PermitAll
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )
    env = Rack::MockRequest.env_for("/")
    status, _headers, body = middleware.call(env)

    assert_equal 200, status
    assert_equal "OK", body.first
  end

  def test_blocks_when_policy_denies
    Turnstile.configuration.request_policy =
      DenyAllRequestPolicy
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )
    env = Rack::MockRequest.env_for("/")
    status, headers, body = middleware.call(env)

    assert_equal 403, status
    assert_equal "text/plain", headers["content-type"]
    assert_equal "Forbidden", body.first
  end

  def test_custom_status_on_denial
    Turnstile.configuration.request_policy =
      DenyAllRequestPolicy
    Turnstile.configuration.request_policy_status = 503
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )
    env = Rack::MockRequest.env_for("/")
    status, _headers, _body = middleware.call(env)

    assert_equal 503, status
  end

  def test_custom_body_string_on_denial
    Turnstile.configuration.request_policy =
      DenyAllRequestPolicy
    Turnstile.configuration.request_policy_body =
      "Service Unavailable"
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )
    env = Rack::MockRequest.env_for("/")
    _status, _headers, body = middleware.call(env)

    assert_equal "Service Unavailable", body.first
  end

  def test_custom_body_callable_on_denial
    Turnstile.configuration.request_policy =
      DenyAllRequestPolicy
    Turnstile.configuration.request_policy_body =
      ->(result) { "Denied: #{result.reason}" }
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )
    env = Rack::MockRequest.env_for("/")
    _status, _headers, body = middleware.call(env)

    assert_match(/Denied:/, body.first)
  end

  def test_ip_policy_integration
    Turnstile.configuration.request_policy =
      LoopbackOnlyPolicy

    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )

    # Allowed from localhost.
    env = Rack::MockRequest.env_for(
      "/", "REMOTE_ADDR" => "127.0.0.1"
    )
    status, _headers, _body = middleware.call(env)
    assert_equal 200, status

    # Denied from elsewhere.
    env = Rack::MockRequest.env_for(
      "/", "REMOTE_ADDR" => "10.0.0.1"
    )
    status, _headers, _body = middleware.call(env)
    assert_equal 403, status
  end

  def test_result_is_frozen
    env = Rack::MockRequest.env_for("/")
    request = Rack::Request.new(env)
    result = Turnstile::RequestPolicy::Base.new(request).call

    assert result.frozen?
  end
end
