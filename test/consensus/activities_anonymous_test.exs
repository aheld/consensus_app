defmodule Consensus.ActivitiesAnonymousTest do
  # `async: false` for one test only: the busy-claim case creates a TEMP TRIGGER, and a
  # test that issues DDL must not share a file lock with another connection (see the
  # elixir skill's `async:` table). Everything else here would be fine async; under
  # `max_cases: 1` (D-033) the flag costs nothing either way.
  use Consensus.DataCase, async: false

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Accounts.{Scope, User}
  alias Consensus.Activities
  alias Consensus.Activities.{Activity, AnonymousOrganizer, Group}
  alias Consensus.Repo
  alias Consensus.Voting

  # Written from docs/plans/accountless-organizer.md §3.1–3.3, §4.6 and §6.3 (D-058) —
  # deliberately not from `lib/consensus/activities.ex`. Where a cross-owner call is
  # specified to raise `FunctionClauseError`, **the raise is the assertion**: a returned
  # error tuple from one of these means an ownership head became a runtime branch.

  @group_taking [
    :change_group,
    :update_group,
    :set_search_area,
    :publish_group,
    :cancel_group,
    :complete_group,
    :resolve_group,
    :rescue_group,
    :reopen_group,
    :add_activity,
    :reorder_activities
  ]

  # One call per group-taking function, with arguments that would be accepted for a
  # draft group of the caller's own. The attrs are irrelevant to the ownership heads.
  defp call(:change_group, scope, group), do: Activities.change_group(scope, group, %{})
  defp call(:update_group, scope, group), do: Activities.update_group(scope, group, %{title: "X"})

  defp call(:set_search_area, scope, group),
    do: Activities.set_search_area(scope, group, %{search_area: "Fishtown"})

  defp call(:publish_group, scope, group), do: Activities.publish_group(scope, group)
  defp call(:cancel_group, scope, group), do: Activities.cancel_group(scope, group)
  defp call(:complete_group, scope, group), do: Activities.complete_group(scope, group)

  defp call(:resolve_group, scope, group),
    do: Activities.resolve_group(scope, group, 1, "organizer_pick")

  defp call(:rescue_group, scope, group), do: Activities.rescue_group(scope, group)
  defp call(:reopen_group, scope, group), do: Activities.reopen_group(scope, group)

  defp call(:add_activity, scope, group),
    do: Activities.add_activity(scope, group, %{name: "Zahav"})

  defp call(:reorder_activities, scope, group),
    do: Activities.reorder_activities(scope, group, [])

  # Plan §4.6 leaves the sweep's name and return shape to the implementation; this is
  # the one line to change if it is not `sweep_anonymous_organizers(now)`.
  defp sweep(now) do
    case Activities.sweep_anonymous_organizers(now) do
      {:ok, count} -> count
      count when is_integer(count) -> count
    end
  end

  defp ago(amount, unit), do: DateTime.add(DateTime.utc_now(:second), -amount, unit)

  defp both_set_scope do
    {_raw_token, organizer} = anonymous_organizer_fixture()
    %Scope{user: user_fixture(), anonymous_organizer: organizer}
  end

  defp unsaved_user_scope, do: %Scope{user: %User{id: nil}}
  defp unsaved_anonymous_scope, do: %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{}}

  # Three owners, one draft group each: two organizers with no account and one account.
  #
  # The two malformed scopes ride in the context too. Passed as literals straight into
  # the local `call/3`, Elixir 1.20's type checker proves they match none of its clauses'
  # inferred types and warns at every generated test — which is the very property under
  # test. Through the context they are `dynamic()`, and the raise is left to the runtime.
  defp three_owners(_context) do
    {anon_scope, anon_group} = anonymous_group_fixture()
    {other_anon_scope, other_anon_group} = anonymous_group_fixture()
    user_scope = user_scope_fixture()
    user_group = group_fixture(user_scope)

    %{
      anon_scope: anon_scope,
      anon_group: anon_group,
      other_anon_scope: other_anon_scope,
      other_anon_group: other_anon_group,
      user_scope: user_scope,
      user_group: user_group,
      both_set_scope: both_set_scope(),
      # Both identities are real owners here — the user of `user_group`, the anonymous
      # organizer of `anon_group` — so without its nil pin one head WOULD match. A
      # both-set scope of strangers (`both_set_scope/0`) can never catch that: neither
      # owner id equals either group's owner column, pinned or not.
      both_with_real_owners: %Scope{
        user: user_scope.user,
        anonymous_organizer: anon_scope.anonymous_organizer
      },
      unsaved_user_scope: unsaved_user_scope(),
      unsaved_anonymous_scope: unsaved_anonymous_scope()
    }
  end

  # The endgame states, as `activities_test.exs` builds them, for an anonymous owner.
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

  describe "an organizer with no account, on their own group" do
    setup :three_owners

    test "create_group/2 sets anonymous_organizer_id and leaves organizer_id nil", ctx do
      assert {:ok, group} = Activities.create_group(ctx.anon_scope, %{title: "Dinner"})
      assert group.anonymous_organizer_id == ctx.anon_scope.anonymous_organizer.id
      assert group.organizer_id == nil
    end

    test "new_group/1 returns an unsaved group owned by the scope, of either kind", ctx do
      assert %Group{id: nil, organizer_id: nil, anonymous_organizer_id: anon_id} =
               Activities.new_group(ctx.anon_scope)

      assert anon_id == ctx.anon_scope.anonymous_organizer.id

      assert %Group{id: nil, organizer_id: user_id, anonymous_organizer_id: nil} =
               Activities.new_group(ctx.user_scope)

      assert user_id == ctx.user_scope.user.id
    end

    test "list_groups/1 returns only that organizer's groups", ctx do
      assert [%Group{id: id}] = Activities.list_groups(ctx.anon_scope)
      assert id == ctx.anon_group.id

      assert [%Group{id: other_id}] = Activities.list_groups(ctx.other_anon_scope)
      assert other_id == ctx.other_anon_group.id

      assert [%Group{id: user_group_id}] = Activities.list_groups(ctx.user_scope)
      assert user_group_id == ctx.user_group.id
    end

    test "get_group!/2 returns it", ctx do
      assert %Group{id: id} = Activities.get_group!(ctx.anon_scope, ctx.anon_group.id)
      assert id == ctx.anon_group.id
    end

    test "change_group/3 returns a changeset", ctx do
      assert %Ecto.Changeset{} = Activities.change_group(ctx.anon_scope, ctx.anon_group, %{})
    end

    test "update_group/3 writes", ctx do
      assert {:ok, %Group{title: "Renamed"}} =
               Activities.update_group(ctx.anon_scope, ctx.anon_group, %{title: "Renamed"})
    end

    test "set_search_area/3 writes", ctx do
      assert {:ok, %Group{search_area: "Fishtown"}} =
               Activities.set_search_area(ctx.anon_scope, ctx.anon_group, %{
                 search_area: "Fishtown"
               })
    end

    test "add_activity/3 writes, and leaves added_by_id nil", ctx do
      assert {:ok, %Activity{} = activity} =
               Activities.add_activity(ctx.anon_scope, ctx.anon_group, %{name: "Zahav"})

      # `activities.added_by_id` references `users`; there is no user (plan §3.3.1).
      assert activity.added_by_id == nil
      assert Repo.get!(Activity, activity.id).added_by_id == nil
    end

    test "update_activity/3 and delete_activity/2 write", ctx do
      activity = activity_fixture(ctx.anon_group)

      assert {:ok, %Activity{name: "Renamed"}} =
               Activities.update_activity(ctx.anon_scope, activity, %{name: "Renamed"})

      assert {:ok, _} = Activities.delete_activity(ctx.anon_scope, activity)
      refute Repo.get(Activity, activity.id)
    end

    test "reorder_activities/3 writes", ctx do
      a = activity_fixture(ctx.anon_group)
      b = activity_fixture(ctx.anon_group)

      assert {:ok, [%Activity{id: first}, %Activity{id: second}]} =
               Activities.reorder_activities(ctx.anon_scope, ctx.anon_group, [b.id, a.id])

      assert {first, second} == {b.id, a.id}
    end

    test "publish_group/2, complete_group/2 and cancel_group/2 transition it", ctx do
      {group, _activities} = voting_group_fixture(ctx.anon_scope)
      assert group.status == :voting

      assert {:ok, %Group{status: :completed}} = Activities.complete_group(ctx.anon_scope, group)

      assert {:ok, %Group{status: :cancelled}} =
               Activities.cancel_group(ctx.anon_scope, ctx.anon_group)
    end

    test "resolve_group/4 breaks a tie", ctx do
      {completed, [a | _]} = tied_group(ctx.anon_scope)

      assert {:ok, %Group{resolution: "organizer_pick", resolved_activity_id: resolved_id}} =
               Activities.resolve_group(ctx.anon_scope, completed, a.id, "organizer_pick")

      assert resolved_id == a.id
    end

    test "rescue_group/2 rescues an all-vetoed pool", ctx do
      {completed, _activities} = all_vetoed_group(ctx.anon_scope)

      assert {:ok, %Group{resolution: "app_rescue"}} =
               Activities.rescue_group(ctx.anon_scope, completed)
    end

    test "reopen_group/2 reopens an all-vetoed pool", ctx do
      {completed, _activities} = all_vetoed_group(ctx.anon_scope)

      assert {:ok, %Group{status: :draft}} = Activities.reopen_group(ctx.anon_scope, completed)
    end
  end

  describe "cross-owner calls on the eleven group-taking functions" do
    setup :three_owners

    for fun <- @group_taking do
      test "#{fun} raises FunctionClauseError for every foreign owner, both directions", ctx do
        fun = unquote(fun)

        # Another organizer with no account.
        assert_raise FunctionClauseError, fn ->
          call(fun, ctx.anon_scope, ctx.other_anon_group)
        end

        # An organizer with no account on an account holder's group…
        assert_raise FunctionClauseError, fn -> call(fun, ctx.anon_scope, ctx.user_group) end

        # …and the reverse.
        assert_raise FunctionClauseError, fn -> call(fun, ctx.user_scope, ctx.anon_group) end
      end

      test "#{fun} raises FunctionClauseError for a both-set or unsaved-id scope", ctx do
        fun = unquote(fun)

        # A both-set scope matches neither head, whichever owner the group has.
        assert_raise FunctionClauseError, fn -> call(fun, ctx.both_set_scope, ctx.anon_group) end
        assert_raise FunctionClauseError, fn -> call(fun, ctx.both_set_scope, ctx.user_group) end

        # …including when each identity in it owns one of the two groups, which is the
        # case the `user: nil` / `anonymous_organizer: nil` pins exist for (plan §3.2).
        assert_raise FunctionClauseError, fn ->
          call(fun, ctx.both_with_real_owners, ctx.anon_group)
        end

        assert_raise FunctionClauseError, fn ->
          call(fun, ctx.both_with_real_owners, ctx.user_group)
        end

        # `id: nil` must not match the other kind's `nil` owner column (the
        # `is_integer(id)` guard, plan §3.2).
        assert_raise FunctionClauseError, fn ->
          call(fun, ctx.unsaved_anonymous_scope, ctx.user_group)
        end

        assert_raise FunctionClauseError, fn ->
          call(fun, ctx.unsaved_user_scope, ctx.anon_group)
        end
      end
    end

    test "nothing was written by any of the refused calls", ctx do
      for fun <- @group_taking, group <- [ctx.other_anon_group, ctx.user_group] do
        try do
          call(fun, ctx.anon_scope, group)
        rescue
          FunctionClauseError -> :ok
        end
      end

      for group <- [ctx.other_anon_group, ctx.user_group] do
        persisted = Repo.get!(Group, group.id)
        assert persisted.status == :draft
        assert persisted.title == group.title
        assert persisted.search_area == nil
        assert Activities.count_activities(group) == 0
      end
    end
  end

  describe "get_group!/2 across owners" do
    setup :three_owners

    test "raises Ecto.NoResultsError for every foreign owner, both directions", ctx do
      assert_raise Ecto.NoResultsError, fn ->
        Activities.get_group!(ctx.anon_scope, ctx.other_anon_group.id)
      end

      assert_raise Ecto.NoResultsError, fn ->
        Activities.get_group!(ctx.anon_scope, ctx.user_group.id)
      end

      assert_raise Ecto.NoResultsError, fn ->
        Activities.get_group!(ctx.user_scope, ctx.anon_group.id)
      end
    end

    test "raises FunctionClauseError for a both-set scope", ctx do
      both = both_set_scope()

      assert_raise FunctionClauseError, fn -> Activities.get_group!(both, ctx.anon_group.id) end
      assert_raise FunctionClauseError, fn -> Activities.get_group!(both, ctx.user_group.id) end
    end

    # Plan §3.2: "raises FunctionClauseError (or, for get_group!, finds nothing)".
    test "an unsaved-id scope never reaches the other kind's group", ctx do
      for {scope, group} <- [
            {unsaved_anonymous_scope(), ctx.user_group},
            {unsaved_user_scope(), ctx.anon_group}
          ] do
        try do
          Activities.get_group!(scope, group.id)
          flunk("get_group!/2 returned a group for an unsaved-id scope")
        rescue
          e in [FunctionClauseError, Ecto.NoResultsError] -> assert e
        end
      end
    end
  end

  describe "update_activity/3 and delete_activity/2 across owners" do
    setup :three_owners

    test "answer {:error, :unauthorized} for every foreign owner, both directions", ctx do
      other_anon_activity = activity_fixture(ctx.other_anon_group)
      user_activity = activity_fixture(ctx.user_group)
      anon_activity = activity_fixture(ctx.anon_group)

      for {scope, activity} <- [
            {ctx.anon_scope, other_anon_activity},
            {ctx.anon_scope, user_activity},
            {ctx.user_scope, anon_activity}
          ] do
        assert {:error, :unauthorized} =
                 Activities.update_activity(scope, activity, %{name: "Hijacked"})

        assert {:error, :unauthorized} = Activities.delete_activity(scope, activity)
        assert Repo.get!(Activity, activity.id).name == activity.name
      end
    end

    test "raise FunctionClauseError for a both-set or unsaved-id scope", ctx do
      both = both_set_scope()
      anon_activity = activity_fixture(ctx.anon_group)
      user_activity = activity_fixture(ctx.user_group)

      for {scope, activity} <- [
            {both, anon_activity},
            {both, user_activity},
            {unsaved_anonymous_scope(), user_activity},
            {unsaved_user_scope(), anon_activity}
          ] do
        assert_raise FunctionClauseError, fn ->
          Activities.update_activity(scope, activity, %{name: "Hijacked"})
        end

        assert_raise FunctionClauseError, fn -> Activities.delete_activity(scope, activity) end
      end
    end
  end

  describe "update_activity_details/3 and adopt_lookup_result/3 (D-060)" do
    setup :three_owners

    @details %{phone: "+1-215-625-8800", address: "237 Saint James Place, Philadelphia"}

    test "both kinds of owner write their own option's details", ctx do
      for group <- [ctx.anon_group, ctx.user_group] do
        scope = if group.id == ctx.anon_group.id, do: ctx.anon_scope, else: ctx.user_scope
        activity = activity_fixture(group)

        assert {:ok, updated} = Activities.update_activity_details(scope, activity, @details)
        assert updated.phone == "+1-215-625-8800"

        assert {:ok, adopted} =
                 Activities.adopt_lookup_result(scope, activity, %{
                   name: "Zahav",
                   category: "israeli",
                   osm_ref: "node/6374481270"
                 })

        assert {adopted.name, adopted.category, adopted.osm_ref} ==
                 {"Zahav", "israeli", "node/6374481270"}
      end
    end

    test "answer {:error, :unauthorized} for every foreign owner, both directions", ctx do
      other_anon_activity = activity_fixture(ctx.other_anon_group)
      user_activity = activity_fixture(ctx.user_group)
      anon_activity = activity_fixture(ctx.anon_group)

      for {scope, activity} <- [
            {ctx.anon_scope, other_anon_activity},
            {ctx.anon_scope, user_activity},
            {ctx.user_scope, anon_activity}
          ] do
        assert {:error, :unauthorized} =
                 Activities.update_activity_details(scope, activity, @details)

        assert {:error, :unauthorized} =
                 Activities.adopt_lookup_result(scope, activity, %{name: "Hijacked"})

        stored = Repo.get!(Activity, activity.id)
        assert {stored.name, stored.phone} == {activity.name, nil}
      end
    end

    test "raise FunctionClauseError for a both-set or unsaved-id scope", ctx do
      anon_activity = activity_fixture(ctx.anon_group)
      user_activity = activity_fixture(ctx.user_group)

      for {scope, activity} <- [
            {both_set_scope(), anon_activity},
            {both_set_scope(), user_activity},
            {unsaved_anonymous_scope(), user_activity},
            {unsaved_user_scope(), anon_activity}
          ] do
        assert_raise FunctionClauseError, fn ->
          Activities.update_activity_details(scope, activity, @details)
        end

        assert_raise FunctionClauseError, fn ->
          Activities.adopt_lookup_result(scope, activity, %{name: "Hijacked"})
        end
      end
    end

    test "details stay editable while voting and once completed; not once cancelled" do
      scope = anonymous_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)

      assert {:ok, %Activity{phone: "+1-215-625-8800"}} =
               Activities.update_activity_details(scope, a, @details)

      # Renaming is still frozen, through either door.
      assert {:error, :pool_locked} = Activities.adopt_lookup_result(scope, a, %{name: "X"})

      {:ok, completed} = Activities.complete_group(scope, group)
      assert completed.status == :completed

      assert {:ok, %Activity{category: "israeli"}} =
               Activities.update_activity_details(scope, b, %{category: "israeli"})

      {cancel_scope, cancel_group} = anonymous_group_fixture()
      cancel_activity = activity_fixture(cancel_group)
      {:ok, _cancelled} = Activities.cancel_group(cancel_scope, cancel_group)

      assert {:error, :group_closed} =
               Activities.update_activity_details(cancel_scope, cancel_activity, @details)
    end

    test "a details write broadcasts {:activity_updated, activity}", ctx do
      activity = activity_fixture(ctx.anon_group)
      Activities.subscribe_group(ctx.anon_group.id)

      {:ok, updated} = Activities.update_activity_details(ctx.anon_scope, activity, @details)

      assert_receive {:activity_updated, ^updated}
    end

    test "a details write cannot rename, and an invalid phone saves nothing", ctx do
      activity = activity_fixture(ctx.anon_group)

      assert {:ok, updated} =
               Activities.update_activity_details(ctx.anon_scope, activity, %{
                 name: "Renamed",
                 osm_ref: "node/1",
                 category: "israeli"
               })

      assert {updated.name, updated.osm_ref} == {activity.name, nil}

      assert {:error, %Ecto.Changeset{}} =
               Activities.update_activity_details(ctx.anon_scope, activity, %{phone: "call us"})

      assert Repo.get!(Activity, activity.id).phone == nil
    end
  end

  describe "list_groups/1, create_group/2 and new_group/1 with a malformed scope" do
    test "a both-set scope raises FunctionClauseError" do
      both = both_set_scope()

      assert_raise FunctionClauseError, fn -> Activities.list_groups(both) end
      assert_raise FunctionClauseError, fn -> Activities.create_group(both, %{title: "X"}) end
      assert_raise FunctionClauseError, fn -> Activities.new_group(both) end
    end

    test "an unsaved-id scope raises FunctionClauseError" do
      for scope <- [unsaved_anonymous_scope(), unsaved_user_scope()] do
        assert_raise FunctionClauseError, fn -> Activities.list_groups(scope) end
        assert_raise FunctionClauseError, fn -> Activities.create_group(scope, %{title: "X"}) end
        assert_raise FunctionClauseError, fn -> Activities.new_group(scope) end
      end
    end

    test "nothing was inserted by a refused create" do
      before = Repo.aggregate(Group, :count)

      for scope <- [both_set_scope(), unsaved_anonymous_scope(), unsaved_user_scope()] do
        try do
          Activities.create_group(scope, %{title: "X"})
        rescue
          FunctionClauseError -> :ok
        end
      end

      assert Repo.aggregate(Group, :count) == before
    end
  end

  describe "the pool is frozen once the vote opens, for an anonymous owner too" do
    test "every pool write answers {:error, :pool_locked}" do
      scope = anonymous_scope_fixture()
      {group, [a, b, c]} = voting_group_fixture(scope)

      assert {:error, :pool_locked} = Activities.add_activity(scope, group, %{name: "Late"})
      assert {:error, :pool_locked} = Activities.update_activity(scope, a, %{name: "Renamed"})
      assert {:error, :pool_locked} = Activities.delete_activity(scope, a)

      assert {:error, :pool_locked} =
               Activities.reorder_activities(scope, group, [c.id, b.id, a.id])

      assert {:error, :pool_locked} =
               Activities.set_search_area(scope, group, %{search_area: "Fishtown"})

      assert Activities.count_activities(group) == 3
      assert Repo.get!(Activity, a.id).name == a.name
    end
  end

  describe "update_organizer_display_name/2" do
    test "persists the name" do
      scope = anonymous_scope_fixture()

      assert {:ok, %AnonymousOrganizer{display_name: "Aaron"}} =
               Activities.update_organizer_display_name(scope, %{display_name: "  Aaron  "})

      assert Repo.get!(AnonymousOrganizer, scope.anonymous_organizer.id).display_name ==
               "Aaron"
    end

    test "stores a blank name as nil" do
      scope = anonymous_scope_fixture(display_name: "Aaron")

      assert {:ok, %AnonymousOrganizer{display_name: nil}} =
               Activities.update_organizer_display_name(scope, %{display_name: "   "})

      assert Repo.get!(AnonymousOrganizer, scope.anonymous_organizer.id).display_name == nil
    end

    # Two tabs, one identity (plan §8): tab A still holds the struct it mounted with.
    test "writes through a stale scope whose value matches what is being set" do
      # Mounted with display_name nil; the update below does not touch this struct.
      stale = anonymous_scope_fixture()

      assert {:ok, _} = Activities.update_organizer_display_name(stale, %{display_name: "Bob"})
      assert stale.anonymous_organizer.display_name == nil

      assert {:ok, %AnonymousOrganizer{display_name: nil}} =
               Activities.update_organizer_display_name(stale, %{display_name: ""})

      assert Repo.get!(AnonymousOrganizer, stale.anonymous_organizer.id).display_name == nil
    end

    test "answers :not_found once the organizer's row is gone" do
      scope = anonymous_scope_fixture()
      Repo.delete!(scope.anonymous_organizer)

      assert {:error, :not_found} =
               Activities.update_organizer_display_name(scope, %{display_name: "Bob"})
    end

    test "refuses a name over the cap and writes nothing" do
      scope = anonymous_scope_fixture(display_name: "Aaron")
      too_long = String.duplicate("a", AnonymousOrganizer.max_display_name_length() + 1)

      assert {:error, %Ecto.Changeset{}} =
               Activities.update_organizer_display_name(scope, %{display_name: too_long})

      assert Repo.get!(AnonymousOrganizer, scope.anonymous_organizer.id).display_name ==
               "Aaron"
    end

    test "refuses an account holder's scope — an account's name is its username" do
      assert_raise FunctionClauseError, fn ->
        Activities.update_organizer_display_name(user_scope_fixture(), %{display_name: "X"})
      end
    end
  end

  # Plan §7.3: `01 setup` saves the group and the name "in the same transaction".
  describe "create_group_with_organizer_name/3 and update_group_with_organizer_name/4" do
    defp group_attrs(attrs \\ %{}),
      do: Map.merge(%{title: "Dinner", deadline_at: future_deadline()}, attrs)

    test "creates the group and sets the name together" do
      scope = anonymous_scope_fixture()

      assert {:ok, %Group{} = group} =
               Activities.create_group_with_organizer_name(scope, group_attrs(), %{
                 display_name: " Sam "
               })

      assert group.anonymous_organizer_id == scope.anonymous_organizer.id
      assert Repo.get!(AnonymousOrganizer, scope.anonymous_organizer.id).display_name == "Sam"
    end

    test "a refused name rolls the new group back with it" do
      scope = anonymous_scope_fixture()
      too_long = String.duplicate("a", AnonymousOrganizer.max_display_name_length() + 1)

      assert {:error, {:organizer_name, %Ecto.Changeset{valid?: false}}} =
               Activities.create_group_with_organizer_name(scope, group_attrs(), %{
                 display_name: too_long
               })

      assert Activities.list_groups(scope) == []
    end

    test "a refused group comes back as the group's own changeset, and names nothing" do
      scope = anonymous_scope_fixture()

      assert {:error, %Ecto.Changeset{data: %Group{}} = changeset} =
               Activities.create_group_with_organizer_name(scope, %{title: ""}, %{
                 display_name: "Sam"
               })

      assert %{title: _} = errors_on(changeset)
      assert Repo.get!(AnonymousOrganizer, scope.anonymous_organizer.id).display_name == nil
    end

    # Forced the same way as the busy claim below: a TEMP trigger aborts the name's
    # UPDATE after the group's INSERT has already run inside the transaction.
    test "a database failure on the name write leaves no group behind" do
      scope = anonymous_scope_fixture()

      Repo.query!("""
      CREATE TEMP TRIGGER d058_name_write_fails BEFORE UPDATE ON anonymous_organizers
      BEGIN SELECT RAISE(ABORT, 'database is locked'); END
      """)

      assert_raise Exqlite.Error, fn ->
        Activities.create_group_with_organizer_name(scope, group_attrs(), %{display_name: "Sam"})
      end

      Repo.query!("DROP TRIGGER d058_name_write_fails")

      assert Activities.list_groups(scope) == []
    end

    test "updates both, and broadcasts the group only once committed" do
      scope = anonymous_scope_fixture()
      group = group_fixture(scope, title: "Old")
      Activities.subscribe_group(group.id)

      assert {:ok, %Group{title: "New"}} =
               Activities.update_group_with_organizer_name(scope, group, %{title: "New"}, %{
                 display_name: "Sam"
               })

      assert_receive {:group_updated, %Group{title: "New"}}
      assert Repo.get!(AnonymousOrganizer, scope.anonymous_organizer.id).display_name == "Sam"
    end

    test "a refused name on update rolls the group back and broadcasts nothing" do
      scope = anonymous_scope_fixture()
      group = group_fixture(scope, title: "Old")
      Activities.subscribe_group(group.id)
      too_long = String.duplicate("a", AnonymousOrganizer.max_display_name_length() + 1)

      assert {:error, {:organizer_name, %Ecto.Changeset{}}} =
               Activities.update_group_with_organizer_name(scope, group, %{title: "New"}, %{
                 display_name: too_long
               })

      assert Repo.get!(Group, group.id).title == "Old"
      refute_receive {:group_updated, _}
    end

    test "have no head for an account holder, or for another owner's group" do
      user_scope = user_scope_fixture()
      user_group = group_fixture(user_scope)
      {_other_scope, other_group} = anonymous_group_fixture()
      scope = anonymous_scope_fixture()

      assert_raise FunctionClauseError, fn ->
        Activities.create_group_with_organizer_name(user_scope, group_attrs(), %{})
      end

      assert_raise FunctionClauseError, fn ->
        Activities.update_group_with_organizer_name(user_scope, user_group, %{}, %{})
      end

      assert_raise FunctionClauseError, fn ->
        Activities.update_group_with_organizer_name(scope, other_group, %{}, %{})
      end
    end
  end

  describe "organizer_custom_name/1" do
    # Read through `get_group_by_slug/1` and `get_group!/2`, which plan §3.3.4 says
    # preload both owners — that is the struct every screen holds.

    test "is the username for an account holder's group" do
      scope = user_scope_fixture()
      group = group_fixture(scope)

      assert Activities.organizer_custom_name(Activities.get_group_by_slug(group.slug)) ==
               scope.user.username

      assert Activities.organizer_custom_name(Activities.get_group!(scope, group.id)) ==
               scope.user.username
    end

    test "is the display name for a named organizer with no account" do
      {scope, group} = anonymous_group_fixture()
      {:ok, _} = Activities.update_organizer_display_name(scope, %{display_name: "Aaron"})

      assert Activities.organizer_custom_name(Activities.get_group_by_slug(group.slug)) ==
               "Aaron"

      assert Activities.organizer_custom_name(Activities.get_group!(scope, group.id)) ==
               "Aaron"
    end

    test "is nil for an unnamed organizer with no account — casing is the web layer's" do
      {_scope, group} = anonymous_group_fixture()

      assert Activities.organizer_custom_name(Activities.get_group_by_slug(group.slug)) == nil
    end

    test "is retroactive across that organizer's sessions (D-058)" do
      {scope, first} = anonymous_group_fixture()
      second = group_fixture(scope)
      {:ok, _} = Activities.update_organizer_display_name(scope, %{display_name: "Aaron"})

      for group <- [first, second] do
        assert Activities.organizer_custom_name(Activities.get_group_by_slug(group.slug)) ==
                 "Aaron"
      end
    end
  end

  describe "mint_anonymous_organizer/0" do
    test "returns a raw token and stores only its SHA-256 digest" do
      {raw_token, %AnonymousOrganizer{id: id}} = Activities.mint_anonymous_organizer()

      assert is_binary(raw_token)
      assert is_integer(id)

      stored = Repo.get!(AnonymousOrganizer, id)
      assert stored.token_hash == :crypto.hash(:sha256, raw_token)
      refute stored.token_hash == raw_token
      assert stored.claimed_at == nil
      assert %DateTime{} = stored.last_seen_at

      # The raw token is in no column of the row, read past the schema.
      %{rows: [row]} = Repo.query!("SELECT * FROM anonymous_organizers WHERE id = ?", [id])
      refute raw_token in row
    end

    test "mints a different token every time" do
      {first, _} = Activities.mint_anonymous_organizer()
      {second, _} = Activities.mint_anonymous_organizer()

      refute first == second
    end
  end

  describe "get_anonymous_organizer_by_token/1" do
    test "resolves a freshly minted token" do
      {raw_token, %AnonymousOrganizer{id: id}} = anonymous_organizer_fixture()

      assert %AnonymousOrganizer{id: ^id} = Activities.get_anonymous_organizer_by_token(raw_token)
    end

    test "is nil for an unknown token" do
      _ = anonymous_organizer_fixture()

      assert Activities.get_anonymous_organizer_by_token(:crypto.strong_rand_bytes(32)) == nil
    end

    test "is nil for a claimed row" do
      user = user_fixture()

      {raw_token, _} =
        anonymous_organizer_fixture(claimed_at: ago(1, :hour), claimed_by_user_id: user.id)

      assert Activities.get_anonymous_organizer_by_token(raw_token) == nil
    end

    test "is nil for a claimed row whose claiming account was deleted" do
      # `claimed_by_user_id` is `:nilify_all`; "claimed" is keyed on `claimed_at`.
      {raw_token, _} = anonymous_organizer_fixture(claimed_at: ago(1, :hour))

      assert Activities.get_anonymous_organizer_by_token(raw_token) == nil
    end

    test "is nil for a row idle longer than 90 days" do
      {raw_token, _} = anonymous_organizer_fixture(last_seen_at: ago(91, :day))

      assert Activities.get_anonymous_organizer_by_token(raw_token) == nil
    end

    test "bumps last_seen_at on a hit older than 24 hours" do
      stale = ago(25, :hour)
      {raw_token, %AnonymousOrganizer{id: id}} = anonymous_organizer_fixture(last_seen_at: stale)

      assert %AnonymousOrganizer{id: ^id} = Activities.get_anonymous_organizer_by_token(raw_token)

      bumped = Repo.get!(AnonymousOrganizer, id).last_seen_at
      assert DateTime.compare(bumped, stale) == :gt
      assert DateTime.diff(DateTime.utc_now(), bumped, :second) < 60
    end

    test "writes nothing for a hit seen within the last 24 hours" do
      fresh = ago(1, :hour)

      {raw_token, %AnonymousOrganizer{id: id} = organizer} =
        anonymous_organizer_fixture(last_seen_at: fresh)

      assert %AnonymousOrganizer{id: ^id} = Activities.get_anonymous_organizer_by_token(raw_token)

      persisted = Repo.get!(AnonymousOrganizer, id)
      assert persisted.last_seen_at == fresh
      assert persisted.updated_at == organizer.updated_at
    end
  end

  describe "claim_anonymous_groups/2" do
    test "moves every group to the account and marks the row claimed" do
      user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()
      scope = Scope.for_anonymous_organizer(organizer)
      first = group_fixture(scope)
      second = group_fixture(scope)
      {_other_scope, bystander} = anonymous_group_fixture()

      assert {:ok, 2} = Activities.claim_anonymous_groups(user, raw_token)

      for group <- [first, second] do
        moved = Repo.get!(Group, group.id)
        assert moved.organizer_id == user.id
        assert moved.anonymous_organizer_id == nil
      end

      assert Enum.map(Activities.list_groups(Scope.for_user(user)), & &1.id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])

      claimed = Repo.get!(AnonymousOrganizer, organizer.id)
      assert %DateTime{} = claimed.claimed_at
      assert claimed.claimed_by_user_id == user.id

      # Another organizer's group is untouched.
      untouched = Repo.get!(Group, bystander.id)
      assert untouched.organizer_id == nil
      assert untouched.anonymous_organizer_id == bystander.anonymous_organizer_id
    end

    test "a claimed row stops resolving" do
      {raw_token, _organizer} = anonymous_organizer_fixture()
      {:ok, _} = Activities.claim_anonymous_groups(user_fixture(), raw_token)

      assert Activities.get_anonymous_organizer_by_token(raw_token) == nil
    end

    test "claiming an identity that owns nothing still claims it" do
      user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()

      assert {:ok, 0} = Activities.claim_anonymous_groups(user, raw_token)
      assert %DateTime{} = Repo.get!(AnonymousOrganizer, organizer.id).claimed_at
    end

    test "the same user again is an idempotent {:ok, 0}" do
      user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()
      group = group_fixture(Scope.for_anonymous_organizer(organizer))

      assert {:ok, 1} = Activities.claim_anonymous_groups(user, raw_token)
      assert {:ok, 0} = Activities.claim_anonymous_groups(user, raw_token)
      assert Repo.get!(Group, group.id).organizer_id == user.id
    end

    test "a different user is refused with :already_claimed, and nothing moves" do
      first_user = user_fixture()
      second_user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()
      group = group_fixture(Scope.for_anonymous_organizer(organizer))

      {:ok, 1} = Activities.claim_anonymous_groups(first_user, raw_token)

      assert {:error, :already_claimed} =
               Activities.claim_anonymous_groups(second_user, raw_token)

      assert Repo.get!(Group, group.id).organizer_id == first_user.id
      assert Repo.get!(AnonymousOrganizer, organizer.id).claimed_by_user_id == first_user.id
    end

    test "an unknown token is :not_found" do
      assert {:error, :not_found} =
               Activities.claim_anonymous_groups(user_fixture(), :crypto.strong_rand_bytes(32))
    end

    # Plan §6.3's type comment: ":not_found — unknown or expired token".
    test "a token idle longer than 90 days is :not_found, and its groups stay put" do
      {raw_token, organizer} = anonymous_organizer_fixture()
      group = group_fixture(Scope.for_anonymous_organizer(organizer))
      organizer |> Ecto.Changeset.change(last_seen_at: ago(91, :day)) |> Repo.update!()

      assert {:error, :not_found} = Activities.claim_anonymous_groups(user_fixture(), raw_token)
      assert Repo.get!(Group, group.id).anonymous_organizer_id == organizer.id
    end

    # Forced without a mock: a TEMP trigger on this sandbox connection aborts the CAS
    # UPDATE with SQLite's own busy message, which reaches Elixir as `Exqlite.Error` —
    # what a real lock timeout raises. It is DDL, hence `async: false` above; the
    # trigger is rolled back with the sandbox transaction. The genuinely concurrent
    # two-claim race is not reproducible here (`max_cases: 1` plus the sandbox makes
    # every write sequential); it lives in `activities_claim_concurrency_test.exs`, on
    # a second dynamic repo.
    @tag :capture_log
    test "a busy database is {:error, {:database_busy, _}} and changes nothing" do
      user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()
      group = group_fixture(Scope.for_anonymous_organizer(organizer))

      Repo.query!("""
      CREATE TEMP TRIGGER d058_busy_claim BEFORE UPDATE ON anonymous_organizers
      BEGIN SELECT RAISE(ABORT, 'database is locked'); END
      """)

      assert {:error, {:database_busy, message}} =
               Activities.claim_anonymous_groups(user, raw_token)

      assert is_binary(message)

      Repo.query!("DROP TRIGGER d058_busy_claim")

      assert Repo.get!(AnonymousOrganizer, organizer.id).claimed_at == nil
      assert Repo.get!(Group, group.id).anonymous_organizer_id == organizer.id
      # Still claimable: the next log-in retries.
      assert {:ok, 1} = Activities.claim_anonymous_groups(user, raw_token)
    end
  end

  # The stale-scope hole a zero-group claim used to leave open: a `/groups/new` tab
  # mounted before a log-in elsewhere claimed the identity still holds its scope, and a
  # group inserted on a claimed identity is reachable by no resolver and no claim.
  describe "a claimed identity creates nothing" do
    test "create_group/2 with the scope the tab mounted with is {:error, :claimed}" do
      user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()
      stale_scope = Scope.for_anonymous_organizer(organizer)

      assert {:ok, 0} = Activities.claim_anonymous_groups(user, raw_token)

      assert {:error, :claimed} =
               Activities.create_group(stale_scope, %{
                 title: unique_group_title(),
                 deadline_at: future_deadline()
               })

      assert Repo.aggregate(Group, :count) == 0
    end

    test "create_group_with_organizer_name/3 refuses too, and writes no name" do
      {raw_token, organizer} = anonymous_organizer_fixture()
      stale_scope = Scope.for_anonymous_organizer(organizer)
      assert {:ok, 0} = Activities.claim_anonymous_groups(user_fixture(), raw_token)

      assert {:error, :claimed} =
               Activities.create_group_with_organizer_name(
                 stale_scope,
                 %{title: unique_group_title(), deadline_at: future_deadline()},
                 %{display_name: "Sam"}
               )

      assert Repo.aggregate(Group, :count) == 0
      assert Repo.get!(AnonymousOrganizer, organizer.id).display_name == nil
    end

    test "an unclaimed identity still creates" do
      {_raw_token, organizer} = anonymous_organizer_fixture()

      assert {:ok, %Group{anonymous_organizer_id: id}} =
               Activities.create_group(Scope.for_anonymous_organizer(organizer), %{
                 title: unique_group_title(),
                 deadline_at: future_deadline()
               })

      assert id == organizer.id
    end

    # Belt and braces: should a group ever land on the identity after its claim (a write
    # path that skipped the guard above), the claiming user's next claim moves it rather
    # than answering a bare `{:ok, 0}`.
    test "a re-claim by the same user moves a group that arrived after the first claim" do
      user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()
      assert {:ok, 0} = Activities.claim_anonymous_groups(user, raw_token)

      late =
        Repo.insert!(%Group{
          anonymous_organizer_id: organizer.id,
          title: unique_group_title(),
          slug: "late-#{System.unique_integer([:positive])}",
          deadline_at: future_deadline()
        })

      assert {:ok, 1} = Activities.claim_anonymous_groups(user, raw_token)

      assert %Group{organizer_id: user_id, anonymous_organizer_id: nil} =
               Repo.get!(Group, late.id)

      assert user_id == user.id
    end
  end

  describe "count_groups/1" do
    test "counts only this organizer's groups" do
      {scope, _group} = anonymous_group_fixture()
      group_fixture(scope)
      anonymous_group_fixture()

      assert Activities.count_groups(scope) == 2
    end
  end

  describe "owns_any_group?/1" do
    test "is true only for an account that organizes something" do
      user = user_fixture()
      refute Activities.owns_any_group?(user)

      group_fixture(Scope.for_user(user))
      assert Activities.owns_any_group?(user)
    end

    test "turns true when a claim moves groups in" do
      user = user_fixture()
      {raw_token, organizer} = anonymous_organizer_fixture()
      group_fixture(Scope.for_anonymous_organizer(organizer))
      refute Activities.owns_any_group?(user)

      {:ok, 1} = Activities.claim_anonymous_groups(user, raw_token)
      assert Activities.owns_any_group?(user)
    end
  end

  describe "the boot sweep" do
    test "deletes only an old, unclaimed row that owns no group" do
      {_, doomed} = anonymous_organizer_fixture(last_seen_at: ago(31, :day))

      # Old, but owns a group people have voted in.
      {_, owner} = anonymous_organizer_fixture()
      owner_scope = Scope.for_anonymous_organizer(owner)
      {group, [activity | _]} = voting_group_fixture(owner_scope)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [activity.id])
      owner |> Ecto.Changeset.change(last_seen_at: ago(31, :day)) |> Repo.update!()

      # Old and owns nothing, but claimed — history, not litter.
      {_, claimed} =
        anonymous_organizer_fixture(last_seen_at: ago(31, :day), claimed_at: ago(31, :day))

      # Owns nothing, but seen recently.
      {_, fresh} = anonymous_organizer_fixture(last_seen_at: ago(1, :day))

      assert sweep(DateTime.utc_now(:second)) == 1

      refute Repo.get(AnonymousOrganizer, doomed.id)
      assert Repo.get(AnonymousOrganizer, owner.id)
      assert Repo.get(AnonymousOrganizer, claimed.id)
      assert Repo.get(AnonymousOrganizer, fresh.id)
      assert Repo.get(Group, group.id)
    end

    test "is idempotent" do
      _ = anonymous_organizer_fixture(last_seen_at: ago(31, :day))
      now = DateTime.utc_now(:second)

      assert sweep(now) == 1
      assert sweep(now) == 0
    end

    # The backstop for a wrong sweep predicate: `ON DELETE RESTRICT` raises instead of
    # cascading through groups, participants and votes (plan §2.2).
    test "deleting a row that owns a group raises" do
      {scope, group} = anonymous_group_fixture()

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(scope.anonymous_organizer) end

      assert Repo.get(AnonymousOrganizer, scope.anonymous_organizer.id)
      assert Repo.get(Group, group.id)
    end
  end

  test "the fixtures build what they say" do
    assert {raw_token, %AnonymousOrganizer{}} = anonymous_organizer_fixture()
    assert is_binary(raw_token)

    assert %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{}} =
             anonymous_scope_fixture()
  end
end
