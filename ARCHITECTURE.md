# Turnstile — Architecture & Design

Turnstile is a Ruby gem that provides **automatic resource loading** and **layered
authorization** for Rails controllers backed by ActiveRecord. Its cardinal design principle
is **deny-all by default**: the base policy classes deny every query unless the host
application explicitly grants it. If a developer forgets to implement a permission method,
the gate remains shut.

## Design Philosophy

- **Safety through denial.** No permission is ever implicitly granted. Base `Policy`
  denies all queries; base `Scope` returns `scope.none`.
- **Rich results over bare booleans.** Every permission query returns a frozen `Result`
  value object carrying the verdict, the permission name, and a human-readable denial
  reason.
- **Convention over configuration.** Controller name maps to model class; model class maps
  to policy class. Every convention is overridable.
- **Separation of concerns across tiers.** Authorization questions are split into four
  distinct layers (request, model, context, view), each with its own base class.
- **Introspectability.** The Reflection API enumerates all permissions a policy governs
  without making authorization decisions.

## The Four Authorization Tiers

### Tier 0 — Request Policies (Rack-level)

Operates before Rails processes the request. Receives only a `Rack::Request` — no user,
no record, no session. Typical uses: IP allowlists, maintenance mode, rate limits.

| Class                              | Behavior                              |
| ---------------------------------- | ------------------------------------- |
| `Turnstile::RequestPolicy::Base`   | Denies all by default                 |
| `Turnstile::RequestPolicy::PermitAll` | Permits everything                 |

`RequestPolicy::Middleware` is a Rack middleware inserted at position 0 by the Railtie. It
instantiates the configured request policy class on every request, calls `#call`, and
either passes through or short-circuits with a configurable HTTP status and body.

The middleware is **always inserted** but acts as a pass-through when no `request_policy`
is configured, allowing runtime toggling (e.g. maintenance mode) without restart.

### Tier 1 — General Policies (model-level)

Context-free authorization. Answers "can user X do Y to record Z?" without knowledge of
the HTTP request.

| Class                              | Behavior                              |
| ---------------------------------- | ------------------------------------- |
| `Turnstile::Authorization::Policy` | Denies all; five standard CRUD perms  |
| `Turnstile::Authorization::PermitAll` | Permits everything                 |

Subclasses override `show?`, `update?`, etc., returning `allow(:perm)` or
`deny(:perm, reason: "...")`. Unimplemented registered permissions are caught by
`method_missing` and denied — the DenyAll backbone.

The inner class `Scope` receives `(user, scope)` and resolves the authorized subset of a
relation. The base implementation returns `scope.none`.

### Tier 2 — Context Policies (request-aware)

Refinements that receive a `RequestContext` (an immutable value object wrapping request,
params, action name, controller name, IP, method, headers, and an XHR flag).

```ruby
class ArticleContextPolicy < Turnstile::Authorization::ContextPolicy
  general_policy ArticlePolicy

  def update?
    base = general_policy_for_record.update?
    return base if base.denied?

    forbidden = changed_attrs & %i[published author_id]
    forbidden.any? && !user.admin? ? deny(:update) : allow(:update)
  end
end
```

**Key behavior:** `method_missing` **delegates** to the linked general policy rather than
denying. You only override permissions that actually need request context; everything else
automatically falls through.

When the controller authorizes, the `Authorization` module tries a context policy first. If
none exists, it falls back to the general policy. Context policies are opt-in refinements.

### Tier 3 — View Policies (visibility)

Two complementary facets:

1. **Section/element permissions.** Coarse-grained ("should user see the admin panel?").
   Declared with `permission :show_admin_panel` and queried with `show_admin_panel?`.

2. **Attribute visibility.** Fine-grained per-attribute control.

```ruby
class ArticleViewPolicy < Turnstile::Authorization::ViewPolicy
  attribute :title,     default: :visible
  attribute :body,      default: :hidden
  attribute :author_id, default: :hidden

  def body_visible?    = show_body?
  def author_id_visible? = show_author?
end
```

Resolution order for each attribute:

1. A method `<name>_visible?` on the policy instance
2. The declared default (`:visible` or `:hidden`)
3. Undeclared attributes → deny

Helper methods: `visible_attributes`, `hidden_attributes`, `filter_attributes(source)`.

View policies **strip inherited CRUD permissions** by truncating the ancestor chain walk at
`Policy`, preventing CRUD permissions from bleeding into the view tier.

## Resource Loading

Three components:

### Config (`Loading::Config`)

A plain data object holding per-controller loading configuration: `resource_class`,
`id_param`, `action_modes`, and `custom_loaders`. Inherited by duplication so child
controllers do not pollute parents.

### DSL (`Loading::Dsl`)

Class-level macros for controllers:

