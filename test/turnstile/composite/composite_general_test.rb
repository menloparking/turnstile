# frozen_string_literal: true

require_relative "../../test_helper"

# --- Test general policies for composite tests ---------

# Allows everything — all permission queries return allow.
class PermissivePolicy < Turnstile::Authorization::Policy
  def index? = allow

  def show? = allow

  def create? = allow

  def update? = allow

  def destroy? = allow
end

# Denies everything (inherits DenyAll default).
class RestrictivePolicy < Turnstile::Authorization::Policy
end

# Allows only read operations.
class ReadOnlyPolicy < Turnstile::Authorization::Policy
  def index? = allow

  def show? = allow
end

# Allows only write operations.
class WriteOnlyPolicy < Turnstile::Authorization::Policy
  def create? = allow

  def update? = allow

  def destroy? = allow
end

# Allows only admins to do anything.
class AdminOnlyPolicy < Turnstile::Authorization::Policy
  def create?
    user&.admin? ? allow : deny(reason: "admin only")
  end

  def update?
    user&.admin? ? allow : deny(reason: "admin only")
  end

  def destroy?
    user&.admin? ? allow : deny(reason: "admin only")
  end
end

# Allows editors and admins for create/update.
class StaffPolicy < Turnstile::Authorization::Policy
  def create?
    if user&.admin? || user&.editor?
      allow
    else
      deny(reason: "staff only")
    end
  end

  def update?
    if user&.admin? || user&.editor?
      allow
    else
      deny(reason: "staff only")
    end
  end
end

# --- AllOf (AND) tests ---------------------------------

