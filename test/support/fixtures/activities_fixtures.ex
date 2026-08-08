defmodule Consensus.ActivitiesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Consensus.Activities` context.
  """

  import Ecto.Query

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
  """
  def group_fixture(scope, attrs \\ %{}) do
    {:ok, group} =
      attrs
      |> Enum.into(%{title: unique_group_title()})
      |> then(&Activities.create_group(scope, &1))

    group
  end

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

  defp next_position(group_id) do
    case Repo.one(from(a in Activity, where: a.group_id == ^group_id, select: max(a.position))) do
      nil -> 1
      max -> max + 1
    end
  end
end