```ruby
class ArticlesController < ApplicationController
  resource_class    Article        # override inferred model
  resource_id_param :slug          # override ID param
  load_singular     :publish       # custom singular actions
  load_plural       :search        # custom plural actions
  skip_loading      :create, :new  # no auto-loading
  load_resource(:preview) { |c| Article.find_by(slug: c.params[:slug]) }
end
```

### Loader (`Loading::Loader`)

The runtime engine invoked by the controller's `before_action`.

Default action modes:

| Actions                            | Mode     | Behavior                       |
| ---------------------------------- | -------- | ------------------------------ |
| `index`                            | plural   | Collection via policy scope    |
| `show`, `edit`, `update`, `destroy`| singular | Single record by ID            |
| `new`, `create`                    | skip     | No auto-loading                |

Model inference: `ArticlesController` → `Article` (strip `Controller`, demodulize,
singularize, `safe_constantize`).

Both singular and plural loads are filtered through the policy scope, so the user can never
load records outside their authorized set.

## Controller Concern

`Turnstile::Controller` is an `ActiveSupport::Concern` that weaves loading and
authorization together.

```
before_action :turnstile_load_and_authorize
  │
  ├── turnstile_load_resource
  │     ├── check custom_loaders[action]
  │     └── Loading::Loader.new(...).load!
  │
  └── turnstile_authorize_resource
        ├── skip if action in turnstile_skip_auth_actions
        └── Authorization.authorize_in_context(user, record, permission, context)
              ├── try context policy first
              └── fall back to general policy
```

Public instance methods (also available as view helpers):

- `authorize(record, permission)` — manual authorization with context
- `view_policy(record)` — instantiated view policy
- `policy(record)` — instantiated general policy
- `policy_scope(scope)` — apply policy scope to a relation
- `skip_authorization` — mark authorization as intentionally skipped

## Reflection API

The `permission` macro registers `PermissionInfo` frozen value objects (name, description,
contextual flag, parameter metadata). The `permissions` class method walks the ancestor
chain in reverse and merges, so descendant overrides win.

```ruby
ArticlePolicy.permissions
# => { index: #<PermissionInfo name=:index ...>, ... }

ArticlePolicy.permission_names
# => [:archive, :create, :destroy, :index, :publish, :show, :update]

ArticlePolicy.contextual_permissions
# => { update: #<PermissionInfo contextual=true ...> }
```

This enables admin UIs, documentation generators, and static analysis tools to enumerate
all governed permissions without instantiating a policy.

## Railtie

Two initializers:

1. **`turnstile.configure_logger`** — sets the gem logger to `Rails.logger`.
2. **`turnstile.request_policy_middleware`** — inserts the request policy middleware at
   position 0 (before sessions, cookies, everything).

## Error Hierarchy

```
Turnstile::Error
├── NotAuthorizedError   (user, record, permission, policy, reason)
├── PolicyNotFoundError  (record)
├── AuthorizationNotPerformedError
└── ResourceNotFoundError (resource_class, resource_id)
```

## Dependencies

### Runtime

- `actionpack >= 7.0`
- `activerecord >= 7.0`
- `activesupport >= 7.0`
- Ruby `>= 3.1`

### Development

- Minitest (test framework)
- Standard Ruby (linter/formatter)
- SQLite3 (in-memory test database)
- A dummy Rails application under `test/dummy/` for integration testing

No FactoryBot. No Devise dependency — just an expectation of a configurable
`current_user` method.

## File Map

```
lib/
  turnstile.rb                          # entry point, module, Railtie guard
  turnstile/
    version.rb                          # VERSION constant
    logging.rb                          # NullLogger, default_logger
    configuration.rb                    # Configuration class
    errors.rb                           # error hierarchy
    authorization.rb                    # module functions (authorize, policy_for, ...)
    authorization/
      result.rb                         # frozen verdict value object
      permission_info.rb                # frozen permission metadata
      reflection.rb                     # permission DSL + ancestor-chain walk
      policy.rb                         # DenyAll base policy + Scope
      permit_all.rb                     # PermitAll convenience policy
      request_context.rb                # frozen request wrapper
      context_policy.rb                 # request-aware policy refinements
      view_policy.rb                    # attribute visibility + section perms
      resolver.rb                       # convention-based policy class lookup
    request_policy.rb                   # barrel require
    request_policy/
      base.rb                           # DenyAll Rack-level policy
      permit_all.rb                     # PermitAll Rack-level policy
      middleware.rb                     # Rack middleware
    loading.rb                          # barrel require
    loading/
      config.rb                         # per-controller config data
      dsl.rb                            # class-level macros
      loader.rb                         # runtime loading engine
    controller.rb                       # ActiveSupport::Concern
    railtie.rb                          # Rails integration
sig/                                    # RBS type signatures
test/
  test_helper.rb                        # shared setup, models, policies
  turnstile/                            # unit tests
  integration/                          # full-stack Rails integration tests
  dummy/                                # minimal Rails app for integration
```
