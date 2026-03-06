# Turnstile

Resource loading and layered authorization for Rails controllers.

Turnstile provides automatic resource loading and a two-tier authorization system for Rails
controllers backed by ActiveRecord. Every permission denies by default. Policies return rich
`Result` objects with human-readable denial reasons rather than bare booleans, and expose a
reflection API for static analysis and documentation tooling.

## Features

- **Deny-all by default** -- the base `Policy` class denies every query. Permissions must be
  explicitly granted.
- **Two-tier authorization** -- general (model-level) and context (request-aware) policies,
  with attribute visibility via the `_allowed?` convention on general policies.
- **Automatic resource loading** -- controllers infer the model class from their name and load
  records via `before_action`, scoped through policy scopes for security.
- **Result objects** -- every permission query returns a frozen `Result` carrying the boolean
  verdict, the permission name, and an optional denial reason.
- **Reflection API** -- enumerate permissions, descriptions, contextual flags, and parameter
  metadata without instantiating a policy.
- **Parent resource scoping** -- nested routes are handled automatically. Declare an explicit
  parent class or enable auto-detection from `*_id` params; the child is scoped through the
  parent's ActiveRecord association.
- **Controller DSL** -- customize loading behaviour per-action: override the model class, change
  the ID param, declare singular/plural/skip actions, or supply fully custom loader blocks.
- **Devise-compatible but not Devise-dependent** -- defaults to `current_user` but works with any
  authentication system.
- **RBS type signatures** included for all public interfaces.

## Installation

Add to your Gemfile:

```ruby
gem "turnstile"
```

Then:

```
bundle install
```

## Quick start

### 1. Define a policy

Create a policy class following the naming convention `<Model>Policy`:

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  # Optionally declare custom permissions beyond CRUD:
  permission :publish, description: "publish an article"
  permission :archive, description: "archive an article"

  def show?
    allow
  end

  def create?
    if user&.admin? || user&.editor?
      allow
    else
      deny(reason: "only admins and editors may create")
    end
  end

  def update?
    if user&.admin?
      allow
    elsif user&.editor? && record.author_id == user.id
      allow
    else
      deny(reason: "you do not own this article")
    end
  end

  def destroy?
    user&.admin? ? allow : deny(reason: "admin only")
  end

  def publish?
    if user&.admin? || user&.editor?
      allow
    else
      deny(reason: "insufficient role")
    end
  end

  def archive?
    deny(reason: "archiving disabled")
  end

  # Scope filters collections so users only see records they may access.
  class Scope < Turnstile::Authorization::Policy::Scope
    def resolve
      if user&.admin?
        scope.all
      else
        scope.where(published: true)
      end
    end
  end
end
```

### 2. Include the controller concern

```ruby
class ArticlesController < ApplicationController
  include Turnstile::Controller
end
```

This single line will:

- Infer the model class as `Article` from the controller name.
- Auto-load `@article` for `show`, `edit`, `update`, and `destroy` (singular actions).
- Auto-load `@articles` for `index` (plural, filtered through the policy scope).
- Skip loading for `new` and `create`.
- Authorize each loaded resource against the current action.

### 3. Manually authorize in create/new

For actions where the record does not yet exist, authorize manually:

```ruby
class ArticlesController < ApplicationController
  include Turnstile::Controller

  def create
    @article = Article.new(article_params)
    authorize(@article, :create)
    # ...
  end
end
```

## Configuration

```ruby
# config/initializers/turnstile.rb
Turnstile.configure do |c|
  # Method on the controller that returns the current user.
  # Defaults to :current_user (Devise-compatible).
  c.current_user_method = :current_user

  # Logger instance. Defaults to Rails.logger when Rails is
  # present, otherwise a silent NullLogger.
  c.logger = Rails.logger

  # Optional namespace prefix for policy resolution.
  # e.g. "Admin" resolves Article -> Admin::ArticlePolicy first,
  # falling back to ArticlePolicy.
  c.policy_namespace = nil
