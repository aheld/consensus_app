defmodule Consensus.ActivitiesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Consensus.Activities` context.
  """

  import Ecto.Query

  alias Consensus.Accounts.Scope
  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Repo

  def unique_group_title, do: "Group #{System.unique_integer([:positive])}"
  def unique_activity_name, do: "Activity #{System.unique_integer([:positive])}"

  @doc "A deadline far enough in the future to be usable for `publish_group/2`."
  def future_deadline, do: DateTime.add(DateTime.utc_now(:second), 1, :day)

  @doc "A deadline already in the past, for `maybe_complete_group/1`."
  def past_deadline, do: DateTime.add(DateTime.utc_now(:second), -1, :day)

  @doc """
  Creates a group organized by the given scope's user.

  Goes through `Consensus.Activities.create_group/2`, the real write path — unlike
  `AccountsFixtures.admin_fixture/1`, there is no chicken-and-egg problem here that
  would justify bypassing it.

  **A `deadline_at` already in the past is the one exception, and it is stamped on
  afterwards rather than passed through the write path.** Since D-055 `Group.changeset/2`
  refuses a deadline that is not in the future, which is correct: an organizer cannot
  create a session that has already closed. A *test* still needs one, because that is the
  precondition for everything about `maybe_complete_group/1` — but what it needs is a
  group whose deadline has *passed*, which is a thing time does, not a thing an organizer
  types. So the group is created normally and the clock is moved by writing the column
  directly, which is the honest simulation and keeps the validation testable.
  """
  def group_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: unique_group_title()})
    {deadline, attrs} = Map.pop(attrs, :deadline_at)

    {:ok, group} =
      attrs
      |> maybe_put_future_deadline(deadline)
      |> then(&Activities.create_group(scope, &1))

    backdate_deadline(group, deadline)
  end

  defp maybe_put_future_deadline(attrs, nil), do: attrs

  defp maybe_put_future_deadline(attrs, deadline) do
    if past?(deadline),
      do: Map.put(attrs, :deadline_at, future_deadline()),
      else: Map.put(attrs, :deadline_at, deadline)
  end

  defp backdate_deadline(group, deadline) do
    if deadline && past?(deadline) do
      group
      |> Ecto.Changeset.change(deadline_at: DateTime.truncate(deadline, :second))
      |> Repo.update!()
    else
      group
    end
  end

  defp past?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt
  defp past?(_other), do: false

  @doc """
  Creates an activity in the given group.

  Inserts directly rather than through `Consensus.Activities.add_activity/3` so a test
  can populate a group regardless of its status (`add_activity/3` refuses a completed
  or cancelled group) or seed a specific `:position` — pass `position:` in `attrs` to
  override the default of "next in the group".
  """
  def activity_fixture(group, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: unique_activity_name()})
    {position, attrs} = Map.pop(attrs, :position, next_position(group.id))

    %Activity{group_id: group.id}
    |> Activity.changeset(attrs)
    |> Ecto.Changeset.put_change(:position, position)
    |> Repo.insert!()
  end

  @doc """
  Mints an organizer with no account (D-058) and returns `{raw_token, organizer}`.

  Goes through `Consensus.Activities.mint_anonymous_organizer/0`, the real write path,
  so the raw token is whatever the resolver will accept. `attrs` are then stamped on
  directly — `:display_name`, `:last_seen_at`, `:claimed_at`, `:claimed_by_user_id` —
  for the same reason `group_fixture/2` backdates a deadline: an identity idle for 90
  days, or one already claimed, is a thing time and another request do, not a thing
  the mint can be asked for.
  """
  def anonymous_organizer_fixture(attrs \\ %{}) do
    {raw_token, organizer} = Activities.mint_anonymous_organizer()

    attrs = Map.new(attrs)

    organizer =
      if attrs == %{},
        do: organizer,
        else: organizer |> Ecto.Changeset.change(attrs) |> Repo.update!()

    {raw_token, organizer}
  end

  @doc "A `%Scope{}` for a freshly minted organizer with no account."
  def anonymous_scope_fixture(attrs \\ %{}) do
    {_raw_token, organizer} = anonymous_organizer_fixture(attrs)
    Scope.for_anonymous_organizer(organizer)
  end

  @doc """
  A group owned by a freshly minted organizer with no account.

  Returns `{scope, group}` — unlike `group_fixture/2` there is no scope in hand to call
  it with, and every caller needs the one that owns the group.
  """
  def anonymous_group_fixture(attrs \\ %{}) do
    scope = anonymous_scope_fixture()
    {scope, group_fixture(scope, attrs)}
  end

  defp next_position(group_id) do
    case Repo.one(from(a in Activity, where: a.group_id == ^group_id, select: max(a.position))) do
      nil -> 1
      max -> max + 1
    end
  end
end
