# RBAC Design — Turnstile Role-Based Access Control

This document describes the design of an RBAC subsystem for Turnstile. The role system sits
**beneath** the existing policy layer: policies remain the decision-makers; the RBAC layer is the
data store they consult.

## Stateless Core, Stateful Extension

Turnstile's policy layer is **stateless**. It owns no database tables, manages no persistent
records, and stores nothing between requests. A policy is a pure function: it receives a user and
a record (or a request context), evaluates predicates, and returns allow or deny. The same inputs
always produce the same output. This makes policies easy to test, easy to reason about, and free
of side effects.

The RBAC subsystem described in this document is the first piece that introduces **persistent
state** into the authorization story. Roles, role assignments, and audit events live in database
tables that change at runtime. This is a deliberate architectural boundary:

| Concern          | Turnstile (core)       | RBAC (extension)            |
| ---------------- | ---------------------- | --------------------------- |
| State            | None                   | 4 tables                    |
| Changes at       | Deploy time            | Runtime                     |
| Decision-maker   | Yes (policies)         | No (data store)             |
| Side effects     | None                   | Writes (assignments, audit) |
| Testable without | Database               | Policies                    |

The RBAC layer is optional. An application can use Turnstile policies without RBAC — hardcoding
role checks, reading boolean columns, or consulting any other data source. The RBAC extension
provides a structured, auditable, time-aware data model for applications that outgrow ad-hoc
boolean columns, but it never makes authorization decisions on its own. Policies call
`user.can?(:ability, roleable)`; they decide what the answer means.

## Guiding Principles

1. **Roles are domain concepts.** A role like `editor` or `billing_admin` carries meaning — it
   describes _why_ someone has access, not just _what_ they can do. Arbitrary permission bundles
   (a bare bag of abilities with no name) should be avoided.

2. **Abilities are code-defined symbols.** The set of things your application can protect changes at
   development time, not at runtime. Abilities live in a registry module checked into source control.
   Role _assignments_ change at runtime and belong in the database.

3. **Roles are always scoped to a roleable.** Every role assignment ties a principal to a role _on_
   a specific record — the roleable (an organization, a project, a cohort). There are no global
   (unscoped) role assignments. A role without a roleable is a permission masquerading as a role.
   If a principal needs a system-wide ability not tied to any record, scope the role to a top-level
   roleable like an organization or tenant.

4. **RBAC is the structural backbone; attribute conditions layer on top.** Pure RBAC answers "does
   this principal hold a role on this roleable that carries this ability?" Policies may impose further
   conditions (record ownership, time windows, request context) after consulting the role system.

5. **Policies remain sovereign.** The RBAC layer never makes authorization decisions on its own. A
   policy calls `user.can?(:publish, record)` and then decides whether to `allow` or `deny`. The
   role system is a lookup table, not a gatekeeper.

## Data Model

All tables use the host application's configured primary key type. If the application sets
`config.generators.orm :active_record, primary_key_type: :uuid`, every table gets UUID primary
keys and foreign keys. If it uses the Rails default (bigint), so do these tables. The gem never
hardcodes a key type — `create_table` and `t.references` inherit from the application's
generators configuration.

The data model uses **polymorphic principals** throughout. A principal is any record that can
hold roles — typically a `User`, but equally a `ServiceAccount`, `ApiKey`,
`Team`, or any model that includes the `RoleBearer` concern. Tables that reference the principal
use `principal_type`/`principal_id` polymorphic columns rather than a direct foreign key to a
users table. Similarly, `role_events` uses polymorphic `actor` and `target` columns so that any
principal type can appear in the audit trail.

### Roles table

Roles are persisted records with a domain name and an optional human description.

```
roles
  id          PK
  name        string       NOT NULL, UNIQUE, indexed
  description string       nullable
  created_at  datetime
  updated_at  datetime
```

`name` is a slug like `editor`, `billing_admin`, `moderator`. The uniqueness constraint prevents
drift. The description is for admin UIs and audit logs, not for authorization logic.

### Role assignments table

A join between **principals** and roles, **always scoped to a roleable**. A principal is any
record that can hold a role — typically a `User`, but also a `ServiceAccount`, `ApiKey`, `Team`,
or any other model that includes the `RoleBearer` concern. A **roleable** is the record the role
is granted on — an `Organization`, `Project`, `Cohort`, or any model the host application
designates. A principal may hold many roles on many roleables; a role may be held by many
principals. Assignments are **time-bounded** with optional start and expiry timestamps.

```
role_assignments
  id              PK
  principal_type  string       NOT NULL, indexed (polymorphic)
  principal_id    NOT NULL, indexed (polymorphic)
  role_id         NOT NULL, FK -> roles, indexed
  roleable_type   string       NOT NULL, indexed (polymorphic)
  roleable_id     NOT NULL, indexed (polymorphic)
  starts_at       datetime     nullable (nil = immediate)
  expires_at      datetime     nullable (nil = no expiry)
  created_at      datetime
  updated_at      datetime

  INDEX(principal_type, principal_id, role_id, roleable_type, roleable_id)
  INDEX(principal_type, principal_id)
  INDEX(roleable_type, roleable_id)
  INDEX(expires_at)
```

Every role assignment is scoped to a concrete roleable: "user 7 is an `editor` on cohort 12."
There are no global (unscoped) role assignments. A role without a roleable is a permission
masquerading as a role — if a principal needs a system-wide ability, scope the role to a
top-level roleable like an organization or tenant.

### Why no unique index on assignments

An earlier draft had a unique constraint on `(principal_type, principal_id, role_id,
roleable_type, roleable_id)`. This prevents a principal from ever holding the same role on the
same roleable more than once — period. That breaks time-bounded assignments with gaps:

- User 7 is `editor` on Cohort 12 from January 1 to March 31.
- The assignment expires.
- User 7 is re-assigned `editor` on Cohort 12 from June 1 to August 31.

The second `create!` violates the unique index even though the two windows do not overlap. The
real invariant is not "at most one row per (principal, role, roleable)" but "at most one
**active** row per (principal, role, roleable) at any point in time." That is an overlap check,
not a uniqueness constraint.

A non-unique composite index on the same five columns preserves query performance for lookups
without blocking legitimate re-assignments. The overlap invariant is enforced in the model with
a custom validation:

```ruby
validate :no_overlapping_assignments, on: :create

private

def no_overlapping_assignments
  scope = RoleAssignment.where(
    principal_type: principal_type,
    principal_id: principal_id,
    role_id: role_id,
    roleable_type: roleable_type,
    roleable_id: roleable_id
  ).where.not(id: id)

  # Check for overlap: two intervals overlap when
  # each starts before the other ends.
  scope = scope.where(
    "starts_at IS NULL OR starts_at < ?",
    expires_at || Float::INFINITY
  ) if expires_at

  scope = scope.where(
    "expires_at IS NULL OR expires_at > ?",
    starts_at || Time.at(0)
  ) if starts_at

  # Unbounded on both sides overlaps everything
  if starts_at.nil? && expires_at.nil?
    # Any existing row overlaps with an unbounded window
    if scope.exists?
      errors.add(:base,
        "overlaps an existing assignment")
    end
    return
  end

  if scope.exists?
    errors.add(:base,
      "overlaps an existing assignment for this " \
      "principal, role, and roleable")
  end
end
```

The validation uses SQL to check for interval overlap without loading rows into Ruby. Two
intervals `[A.starts_at, A.expires_at)` and `[B.starts_at, B.expires_at)` overlap when
`A.starts_at < B.expires_at AND B.starts_at < A.expires_at`, treating `NULL` as unbounded
(negative infinity for `starts_at`, positive infinity for `expires_at`).

This is a model-level check, not a database constraint. In high-concurrency environments, wrap
the create in an advisory lock or a serializable transaction to prevent TOCTOU races. For most
Rails applications, the model validation is sufficient.

Time bounds are optional. `starts_at` defaults to null (effective immediately). `expires_at`
defaults to null (no expiry). When both are set, the assignment is active only within the window.
A query scope filters on `starts_at <= now AND (expires_at IS NULL OR expires_at > now)`.

### Role events table (audit log)

An append-only ledger of every role change. Every creation, revocation, and modification of a
role assignment produces a `role_event` recording who did what, to whom, and when.

```
role_events
  id              PK
  actor_type      string       nullable (polymorphic)
  actor_id        nullable, indexed (polymorphic)
  target_type     string       NOT NULL (polymorphic)
  target_id       NOT NULL, indexed (polymorphic)
  action          string       NOT NULL (e.g. "assign", "revoke", "expire", "modify")
  role_name       string       nullable (present for role operations)
  roleable_type   string       nullable (present for role ops)
  roleable_id     nullable (present for role ops)
  metadata        jsonb        nullable (extra context: old/new values, reason)
  created_at      datetime     NOT NULL

  INDEX(target_type, target_id)
  INDEX(actor_type, actor_id)
  INDEX(roleable_type, roleable_id)
  INDEX(action)
  INDEX(created_at)
```

The table is **append-only** — events are never updated or deleted. This makes the audit trail
tamper-evident and suitable for compliance requirements.

Key fields:

- `actor_type` / `actor_id` — the principal who caused the change. Both null when the system
  itself acts (e.g. an expiration sweep, a seed script, or an automated process).