end
```

## Request policies (Rack-level)

Request policies operate at the Rack level, before Rails processes the request. They receive
only a `Rack::Request` — no user, no record, no session. Typical uses include IP allowlists,
maintenance mode gates, and rate limits.

The base class denies all by default. Subclass it and override `call`:

```ruby
class MaintenancePolicy < Turnstile::RequestPolicy::Base
  def call
    if ENV["MAINTENANCE_MODE"] == "1"
      deny(reason: "down for maintenance")
    else
      allow
    end
  end
end
```

```ruby
require "ipaddr"

class IpAllowlistPolicy < Turnstile::RequestPolicy::Base
  ALLOWED = IPAddr.new("10.0.0.0/8")

  def call
    if ALLOWED.include?(IPAddr.new(request.ip))
      allow
    else
      deny(reason: "IP #{request.ip} not in allowlist")
    end
  end
end
```

Configure the policy and optional response settings in your initializer:

```ruby
Turnstile.configure do |c|
  c.request_policy = MaintenancePolicy

  # HTTP status for denied requests (default: 403):
  c.request_policy_status = 503

  # Static body or a callable receiving the Result:
  c.request_policy_body = "Be back soon"
  c.request_policy_body = ->(result) { result.reason }
end
```

The Railtie inserts the middleware at position 0 automatically. When no `request_policy` is
configured, the middleware acts as a pass-through — no overhead.

`Turnstile::RequestPolicy::PermitAll` is available as a convenience base class that allows
everything, useful during development or when you want deny-by-exception.

## Policy tiers

### General policies (Policy)

Model-level, context-free authorization. "Can user X do Y to record Z?"

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  def show?
    allow
  end

  def destroy?
    user&.admin? ? allow : deny(reason: "admin only")
  end
end
```

The base `Policy` declares five standard CRUD permissions (`create`, `destroy`, `index`, `show`,
`update`). All deny by default. Subclasses override the ones they wish to grant.

#### PermitAll

For truly public resources or during development:

```ruby
class PublicPagePolicy < Turnstile::Authorization::PermitAll
  # Everything allowed by default. Lock down selectively:
  def destroy?
    deny(reason: "pages are immutable")
  end
end
```

`PermitAll` permits any permission query, including undeclared ones (via `method_missing`).

#### Scopes

Scopes filter collections so that users only see records within their access. Define a `Scope`
inner class:

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  class Scope < Turnstile::Authorization::Policy::Scope
    def resolve
      if user&.admin?
        scope.all
      else
        scope.where(published: true)
      end
    end
  end
end
```

The base `Scope#resolve` returns `scope.none` (deny all).

### Context policies (ContextPolicy)

Request-aware refinements that receive a `RequestContext` wrapping the HTTP request, params, action
name, and controller name. Use these when authorization depends on *which attributes* are being
changed, the request IP, or other environmental factors.

```ruby
class ArticleContextPolicy < Turnstile::Authorization::ContextPolicy
  general_policy ArticlePolicy

  permission :update, contextual: true,
    description: "edit with attribute restrictions",
    parameters: [:changed_attributes]

  def update?
    base = general_policy_for_record.update?
    return base if base.denied?

    changed = context.params.fetch(:article, {}).keys.map(&:to_sym)
    forbidden = changed & %i[published author_id]

    if forbidden.any? && !user&.admin?
      deny(reason: "cannot modify #{forbidden.join(", ")}")
    else
      allow
    end
  end
end
```

Key behaviour:

- `general_policy ArticlePolicy` links the context policy to its base general policy.
- Permission queries not explicitly overridden delegate to the general policy at runtime (so
  `ArticleContextPolicy#show?` delegates to `ArticlePolicy#show?`).
- `general_policy_for_record` returns an instantiated general policy for the current user and
  record, useful for checking the base permission before applying contextual refinements.
- When no context policy exists for a model, `authorize_in_context` falls back to the general
  policy automatically.

#### RequestContext

The `RequestContext` value object exposes:

| Method            | Returns                             |
| ----------------- | ----------------------------------- |
| `request`         | The `ActionDispatch::Request`       |
| `params`          | Controller params                   |
| `action_name`     | Current action as a Symbol          |
| `controller_name` | The controller name                 |
| `ip`              | `request.remote_ip`                 |
| `method`          | HTTP method                         |
| `content_type`    | Request content type                |
| `headers`         | Request headers                     |
| `xhr?`            | Whether the request is XHR          |

