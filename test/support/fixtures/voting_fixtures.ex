defmodule Consensus.VotingFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Consensus.Voting` context.

  `voting_group_fixture/2` is the one worth reading: almost every test here needs a
  group that is actually **open** (`:voting`), which `ActivitiesFixtures.group_fixture/2`
  is not — `Consensus.Activities.publish_group/2` refuses an empty pool and a missing
  deadline, so the fixture seeds both and publishes.
  """

  import Consensus.ActivitiesFixtures

  alias Consensus.Activities
  alias Consensus.Activities.Group
  alias Consensus.Repo
  alias Consensus.Voting

  @doc """
  A published (`:voting`) group with `count` activities, positions 1..count.

  Returns `{group, activities}` — the activities in position order, since almost every
  ballot test needs their ids.
  """
  def voting_group_fixture(scope, count \\ 3, attrs \\ %{}) do
    group = group_fixture(scope, Map.merge(%{deadline_at: future_deadline()}, Map.new(attrs)))
    activities = for _ <- 1..count, do: activity_fixture(group)
    {:ok, group} = Activities.publish_group(scope, group)
    {group, activities}
  end

  @doc """
  Forces a group's status and/or timestamps directly, bypassing the lifecycle functions.

  Used to build states the public API deliberately refuses to produce — most importantly
  a `:voting` group whose deadline has already passed, which every read path in
  `Consensus.Activities` would otherwise auto-complete on sight (D-029).
  """
  def force_group!(%Group{} = group, changes) do
    group |> Group.status_changeset(Map.new(changes)) |> Repo.update!()
  end

  @doc "Moves a group's deadline into the past without touching its status."
  def expire_deadline!(%Group{} = group) do
    group
    |> Ecto.Changeset.change(deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :minute))
    |> Repo.update!()
  end

  @doc "A guest participant in an open group."
  def participant_fixture(%Group{} = group, attrs \\ %{}) do
    {:ok, participant} = Voting.create_participant(group, attrs)
    participant
  end
end
