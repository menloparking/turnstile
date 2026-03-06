# frozen_string_literal: true

require_relative "../../test_helper"
require "rack"

# --- Test request policies for composite tests --------

# Always allows.
class AlwaysAllowRequestPolicy <
  Turnstile::RequestPolicy::Base
  def call = allow
end

# Always denies with a reason.
class AlwaysDenyRequestPolicy <
  Turnstile::RequestPolicy::Base
  def call = deny(reason: "always denied")
end

# Allows only GET requests.
class CompositeGetOnlyPolicy <
  Turnstile::RequestPolicy::Base
  def call
    request.get? ? allow : deny(reason: "GET only")
  end
end

# Allows only loopback IPs.
class CompositeLoopbackPolicy <
  Turnstile::RequestPolicy::Base
  def call
    if request.ip == "127.0.0.1"
      allow
    else
      deny(reason: "loopback only")
    end
  end
end

# Blocks /admin paths.
class CompositeBlockAdminPolicy <
  Turnstile::RequestPolicy::Base
  def call
    if request.path.start_with?("/admin")
      deny(reason: "admin blocked")
    else
      allow
    end
  end
end

# --- AllOf (AND) tests ---------------------------------

class CompositeRequestAllOfTest < Minitest::Test
  include TurnstileTestSetup

  def test_all_of_allows_when_all_allow
    composite = Turnstile::Composite::Request::AllOf.build(
      AlwaysAllowRequestPolicy, AlwaysAllowRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.allowed?
  end

  def test_all_of_denies_when_first_denies
    composite = Turnstile::Composite::Request::AllOf.build(
      AlwaysDenyRequestPolicy, AlwaysAllowRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
    assert_equal "always denied", result.reason
  end

  def test_all_of_denies_when_second_denies
    composite = Turnstile::Composite::Request::AllOf.build(
      AlwaysAllowRequestPolicy, AlwaysDenyRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
    assert_equal "always denied", result.reason
  end

  def test_all_of_denies_when_all_deny
    composite = Turnstile::Composite::Request::AllOf.build(
      AlwaysDenyRequestPolicy, AlwaysDenyRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
  end

  def test_all_of_short_circuits_on_first_denial
    # The second policy would allow, but we never reach it
    # because the first denies.
    call_count = 0
    counter = Class.new(Turnstile::RequestPolicy::Base) {
      define_method(:call) {
        call_count += 1
        allow
      }
    }

    composite = Turnstile::Composite::Request::AllOf.build(
      AlwaysDenyRequestPolicy, counter
    )
    composite.new(get_request("/")).call

    assert_equal 0, call_count
  end

  def test_all_of_with_real_policies
    # GET from localhost: both should allow
    composite = Turnstile::Composite::Request::AllOf.build(
      CompositeGetOnlyPolicy, CompositeLoopbackPolicy
    )
    result = composite.new(
      get_request("/", ip: "127.0.0.1")
    ).call
    assert result.allowed?

    # POST from localhost: GET-only denies
    result = composite.new(
      post_request("/", ip: "127.0.0.1")
    ).call
    assert result.denied?
    assert_equal "GET only", result.reason

    # GET from external: loopback denies
    result = composite.new(
      get_request("/", ip: "10.0.0.1")
    ).call
    assert result.denied?
    assert_equal "loopback only", result.reason
  end

  def test_all_of_is_subclass_of_request_policy_base
    composite = Turnstile::Composite::Request::AllOf.build(
      AlwaysAllowRequestPolicy
    )
    assert composite < Turnstile::RequestPolicy::Base
  end

  def test_all_of_policies_frozen
    composite = Turnstile::Composite::Request::AllOf.build(
      AlwaysAllowRequestPolicy, AlwaysDenyRequestPolicy
    )
    assert composite.policies.frozen?
  end

  private

  def get_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "GET", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end

  def post_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "POST", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end
end

# --- AnyOf (OR) tests ----------------------------------

class CompositeRequestAnyOfTest < Minitest::Test
  include TurnstileTestSetup

  def test_any_of_allows_when_first_allows
    composite = Turnstile::Composite::Request::AnyOf.build(
      AlwaysAllowRequestPolicy, AlwaysDenyRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.allowed?
  end

  def test_any_of_allows_when_second_allows
    composite = Turnstile::Composite::Request::AnyOf.build(
      AlwaysDenyRequestPolicy, AlwaysAllowRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.allowed?
  end

  def test_any_of_denies_when_all_deny
    composite = Turnstile::Composite::Request::AnyOf.build(
      AlwaysDenyRequestPolicy, AlwaysDenyRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
  end

  def test_any_of_short_circuits_on_first_allow
    call_count = 0
    counter = Class.new(Turnstile::RequestPolicy::Base) {
      define_method(:call) {
        call_count += 1
        deny(reason: "counted")
      }
    }

    composite = Turnstile::Composite::Request::AnyOf.build(
      AlwaysAllowRequestPolicy, counter
    )
    composite.new(get_request("/")).call

    assert_equal 0, call_count
  end

  def test_any_of_returns_last_denial_reason
    fast_deny = Class.new(Turnstile::RequestPolicy::Base) {
      define_method(:call) { deny(reason: "first") }
    }
    slow_deny = Class.new(Turnstile::RequestPolicy::Base) {
      define_method(:call) { deny(reason: "second") }
    }

    composite = Turnstile::Composite::Request::AnyOf.build(
      fast_deny, slow_deny
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
    assert_equal "second", result.reason
  end

  def test_any_of_with_empty_policies_denies
    composite = Turnstile::Composite::Request::AnyOf.build
    result = composite.new(get_request("/")).call

    assert result.denied?
    assert_match(/no policies/, result.reason)
  end

  def test_any_of_with_real_policies
    # Either GET or loopback suffices.
    composite = Turnstile::Composite::Request::AnyOf.build(
      CompositeGetOnlyPolicy, CompositeLoopbackPolicy
    )

    # GET from external: GET-only allows
    result = composite.new(
      get_request("/", ip: "10.0.0.1")
    ).call
    assert result.allowed?

    # POST from loopback: loopback allows
    result = composite.new(
      post_request("/", ip: "127.0.0.1")
    ).call
    assert result.allowed?

    # POST from external: both deny
    result = composite.new(
      post_request("/", ip: "10.0.0.1")
    ).call
    assert result.denied?
  end

  def test_any_of_is_subclass_of_request_policy_base
    composite = Turnstile::Composite::Request::AnyOf.build(
      AlwaysAllowRequestPolicy
    )
    assert composite < Turnstile::RequestPolicy::Base
  end

  private

  def get_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "GET", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end

  def post_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "POST", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end
end

# --- NoneOf (NOT) tests --------------------------------

class CompositeRequestNoneOfTest < Minitest::Test
  include TurnstileTestSetup

  def test_none_of_allows_when_all_deny
    composite = Turnstile::Composite::Request::NoneOf.build(
      AlwaysDenyRequestPolicy, AlwaysDenyRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.allowed?
  end

  def test_none_of_denies_when_any_allows
    composite = Turnstile::Composite::Request::NoneOf.build(
      AlwaysDenyRequestPolicy, AlwaysAllowRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
  end

  def test_none_of_denies_when_all_allow
    composite = Turnstile::Composite::Request::NoneOf.build(
      AlwaysAllowRequestPolicy, AlwaysAllowRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
  end

  def test_none_of_single_policy_inverts_deny_to_allow
    composite = Turnstile::Composite::Request::NoneOf.build(
      AlwaysDenyRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.allowed?
  end

  def test_none_of_single_policy_inverts_allow_to_deny
    composite = Turnstile::Composite::Request::NoneOf.build(
      AlwaysAllowRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
  end

  def test_none_of_denial_includes_policy_info
    composite = Turnstile::Composite::Request::NoneOf.build(
      AlwaysAllowRequestPolicy
    )
    result = composite.new(get_request("/")).call

    assert result.denied?
    assert_match(
      /AlwaysAllowRequestPolicy.*allowed/, result.reason
    )
  end

  def test_none_of_with_real_policies
    # NOT(admin blocked) — allow admin, deny others
    composite = Turnstile::Composite::Request::NoneOf.build(
      CompositeBlockAdminPolicy
    )

    # /admin: BlockAdmin denies → NoneOf allows
    result = composite.new(get_request("/admin")).call
    assert result.allowed?

    # /articles: BlockAdmin allows → NoneOf denies
    result = composite.new(get_request("/articles")).call
    assert result.denied?
  end

  def test_none_of_is_subclass_of_request_policy_base
    composite = Turnstile::Composite::Request::NoneOf.build(
      AlwaysAllowRequestPolicy
    )
    assert composite < Turnstile::RequestPolicy::Base
  end

  private

  def get_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "GET", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end
end

# --- Operator syntax tests -----------------------------

class CompositeRequestOperatorTest < Minitest::Test
  include TurnstileTestSetup

  def test_ampersand_creates_all_of
    composite = AlwaysAllowRequestPolicy &
      CompositeGetOnlyPolicy
    assert composite < Turnstile::Composite::Request::AllOf
  end

  def test_pipe_creates_any_of
    composite = AlwaysAllowRequestPolicy |
      CompositeGetOnlyPolicy
    assert composite < Turnstile::Composite::Request::AnyOf
  end

  def test_tilde_creates_none_of
    composite = ~AlwaysAllowRequestPolicy
    assert composite < Turnstile::Composite::Request::NoneOf
  end

  def test_ampersand_evaluates_correctly
    composite = CompositeGetOnlyPolicy &
      CompositeLoopbackPolicy

    result = composite.new(
      get_request("/", ip: "127.0.0.1")
    ).call
    assert result.allowed?

    result = composite.new(
      post_request("/", ip: "127.0.0.1")
    ).call
    assert result.denied?
  end

  def test_pipe_evaluates_correctly
    composite = CompositeGetOnlyPolicy |
      CompositeLoopbackPolicy

    # POST from loopback: GET fails, loopback succeeds
    result = composite.new(
      post_request("/", ip: "127.0.0.1")
    ).call
    assert result.allowed?

    # POST from external: both fail
    result = composite.new(
      post_request("/", ip: "10.0.0.1")
    ).call
    assert result.denied?
  end

  def test_tilde_evaluates_correctly
    composite = ~CompositeBlockAdminPolicy

    # /admin: block denies → NOT inverts to allow
    result = composite.new(get_request("/admin")).call
    assert result.allowed?

    # /home: block allows → NOT inverts to deny
    result = composite.new(get_request("/home")).call
    assert result.denied?
  end

  private

  def get_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "GET", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end

  def post_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "POST", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end
end

# --- Nesting tests -------------------------------------

class CompositeRequestNestingTest < Minitest::Test
  include TurnstileTestSetup

  def test_nested_all_of_with_any_of
    # Must be GET AND (loopback OR not-admin-path)
    inner = Turnstile.any_of(
      CompositeLoopbackPolicy, CompositeBlockAdminPolicy
    )
    composite = Turnstile.all_of(
      CompositeGetOnlyPolicy, inner
    )

    # GET from loopback to /admin: GET ok, loopback ok → allow
    result = composite.new(
      get_request("/admin", ip: "127.0.0.1")
    ).call
    assert result.allowed?

    # GET from external to /home: GET ok, not-admin ok → allow
    result = composite.new(
      get_request("/home", ip: "10.0.0.1")
    ).call
    assert result.allowed?

    # GET from external to /admin: GET ok, loopback fails,
    # block-admin denies → inner any_of denies → deny
    result = composite.new(
      get_request("/admin", ip: "10.0.0.1")
    ).call
    assert result.denied?

    # POST from loopback: GET fails → deny (short circuit)
    result = composite.new(
      post_request("/admin", ip: "127.0.0.1")
    ).call
    assert result.denied?
  end

  def test_nested_operator_syntax
    # (GET & loopback) | ~block-admin
    composite =
      (CompositeGetOnlyPolicy & CompositeLoopbackPolicy) |
      (~CompositeBlockAdminPolicy)

    # GET from loopback anywhere: left side allows
    result = composite.new(
      get_request("/admin", ip: "127.0.0.1")
    ).call
    assert result.allowed?

    # POST from external to /admin: left denies,
    # right: block-admin denies /admin → NOT inverts → allow
    result = composite.new(
      post_request("/admin", ip: "10.0.0.1")
    ).call
    assert result.allowed?

    # POST from external to /home: left denies,
    # right: block-admin allows /home → NOT inverts → deny
    result = composite.new(
      post_request("/home", ip: "10.0.0.1")
    ).call
    assert result.denied?
  end

  def test_deeply_nested_three_levels
    # NOT(any_of(GET, all_of(loopback, NOT(block-admin))))
    inner_not = ~CompositeBlockAdminPolicy
    inner_all = Turnstile.all_of(
      CompositeLoopbackPolicy, inner_not
    )
    inner_any = Turnstile.any_of(
      CompositeGetOnlyPolicy, inner_all
    )
    composite = Turnstile.none_of(inner_any)

    # GET request: inner_any allows (GET ok) → none_of denies
    result = composite.new(get_request("/")).call
    assert result.denied?

    # POST from loopback to /admin: inner_all checks
    # loopback(ok) AND NOT(block-admin) — block-admin denies
    # /admin → NOT allows → inner_all allows → inner_any
    # allows → none_of denies
    result = composite.new(
      post_request("/admin", ip: "127.0.0.1")
    ).call
    assert result.denied?

    # POST from external to /home: GET fails, loopback fails
    # → inner_all fails, inner_any: both fail → denies
    # → none_of inverts → allows
    result = composite.new(
      post_request("/home", ip: "10.0.0.1")
    ).call
    assert result.allowed?
  end

  private

  def get_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "GET", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end

  def post_request(path, ip: "127.0.0.1")
    env = Rack::MockRequest.env_for(
      path, :method => "POST", "REMOTE_ADDR" => ip
    )
    Rack::Request.new(env)
  end
end

# --- Middleware integration tests ----------------------

class CompositeRequestMiddlewareTest < Minitest::Test
  include TurnstileTestSetup

  INNER_APP = ->(_env) {
    [200, {"content-type" => "text/plain"}, ["OK"]]
  }

  def test_composite_works_as_middleware_policy
    composite = CompositeGetOnlyPolicy &
      CompositeLoopbackPolicy

    Turnstile.configuration.request_policy = composite
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )

    # Allowed: GET from localhost
    env = Rack::MockRequest.env_for(
      "/", :method => "GET", "REMOTE_ADDR" => "127.0.0.1"
    )
    status, _, body = middleware.call(env)
    assert_equal 200, status
    assert_equal "OK", body.first

    # Denied: POST from localhost
    env = Rack::MockRequest.env_for(
      "/", :method => "POST", "REMOTE_ADDR" => "127.0.0.1"
    )
    status, _, _ = middleware.call(env)
    assert_equal 403, status
  end

  def test_module_helper_composite_as_middleware
    composite = Turnstile.any_of(
      CompositeGetOnlyPolicy, CompositeLoopbackPolicy
    )

    Turnstile.configuration.request_policy = composite
    middleware = Turnstile::RequestPolicy::Middleware.new(
      INNER_APP
    )

    # POST from loopback: loopback allows
    env = Rack::MockRequest.env_for(
      "/", :method => "POST", "REMOTE_ADDR" => "127.0.0.1"
    )
    status, _, _ = middleware.call(env)
    assert_equal 200, status

    # POST from external: both deny
    env = Rack::MockRequest.env_for(
      "/", :method => "POST", "REMOTE_ADDR" => "10.0.0.1"
    )
    status, _, _ = middleware.call(env)
    assert_equal 403, status
  end
end

# --- Module helper detection tests ---------------------

class CompositeRequestModuleHelperTest < Minitest::Test
  include TurnstileTestSetup

  def test_all_of_detects_request_policies
    composite = Turnstile.all_of(
      AlwaysAllowRequestPolicy,
      CompositeGetOnlyPolicy
    )
    assert composite < Turnstile::Composite::Request::AllOf
  end

  def test_any_of_detects_request_policies
    composite = Turnstile.any_of(
      AlwaysAllowRequestPolicy,
      CompositeGetOnlyPolicy
    )
    assert composite < Turnstile::Composite::Request::AnyOf
  end

  def test_none_of_detects_request_policies
    composite = Turnstile.none_of(
      AlwaysAllowRequestPolicy
    )
    assert composite < Turnstile::Composite::Request::NoneOf
  end
end