### Attribute visibility — the `_allowed?` convention

Attribute visibility is handled through general policies using `<attr>_allowed?` methods,
queried by the `Presented` decorator. No separate view policy tier is needed.

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  def show?
    allow
  end

  # Attribute visibility:
  def title_allowed?
    allow
  end

  def body_allowed?
    user&.admin? ? allow : deny(reason: "restricted")
  end
end
```

DenyAll applies: if no `_allowed?` method exists for a column attribute, the decorator
denies access by default.

### Presented decorator

The controller automatically wraps loaded resources in `Turnstile::Presented` for read
actions. The decorator guards column attribute access through the policy's `_allowed?`
methods.

```ruby
# In strict mode, denied attributes raise AttributeDeniedError.
# In lenient mode, denied attributes return nil.
presented = Turnstile::Presented.new(article, user)

presented.title           # => "On Hobbits" (allowed)
presented.body            # => raises AttributeDeniedError (denied)
presented.unwrap          # => the raw Article record
presented.policy          # => the resolved ArticlePolicy instance

# Rich access API:
presented.allowed?(:title)              # => true
presented.allowed(:body)                # => nil (denied)
presented[:title]                       # => "On Hobbits"
presented.fetch(:body) { "Restricted" } # => "Restricted"

presented.if_allowed(:body) { |v| render(v) }
  .else { render("Restricted") }

# Pattern matching (denied attributes absent):
case presented
in { title: String => t }
  puts t
end
```

Skip auto-presentation for specific actions:

```ruby
class ArticlesController < ApplicationController
  include Turnstile::Controller
  skip_presentation :raw_export
end
```

## Result objects

Every permission query returns a `Turnstile::Authorization::Result`:

```ruby
result = policy.update?
result.allowed?    # => false
result.denied?     # => true
result.reason      # => "you do not own this article"
result.permission  # => :update
result.to_s        # => "denied:update (you do not own this article)"
```

Results are frozen value objects. The denial reason propagates into `NotAuthorizedError` when
authorization is enforced with `bang: true` (the default).

## Reflection API

Policies expose metadata about their declared permissions without requiring instantiation:

```ruby
ArticlePolicy.permission_names
# => [:archive, :create, :destroy, :index, :publish, :show, :update]

ArticlePolicy.permissions[:publish]
# => #<PermissionInfo publish "publish an article">

ArticlePolicy.permissions[:publish].description
# => "publish an article"

ArticlePolicy.contextual_permissions
# => {} (none on a general policy)

ArticleContextPolicy.contextual_permissions
# => { update: #<PermissionInfo update contextual params=[:changed_attributes] ...> }

ArticleContextPolicy.contextual_permissions[:update].parameters
# => [:changed_attributes]
```

Each `PermissionInfo` exposes: `name`, `description`, `contextual?`, and `parameters`.

## Controller DSL

Customize resource loading when conventions do not suffice:

```ruby
class ArticlesController < ApplicationController
  include Turnstile::Controller

  # Override the inferred model class:
  resource_class BlogPost

  # Override the ID param (default: :id):
  resource_id_param :slug

  # Declare custom actions that load a singular record:
  load_singular :publish, :archive

  # Declare custom actions that load a collection:
  load_plural :search

  # Skip loading for specific actions:
  skip_loading :dashboard

  # Fully custom loader for an action:
  load_resource :transfer do |controller|
    { :@article => Article.find(controller.params[:article_id]) }
  end

  # Skip authorization for specific actions:
  skip_authorization :health_check
end
```

### Parent resources

Nested routes produce params like `:user_id` for paths such as `/users/:user_id/articles/:id`.
Turnstile can detect the parent resource, load it through its policy scope, discover the
ActiveRecord association, and scope the child through it.

```ruby
class ArticlesController < ApplicationController
  include Turnstile::Controller

  # Explicit parent — loads User via :user_id, scopes
  # articles through user.articles:
  parent_resource User

  # With a custom param key:
  parent_resource User, id_param: :author_id

  # Or auto-detect from *_id params:
  auto_parent
