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
- **Separation of concerns across tiers.** Authorization questions are split into three
  distinct layers (request, model, context), each with its own base class.
- **Introspectability.** The Reflection API enumerates all permissions a policy governs
  without making authorization decisions.

## The Three Authorization Tiers

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

Subclasses override `show?`, `update?`, etc., returning `allow` or
`deny(reason: "...")`. Unimplemented registered permissions are caught by
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
    forbidden.any? && !user.admin? ? deny : allow
  end
end
```

**Key behavior:** `method_missing` **delegates** to the linked general policy rather than
denying. You only override permissions that actually need request context; everything else
automatically falls through.

When the controller authorizes, the `Authorization` module tries a context policy first. If
none exists, it falls back to the general policy. Context policies are opt-in refinements.

### Attribute Visibility — the `_allowed?` Convention

Attribute visibility is handled through general policies, not a separate tier. The
`Presented` decorator queries `<attr>_allowed?` methods on the general policy to decide
whether a column attribute may be read.

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  def title_allowed?
    allow
  end

  def body_allowed?
    user&.admin? ? allow : deny(reason: "restricted")
  end
end
```

DenyAll applies: if no `_allowed?` method exists for an attribute, the decorator denies
access by default.

### Composite Policies (boolean composition)

Policies can be combined with boolean logic through the `Turnstile::Composite` module.
Three combinators exist: `AllOf` (AND), `AnyOf` (OR), and `NoneOf` (NOT). Each combinator
has both a request-policy variant (Tier 0) and a general-policy variant (Tier 1).

**Key design decision:** `build(*policy_classes)` returns an **anonymous class**
(`Class.new(self)`) with a frozen `@policies` array, not an instance. This means a
composite can be used anywhere a policy **class** is expected — as `c.request_policy`,
or as the argument to `authorize`.

#### Request composites (`Composite::Request`)

Subclass `RequestPolicy::Base`. Override `call` to iterate over child policy classes,
instantiating each with the same `request` and combining results:

| Combinator | Logic                            | Short-circuit      |
| ---------- | -------------------------------- | ------------------ |
| `AllOf`    | All must allow                   | First denial       |
| `AnyOf`    | At least one must allow          | First allow        |
| `NoneOf`   | All must deny (inverts meaning)  | First allow→deny   |

#### General composites (`Composite::General`)

Subclass `Authorization::Policy`. Permission queries (`?` methods) are intercepted by
`method_missing`, which instantiates each child policy with `(user, record)` and dispatches
the same query:

| Combinator | Logic                            | Short-circuit      |
| ---------- | -------------------------------- | ------------------ |
| `AllOf`    | All must allow                   | First denial       |
| `AnyOf`    | At least one must allow          | First allow        |
| `NoneOf`   | All must deny (inverts meaning)  | First allow→deny   |

#### Three access forms

1. **Module helpers:** `Turnstile.all_of(A, B)`, `.any_of(A, B)`, `.none_of(A)`. The helpers
   auto-detect the tier: when all arguments descend from `RequestPolicy::Base`, a request
   composite is built; otherwise a general composite.
2. **Operator syntax:** `A & B`, `A | B`, `~A`. Wired via `extend` on the base classes at
   the bottom of `composite.rb`.
3. **Nesting:** Composites are classes, so they can be passed as arguments to other
   composites: `Turnstile.all_of(A, Turnstile.any_of(B, C))`.

#### Load order dependency

`composite.rb` must be required after both `authorization.rb` and `request_policy.rb`
because it subclasses their base classes and extends them with operator modules.

### Presented Decorator

`Turnstile::Presented` wraps an ActiveRecord record and its resolved general policy. Column
attribute reads route through `method_missing`, which checks `<attr>_allowed?` before
delegating. Non-column methods pass through unguarded.

In **strict** mode (`presented_mode = :strict`), denied attributes raise
`AttributeDeniedError`. In **lenient** mode, they return `nil`.

Rich access API:

| Method                    | Behaviour                                    |
| ------------------------- | -------------------------------------------- |
| `allowed?(attr)`          | Predicate — returns boolean                  |
| `if_allowed(attr) { v }` | Block guard; returns `IfAllowedResult`       |
| `.else { fallback }`      | Chained fallback on `IfAllowedResult`        |
| `allowed(attr)`           | Returns value or nil                         |
| `[attr]`                  | Hash-like access; value or nil               |
| `fetch(attr) { fallback }`| Value or block fallback                      |
| `deconstruct_keys(keys)`  | Pattern matching; denied keys absent         |
| `policy`                  | The resolved general policy instance         |
| `unwrap`                  | Escape hatch — the raw record                |

Rails identity methods (`to_param`, `to_key`, `model_name`, `persisted?`, `id`, etc.)
pass through unguarded so that form builders, link helpers, and routing work without
ceremony. Type checks (`is_a?`, `kind_of?`) delegate to the record.

Associations that have their own policy are wrapped recursively (deep presentation).
Collections become `PresentedCollection` instances.

Auto-presentation: the controller concern wraps loaded resources in `Presented` or
`PresentedCollection` for read actions (`show`, `edit`, `index`). Write actions (`create`,
`update`, `destroy`) receive raw records for mutation. Skip with `skip_presentation`.

## Resource Loading

Three components:

### Config (`Loading::Config`)

A plain data object holding per-controller loading configuration: `resource_class`,
`id_param`, `action_modes`, `custom_loaders`, `parent_class`, `parent_id_param`, and
`parent_auto`. Inherited by duplication so child controllers do not pollute parents.

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

  # Parent resource (nested routes):
  parent_resource User             # explicit parent
  parent_resource User, id_param: :author_id  # custom param
  auto_parent                      # detect from *_id params
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

#### Parent resource loading

When `parent_class` is set or `parent_auto` is enabled, the loader:

1. **Resolves the parent** — from explicit config, or by scanning params for `*_id` keys
   and trying `classify.safe_constantize` on each prefix.
2. **Loads the parent** through its own policy scope (`find_by(id:)`) and raises
   `ResourceNotFoundError` if not found.
3. **Discovers the association** — walks `reflect_on_all_associations` on the parent class
   to find a `has_many` or `has_one` targeting the child model.
4. **Scopes the child** through the parent's association (e.g. `user.articles`). Falls back
   to the child's own policy scope when no association is found.

The loader returns both parent and child in the assignments hash (e.g.
`{ :@user => <User>, :@article => <Article> }`). The controller sets all ivars;
authorization runs on the child resource only.

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
├── AttributeDeniedError (attribute, record, reason)
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
      resolver.rb                       # convention-based policy class lookup
    request_policy.rb                   # barrel require
    request_policy/
      base.rb                           # DenyAll Rack-level policy
      permit_all.rb                     # PermitAll Rack-level policy
      middleware.rb                     # Rack middleware
    composite.rb                        # boolean composition (all_of, any_of, none_of)
    loading.rb                          # barrel require
    loading/
      config.rb                         # per-controller config data
      dsl.rb                            # class-level macros
      loader.rb                         # runtime loading engine
    controller.rb                       # ActiveSupport::Concern
    presented.rb                        # attribute-guarding decorator
    presented_collection.rb             # collection wrapper
    railtie.rb                          # Rails integration
sig/                                    # RBS type signatures
  turnstile.rbs                         # top-level module
  turnstile/
    composite.rbs                       # composite policy types
test/
  test_helper.rb                        # shared setup, models, policies
  turnstile/                            # unit tests
    composite/                          # composite policy tests
  integration/                          # full-stack Rails integration tests
  dummy/                                # minimal Rails app for integration
```