class CompositeGeneralAllOfTest < Minitest::Test
  include TurnstileTestSetup

  def setup
    super
    @admin = User.create!(name: "Admin", role: "admin")
    @editor = User.create!(name: "Editor", role: "editor")
    @reader = User.create!(name: "Reader", role: "reader")
    @article = Article.create!(
      title: "Test", author_id: @admin.id
    )
  end

  def teardown
    Article.delete_all
    User.delete_all
    super
  end

  def test_all_of_allows_when_both_allow
    composite = Turnstile::Composite::General::AllOf.build(
      PermissivePolicy, ReadOnlyPolicy
    )
    result = composite.new(@admin, @article).show?

    assert result.allowed?
  end

  def test_all_of_denies_when_first_denies
    composite = Turnstile::Composite::General::AllOf.build(
      RestrictivePolicy, PermissivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.denied?
  end

  def test_all_of_denies_when_second_denies
    composite = Turnstile::Composite::General::AllOf.build(
      PermissivePolicy, RestrictivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.denied?
  end

  def test_all_of_denies_when_both_deny
    composite = Turnstile::Composite::General::AllOf.build(
      RestrictivePolicy, RestrictivePolicy
    )
    result = composite.new(@admin, @article).destroy?

    assert result.denied?
  end

  def test_all_of_with_admin_only_and_staff
    # Admin must satisfy both AdminOnly AND Staff.
    composite = Turnstile::Composite::General::AllOf.build(
      AdminOnlyPolicy, StaffPolicy
    )

    # Admin passes both
    result = composite.new(@admin, @article).create?
    assert result.allowed?

    # Editor passes Staff but not AdminOnly
    result = composite.new(@editor, @article).create?
    assert result.denied?
    assert_equal "admin only", result.reason

    # Reader passes neither
    result = composite.new(@reader, @article).create?
    assert result.denied?
  end

  def test_all_of_short_circuits_on_first_denial
    call_count = 0
    counter = Class.new(Turnstile::Authorization::Policy) {
      define_method(:create?) {
        call_count += 1
        allow
      }
    }

    composite = Turnstile::Composite::General::AllOf.build(
      RestrictivePolicy, counter
    )
    composite.new(@admin, @article).create?

    assert_equal 0, call_count
  end

  def test_all_of_is_subclass_of_policy
    composite = Turnstile::Composite::General::AllOf.build(
      PermissivePolicy
    )
    assert composite < Turnstile::Authorization::Policy
  end

  def test_all_of_policies_frozen
    composite = Turnstile::Composite::General::AllOf.build(
      PermissivePolicy, RestrictivePolicy
    )
    assert composite.policies.frozen?
  end

  def test_all_of_responds_to_permission_queries
    composite = Turnstile::Composite::General::AllOf.build(
      PermissivePolicy
    )
    policy = composite.new(@admin, @article)

    assert_respond_to policy, :create?
    assert_respond_to policy, :show?
    assert_respond_to policy, :destroy?
  end
end

# --- AnyOf (OR) tests ----------------------------------

class CompositeGeneralAnyOfTest < Minitest::Test
  include TurnstileTestSetup

  def setup
    super
    @admin = User.create!(name: "Admin", role: "admin")
    @editor = User.create!(name: "Editor", role: "editor")
    @reader = User.create!(name: "Reader", role: "reader")
    @article = Article.create!(
      title: "Test", author_id: @admin.id
    )
  end

  def teardown
    Article.delete_all
    User.delete_all
    super
  end

  def test_any_of_allows_when_first_allows
    composite = Turnstile::Composite::General::AnyOf.build(
      PermissivePolicy, RestrictivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.allowed?
  end

  def test_any_of_allows_when_second_allows
    composite = Turnstile::Composite::General::AnyOf.build(
      RestrictivePolicy, PermissivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.allowed?
  end

  def test_any_of_denies_when_all_deny
    composite = Turnstile::Composite::General::AnyOf.build(
      RestrictivePolicy, RestrictivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.denied?
  end

  def test_any_of_short_circuits_on_first_allow
    call_count = 0
    counter = Class.new(Turnstile::Authorization::Policy) {
      define_method(:create?) {
        call_count += 1
        deny(reason: "counted")
      }
    }

    composite = Turnstile::Composite::General::AnyOf.build(
      PermissivePolicy, counter
    )
    composite.new(@admin, @article).create?

    assert_equal 0, call_count
  end

  def test_any_of_with_admin_or_staff
    # Either AdminOnly OR Staff allows create.
    composite = Turnstile::Composite::General::AnyOf.build(
      AdminOnlyPolicy, StaffPolicy
    )

    # Admin passes AdminOnly (short circuits)
    result = composite.new(@admin, @article).create?
    assert result.allowed?

    # Editor fails AdminOnly, passes Staff
    result = composite.new(@editor, @article).create?
    assert result.allowed?

    # Reader fails both
    result = composite.new(@reader, @article).create?
    assert result.denied?
  end

  def test_any_of_with_read_or_write
    # ReadOnly | WriteOnly — covers all CRUD
    composite = Turnstile::Composite::General::AnyOf.build(
      ReadOnlyPolicy, WriteOnlyPolicy
    )

    result = composite.new(@admin, @article).show?
    assert result.allowed?

    result = composite.new(@admin, @article).create?
    assert result.allowed?
  end

  def test_any_of_is_subclass_of_policy
    composite = Turnstile::Composite::General::AnyOf.build(
      PermissivePolicy
    )
    assert composite < Turnstile::Authorization::Policy
  end
end

# --- NoneOf (NOT) tests --------------------------------

class CompositeGeneralNoneOfTest < Minitest::Test
  include TurnstileTestSetup

  def setup
    super
    @admin = User.create!(name: "Admin", role: "admin")
    @editor = User.create!(name: "Editor", role: "editor")
    @reader = User.create!(name: "Reader", role: "reader")
    @article = Article.create!(
      title: "Test", author_id: @admin.id
    )
  end

  def teardown
    Article.delete_all
    User.delete_all
    super
  end

  def test_none_of_allows_when_all_deny
    composite = Turnstile::Composite::General::NoneOf.build(
      RestrictivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.allowed?
  end

  def test_none_of_denies_when_any_allows
    composite = Turnstile::Composite::General::NoneOf.build(
      PermissivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.denied?
  end

  def test_none_of_inverts_admin_only
    # NOT(AdminOnly) — non-admins can create, admins cannot
    composite = Turnstile::Composite::General::NoneOf.build(
      AdminOnlyPolicy
    )

    # Admin: AdminOnly allows → NoneOf denies
    result = composite.new(@admin, @article).create?
    assert result.denied?

    # Reader: AdminOnly denies → NoneOf allows
    result = composite.new(@reader, @article).create?
    assert result.allowed?
  end

  def test_none_of_denial_includes_policy_info
    composite = Turnstile::Composite::General::NoneOf.build(
      PermissivePolicy
    )
    result = composite.new(@admin, @article).create?

    assert result.denied?
    assert_match(/PermissivePolicy.*allowed/, result.reason)
  end

  def test_none_of_with_multiple_policies
    # None of [ReadOnly, WriteOnly] must allow.
    # ReadOnly allows show → NoneOf denies show.
    composite = Turnstile::Composite::General::NoneOf.build(
      ReadOnlyPolicy, WriteOnlyPolicy
    )

    # show? — ReadOnly allows → NoneOf denies
    result = composite.new(@admin, @article).show?
    assert result.denied?

    # create? — ReadOnly denies, WriteOnly allows → denies
    result = composite.new(@admin, @article).create?
    assert result.denied?

    # For a query both deny (like :index from WriteOnly
    # perspective, but ReadOnly allows index) — so still
    # denied.
  end

  def test_none_of_is_subclass_of_policy
    composite = Turnstile::Composite::General::NoneOf.build(
      PermissivePolicy
    )
    assert composite < Turnstile::Authorization::Policy
  end
end

# --- Operator syntax tests -----------------------------

class CompositeGeneralOperatorTest < Minitest::Test
  include TurnstileTestSetup

  def setup
    super
    @admin = User.create!(name: "Admin", role: "admin")
    @editor = User.create!(name: "Editor", role: "editor")
    @reader = User.create!(name: "Reader", role: "reader")
    @article = Article.create!(
      title: "Test", author_id: @admin.id
    )
  end

  def teardown
    Article.delete_all
    User.delete_all
    super
  end

  def test_ampersand_creates_all_of
    composite = AdminOnlyPolicy & StaffPolicy
    assert composite < Turnstile::Composite::General::AllOf
  end

  def test_pipe_creates_any_of
    composite = AdminOnlyPolicy | StaffPolicy
    assert composite < Turnstile::Composite::General::AnyOf
  end

  def test_tilde_creates_none_of
    composite = ~AdminOnlyPolicy
    assert composite < Turnstile::Composite::General::NoneOf
  end

  def test_ampersand_evaluates_correctly
    composite = AdminOnlyPolicy & StaffPolicy

    # Admin passes both
    result = composite.new(@admin, @article).create?
    assert result.allowed?

    # Editor passes Staff but not AdminOnly
    result = composite.new(@editor, @article).create?
    assert result.denied?
  end

  def test_pipe_evaluates_correctly
    composite = AdminOnlyPolicy | StaffPolicy

    # Editor fails AdminOnly, passes Staff
    result = composite.new(@editor, @article).create?
    assert result.allowed?

    # Reader fails both
    result = composite.new(@reader, @article).create?
    assert result.denied?
  end

  def test_tilde_evaluates_correctly
    composite = ~AdminOnlyPolicy

    # Admin: AdminOnly allows → NOT denies
    result = composite.new(@admin, @article).create?
    assert result.denied?

    # Reader: AdminOnly denies → NOT allows
    result = composite.new(@reader, @article).create?
    assert result.allowed?
  end
end

# --- Nesting tests -------------------------------------

class CompositeGeneralNestingTest < Minitest::Test
  include TurnstileTestSetup

  def setup
    super
    @admin = User.create!(name: "Admin", role: "admin")
    @editor = User.create!(name: "Editor", role: "editor")
    @reader = User.create!(name: "Reader", role: "reader")
    @article = Article.create!(
      title: "Test", author_id: @admin.id
    )
  end

  def teardown
    Article.delete_all
    User.delete_all
    super
  end

  def test_nested_all_of_with_any_of
    # Must be Staff AND (AdminOnly OR ReadOnly)
    inner = Turnstile.any_of(AdminOnlyPolicy, ReadOnlyPolicy)
    composite = Turnstile.all_of(StaffPolicy, inner)

    # Admin creating: Staff allows, AdminOnly allows → allow
    result = composite.new(@admin, @article).create?
    assert result.allowed?

    # Editor showing: Staff denies show (DenyAll for show?)
    # → short circuit deny
    result = composite.new(@editor, @article).show?
    assert result.denied?

    # Admin showing: Staff denies show → deny
    result = composite.new(@admin, @article).show?
    assert result.denied?
  end

  def test_nested_operator_syntax
    # (AdminOnly & StaffPolicy) | ReadOnlyPolicy
    composite =
      (AdminOnlyPolicy & StaffPolicy) | ReadOnlyPolicy

    # Admin creating: left side allows (both pass)
    result = composite.new(@admin, @article).create?
    assert result.allowed?

    # Reader showing: left denies, ReadOnly allows show
    result = composite.new(@reader, @article).show?
    assert result.allowed?

    # Reader creating: left denies, ReadOnly denies create
    result = composite.new(@reader, @article).create?
    assert result.denied?
  end

  def test_deeply_nested
    # NOT(any_of(AdminOnly, all_of(Staff, ReadOnly)))
    inner_all = Turnstile.all_of(StaffPolicy, ReadOnlyPolicy)
    inner_any = Turnstile.any_of(AdminOnlyPolicy, inner_all)
    composite = Turnstile.none_of(inner_any)

    # Admin create: AdminOnly allows → any_of allows →
    # none_of denies
    result = composite.new(@admin, @article).create?
    assert result.denied?

    # Reader create: AdminOnly denies, Staff denies →
    # inner_all denies, inner_any denies → none_of allows
    result = composite.new(@reader, @article).create?
    assert result.allowed?
  end
end

# --- Module helper detection tests ---------------------

class CompositeGeneralModuleHelperTest < Minitest::Test
  include TurnstileTestSetup

  def test_all_of_detects_general_policies
    composite = Turnstile.all_of(
      AdminOnlyPolicy, StaffPolicy
    )
    assert composite < Turnstile::Composite::General::AllOf
  end

  def test_any_of_detects_general_policies
    composite = Turnstile.any_of(
      AdminOnlyPolicy, StaffPolicy
    )
    assert composite < Turnstile::Composite::General::AnyOf
  end

  def test_none_of_detects_general_policies
    composite = Turnstile.none_of(AdminOnlyPolicy)
    assert composite < Turnstile::Composite::General::NoneOf
  end
end