- `target_type` / `target_id` — the principal whose access changed.
- `action` — a verb describing the change. A controlled vocabulary:
  - `assign` — a role was assigned to the target.
  - `revoke` — a role assignment was removed.
  - `expire` — a time-bounded assignment reached its `expires_at` and was deactivated.
  - `modify` — an assignment's attributes changed (e.g. `expires_at` was extended).
- `role_name` — denormalized from the role record at event time. If the role is later renamed, the
  event preserves the name that was in effect when the change happened.
- `roleable_type` / `roleable_id` — present for role operations (all role assignments are scoped).
  "User 3 was assigned `mentor` on Cohort 12."
- `metadata` — a JSONB column for anything that does not justify its own column: the reason for the
  change, the old and new `expires_at` on a modification, the IP address of the actor, etc.

## Ability Registry

Abilities are defined in code, not in the database. They change at development time when a
developer adds a new protected operation. The question is _how_ to represent them in code so that
typos, stale references, and phantom checks are caught before they reach production.

### The problem with bare symbols

A naïve registry built on a hash of symbols works:

```ruby
user.can?(:publsh)   # typo — silently returns false at runtime
```

Nothing catches this. The ability `:publsh` is not in the registry, so `can?` returns false, the
feature appears broken, and someone files a bug. Worse: a view that checks `can?(:preview)` keeps
compiling long after the `:preview` ability is removed — a dead permission check that silently
degrades to "deny" with no warning.

We can do better. Below are three approaches, ordered from simplest to most rigorous. They are
not mutually exclusive — each adds a layer.

### Approach 1: Named constants

Define each ability as a module constant. Call sites reference the constant, not a symbol.

```ruby
# app/models/abilities.rb
module Abilities
  CREATE_ARTICLE  = :create_article
  UPDATE_ARTICLE  = :update_article
  DESTROY_ARTICLE = :destroy_article
  PUBLISH         = :publish
  ARCHIVE         = :archive
  MANAGE_USERS    = :manage_users
  VIEW_BILLING    = :view_billing
  MANAGE_BILLING  = :manage_billing

  DESCRIPTIONS = {
    CREATE_ARTICLE  => "Create an article",
    UPDATE_ARTICLE  => "Edit an article",
    DESTROY_ARTICLE => "Delete an article",
    PUBLISH         => "Publish an article",
    ARCHIVE         => "Archive an article",
    MANAGE_USERS    => "Administer user accounts",
    VIEW_BILLING    => "View billing information",
    MANAGE_BILLING  => "Modify billing settings"
  }.freeze

  ALL = DESCRIPTIONS.keys.freeze

  def self.valid?(ability)
    DESCRIPTIONS.key?(ability.to_sym)
  end

  def self.describe(ability)
    DESCRIPTIONS.fetch(ability.to_sym)
  end
end
```

Call sites become:

```ruby
user.can?(Abilities::PUBLISH, article)
user.can?(Abilities::MANAGE_BILLING, org)
```

A typo like `Abilities::PUBLSH` raises `NameError` at boot time (eager load) or first reference
(autoload). A removed constant breaks every file that references it — `grep` and the autoloader
both catch it. This is zero-cost at runtime: the constants resolve to the same frozen symbols.

**What this buys:** Boot-time detection of typos and stale references. IDE autocompletion. Easy
`grep` for usage when deprecating an ability.

**What this does not buy:** The method signature of `can?` still accepts any `Symbol`. Nothing
prevents `user.can?(:banana)` if someone bypasses the constants.

### Approach 2: A typed ability type with RBS

RBS can close the gap that constants leave open. Define an `ability` type as a union of literal
symbols, then type `can?` to accept only that union.

```rbs
# sig/abilities.rbs
module Abilities
  type ability = :create_article
              | :update_article
              | :destroy_article
              | :publish
              | :archive
              | :manage_users
              | :view_billing
              | :manage_billing

  CREATE_ARTICLE:  ability
  UPDATE_ARTICLE:  ability
  DESTROY_ARTICLE: ability
  PUBLISH:         ability
  ARCHIVE:         ability
  MANAGE_USERS:    ability
  VIEW_BILLING:    ability
  MANAGE_BILLING:  ability

  ALL: Array[ability]
  DESCRIPTIONS: Hash[ability, String]

  def self.valid?: (Symbol ability) -> bool
  def self.describe: (ability) -> String
end
```

```rbs
# sig/role_bearer.rbs
module RoleBearer
  def can?: (Abilities::ability ability,
    untyped roleable, ?at: Time) -> bool
  def has_role?: (String | Symbol role_name,
    untyped roleable, ?at: Time) -> bool
  def memberships: (untyped roleable,
    ?at: Time) -> RoleAssignment::ActiveRecord_Relation
end
```

Now Steep (or any RBS-aware type checker) rejects:

```ruby
user.can?(:banana)       # Type error: :banana is not Abilities::ability
user.can?(:publsh)       # Type error: :publsh is not Abilities::ability
```

A view that checks a removed ability fails type checking as soon as the literal is dropped from
the union — before the code is deployed, before a test runs.

**What this buys:** Static proof that every `can?` call names a real ability. CI catches phantom
checks, typos, and stale references at analysis time. The type checker becomes an exhaustive
audit of every authorization decision point in the codebase.

**What this does not buy:** RBS type checking is opt-in and requires Steep in CI. Teams that do
not run Steep do not get the benefit. The union type must be kept in sync with the Ruby constants
(addressed in approach 3).

### Approach 3: Generated registry with sync enforcement

The two-file problem — Ruby constants and RBS types that must agree — is solved by making one
the source of truth and generating the other.

**Option A: Ruby is the source, generate RBS.**

A Rake task reads `Abilities::DESCRIPTIONS` and emits the `.rbs` file:

```ruby
# lib/tasks/abilities.rake
namespace :abilities do
  desc "Regenerate sig/abilities.rbs from Abilities module"
  task generate_rbs: :environment do
    abilities = Abilities::DESCRIPTIONS.keys
    union = abilities.map { |a| "  | :#{a}" }.join("\n")

    rbs = <<~RBS
      # AUTO-GENERATED — do not edit by hand.
      # Run: rake abilities:generate_rbs
      module Abilities
        type ability = #{union.lstrip}

      #{abilities.map { |a| "  #{a.to_s.upcase}: ability" }.join("\n")}

        ALL: Array[ability]
        DESCRIPTIONS: Hash[ability, String]

        def self.valid?: (Symbol ability) -> bool
        def self.describe: (ability) -> String
      end
    RBS

    File.write("sig/abilities.rbs", rbs)
    puts "Wrote sig/abilities.rbs with #{abilities.size} abilities"
  end
end
```

CI runs `rake abilities:generate_rbs` and then `git diff --exit-code sig/abilities.rbs`. If the
generated file does not match what is checked in, the build fails — someone added an ability
constant but forgot to regenerate the types.

**Option B: a shared YAML manifest is the source, generate both.**

```yaml
# config/abilities.yml
create_article:  "Create an article"
update_article:  "Edit an article"
destroy_article: "Delete an article"
publish:         "Publish an article"
archive:         "Archive an article"
manage_users:    "Administer user accounts"
view_billing:    "View billing information"
manage_billing:  "Modify billing settings"
```

A single Rake task reads the YAML and generates both `app/models/abilities.rb` (the constants
module) and `sig/abilities.rbs` (the type definitions). The YAML file is the single source of
truth. Developers edit one file; the generator keeps Ruby and RBS in lockstep.

**What this buys:** Single source of truth. No possibility of Ruby/RBS drift. CI-enforceable.
The generator can also produce admin UI seed data, API documentation, and TypeScript enums for
frontend clients from the same manifest.

### Approach 4: Runtime validation as a safety net

Even with constants and RBS, the database column `role_abilities.ability` stores strings. A
runtime validation ensures that no unregistered string enters the database:

```ruby
class RoleAbility < ApplicationRecord
  belongs_to :role

  validates :ability, presence: true,
    inclusion: {
      in: ->(_) { Abilities::ALL.map(&:to_s) },
      message: "%{value} is not a registered ability"
    }
end
```

And a boot-time check can verify that the database contains no orphaned abilities:

```ruby
# config/initializers/ability_integrity.rb
Rails.application.config.after_initialize do
  next unless ActiveRecord::Base.connection.table_exists?(:role_abilities)

  stale = RoleAbility.where.not(ability: Abilities::ALL.map(&:to_s))
  if stale.any?
    names = stale.pluck(:ability).uniq.sort.join(", ")
    Rails.logger.warn(
      "[RBAC] Stale abilities in role_abilities table: #{names}. " \
      "Run rake abilities:cleanup to remove them."
    )
  end
end
```

This catches data drift — abilities that were removed from code but whose database rows were
never cleaned up.

### Recommended combination

Use all four approaches together. They layer naturally:

| Layer                | Catches                            | When         |
| -------------------- | ---------------------------------- | ------------ |
| Named constants      | Typos, stale refs (NameError)      | Boot / load  |
| RBS union type       | Invalid ability args to `can?`     | CI (Steep)   |
| Generated sync       | Ruby/RBS drift                     | CI (diff)    |
| Runtime validation   | Bad data entering the database     | Runtime      |
| Boot-time integrity  | Orphaned abilities in the database | Boot         |