end
```

When a parent is loaded, the controller sets both `@user` and `@article` (or `@articles`).
The parent is loaded through its own policy scope, the child through the parent's
association. If no matching association is found, the child falls back to its own policy
scope.

Parent loading raises `ResourceNotFoundError` when the parent record is not found within
the policy scope, ensuring users cannot probe records they are not authorized to see.

### Default action modes

| Actions                           | Mode     | Behaviour                    |
| --------------------------------- | -------- | ---------------------------- |
| `index`                           | plural   | Loads collection via scope   |
| `show`, `edit`, `update`, `destroy` | singular | Loads single record by ID  |
| `new`, `create`                   | skip     | No auto-loading              |
| Everything else                   | skip     | No auto-loading              |

### Controller helper methods

| Method                                    | Description                                       |
| ----------------------------------------- | ------------------------------------------------- |
| `authorize(record, permission = nil)`     | Authorize with context (uses current action)      |
| `authorize_without_context(record, perm)` | Authorize using general policy only               |
| `policy(record)`                          | Get an instantiated general policy                |
| `policy_scope(scope)`                     | Apply the policy scope to a relation              |
| `skip_authorization`                      | Mark authorization as intentionally skipped       |

## Resolver

The resolver maps records to policy classes by naming convention:

| Record type      | General            | Context                  |
| ---------------- | ------------------ | ------------------------ |
| `Article` (class or instance) | `ArticlePolicy` | `ArticleContextPolicy` |
| `:article` (symbol) | `ArticlePolicy` | `ArticleContextPolicy`  |

When `policy_namespace` is configured (e.g. `"Admin"`), the resolver tries `Admin::ArticlePolicy`
first, then falls back to `ArticlePolicy`.

Use `Resolver.resolve(record, type:)` for a nil-returning lookup, or `Resolver.resolve!` to raise
`PolicyNotFoundError`.

## Error handling

Turnstile defines four error classes, all inheriting from `Turnstile::Error`:

| Error                            | When raised                                         |
| -------------------------------- | --------------------------------------------------- |
| `NotAuthorizedError`             | A policy denied access (carries `user`, `record`, `permission`, `policy`, `reason`) |
| `PolicyNotFoundError`            | No policy class found for a record                  |
| `AuthorizationNotPerformedError` | A controller action completed without authorizing   |
| `AttributeDeniedError`           | A presented attribute was denied (carries `attribute`, `record`, `reason`) |
| `ResourceNotFoundError`          | A record was not found during loading (carries `resource_class`, `resource_id`) |

Handle in your `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  rescue_from Turnstile::NotAuthorizedError do |e|
    flash[:alert] = e.reason || "Not authorized"
    redirect_to root_path
  end

  rescue_from Turnstile::ResourceNotFoundError do |e|
    head :not_found
  end
end
```

## Logging

All authorization decisions are logged through `Turnstile.logger`:

- **Denials** are logged at `info` level with the permission, record class, user class, and reason.
- **Allows** are logged at `debug` level.

When Rails is present, the logger defaults to `Rails.logger` via a Railtie. Otherwise it falls
back to a silent `NullLogger`. Override at any time:

```ruby
Turnstile.logger = Logger.new($stdout)
```

## Testing

Turnstile uses Minitest. Run the test suite:

```
bundle exec rake test
```

In your own tests, you can instantiate policies directly:

```ruby
policy = ArticlePolicy.new(user, article)
assert policy.show?.allowed?
assert policy.destroy?.denied?
assert_equal "admin only", policy.destroy?.reason
```

For context policies:

```ruby
ctx = Turnstile::Authorization::RequestContext.new(
  request: nil,
  params: { article: { title: "New Title" } },
  action_name: :update
)
policy = ArticleContextPolicy.new(user, article, ctx)
assert policy.update?.allowed?
```

For attribute visibility via Presented:

```ruby
presented = Turnstile::Presented.new(article, user)
assert presented.allowed?(:title)
refute presented.allowed?(:body)
assert_nil presented.allowed(:body)
```

Reset configuration between tests:

```ruby
def setup
  Turnstile.reset_configuration!
end
```

## Requirements

- Ruby >= 3.1
- Rails >= 7.0 (`actionpack`, `activerecord`, `activesupport`)

## License

MIT. See [LICENSE](LICENSE).
