defmodule Consensus.Voting.Vote do
  @moduledoc """
  One mark a participant put on one activity: an **approval** or a **veto**.

  Approval voting is the MVP tally — "tap all you'd be happy with" — so a ballot is a
  set of `:approve` rows plus at most one `:veto` row. Ranked-choice is explicitly
  Post-MVP (PRD scope discipline); there is deliberately no rank or weight column here
  to tempt it into existence.

  Rows are written only by `Consensus.Voting.cast_ballot/3`, all of them inside the one
  transaction that also stamps `Participant.voted_at`. A unique index on
  `(participant_id, activity_id)` means one participant cannot both approve and veto
  the same option even if the client tries.

  `kind` is a plain string column read through `Ecto.Enum`, the same shape as
  `Group.status` and `Participant.kind`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:approve, :veto]

  @doc "Every kind of vote."
  def kinds, do: @kinds

  schema "votes" do
    field :kind, Ecto.Enum, values: @kinds

    belongs_to :participant, Consensus.Voting.Participant
    belongs_to :activity, Consensus.Activities.Activity

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a single mark.

  Casts exactly `[:kind]`. `:participant_id` and `:activity_id` are set programmatically
  on the struct by `Consensus.Voting.cast_ballot/3` — which has already checked that the
  activity belongs to the participant's group — and are deliberately absent from `cast/3`,
  because ids that arrive from a browser must never reach a `cast` unvalidated.
  """
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:kind])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:participant_id)
    |> foreign_key_constraint(:activity_id)
    |> unique_constraint([:participant_id, :activity_id],
      name: :votes_participant_id_activity_id_index
    )
  end
end