The constants are the minimum. RBS is the force multiplier. Generation keeps them honest.
Runtime validation is the last line of defense.

### Why not database-stored abilities?

If abilities lived in the database, you would need a migration every time you added a protected
operation — but you would _also_ need a code deployment because the policy that checks the
ability is in code. The migration buys nothing; the code is the source of truth. Keeping abilities
in a code-defined registry makes this explicit and opens the door to static analysis.

## Role-Ability Mapping

Each role carries a set of abilities. This mapping lives in a dedicated table so that it can be
edited at runtime through an admin UI without redeploying.

```
role_abilities
  id          PK
  role_id     NOT NULL, FK -> roles, indexed
  ability     string       NOT NULL, indexed
  created_at  datetime

  UNIQUE(role_id, ability)
```

`ability` references a symbol name from the registry. A validation on the model ensures that only
registered abilities can be assigned to roles:

```ruby
class RoleAbility < ApplicationRecord
  belongs_to :role

  validates :ability, presence: true,
    inclusion: {
      in: ->(_) { Abilities::ALL.map(&:to_s) },
      message: "%{value} is not a registered ability"
    }
end
```

The `inclusion` validator uses a lambda so it reads the current `Abilities::ALL` at validation
time rather than at class load time. This keeps the database honest without moving the ability
definitions themselves into the database.

## ActiveRecord Models

### Role

```ruby
class Role < ApplicationRecord
  has_many :role_abilities, dependent: :destroy
  has_many :role_assignments, dependent: :destroy

  validates :name, presence: true, uniqueness: true

  def abilities
    role_abilities.pluck(:ability).map(&:to_sym)
  end

  def grants?(ability)
    role_abilities.exists?(ability: ability.to_s)
  end
end
```

### RoleAssignment

```ruby
class RoleAssignment < ApplicationRecord
  belongs_to :principal, polymorphic: true
  belongs_to :role
  belongs_to :roleable, polymorphic: true

  validate :no_overlapping_assignments, on: :create

  # --- Time-aware scopes ---
  #
  # Every scope that cares about "is this assignment live?"
  # accepts an optional `at:` keyword. When omitted it defaults
  # to `Time.current` — normal production behaviour.  Passing a
  # specific instant lets callers answer "what permissions did
  # this user have at 3 AM last Tuesday?" without touching the
  # data.

  scope :active, ->(at: Time.current) {
    where("starts_at IS NULL OR starts_at <= ?", at)
      .where("expires_at IS NULL OR expires_at > ?", at)
  }

  scope :for_roleable, ->(roleable) {
    where(roleable_type: roleable.class.name,
      roleable_id: roleable.id)
  }

  def active?(at: Time.current)
    (starts_at.nil? || starts_at <= at) &&
      (expires_at.nil? || expires_at > at)
  end

  def expired?(at: Time.current)
    expires_at.present? && expires_at <= at
  end

  private

  def no_overlapping_assignments
    scope = self.class.where(
      principal_type: principal_type,
      principal_id: principal_id,
      role_id: role_id,
      roleable_type: roleable_type,
      roleable_id: roleable_id
    ).where.not(id: id)

    scope = if starts_at.nil? && expires_at.nil?
      # Unbounded window — overlaps any existing row
      scope
    elsif starts_at.nil?
      # Open start — overlaps if existing starts before
      # our end
      scope.where(
        "starts_at IS NULL OR starts_at < ?", expires_at
      )
    elsif expires_at.nil?
      # Open end — overlaps if existing ends after our
      # start
      scope.where(
        "expires_at IS NULL OR expires_at > ?", starts_at
      )
    else
      # Bounded — standard interval overlap check
      scope
        .where(
          "starts_at IS NULL OR starts_at < ?", expires_at
        )
        .where(
          "expires_at IS NULL OR expires_at > ?", starts_at
        )
    end

    return unless scope.exists?

    errors.add(:base,
      "overlaps an existing assignment for this " \
      "principal, role, and roleable")
  end
end
```

### RoleEvent (audit log)

An append-only record. Never updated, never deleted.

```ruby
class RoleEvent < ApplicationRecord
  belongs_to :actor, polymorphic: true, optional: true
  belongs_to :target, polymorphic: true
  belongs_to :roleable, polymorphic: true, optional: true

  ACTIONS = %w[
    assign revoke expire modify
  ].freeze

  validates :action, presence: true, inclusion: {in: ACTIONS}
  validates :target_type, presence: true
  validates :target_id, presence: true

  scope :for_target, ->(target) {
    where(target_type: target.class.name, target_id: target.id)
  }

  scope :for_actor, ->(actor) {
    where(actor_type: actor.class.name, actor_id: actor.id)
  }

  scope :for_roleable, ->(roleable) {
    where(roleable_type: roleable.class.name,
      roleable_id: roleable.id)
  }

  scope :recent, -> { order(created_at: :desc) }

  # Factory methods for recording events. Policies and service
  # objects call these — the models themselves should not be
  # responsible for knowing who the actor is.

  def self.record_assign(actor:, target:, role:,
    roleable:, metadata: nil)
    create!(
      actor: actor,
      target: target,
      action: "assign",
      role_name: role.name,
      roleable: roleable,
      metadata: metadata
    )
  end

  def self.record_revoke(actor:, target:, role:,
    roleable:, metadata: nil)
    create!(
      actor: actor,
      target: target,
      action: "revoke",
      role_name: role.name,
      roleable: roleable,
      metadata: metadata
    )
  end
end
```

### Why factory methods instead of callbacks?

The audit log must record _who_ caused the change (`actor`). ActiveRecord callbacks on
`RoleAssignment` do not have access to the acting principal — they only see
the model being saved. Threading the actor through a `Current` attribute or callback context is
fragile and couples the model layer to the request layer.

Instead, role changes are performed through **service objects** (or controller actions) that
explicitly call both the assignment operation and the audit event in a transaction:

```ruby
class RoleService
  def self.assign(actor:, principal:, role:,
    roleable:, starts_at: nil, expires_at: nil)
    ActiveRecord::Base.transaction do
      assignment = RoleAssignment.create!(
        principal: principal,
        role: role,
        roleable: roleable,
        starts_at: starts_at,
        expires_at: expires_at
      )

      RoleEvent.record_assign(
        actor: actor,
        target: principal,
        role: role,
        roleable: roleable,
        metadata: {
          starts_at: starts_at&.iso8601,
          expires_at: expires_at&.iso8601
        }.compact
      )

      assignment
    end
  end

  def self.revoke(actor:, assignment:)
    ActiveRecord::Base.transaction do
      RoleEvent.record_revoke(
        actor: actor,
        target: assignment.principal,
        role: assignment.role,
        roleable: assignment.roleable,
        metadata: {
          was_active: assignment.active?,
          original_expires_at: assignment.expires_at&.iso8601
        }.compact
      )

      assignment.destroy!
    end
  end

  def self.extend_expiry(actor:, assignment:,
    new_expires_at:)
    ActiveRecord::Base.transaction do
      old_expires_at = assignment.expires_at

      assignment.update!(expires_at: new_expires_at)

      RoleEvent.create!(
        actor: actor,
        target: assignment.principal,
        action: "modify",
        role_name: assignment.role.name,
        roleable: assignment.roleable,
        metadata: {
          field: "expires_at",
          old_value: old_expires_at&.iso8601,
          new_value: new_expires_at&.iso8601
        }
      )

      assignment
    end
  end
end
```

This keeps the audit trail explicit, testable, and impossible to accidentally bypass. Every code
path that changes role assignments must go through the service (or write its own event), which
makes it easy to grep for audit coverage gaps.

### Principal Concern

A concern mixed into any model that can hold roles — the **principal**. The most common principal
is `User`, but the concern works equally well on `ServiceAccount`, `ApiKey`, `Team`, or any other
model. Every query is **scoped to a roleable** — there are no global role checks.

Every query method accepts an optional `at:` keyword that defaults to `Time.current`. In normal
production use you never pass it — the method answers "can this principal do this _right now_ on
this roleable?" For auditing, debugging, compliance, and tests you pass a specific instant to ask
"could this principal do this at 3 AM last Tuesday?" or "will they still have access next month?"

```ruby
# app/models/concerns/role_bearer.rb
module RoleBearer
  extend ActiveSupport::Concern

  included do
    has_many :role_assignments, as: :principal, dependent: :destroy
    has_many :roles, through: :role_assignments
  end

  # Can this user perform the named ability on a specific
  # roleable? Checks role abilities on the roleable.
  def can?(ability, roleable, at: Time.current)
    ability_s = ability.to_s
    role_granted?(ability_s, roleable, at:)
  end

  # Does this user hold the named role on a specific roleable?
  def has_role?(role_name, roleable, at: Time.current)
    role_assignments.active(at:).for_roleable(roleable)
      .joins(:role)
      .exists?(roles: {name: role_name.to_s})
  end

  # All active role assignments on a specific roleable.
  def memberships(roleable, at: Time.current)
    role_assignments.active(at:).for_roleable(roleable)
      .includes(:role)
  end

  private

  def role_granted?(ability_s, roleable, at:)
    scoped_role_ids = role_assignments
      .active(at:).for_roleable(roleable)
      .select(:role_id)
    RoleAbility
      .where(role_id: scoped_role_ids)
      .exists?(ability: ability_s)
  end
end
```

