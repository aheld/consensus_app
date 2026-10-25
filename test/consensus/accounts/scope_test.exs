defmodule Consensus.Accounts.ScopeTest do
  use Consensus.DataCase, async: true

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Accounts.{Scope, User}
  alias Consensus.Activities.AnonymousOrganizer

  # Written from docs/plans/accountless-organizer.md §3.1, not from the implementation.

  describe "for_anonymous_organizer/1" do
    test "returns nil for nil, mirroring for_user/1" do
      assert Scope.for_anonymous_organizer(nil) == nil
    end

    test "wraps a saved organizer, with no user" do
      {_raw_token, organizer} = anonymous_organizer_fixture()

      assert %Scope{user: nil, anonymous_organizer: ^organizer} =
               Scope.for_anonymous_organizer(organizer)
    end

    # The `is_integer(id)` guard: an `%AnonymousOrganizer{}` from a failed mint has
    # `id: nil`, and once both owner columns are nullable a scope built from it would
    # match every user-owned group's `anonymous_organizer_id: nil` (D-058 §2).
    test "refuses an unsaved organizer" do
      # Built from the changeset, not as a bare literal the type checker would flag.
      unsaved =
        :sha256
        |> :crypto.hash("never inserted")
        |> AnonymousOrganizer.creation_changeset()
        |> Ecto.Changeset.apply_changes()

      assert unsaved.id == nil
      assert_raise FunctionClauseError, fn -> Scope.for_anonymous_organizer(unsaved) end
    end
  end

  describe "authenticated?/1" do
    test "is true only for a scope holding a user" do
      user = user_fixture()

      assert Scope.authenticated?(Scope.for_user(user))
      refute Scope.authenticated?(anonymous_scope_fixture())
      refute Scope.authenticated?(%Scope{})
      refute Scope.authenticated?(nil)
    end

    test "does not touch the database to answer" do
      # A raw struct is enough: it is a shape predicate, like `admin?/1`.
      assert Scope.authenticated?(%Scope{user: %User{}})
    end
  end
end
