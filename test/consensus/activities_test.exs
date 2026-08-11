defmodule Consensus.ActivitiesTest do
  use Consensus.DataCase, async: true

  import Ecto.Query
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Activities.Group
  alias Consensus.Repo
  alias Consensus.Voting
  alias Consensus.Voting.Participant
  alias Consensus.Voting.Vote

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

    test "refuses a group that is no longer a draft" do
      scope = user_scope_fixture()
      group = group_fixture(scope)
      {:ok, cancelled} = Activities.cancel_group(scope, group)

      assert {:error, :pool_locked} = Activities.add_activity(scope, cancelled, %{name: "x"})
    end
  end

  # D-037. `votes.activity_id` cascades, so editing the pool after the vote opens
  # silently destroys ballots that have already been cast — and the ballot is locked
  # (D-036), so the voter cannot recast. Every pool write therefore refuses outside
  # `:draft`. These four assertions are the enforcement; the LiveViews only hide the
  # controls.
  describe "the pool is frozen once the vote opens" do
    setup do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: DateTime.add(DateTime.utc_now(), 3600)})
      {:ok, a} = Activities.add_activity(scope, group, %{name: "Guisados"})
      {:ok, b} = Activities.add_activity(scope, group, %{name: "Mozza"})
      {:ok, voting} = Activities.publish_group(scope, group)

      %{scope: scope, group: voting, a: a, b: b}
    end

    test "add_activity/3 refuses", %{scope: scope, group: group} do
      assert {:error, :pool_locked} = Activities.add_activity(scope, group, %{name: "Late"})
      assert Activities.count_activities(group) == 2
    end

    test "update_activity/3 refuses", %{scope: scope, a: a} do
      assert {:error, :pool_locked} = Activities.update_activity(scope, a, %{name: "Renamed"})
      assert Repo.get!(Activity, a.id).name == "Guisados"
    end

    test "delete_activity/2 refuses, which is what protects cast ballots", %{scope: scope, a: a} do
      assert {:error, :pool_locked} = Activities.delete_activity(scope, a)
      assert Repo.get(Activity, a.id)
    end

    test "reorder_activities/3 refuses", %{scope: scope, group: group, a: a, b: b} do
      assert {:error, :pool_locked} = Activities.reorder_activities(scope, group, [b.id, a.id])

      ordered =
        from(x in Activity,
          where: x.group_id == ^group.id,
          order_by: [asc: x.position],
          select: x.id
        )
        |> Repo.all()

      assert ordered == [a.id, b.id]
    end

    test "a completed group is frozen too", %{scope: scope, group: group, a: a} do
      {:ok, completed} = Activities.complete_group(scope, group)

      assert {:error, :pool_locked} = Activities.add_activity(scope, completed, %{name: "x"})
      assert {:error, :pool_locked} = Activities.delete_activity(scope, a)
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

  # The two endgame states the plan calls takeovers: a completed pool in which every
  # option was vetoed, and a completed pool whose survivors dead-heat at the top.
  # Resolution stamps an interpretation on the group; it never touches a vote row.
  defp all_vetoed_group(scope) do
    {group, activities} = voting_group_fixture(scope)

    for activity <- activities do
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [], activity.id)
    end

    {:ok, completed} = Activities.complete_group(scope, group)
    {completed, activities}
  end

  defp tied_group(scope) do
    {group, [a, b, c]} = voting_group_fixture(scope)
    {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id, b.id])
    {:ok, completed} = Activities.complete_group(scope, group)
    {completed, [a, b, c]}
  end

  defp group_votes(activities) do
    ids = Enum.map(activities, & &1.id)
    Repo.all(from(v in Vote, where: v.activity_id in ^ids))
  end

  describe "resolve_group/4" do
    test "breaks a tie for the organizer's chosen row, stamps all three columns and broadcasts" do
      scope = user_scope_fixture()
      {completed, [_a, b, _c]} = tied_group(scope)
      :ok = Activities.subscribe_group(completed.id)

      assert {:ok, resolved} = Activities.resolve_group(scope, completed, b.id, "organizer_pick")
      assert resolved.resolution == "organizer_pick"
      assert resolved.resolved_activity_id == b.id
      assert %DateTime{} = resolved.resolved_at
      assert_receive {:group_updated, ^resolved}

      assert Repo.get!(Group, completed.id).resolution == "organizer_pick"
    end

    test "accepts the activity id as a string, the way a client event delivers it" do
      scope = user_scope_fixture()
      {completed, [a | _]} = tied_group(scope)

      assert {:ok, resolved} =
               Activities.resolve_group(scope, completed, to_string(a.id), "app_pick")

      assert resolved.resolution == "app_pick"
      assert resolved.resolved_activity_id == a.id
    end

    test "refuses a second resolution, and writes nothing" do
      scope = user_scope_fixture()
      {completed, [a, b | _]} = tied_group(scope)
      {:ok, resolved} = Activities.resolve_group(scope, completed, a.id, "organizer_pick")

      assert {:error, :already_resolved} =
               Activities.resolve_group(scope, resolved, b.id, "organizer_pick")

      persisted = Repo.get!(Group, completed.id)
      assert persisted.resolved_activity_id == a.id
      assert persisted.resolution == "organizer_pick"
    end

    test "refuses a stale struct that predates a resolution committed in another tab" do
      scope = user_scope_fixture()
      {completed, [a, b | _]} = tied_group(scope)

      # Tab A resolves; tab B still holds the pre-resolve struct (resolution: nil)
      # — the window between that commit and PubSub delivery. The in-transaction
      # re-read, not the struct, must answer, or two tabs are last-write-wins.
      {:ok, _resolved} = Activities.resolve_group(scope, completed, a.id, "organizer_pick")
      assert completed.resolution == nil

      assert {:error, :already_resolved} =
               Activities.resolve_group(scope, completed, b.id, "app_pick")

      persisted = Repo.get!(Group, completed.id)
      assert persisted.resolution == "organizer_pick"
      assert persisted.resolved_activity_id == a.id
    end

    test "refuses a group that is not completed" do
      scope = user_scope_fixture()

      {voting, [a, b | _]} = voting_group_fixture(scope)
      {:ok, _} = Voting.cast_ballot(participant_fixture(voting), [a.id, b.id])
      assert {:error, :not_completed} = Activities.resolve_group(scope, voting, a.id, "app_pick")

      draft = group_fixture(scope)
      option = activity_fixture(draft)

      assert {:error, :not_completed} =
               Activities.resolve_group(scope, draft, option.id, "organizer_pick")
    end

    test "refuses an unknown resolution kind" do
      scope = user_scope_fixture()
      {completed, [a | _]} = tied_group(scope)

      assert {:error, :invalid_resolution} =
               Activities.resolve_group(scope, completed, a.id, "coin_flip")
    end

    test "refuses an activity outside the tied-at-top candidate set" do
      scope = user_scope_fixture()
      {completed, [_a, _b, c]} = tied_group(scope)

      # c survived but is not tied at the top.
      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, c.id, "organizer_pick")

      # A foreign group's activity, a deleted id, and garbage all land the same way.
      {_other, [foreign | _]} = voting_group_fixture(scope)

      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, foreign.id, "organizer_pick")

      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, -1, "app_pick")

      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, "12abc", "app_pick")

      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, nil, "organizer_pick")
    end

    test "refuses a tie pick on a group that is not actually tied" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id])
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id, b.id])
      {:ok, completed} = Activities.complete_group(scope, group)

      # a won outright; there is no tie for anyone to break — not even onto the winner.
      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, b.id, "organizer_pick")

      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, a.id, "organizer_pick")
    end

    test "refuses an app_rescue unless every option is vetoed" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [b.id], a.id)
      {:ok, completed} = Activities.complete_group(scope, group)

      # a is vetoed, but b survived with an approval — there is nothing to rescue.
      assert {:error, :not_a_candidate} =
               Activities.resolve_group(scope, completed, a.id, "app_rescue")
    end

    test "raises for someone else's group" do
      scope = user_scope_fixture()
      stranger = user_scope_fixture()
      {completed, [a | _]} = tied_group(scope)

      assert_raise FunctionClauseError, fn ->
        Activities.resolve_group(stranger, completed, a.id, "organizer_pick")
      end
    end
  end

  describe "rescue_group/2" do
    test "picks one of the vetoed options, records an app_rescue and broadcasts" do
      scope = user_scope_fixture()
      {completed, activities} = all_vetoed_group(scope)
      :ok = Activities.subscribe_group(completed.id)

      assert {:ok, rescued} = Activities.rescue_group(scope, completed)
      assert rescued.resolution == "app_rescue"
      assert rescued.resolved_activity_id in Enum.map(activities, & &1.id)
      assert %DateTime{} = rescued.resolved_at
      assert_receive {:group_updated, ^rescued}

      # The rescue is an interpretation: every vote row survives it.
      assert length(group_votes(activities)) == 3
    end

    test "refuses when the pool is not fully vetoed" do
      scope = user_scope_fixture()

      # A tie has nothing vetoed at all.
      {tied, _activities} = tied_group(scope)
      assert {:error, :not_a_candidate} = Activities.rescue_group(scope, tied)

      # A partial veto still has a survivor; there is nothing to rescue.
      {group, [a, b, _c]} = voting_group_fixture(scope)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [b.id], a.id)
      {:ok, completed} = Activities.complete_group(scope, group)
      assert {:error, :not_a_candidate} = Activities.rescue_group(scope, completed)
    end

    test "refuses while the vote is still open, even with everything vetoed" do
      scope = user_scope_fixture()
      {group, activities} = voting_group_fixture(scope)

      for activity <- activities do
        {:ok, _} = Voting.cast_ballot(participant_fixture(group), [], activity.id)
      end

      assert {:error, :not_completed} = Activities.rescue_group(scope, group)
    end

    test "refuses a group that was already rescued" do
      scope = user_scope_fixture()
      {completed, _activities} = all_vetoed_group(scope)
      {:ok, rescued} = Activities.rescue_group(scope, completed)

      assert {:error, :already_resolved} = Activities.rescue_group(scope, rescued)
    end

    test "raises for someone else's group" do
      scope = user_scope_fixture()
      stranger = user_scope_fixture()
      {completed, _activities} = all_vetoed_group(scope)

      assert_raise FunctionClauseError, fn ->
        Activities.rescue_group(stranger, completed)
      end
    end
  end

  describe "reopen_group/2" do
    test "reopens an all-vetoed group: votes gone, ballots unlocked, deadline cleared, participants and tokens survive" do
      scope = user_scope_fixture()
      {completed, activities} = all_vetoed_group(scope)

      before =
        Repo.all(
          from(p in Participant, where: p.group_id == ^completed.id, order_by: [asc: p.id])
        )

      assert length(before) == 3
      assert Enum.all?(before, & &1.voted_at)

      :ok = Activities.subscribe_group(completed.id)

      assert {:ok, reopened} = Activities.reopen_group(scope, completed)
      assert reopened.status == :draft
      assert reopened.deadline_at == nil
      assert reopened.completed_at == nil
      assert reopened.resolution == nil
      assert reopened.resolved_activity_id == nil
      assert reopened.resolved_at == nil
      assert_receive {:group_updated, ^reopened}

      # Round 1's votes are gone by design — its outcome was "everything vetoed".
      assert group_votes(activities) == []

      # The participants and their tokens survive: the share link keeps working and
      # nobody re-enters a name. Every ballot is unlocked.
      after_reopen =
        Repo.all(
          from(p in Participant, where: p.group_id == ^completed.id, order_by: [asc: p.id])
        )

      assert Enum.map(after_reopen, & &1.id) == Enum.map(before, & &1.id)
      assert Enum.map(after_reopen, & &1.token) == Enum.map(before, & &1.token)
      assert Enum.all?(after_reopen, &is_nil(&1.voted_at))
    end

    test "leaves another group's votes and participants alone" do
      scope = user_scope_fixture()
      {completed, _activities} = all_vetoed_group(scope)

      {other, [x | _]} = voting_group_fixture(scope)
      bystander = participant_fixture(other)
      {:ok, _} = Voting.cast_ballot(bystander, [x.id])

      assert {:ok, _reopened} = Activities.reopen_group(scope, completed)

      assert [%Vote{}] = Repo.all(from(v in Vote, where: v.activity_id == ^x.id))
      assert Repo.get!(Participant, bystander.id).voted_at
    end

    test "the reopened pool is editable again, and publishing needs a fresh deadline" do
      scope = user_scope_fixture()
      {completed, _activities} = all_vetoed_group(scope)
      {:ok, reopened} = Activities.reopen_group(scope, completed)

      assert {:ok, _added} = Activities.add_activity(scope, reopened, %{name: "Round 2"})
      assert {:error, :no_deadline} = Activities.publish_group(scope, reopened)
    end

    test "refuses a group that is not completed" do
      scope = user_scope_fixture()
      {voting, _activities} = voting_group_fixture(scope)

      assert {:error, :not_completed} = Activities.reopen_group(scope, voting)
      assert {:error, :not_completed} = Activities.reopen_group(scope, group_fixture(scope))
    end

    test "refuses a completed group that is not fully vetoed" do
      scope = user_scope_fixture()

      # A dead heat is the tie takeover's case, not this exit's.
      {tied, _activities} = tied_group(scope)
      assert {:error, :not_all_vetoed} = Activities.reopen_group(scope, tied)

      # An untouched pool completed without a single ballot.
      {group, _activities} = voting_group_fixture(scope)
      {:ok, untouched} = Activities.complete_group(scope, group)
      assert {:error, :not_all_vetoed} = Activities.reopen_group(scope, untouched)
    end

    test "refuses a rescued group — its result is already declared" do
      scope = user_scope_fixture()
      {completed, _activities} = all_vetoed_group(scope)
      {:ok, rescued} = Activities.rescue_group(scope, completed)

      assert {:error, :already_resolved} = Activities.reopen_group(scope, rescued)
    end

    test "refuses a stale struct that predates a rescue committed in another tab, deleting nothing" do
      scope = user_scope_fixture()
      {completed, activities} = all_vetoed_group(scope)

      # Tab A rescues; tab B still holds the pre-rescue struct (resolution: nil) —
      # the window between that commit and PubSub delivery. Guarding on the stale
      # struct once let this reopen "succeed": votes deleted, status :draft, and
      # the "app_rescue" stamp left in place, silently pre-deciding round 2.
      {:ok, rescued} = Activities.rescue_group(scope, completed)
      assert completed.resolution == nil

      assert {:error, :already_resolved} = Activities.reopen_group(scope, completed)

      # The declared result stands whole: still completed, still stamped, every
      # vote row and every locked ballot intact.
      persisted = Repo.get!(Group, completed.id)
      assert persisted.status == :completed
      assert persisted.resolution == "app_rescue"
      assert persisted.resolved_activity_id == rescued.resolved_activity_id
      assert length(group_votes(activities)) == 3

      participants = Repo.all(from(p in Participant, where: p.group_id == ^completed.id))
      assert Enum.all?(participants, & &1.voted_at)
    end

    test "refuses a stale struct whose group was already reopened in another tab" do
      scope = user_scope_fixture()
      {completed, _activities} = all_vetoed_group(scope)
      {:ok, _reopened} = Activities.reopen_group(scope, completed)

      # The stale struct still reads :completed; the in-transaction re-read sees
      # the :draft the first reopen left behind.
      assert {:error, :not_completed} = Activities.reopen_group(scope, completed)
      assert Repo.get!(Group, completed.id).status == :draft
    end

    test "Group.reopen_changeset/1 forces every clear, even when the struct already reads cleared" do
      # change/2 drops a change equal to the struct's current value, so a stale
      # struct still reading nil for a column the database has since set would
      # silently keep that column. The changeset must emit all six writes
      # unconditionally — it cannot know how fresh its struct is.
      changeset = Group.reopen_changeset(%Group{status: :draft, resolution: nil})

      assert changeset.changes == %{
               status: :draft,
               completed_at: nil,
               deadline_at: nil,
               resolution: nil,
               resolved_activity_id: nil,
               resolved_at: nil
             }
    end

    test "raises for someone else's group" do
      scope = user_scope_fixture()
      stranger = user_scope_fixture()
      {completed, _activities} = all_vetoed_group(scope)

      assert_raise FunctionClauseError, fn ->
        Activities.reopen_group(stranger, completed)
      end
    end
  end
end