The concern provides a single tier of role query, always scoped to a roleable:

- `can?(Abilities::PUBLISH, article)` checks whether any of the principal's active roles on
  `article` carry the `:publish` ability.

- `has_role?(:editor, cohort)` checks whether the principal holds the named role on a specific
  roleable.

- `memberships(cohort)` returns the principal's active role assignments on a roleable, useful for
  UI displays ("you are a mentor on this cohort, expiring March 15").

**Time travel:** Every method defaults to now but accepts `at:` for point-in-time queries:

```ruby
# Normal use — "can they do this right now on this article?"
user.can?(Abilities::PUBLISH, article)

# Audit — "could they do this last Tuesday at 3 AM?"
user.can?(Abilities::PUBLISH, article, at: 3.days.ago)

# Forecasting — "will they still have access next month?"
user.has_role?(:mentor, cohort, at: 1.month.from_now)

# What roles did they hold on this cohort during the incident?
user.memberships(cohort, at: incident_time)
```

## Integration with Turnstile Policies

The RBAC layer provides _data_ to policies. Policies remain the sole decision-makers.

### Before RBAC (current pattern)

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  def update?
    if user&.admin?
      allow
    elsif user&.editor? && record.author_id == user.id
      allow
    else
      deny(reason: "you do not own this article")
    end
  end
end
```

Here `admin?` and `editor?` are ad-hoc boolean methods on the User model. They work, but every
new role means a new method, a new migration to add the column, and shotgun surgery across every
policy that should respect the new role.

### After RBAC

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  def update?
    if user&.can?(Abilities::UPDATE_ARTICLE, record)
      allow
    elsif user&.can?(Abilities::UPDATE_OWN_ARTICLE, record) &&
          record.author_id == user&.id
      allow
    else
      deny(reason: "not permitted to update this article")
    end
  end
end
```

The policy no longer names roles. It asks _can the user do this thing on this record?_ The
mapping from roles to abilities is data, managed through an admin UI or seeds. Adding a new role
that can update articles means creating a `Role` record and assigning it the `UPDATE_ARTICLE`
ability — no code change, no deployment.

### Scopes

Policy scopes consult the role system the same way. For scopes, the roleable is typically a
parent or container object — the organization, project, or namespace that owns the records
being filtered.

Turnstile's `Policy::Scope` base class will be extended with an optional `at:` keyword so that
scopes can evaluate time-bounded role assignments at an arbitrary instant. The base signature
becomes `Scope.new(user, scope, at: Time.current)`, and `resolve` uses `@at` instead of
hardcoding `Time.current`. This keeps the scope API consistent with `can?`, `has_role?`, and
`memberships` — all of which already accept `at:`. Normal production code never passes `at:`;
audit tools, compliance reports, and tests pass an explicit instant.

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  class Scope < Turnstile::Authorization::Policy::Scope
    def resolve
      if user&.can?(Abilities::VIEW_ALL_ARTICLES,
           scope.proxy_association&.owner || scope, at: at)
        scope.all
      elsif user&.can?(Abilities::VIEW_OWN_ARTICLES,
              scope.proxy_association&.owner || scope, at: at)
        scope.where(author_id: user.id)
      else
        scope.none
      end
    end
  end
end
```

### Context policies

Context policies layer on top as before. The RBAC check provides the base permission; the
context policy adds request-aware refinements:

```ruby
class ArticleContextPolicy < Turnstile::Authorization::ContextPolicy
  general_policy ArticlePolicy

  def update?
    base = general_policy_for_record.update?
    return base if base.denied?

    changed = context.params.fetch(:article, {}).keys.map(&:to_sym)
    sensitive = changed & %i[published author_id]

    if sensitive.any? && !user&.can?(Abilities::UPDATE_SENSITIVE_FIELDS, record)
      deny(reason: "cannot modify #{sensitive.join(", ")}")
    else
      allow
    end
  end
end
```

### Presented decorator / attribute visibility

Attribute visibility methods also consult abilities:

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  def revenue_allowed?
    user&.can?(Abilities::VIEW_BILLING, record) ? allow : deny(reason: "restricted")
  end
end
```

## Querying Patterns

Every RBAC primitive maps to a single SQL expression. This matters: if a permission check
cannot be expressed as a composable SQL fragment, it cannot be pushed into a `WHERE` clause,
which means it cannot participate in policy scopes, cannot be used for batch filtering, and
forces N+1 round-trips for any collection operation. The design maintains SQL equivalence for
every primitive — including composed queries and inverse evaluations.

All SQL fragments below use `$now` as a placeholder for the evaluation instant (`Time.current`
in normal use, an explicit `at:` value for time-travel queries). The `active_at($now)` predicate
expands to:

```sql
(starts_at IS NULL OR starts_at <= $now)
AND (expires_at IS NULL OR expires_at > $now)
```

### Forward queries: what can principal X do?

#### Single ability check — `can?(ability, roleable)`

The most common pattern. One SQL `EXISTS` query through the join:

```ruby
user.can?(Abilities::PUBLISH, article)
```

SQL equivalent:

```sql
-- Does principal (User, 7) hold any active role on (Article, 42)
-- that carries the 'publish' ability?
SELECT EXISTS (
  SELECT 1
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Article'
    AND ra.roleable_id    = 42
    AND rb.ability         = 'publish'
    AND active_at($now)
)
```

#### Role membership check — `has_role?(role_name, roleable)`

For UI gating (showing/hiding dashboards, nav items):

```ruby
user.has_role?(:editor, project)
```

SQL equivalent:

```sql
SELECT EXISTS (
  SELECT 1
  FROM role_assignments ra
  JOIN roles r ON r.id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Project'
    AND ra.roleable_id    = 5
    AND r.name            = 'editor'
    AND active_at($now)
)
```

#### Active memberships — `memberships(roleable)`

Returns the principal's active role assignments on a roleable, useful for UI displays ("you are
a mentor on this cohort, expiring March 15"):

```ruby
user.memberships(cohort, at: incident_time)
  .map { |a| a.role.name }
```

SQL equivalent:

```sql
SELECT ra.*, r.name AS role_name
FROM role_assignments ra
JOIN roles r ON r.id = ra.role_id
WHERE ra.principal_type = 'User'
  AND ra.principal_id   = 7
  AND ra.roleable_type  = 'Cohort'
  AND ra.roleable_id    = 12
  AND active_at($now)
```

#### Effective abilities on a roleable

For admin UIs and debugging. Not on the hot path:

```ruby
scoped_role_ids = principal.role_assignments
  .active.for_roleable(project).select(:role_id)
all_abilities = RoleAbility
  .where(role_id: scoped_role_ids)
  .pluck(:ability).uniq.sort
```

SQL equivalent:

```sql
SELECT DISTINCT rb.ability
FROM role_assignments ra
JOIN role_abilities rb ON rb.role_id = ra.role_id
WHERE ra.principal_type = 'User'
  AND ra.principal_id   = 7
  AND ra.roleable_type  = 'Project'
  AND ra.roleable_id    = 5
  AND active_at($now)
ORDER BY rb.ability
```

### Inverse queries: who can do X on Y?

The forward query asks "can principal X do ability A on roleable Y?" The inverse asks "which
principals can do ability A on roleable Y?" Both map to the same tables and indices — the
difference is which column is the input and which is the output.

