defmodule Consensus.ActivitiesTest do
  use Consensus.DataCase, async: true

  import Ecto.Query
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities
  alias Consensus.Activities.Group
  alias Consensus.Repo

  describe "slugs" do
    test "are generated automatically and are unique" do
      scope = user_scope_fixture()
      group_a = group_fixture(scope)
      group_b = group_fixture(scope)

      assert is_binary(group_a.slug)
      assert is_binary(group_b.slug)
      refute group_a.slug == group_b.slug
    end
  end

  describe "get_group!/2" do
    test "returns the group for its organizer" do
      scope = user_scope_fixture()
      group = group_fixture(scope)

      fetched = Activities.get_group!(scope, group.id)
      assert fetched.id == group.id
    end

    test "raises when the group belongs to someone else" do
      owner_scope = user_scope_fixture()
      stranger_scope = user_scope_fixture()
      group = group_fixture(owner_scope)

      assert_raise Ecto.NoResultsError, fn ->
        Activities.get_group!(stranger_scope, group.id)
      end
    end
  end

  describe "get_group_by_slug/1" do
    test "returns the group, unscoped" do
      scope = user_scope_fixture()
      group = group_fixture(scope)

      assert %Group{id: id} = Activities.get_group_by_slug(group.slug)
      assert id == group.id
    end

    test "returns nil for an unknown slug" do
      refute Activities.get_group_by_slug("no-such-slug")
    end
  end

  describe "change_group/3 and update_group/3 ownership" do
    test "raise for someone else's group" do
      owner_scope = user_scope_fixture()
      stranger_scope = user_scope_fixture()
      group = group_fixture(owner_scope)

      assert_raise FunctionClauseError, fn ->
        Activities.change_group(stranger_scope, group)
      end

      assert_raise FunctionClauseError, fn ->
        Activities.update_group(stranger_scope, group, %{title: "Hijacked"})
      end
    end

    test "update_group updates and broadcasts" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      :ok = Activities.subscribe_group(group.id)

      assert {:ok, updated} = Activities.update_group(scope, group, %{title: "New title"})
      assert updated.title == "New title"
      assert_receive {:group_updated, ^updated}
    end
  end

  describe "activity description cap" do
    test "rejects a description over 140 characters" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      too_long = String.duplicate("a", 141)

      assert {:error, changeset} =
               Activities.add_activity(scope, group, %{name: "x", description: too_long})

      assert "should be at most 140 character(s)" in errors_on(changeset).description
    end

    test "accepts exactly 140 characters" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      exactly = String.duplicate("a", 140)

      assert {:ok, activity} =
               Activities.add_activity(scope, group, %{name: "x", description: exactly})

      assert activity.description == exactly
    end
  end

  describe "add_activity/3" do
    test "appends at max(position) + 1 and broadcasts" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      :ok = Activities.subscribe_group(group.id)

      assert {:ok, first} = Activities.add_activity(scope, group, %{name: "First"})
      assert first.position == 1
      assert_receive {:activity_added, ^first}

      assert {:ok, second} = Activities.add_activity(scope, group, %{name: "Second"})
      assert second.position == 2
    end

    test "refuses a group that is not draft or voting" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      {:ok, cancelled} = Activities.cancel_group(scope, group)

      assert {:error, :group_not_open} = Activities.add_activity(scope, cancelled, %{name: "x"})
    end
  end

  describe "update_activity/3 and delete_activity/2 ownership" do
    test "refuse someone else's activity" do
      owner_scope = user_scope_fixture()
      stranger_scope = user_scope_fixture()
      group = group_fixture(owner_scope)
      activity = activity_fixture(group)

      assert {:error, :unauthorized} =
               Activities.update_activity(stranger_scope, activity, %{name: "Nope"})

      assert {:error, :unauthorized} = Activities.delete_activity(stranger_scope, activity)
    end
  end

  describe "delete_activity/2 renumbering" do
    test "keeps remaining positions contiguous after deleting one in the middle" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      first = activity_fixture(group)
      middle = activity_fixture(group)
      last = activity_fixture(group)

      assert {:ok, deleted} = Activities.delete_activity(scope, middle)
      assert deleted.id == middle.id

      remaining =
        Activities.get_group!(scope, group.id).activities |> Enum.sort_by(& &1.position)

      assert Enum.map(remaining, & &1.id) == [first.id, last.id]
      assert Enum.map(remaining, & &1.position) == [1, 2]
    end
  end

  describe "reorder_activities/3" do
    test "rejects an id list that is not exactly the group's current activity ids" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      first = activity_fixture(group)
      second = activity_fixture(group)

      # missing an id
      assert {:error, :invalid_ids} = Activities.reorder_activities(scope, group, [first.id])
      # a foreign id
      assert {:error, :invalid_ids} =
               Activities.reorder_activities(scope, group, [first.id, second.id, 999_999])

      # a repeated id
      assert {:error, :invalid_ids} =
               Activities.reorder_activities(scope, group, [first.id, first.id])
    end

    test "reorders positions to match the given list and broadcasts" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      first = activity_fixture(group)
      second = activity_fixture(group)
      :ok = Activities.subscribe_group(group.id)

      assert {:ok, [reordered_first, reordered_second]} =
               Activities.reorder_activities(scope, group, [second.id, first.id])

      assert reordered_first.id == second.id
      assert reordered_first.position == 1
      assert reordered_second.id == first.id
      assert reordered_second.position == 2

      assert_receive {:activities_changed, activities}
      assert Enum.map(activities, & &1.id) == [second.id, first.id]
    end
  end

  describe "publish_group/2" do
    test "refuses an empty pool" do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})

      assert {:error, :no_activities} = Activities.publish_group(scope, group)
    end

    test "refuses a missing deadline" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      activity_fixture(group)

      assert {:error, :no_deadline} = Activities.publish_group(scope, group)
    end

    test "publishes a draft group that has both activities and a deadline" do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)

      assert {:ok, published} = Activities.publish_group(scope, group)
      assert published.status == :voting
    end

    test "refuses a group that has already left draft" do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, voting} = Activities.publish_group(scope, group)

      assert {:error, :not_draft} = Activities.publish_group(scope, voting)
    end
  end

  describe "cancel_group/2" do
    test "cancels an open group" do
      scope = user_scope_fixture()
      group = group_fixture(scope)

      assert {:ok, cancelled} = Activities.cancel_group(scope, group)
      assert cancelled.status == :cancelled
      assert cancelled.cancelled_at
    end

    test "refuses an already-cancelled group" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      {:ok, cancelled} = Activities.cancel_group(scope, group)

      assert {:error, :already_finished} = Activities.cancel_group(scope, cancelled)
    end

    test "refuses an already-completed group" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      {:ok, completed} = Activities.complete_group(scope, group)

      assert {:error, :already_finished} = Activities.cancel_group(scope, completed)
    end
  end

  describe "maybe_complete_group/1" do
    test "completes a voting group past its deadline, and persists the transition" do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, voting} = Activities.publish_group(scope, group)

      past = past_deadline()
      Repo.update_all(from(g in Group, where: g.id == ^voting.id), set: [deadline_at: past])
      stale = %{voting | deadline_at: past}

      completed = Activities.maybe_complete_group(stale)
      assert completed.status == :completed
      assert completed.completed_at

      assert Repo.get!(Group, voting.id).status == :completed
    end

    test "leaves a voting group before its deadline untouched" do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, voting} = Activities.publish_group(scope, group)

      assert Activities.maybe_complete_group(voting).status == :voting
    end

    test "leaves a draft group untouched regardless of deadline" do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: past_deadline()})

      assert Activities.maybe_complete_group(group).status == :draft
    end
  end

  describe "list_groups/1, list_active_groups/1, list_past_groups/1" do
    test "list_groups/1 returns only the caller's groups, newest first, activities preloaded" do
      scope = user_scope_fixture()
      stranger_scope = user_scope_fixture()

      _older = group_fixture(scope)
      newer = group_fixture(scope)
      _someone_elses = group_fixture(stranger_scope)

      activity_fixture(newer)

      assert [first, second] = Activities.list_groups(scope)
      assert first.id == newer.id
      assert Ecto.assoc_loaded?(first.activities)
      assert length(first.activities) == 1
      assert second.id != newer.id
    end

    test "splits by status, completing an overdue voting group along the way" do
      scope = user_scope_fixture()

      draft = group_fixture(scope)

      voting_group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(voting_group)
      {:ok, voting} = Activities.publish_group(scope, voting_group)

      overdue_group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(overdue_group)
      {:ok, overdue} = Activities.publish_group(scope, overdue_group)

      Repo.update_all(from(g in Group, where: g.id == ^overdue.id),
        set: [deadline_at: past_deadline()]
      )

      cancelled_group = group_fixture(scope)
      {:ok, cancelled} = Activities.cancel_group(scope, cancelled_group)

      active_ids = scope |> Activities.list_active_groups() |> Enum.map(& &1.id)
      past_ids = scope |> Activities.list_past_groups() |> Enum.map(& &1.id)

      assert draft.id in active_ids
      assert voting.id in active_ids
      refute overdue.id in active_ids
      refute cancelled.id in active_ids

      assert cancelled.id in past_ids
      assert overdue.id in past_ids
      assert Repo.get!(Group, overdue.id).status == :completed
    end
  end

  describe "count_activities/1" do
    test "counts by group struct or by id" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      activity_fixture(group)
      activity_fixture(group)

      assert Activities.count_activities(group) == 2
      assert Activities.count_activities(group.id) == 2
    end
  end
end
