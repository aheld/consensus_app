defmodule Consensus.Activities.GroupTest do
  use Consensus.DataCase, async: true

  import Consensus.AccountsFixtures

  alias Consensus.Activities.{AnonymousOrganizer, Group}

  # The CHECK itself is pinned against raw SQL in release_test.exs; this pins that
  # `changeset/2` maps it to an error instead of letting `Exqlite.Error` escape (D-058).
  describe "changeset/2 and the ownership CHECK" do
    test "a group with no owner is a changeset error, not a raise" do
      assert {:error, changeset} =
               %Group{} |> Group.changeset(%{title: "Dinner"}) |> Repo.insert()

      assert %{organizer_id: ["a group must have exactly one owner"]} = errors_on(changeset)
    end

    test "a group with both owners is a changeset error, not a raise" do
      user = user_fixture()

      anonymous =
        :sha256
        |> :crypto.hash("token")
        |> AnonymousOrganizer.creation_changeset()
        |> Repo.insert!()

      assert {:error, changeset} =
               %Group{organizer_id: user.id, anonymous_organizer_id: anonymous.id}
               |> Group.changeset(%{title: "Dinner"})
               |> Repo.insert()

      assert %{organizer_id: ["a group must have exactly one owner"]} = errors_on(changeset)
    end

    test "either owner alone inserts" do
      user = user_fixture()

      anonymous =
        :sha256
        |> :crypto.hash("token")
        |> AnonymousOrganizer.creation_changeset()
        |> Repo.insert!()

      assert {:ok, _} =
               %Group{organizer_id: user.id} |> Group.changeset(%{title: "A"}) |> Repo.insert()

      assert {:ok, _} =
               %Group{anonymous_organizer_id: anonymous.id}
               |> Group.changeset(%{title: "B"})
               |> Repo.insert()
    end
  end
end