Inverse queries serve notification routing ("who should be notified when an article is pending
review?"), admin UIs ("who has access to this project?"), compliance audits ("list every
principal with billing access on this organization"), and bulk operations ("email all editors
on this cohort").

#### Principals who can perform an ability on a roleable

```ruby
role_ids = RoleAbility.where(ability: "publish")
  .select(:role_id)
principal_refs = RoleAssignment.active.for_roleable(article)
  .where(role_id: role_ids)
  .pluck(:principal_type, :principal_id).uniq
```

SQL equivalent:

```sql
SELECT DISTINCT ra.principal_type, ra.principal_id
FROM role_assignments ra
JOIN role_abilities rb ON rb.role_id = ra.role_id
WHERE ra.roleable_type = 'Article'
  AND ra.roleable_id   = 42
  AND rb.ability        = 'publish'
  AND active_at($now)
```

To load only `User` principals:

```ruby
user_ids = principal_refs
  .select { |type, _| type == "User" }
  .map(&:last)
User.where(id: user_ids)
```

SQL equivalent (single query, no Ruby post-filtering):

```sql
SELECT u.*
FROM users u
WHERE u.id IN (
  SELECT ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.roleable_type  = 'Article'
    AND ra.roleable_id    = 42
    AND rb.ability         = 'publish'
    AND active_at($now)
)
```

#### Principals who hold a specific role on a roleable

```ruby
RoleAssignment.active.for_roleable(project)
  .joins(:role).where(roles: {name: "editor"})
  .pluck(:principal_type, :principal_id)
```

SQL equivalent:

```sql
SELECT DISTINCT ra.principal_type, ra.principal_id
FROM role_assignments ra
JOIN roles r ON r.id = ra.role_id
WHERE ra.roleable_type = 'Project'
  AND ra.roleable_id   = 5
  AND r.name           = 'editor'
  AND active_at($now)
```

#### All principals with any access on a roleable

For admin UIs showing "who has access to this project?":

```ruby
RoleAssignment.active.for_roleable(project)
  .select(:principal_type, :principal_id).distinct
```

SQL equivalent:

```sql
SELECT DISTINCT ra.principal_type, ra.principal_id
FROM role_assignments ra
WHERE ra.roleable_type = 'Project'
  AND ra.roleable_id   = 5
  AND active_at($now)
```

### Composed queries: roleable hierarchies

This design does not include hierarchical roles (role A inheriting from role B), but many
applications have **hierarchical roleables**: an `Organization` owns `Project`s, a `Project`
owns `Article`s. The question becomes: "does the user's `editor` role on the organization
cascade to the articles within it?"

The RBAC layer itself does **not** cascade. A role assignment on `Organization 3` says nothing
about `Project 7` unless the policy explicitly checks the parent. This is deliberate — implicit
cascading makes it impossible to grant access to an organization without granting access to
everything inside it, which is rarely the correct behavior.

Policies that want hierarchical evaluation compose the primitives explicitly:

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  def update?
    # Direct check on the article itself
    if user&.can?(Abilities::UPDATE_ARTICLE, record)
      allow
    # Cascade: check the article's project
    elsif record.project &&
          user&.can?(Abilities::UPDATE_ARTICLE, record.project)
      allow
    # Cascade: check the project's organization
    elsif record.project&.organization &&
          user&.can?(Abilities::UPDATE_ARTICLE,
            record.project.organization)
      allow
    else
      deny(reason: "not permitted to update this article")
    end
  end
end
```

Each `can?` call is its own SQL `EXISTS` — composing them produces a chain of `OR EXISTS`
clauses. This is not a graph traversal; it is a bounded, explicit list of scopes to check.

#### SQL equivalence for hierarchical `can?`

The composed Ruby above maps to:

```sql
-- Can principal (User, 7) update Article 42?
-- Check the article itself, its project, and the project's org.
SELECT EXISTS (
  -- Direct: role on the article
  SELECT 1
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Article'
    AND ra.roleable_id    = 42
    AND rb.ability         = 'update_article'
    AND active_at($now)
)
OR EXISTS (
  -- Parent: role on the article's project
  SELECT 1
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Project'
    AND ra.roleable_id    = (SELECT project_id FROM articles
                             WHERE id = 42)
    AND rb.ability         = 'update_article'
    AND active_at($now)
)
OR EXISTS (
  -- Grandparent: role on the project's organization
  SELECT 1
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Organization'
    AND ra.roleable_id    = (SELECT p.organization_id
                             FROM projects p
                             JOIN articles a ON a.project_id = p.id
                             WHERE a.id = 42)
    AND rb.ability         = 'update_article'
    AND active_at($now)
)
```

Each `OR EXISTS` is independent and short-circuits. The database resolves the parent IDs via
subselects on the application's own tables — no RBAC schema changes needed.

#### Inverse: who can update Article 42 (including hierarchy)?

The inverse of the hierarchical query — "which principals can update this article, considering
roles on the article, its project, and its project's organization?" — follows the same pattern
with the axes swapped:

```sql
SELECT DISTINCT principal_type, principal_id FROM (
  -- Roles on the article itself
  SELECT ra.principal_type, ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.roleable_type = 'Article'
    AND ra.roleable_id   = 42
    AND rb.ability        = 'update_article'
    AND active_at($now)

  UNION

  -- Roles on the article's project
  SELECT ra.principal_type, ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.roleable_type = 'Project'
    AND ra.roleable_id   = (SELECT project_id FROM articles
                            WHERE id = 42)
    AND rb.ability        = 'update_article'
    AND active_at($now)

  UNION

  -- Roles on the project's organization
  SELECT ra.principal_type, ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.roleable_type = 'Organization'
    AND ra.roleable_id   = (SELECT p.organization_id
                            FROM projects p
                            JOIN articles a ON a.project_id = p.id
                            WHERE a.id = 42)
    AND rb.ability        = 'update_article'
    AND active_at($now)
) AS authorized_principals
```

The pattern is mechanical: for each level of the hierarchy, emit one `UNION` branch with the
roleable resolved via subselect. The policy defines which levels to check; the SQL mirrors that
list exactly. No recursion, no graph traversal, no `WITH RECURSIVE`.

#### Helper: `authorized_principals` scope

Applications that frequently run inverse queries can wrap the pattern in a reusable scope:

```ruby
# app/models/concerns/role_bearer.rb (class methods)
module RoleBearer
  module ClassMethods
    # Returns principal type/id pairs who hold the given
    # ability on any of the provided roleables.
    def authorized_principals(ability, *roleables,
      at: Time.current)
      role_ids = RoleAbility.where(ability: ability.to_s)
        .select(:role_id)

      by_role = roleables.flat_map do |roleable|
        RoleAssignment.active(at:)
          .for_roleable(roleable)
          .where(role_id: role_ids)
          .pluck(:principal_type, :principal_id)
      end

      by_role.uniq
    end
  end
end
```

Usage with hierarchy:

```ruby
# Who can update this article, checking all three levels?
refs = User.authorized_principals(
  Abilities::UPDATE_ARTICLE,
  article,
  article.project,
  article.project.organization
)
```

The caller decides which roleables to check — the hierarchy is explicit, not implicit.

### Scope integration: forward and inverse policy scopes

Turnstile's existing `Policy::Scope#resolve` answers the forward question: "which records can
this user see?" The RBAC layer provides the data for that decision.

#### Forward scope: which articles can user X see?

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  class Scope < Turnstile::Authorization::Policy::Scope
    def resolve
      return scope.none unless user

      # IDs of roleables where the user has view access
      viewable_ids = RoleAssignment.active(at: at)
        .where(principal: user)
        .where(roleable_type: "Article")
        .joins(role: :role_abilities)
        .where(role_abilities: {ability: "view_article"})
        .pluck(:roleable_id)

      scope.where(id: viewable_ids)
    end
  end
end
```

SQL equivalent:

```sql
SELECT a.*
FROM articles a
WHERE a.id IN (
  SELECT ra.roleable_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Article'
    AND rb.ability         = 'view_article'
    AND active_at($now)
)
```

When the scope needs to check parent roleables (e.g., "user can view all articles in projects
they have access to"), the query composes with a join:

```ruby
def resolve
  return scope.none unless user

  # Articles the user can view directly
  direct_ids = role_assignment_ids_for("Article",
    "view_article")

  # Articles in projects the user can view
  project_ids = role_assignment_ids_for("Project",
    "view_article")

  scope.where(id: direct_ids)
    .or(scope.where(project_id: project_ids))
end

private

def role_assignment_ids_for(roleable_type, ability)
  RoleAssignment.active(at: at)
    .where(principal: user,
      roleable_type: roleable_type)
    .joins(role: :role_abilities)
    .where(role_abilities: {ability: ability})
    .pluck(:roleable_id)
end
```

SQL equivalent:

```sql
SELECT a.*
FROM articles a
WHERE a.id IN (
  -- Direct role on the article
  SELECT ra.roleable_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Article'
    AND rb.ability         = 'view_article'
    AND active_at($now)
)
OR a.project_id IN (
  -- Role on the article's project
  SELECT ra.roleable_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.principal_id   = 7
    AND ra.roleable_type  = 'Project'
    AND rb.ability         = 'view_article'
    AND active_at($now)
)
```

#### Inverse scope: which users can see Article 42?

The inverse of the forward scope. Instead of "which articles can user X see?" it answers "which
users can see article Y?" This is useful for notification routing, access auditing, and admin
UIs that show "who has access to this record."

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  # Inverse scope: returns principals who can access a record.
  class InverseScope
    attr_reader :record, :ability, :at

    def initialize(record, ability, at: Time.current)
      @record = record
      @ability = ability.to_s
      @at = at
    end

    # Returns principal type/id pairs. The caller decides
    # which principal types to load.
    def resolve
      by_role = RoleAssignment.active(at: at)
        .for_roleable(record)
        .joins(role: :role_abilities)
        .where(role_abilities: {ability: ability})
        .pluck(:principal_type, :principal_id)

      by_role.uniq
    end

    # Convenience: resolve and load User records directly.
    def users
      refs = resolve
      user_ids = refs
        .select { |type, _| type == "User" }
        .map(&:last)
      User.where(id: user_ids)
    end
  end
end
```

SQL equivalent of `resolve`:

```sql
SELECT DISTINCT ra.principal_type, ra.principal_id
FROM role_assignments ra
JOIN role_abilities rb ON rb.role_id = ra.role_id
WHERE ra.roleable_type = 'Article'
  AND ra.roleable_id   = 42
  AND rb.ability        = 'view_article'
  AND active_at($now)
```

SQL equivalent of `users` (single query):

```sql
SELECT u.*
FROM users u
WHERE u.id IN (
  SELECT ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.principal_type = 'User'
    AND ra.roleable_type  = 'Article'
    AND ra.roleable_id    = 42
    AND rb.ability         = 'view_article'
    AND active_at($now)
)
```

With hierarchy (checking the article, its project, and its organization):

```ruby
class ArticlePolicy < Turnstile::Authorization::Policy
  class InverseScope
    def resolve_with_hierarchy
      roleables = [record]
      roleables << record.project if record.respond_to?(:project)
      if record.respond_to?(:project) &&
         record.project&.respond_to?(:organization)
        roleables << record.project.organization
      end
      roleables.compact!

      by_role = roleables.flat_map do |roleable|
        RoleAssignment.active(at: at)
          .for_roleable(roleable)
          .joins(role: :role_abilities)
          .where(role_abilities: {ability: ability})
          .pluck(:principal_type, :principal_id)
      end

      by_role.uniq
    end
  end
end
```

SQL equivalent:

```sql
SELECT DISTINCT principal_type, principal_id FROM (
  -- Roles on the article
  SELECT ra.principal_type, ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.roleable_type = 'Article'
    AND ra.roleable_id   = 42
    AND rb.ability        = 'view_article'
    AND active_at($now)

  UNION

  -- Roles on the article's project
  SELECT ra.principal_type, ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.roleable_type = 'Project'
    AND ra.roleable_id   = (SELECT project_id FROM articles
                            WHERE id = 42)
    AND rb.ability        = 'view_article'
    AND active_at($now)

  UNION

  -- Roles on the project's organization
  SELECT ra.principal_type, ra.principal_id
  FROM role_assignments ra
  JOIN role_abilities rb ON rb.role_id = ra.role_id
  WHERE ra.roleable_type = 'Organization'
    AND ra.roleable_id   = (SELECT p.organization_id
                            FROM projects p
                            JOIN articles a ON a.project_id = p.id
                            WHERE a.id = 42)
    AND rb.ability        = 'view_article'
    AND active_at($now)
) AS authorized_principals
```

### Point-in-time queries (time travel)

Every read-path method accepts `at:` to evaluate permissions at an arbitrary instant. The
database is not modified — the same `starts_at` / `expires_at` columns are evaluated against
the supplied time instead of `Time.current`.

"Could this user publish articles on this project last Tuesday at 3 AM?"

```ruby
user.can?(Abilities::PUBLISH, project, at: Time.new(2026, 2, 24, 3))
```

"What roles did this user hold on this cohort during the incident window?"

```ruby
user.memberships(cohort, at: incident_time)
  .map { |a| a.role.name }
```

"Will this user still have mentor access next month?"

```ruby
user.has_role?(:mentor, cohort, at: 1.month.from_now)
```

"Which principals could manage billing on this organization at the end of last quarter?"

```ruby
eoq = Time.new(2026, 3, 31, 23, 59, 59)
role_ids = RoleAbility.where(ability: "manage_billing")
  .select(:role_id)
RoleAssignment.active(at: eoq).for_roleable(org)
  .where(role_id: role_ids)
  .pluck(:principal_type, :principal_id)
```

The `active(at:)` scope composes naturally with `for_roleable` and any other ActiveRecord scope.
No special query builder is needed. Every SQL fragment above works identically with time travel —
substitute `$now` with the desired instant.

### SQL equivalence guarantee

Every Ruby method in the `RoleBearer` concern and every scope in a policy maps to a single SQL
expression. This is not an accident — it is a design invariant. The rules:

1. **No Ruby-side filtering.** If a permission check touches the database, the entire predicate
   must be expressible as SQL. Methods like `can?` use `EXISTS` subqueries; scopes use `WHERE IN`
   with subselects. There is no `select { ... }` on an array of results.

2. **No recursion.** Hierarchical roleable checks are explicit `OR EXISTS` chains, not
   `WITH RECURSIVE` graph traversals. The policy declares which levels to check; the query
   mirrors that list. This bounds query complexity and makes execution plans predictable.

3. **No implicit cascading.** A role on `Organization 3` does not automatically grant access to
   `Project 7` within it. Cascading is a policy decision, not a data model property. The SQL
   reflects only what the policy explicitly checks.

4. **Composable fragments.** Each primitive (`can?`, `has_role?`, `memberships`, inverse lookups)
   produces a SQL fragment that can be composed with `AND`, `OR`, `UNION`, or embedded as a
   subquery in a larger expression. ActiveRecord's `where`, `joins`, `merge`, and `or` methods
   handle the composition.

5. **Symmetry between forward and inverse.** The forward query "can user X do ability A on
   roleable Y?" and the inverse "which principals can do ability A on roleable Y?" use the
   same tables, same indices, and same join pattern. The only difference is which column is
   parameterized and which is projected.

### Audit log queries

#### History for a principal

"What happened to this user's access over time?"

```ruby
RoleEvent.for_target(user).recent
# => all events where this user's access changed,
#    newest first
```

#### Changes made by an actor

"What did this admin do?"

```ruby
RoleEvent.for_actor(admin).recent.limit(50)
```

#### History for a roleable

"Who was granted or revoked access on this cohort?"

```ruby
RoleEvent.for_roleable(cohort).recent
```

#### Recent changes (global view)

For an admin dashboard showing the latest role activity across the system:

```ruby
RoleEvent.recent.includes(:actor, :target).limit(100)
```

#### Filtering by action

"Show me all revocations in the last 30 days":

```ruby
RoleEvent.where(action: "revoke")
  .where("created_at > ?", 30.days.ago)
  .recent
```

#### Expiration sweep

A scheduled job that deactivates expired assignments and records the event:

```ruby
RoleAssignment.where("expires_at <= ?", Time.current)
  .find_each do |assignment|
    ActiveRecord::Base.transaction do
      RoleEvent.create!(
        actor: nil,
        target: assignment.principal,
        action: "expire",
        role_name: assignment.role.name,
        roleable: assignment.roleable,
        metadata: {expired_at: assignment.expires_at.iso8601}
      )

      assignment.destroy!
    end
  end
```

`actor: nil` signals that the system — not a human or service account — caused the change.

## Caching Considerations

For most Rails applications, the `EXISTS` queries in `can?` are fast enough without caching. The
role_abilities table is small (dozens of rows) and the indices cover every query pattern.

If profiling shows authorization queries are a bottleneck:

1. **Request-level memoization.** Cache the principal's ability set for a given roleable in a
   `@_abilities` instance variable on the principal model, cleared at the end of the request. This
   turns N `can?` calls per request into one query per roleable.

2. **Counter-cache or materialized set.** Maintain a serialized array of ability strings on the
   principal record, updated by callbacks on RoleAssignment. This eliminates the
   join entirely but adds write-time complexity.

3. **Redis/cache store.** For applications with thousands of abilities or very high request rates,
   cache the ability set in Redis keyed by principal type/id and roleable type/id, with TTL expiry
   and invalidation on role changes.

Start without caching. Add it only when measured.

## Instrumentation

The RBAC layer has two kinds of observable operations: **reads** (permission checks) and
**writes** (role assignments and revocations). Each benefits from a different
instrumentation mechanism.

### Read path: `ActiveSupport::Notifications.instrument`

Permission checks (`can?`, `has_role?`, `memberships`) are the hot path. Wrapping them in
`Notifications.instrument` makes them visible to log subscribers, APM tools, and custom
dashboards without changing their return values.

```ruby
# app/models/concerns/role_bearer.rb (instrumented)
def can?(ability, roleable, at: Time.current)
  ActiveSupport::Notifications.instrument(
    "can.turnstile_rbac",
    principal: self, ability: ability,
    roleable: roleable, at: at
  ) do |payload|
    ability_s = ability.to_s
    result = role_granted?(ability_s, roleable, at:)
    payload[:result] = result
    result
  end
end
```

The block form of `instrument` automatically records `:start`, `:finish`, `:duration`, and
`:allocations`. A subscriber can log slow checks, report hit/miss ratios, or feed metrics into
Prometheus:

```ruby
ActiveSupport::Notifications.subscribe(
  "can.turnstile_rbac"
) do |event|
  if event.duration > 50 # ms
    Rails.logger.warn(
      "[RBAC] Slow permission check: " \
      "#{event.payload[:ability]} on " \
      "#{event.payload[:roleable].class}#" \
      "#{event.payload[:roleable].id} " \
      "(#{event.duration.round(1)}ms)"
    )
  end
end
```

Suggested event names:

| Event                         | Fires from     | Payload keys                           |
| ----------------------------- | -------------- | -------------------------------------- |
| `can.turnstile_rbac`          | `can?`         | principal, ability, roleable, at, result |
| `has_role.turnstile_rbac`     | `has_role?`    | principal, role_name, roleable, at, result |
| `memberships.turnstile_rbac`  | `memberships`  | principal, roleable, at, count         |

### Write path: `ActiveSupport::EventReporter`

Rails 8.1 introduces `EventReporter` for structured domain events — events that carry semantic
meaning beyond timing. Role assignments and revocations are domain events: they
describe something that happened in the business, not just a performance measurement.

```ruby
class RoleService
  def self.assign(actor:, principal:, role:,
    roleable:, starts_at: nil, expires_at: nil)
    ActiveRecord::Base.transaction do
      assignment = RoleAssignment.create!(
        principal: principal,
        role: role,
        roleable: roleable,
        starts_at: starts_at,
        expires_at: expires_at
      )

      RoleEvent.record_assign(
        actor: actor,
        target: principal,
        role: role,
        roleable: roleable,
        metadata: {
          starts_at: starts_at&.iso8601,
          expires_at: expires_at&.iso8601
        }.compact
      )

      Rails.event.notify(
        "role_assigned.turnstile_rbac",
        actor: actor,
        principal: principal,
        role: role.name,
        roleable: roleable,
        starts_at: starts_at,
        expires_at: expires_at
      )

      assignment
    end
  end
end
```

`Rails.event.notify` emits a structured event with automatic parameter filtering (sensitive
values like `:password` are scrubbed), source location tagging, and namespace-filtered log
output. Subscribe to the `turnstile_rbac` namespace to capture all write events:

```ruby
# config/initializers/rbac_instrumentation.rb
Rails.event.subscribe("turnstile_rbac") do |event|
  Rails.logger.info(
    "[RBAC] #{event.name}: " \
    "principal=#{event.payload[:principal]&.to_gid} " \
    "role=#{event.payload[:role]} " \
    "roleable=#{event.payload[:roleable]&.to_gid}"
  )
end
```

Suggested write-path events:

| Event                              | Fires from              |
| ---------------------------------- | ----------------------- |
| `role_assigned.turnstile_rbac`     | `RoleService.assign`    |
| `role_revoked.turnstile_rbac`      | `RoleService.revoke`    |
| `role_modified.turnstile_rbac`     | `RoleService.extend_expiry` |
| `role_expired.turnstile_rbac`      | Expiration sweep        |

### Why two mechanisms?

`Notifications.instrument` wraps a block and measures duration — ideal for the read path where
timing matters and the caller needs the return value. `EventReporter.notify` fires a one-shot
structured event with no block — ideal for the write path where the event is a side effect of an
operation that has already completed. Using both keeps instrumentation idiomatic and avoids
shoe-horning domain events into a timing API.

## Migration Plan

### Step 1: Generate tables

```ruby
class CreateRbacTables < ActiveRecord::Migration[8.1]
  def change
    create_table :roles do |t|
      t.string :name, null: false
      t.string :description
      t.timestamps
      t.index :name, unique: true
    end

    create_table :role_abilities do |t|
      t.references :role, null: false, foreign_key: true
      t.string :ability, null: false
      t.datetime :created_at, null: false
      t.index [:role_id, :ability], unique: true
      t.index :ability
    end

    create_table :role_assignments do |t|
      t.references :principal, null: false, polymorphic: true
      t.references :role, null: false, foreign_key: true
      t.references :roleable, null: false, polymorphic: true
      t.datetime :starts_at
      t.datetime :expires_at
      t.timestamps
      t.index [:principal_type, :principal_id, :role_id,
        :roleable_type, :roleable_id],
        name: "idx_role_assignments_lookup"
      t.index :expires_at
    end

    create_table :role_events do |t|
      t.references :actor, polymorphic: true
      t.references :target, null: false, polymorphic: true
      t.string :action, null: false
      t.string :role_name
      t.references :roleable, polymorphic: true
      t.jsonb :metadata
      t.datetime :created_at, null: false
      t.index :action
      t.index :created_at
    end
  end
end
```

### Step 2: Seed roles and abilities

```ruby
# db/seeds/rbac.rb
roles = {
  admin: {
    description: "Full system access",
    abilities: Abilities::ALL
  },
  editor: {
    description: "Content management",
    abilities: [
      Abilities::CREATE_ARTICLE,
      Abilities::UPDATE_ARTICLE,
      Abilities::PUBLISH,
      Abilities::ARCHIVE
    ]
  },
  viewer: {
    description: "Read-only access",
    abilities: []
  }
}

roles.each do |name, config|
  role = Role.find_or_create_by!(name: name.to_s) do |r|
    r.description = config[:description]
  end

  config[:abilities].each do |ability|
    RoleAbility.find_or_create_by!(
      role: role, ability: ability.to_s
    )
  end
end
```

### Step 3: Migrate existing boolean columns

If the user model currently has columns like `admin`, `editor`, etc., they must be mapped to
scoped role assignments. Determine the appropriate roleable for each — typically the application's
top-level container (an organization, a tenant, etc.):

```ruby
class MigrateBooleanRolesToRbac < ActiveRecord::Migration[8.1]
  def up
    admin_role = Role.find_by!(name: "admin")
    editor_role = Role.find_by!(name: "editor")

    User.where(admin: true).find_each do |user|
      # Scope to the user's organization (or whatever
      # top-level roleable makes sense for the app).
      RoleAssignment.find_or_create_by!(
        principal: user,
        role: admin_role,
        roleable: user.organization
      )
    end

    User.where(editor: true).find_each do |user|
      RoleAssignment.find_or_create_by!(
        principal: user,
        role: editor_role,
        roleable: user.organization
      )
    end

    # Remove boolean columns after verifying:
    # remove_column :users, :admin
    # remove_column :users, :editor
  end
end
```

### Step 4: Update policies

Replace `user.admin?` / `user.editor?` with `user.can?(:ability, record)` in each policy. This
can be done incrementally — the old boolean methods can coexist with the new role system during
the transition.

## What This Design Does Not Include

- **Global (unscoped) roles.** Every role assignment is scoped to a roleable. There is no concept
  of a "site-wide admin role" that floats untethered from any record. If a principal needs a
  system-wide ability, scope the role to a top-level roleable like an organization or tenant.
  Global roles conflate "permission" with "role" and are a common source of confusion in gems
  like Rolify.

- **Zanzibar / ReBAC.** Relationship-based access control with graph traversal solves
  multi-service, Google-scale problems. For a typical Rails monolith, RBAC with a roles table is
  the right answer. If the application later needs "user X can edit document Y because they belong
  to organization Z which owns folder W which contains document Y," that is a different system.

- **Hierarchical roles.** Role A inheriting from role B adds complexity (cycle detection, ordering)
  for marginal benefit. If an `admin` needs everything an `editor` has, assign both the `admin`
  role abilities and the `editor` role abilities to the `admin` role. Flat is better than nested.
  Note: hierarchical **roleables** (organization → project → article) are supported through
  explicit policy composition — see "Composed queries: roleable hierarchies" in the Querying
  Patterns section. The hierarchy is expressed in policies, not in the data model.

- **Implicit cascading.** A role on an organization does not automatically cascade to projects or
  articles within it. Cascading is a policy decision. Policies that want hierarchical evaluation
  compose explicit `can?` checks against each level of the hierarchy, producing bounded `OR EXISTS`
  SQL chains. See "SQL equivalence guarantee" for the design invariants.

## MustImplement Policy

Turnstile's base `Policy` is DenyAll: unoverridden permission methods return `deny`. This is safe
but silent — an application can ship with a policy that denies everything and never notice.
`PermitAll` is the mirror: everything is allowed.

`MustImplement` is the third tier. It **raises** when a permission method is called without an
override. The host application cannot accidentally rely on a default; it must provide an explicit
implementation for every registered permission.

### Why?

Libraries and engines that ship default policies face a dilemma. If the default denies, the host
application might never override the policy and wonder why nothing works. If the default allows,
the host application might never override the policy and accidentally expose privileged operations.
Raising forces the host to make a conscious choice for each permission.

### Implementation

```ruby
module Turnstile
  module Authorization
    class MustImplement < Policy
      class NotImplementedError < ::NotImplementedError
        def initialize(policy_class, permission)
          super(
            "#{policy_class.name}##{permission}? must be " \
            "overridden — the base policy requires an " \
            "explicit implementation"
          )
        end
      end

      class Scope < Policy::Scope
        def resolve
          raise NotImplementedError.new(
            self.class.name,
            :resolve
          )
        end
      end

      private

      def method_missing(method, *args)
        perm = method.to_s.chomp("?").to_sym
        if method.to_s.end_with?("?") &&
            self.class.permissions.key?(perm)
          raise NotImplementedError.new(
            self.class, perm
          )
        end
        super
      end

      def respond_to_missing?(method, include_private = false)
        if method.to_s.end_with?("?") &&
            self.class.permissions.key?(
              method.to_s.chomp("?").to_sym
            )
          true
        else
          super
        end
      end
    end
  end
end
```

### Behaviour comparison

| Base class      | Unoverridden permission | Unoverridden scope |
| --------------- | ----------------------- | ------------------ |
| `Policy`        | Returns `deny`          | Returns `scope.none` |
| `PermitAll`     | Returns `allow`         | Returns `scope.all`  |
| `MustImplement` | Raises `NotImplementedError` | Raises `NotImplementedError` |

### When to use

- **Library/engine default policies.** Ship a policy that inherits from `MustImplement`. The host
  application subclasses it and overrides every permission. If they miss one, they get a clear error
  in development or test — not a silent deny or a security hole.

- **Placeholder policies during development.** A team can stub out a new policy with
  `MustImplement` and fill in permissions one at a time. CI fails if any permission is left
  unimplemented.

- **Contract enforcement.** A shared policy interface between teams or services. The
  `MustImplement` base guarantees every consumer has addressed every permission.

### Composability

`MustImplement` inherits from `Policy`, so it participates in the composite operators:

```ruby
# This works — AnyOf will try ConcretePolicy first, and
# only reach the MustImplement policy if ConcretePolicy
# denies. But if MustImplement has an unoverridden
# permission, it raises — which is the intended signal.
ConcretePolicy | SomeMustImplementPolicy  # => AnyOf composite
```

This is intentional. A `MustImplement` policy in a composite signals a bug: the host should have
overridden it before wiring it into a composite. The raise surfaces this during development.

## RBAC Admin Engine

An optional Rails engine that provides a management UI for roles, role assignments, and the
role-ability mapping. Mounted by the host application at a path of its choosing.

### Design goals

1. **Self-securing.** The engine's own controllers are protected by Turnstile policies. If the
   host application does not override these policies, the engine raises
   `MustImplement::NotImplementedError` on every request — it does not silently grant or deny
   access.

2. **Minimal opinions on UI.** The engine provides functional views with standard Rails conventions.
   The host application can override views, layouts, and partials using Rails' engine view path
   precedence.

3. **No JavaScript framework.** Server-rendered HTML with Turbo and Stimulus for interactivity.
   The engine works without a build step.

4. **Read-write separation.** Listing and viewing resources are separate permissions from creating,
   updating, or destroying them. An operator might have read-only access to the admin UI for
   auditing.

### Engine structure

```
turnstile-rbac-admin/
├── app/
│   ├── controllers/
│   │   └── turnstile/
│   │       └── rbac/
│   │           └── admin/
│   │               ├── application_controller.rb
│   │               ├── roles_controller.rb
│   │               ├── role_assignments_controller.rb
│   │               ├── role_abilities_controller.rb
│   │               └── role_events_controller.rb
│   ├── policies/
│   │   └── turnstile/
│   │       └── rbac/
│   │           └── admin/
│   │               ├── role_policy.rb
│   │               ├── role_assignment_policy.rb
│   │               ├── role_ability_policy.rb
│   │               └── role_event_policy.rb
│   └── views/
│       └── turnstile/
│           └── rbac/
│               └── admin/
│                   ├── layouts/
│                   │   └── application.html.erb
│                   ├── roles/
│                   ├── role_assignments/
│                   ├── role_abilities/
│                   └── role_events/
├── config/
│   └── routes.rb
└── lib/
    └── turnstile/
        └── rbac/
            └── admin/
                └── engine.rb
```

### Engine mount

```ruby
# config/routes.rb (host application)
Rails.application.routes.draw do
  mount Turnstile::Rbac::Admin::Engine,
    at: "/admin/rbac"
end
```

### Engine definition

```ruby
module Turnstile
  module Rbac
    module Admin
      class Engine < ::Rails::Engine
        isolate_namespace Turnstile::Rbac::Admin

        initializer "turnstile_rbac_admin.assets" do
          # Turbo and Stimulus are expected from the
          # host application's importmap or asset pipeline.
        end
      end
    end
  end
end
```

### Base controller

```ruby
module Turnstile
  module Rbac
    module Admin
      class ApplicationController < ::ApplicationController
        before_action :authorize_rbac_admin!

        layout "turnstile/rbac/admin/layouts/application"

        private

        def authorize_rbac_admin!
          # Each action authorizes through the resource's
          # policy. This base method is a hook for the host
          # to add shared checks (e.g., IP restrictions).
        end
      end
    end
  end
end
```

### Default engine policies (MustImplement)

Every resource managed by the engine has a default policy that inherits from `MustImplement`. The
host application **must** override each one.

```ruby
module Turnstile
  module Rbac
    module Admin
      class RolePolicy < Turnstile::Authorization::MustImplement
        permission :index,
          description: "List all roles"
        permission :show,
          description: "View a single role and its abilities"
        permission :create,
          description: "Create a new role"
        permission :update,
          description: "Rename a role or change its description"
        permission :destroy,
          description: "Delete a role"

        class Scope < Turnstile::Authorization::MustImplement::Scope
          # Host must override resolve to control which
          # roles are visible.
        end
      end
    end
  end
end
```

```ruby
module Turnstile
  module Rbac
    module Admin
      class RoleAssignmentPolicy <
          Turnstile::Authorization::MustImplement
        permission :index,
          description: "List role assignments"
        permission :show,
          description: "View a single role assignment"
        permission :create,
          description: "Assign a role to a principal"
        permission :destroy,
          description: "Revoke a role assignment"

        class Scope <
            Turnstile::Authorization::MustImplement::Scope
        end
      end
    end
  end
end
```

```ruby
module Turnstile
  module Rbac
    module Admin
      class RoleAbilityPolicy <
          Turnstile::Authorization::MustImplement
        permission :index,
          description: "List abilities for a role"
        permission :create,
          description: "Map an ability to a role"
        permission :destroy,
          description: "Remove an ability from a role"

        class Scope <
            Turnstile::Authorization::MustImplement::Scope
        end
      end
    end
  end
end
```

```ruby
module Turnstile
  module Rbac
    module Admin
      class RoleEventPolicy <
          Turnstile::Authorization::MustImplement
        permission :index,
          description: "List audit log events"
        permission :show,
          description: "View a single audit event"

        # No create/update/destroy — events are immutable.

        class Scope <
            Turnstile::Authorization::MustImplement::Scope
        end
      end
    end
  end
end
```

### Host application overrides

The host application creates policies that match the engine's namespace. Rails' autoloader
resolves the host's version first because `app/policies` appears before the engine's policies
in the load path.

```ruby
# app/policies/turnstile/rbac/admin/role_policy.rb
# (host application)
module Turnstile
  module Rbac
    module Admin
      class RolePolicy < Turnstile::Authorization::Policy
        permission :index,
          description: "List all roles"
        permission :show,
          description: "View a single role"
        permission :create,
          description: "Create a new role"
        permission :update,
          description: "Update a role"
        permission :destroy,
          description: "Delete a role"

        def index?
          user.can?(Abilities::MANAGE_ROLES, tenant)
        end

        def show?
          index?
        end

        def create?
          user.can?(Abilities::MANAGE_ROLES, tenant)
        end

        def update?
          create?
        end

        def destroy?
          create?
        end

        class Scope < Turnstile::Authorization::Policy::Scope
          def resolve
            if user.can?(Abilities::MANAGE_ROLES, tenant)
              scope.all
            else
              scope.none
            end
          end
        end

        private

        def tenant
          # The host decides what "tenant" means — an
          # Organization, a Company, the global scope, etc.
          record.respond_to?(:roleable) ?
            record.roleable : user.default_organization
        end
      end
    end
  end
end
```

### Example controller

```ruby
module Turnstile
  module Rbac
    module Admin
      class RolesController < ApplicationController
        def index
          @roles = policy_scope(Turnstile::Rbac::Role)
          authorize(@roles, :index?)
        end

        def show
          @role = Turnstile::Rbac::Role.find(params[:id])
          authorize(@role, :show?)
        end

        def new
          @role = Turnstile::Rbac::Role.new
          authorize(@role, :create?)
        end

        def create
          @role = Turnstile::Rbac::Role.new(role_params)
          authorize(@role, :create?)
          if @role.save
            redirect_to role_path(@role),
              notice: "Role created."
          else
            render :new, status: :unprocessable_entity
          end
        end

        def edit
          @role = Turnstile::Rbac::Role.find(params[:id])
          authorize(@role, :update?)
        end

        def update
          @role = Turnstile::Rbac::Role.find(params[:id])
          authorize(@role, :update?)
          if @role.update(role_params)
            redirect_to role_path(@role),
              notice: "Role updated."
          else
            render :edit, status: :unprocessable_entity
          end
        end

        def destroy
          @role = Turnstile::Rbac::Role.find(params[:id])
          authorize(@role, :destroy?)
          @role.destroy!
          redirect_to roles_path,
            notice: "Role deleted."
        end

        private

        def role_params
          params.require(:role).permit(:name, :description)
        end
      end
    end
  end
end
```

### Routes

```ruby
# config/routes.rb (engine)
Turnstile::Rbac::Admin::Engine.routes.draw do
  resources :roles do
    resources :role_abilities,
      only: [:index, :create, :destroy],
      path: "abilities"
  end
  resources :role_assignments, only: [:index, :show, :create, :destroy]
  resources :role_events, only: [:index, :show], path: "events"
end
```

### Failure mode: unoverridden policies

If the host application mounts the engine but does not override the policies, the first request
to any engine endpoint raises:

```
Turnstile::Authorization::MustImplement::NotImplementedError:
  Turnstile::Rbac::Admin::RolePolicy#index? must be overridden
  — the base policy requires an explicit implementation
```

This is the intended behavior. The error message tells the developer exactly which policy and
permission needs implementation. There is no ambiguity, no silent denial, and no accidental
exposure.

### View override convention

The host application can override any engine view by placing a file at the same path under
`app/views`:

```
app/views/turnstile/rbac/admin/roles/index.html.erb
```

Rails resolves `app/views` before the engine's `app/views`, so the host's version wins. The
engine's default views serve as a functional starting point and a reference implementation.

## Summary

| Layer             | Lives in  | Changes at    | Managed by       |
| ----------------- | --------- | ------------- | ---------------- |
| Abilities         | Code      | Deploy time   | Developers       |
| Roles             | Database  | Runtime       | Admins           |
| Role-ability map  | Database  | Runtime       | Admins           |
| Role assignments  | Database  | Runtime       | Admins           |
| Audit log         | Database  | Runtime       | System           |
| Instrumentation   | Code      | Deploy time   | Developers       |
| Policies          | Code      | Deploy time   | Developers       |

The policy layer is the brain. The RBAC layer is the memory. Policies ask questions; the role
system provides answers. Neither replaces the other.
