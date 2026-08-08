defmodule Consensus.Activities.Group do
  @moduledoc """
  A titled, deadlined pool of options that a group of people will vote on.

  `slug` is the public share id — the join link is `/join/<slug>` — generated
  server-side so it never has to round-trip through a form. `activity_type` is plain
  data (`"restaurant"` today), never a branch in code: see CLAUDE.md product invariant
  2, "the engine is activity-agnostic".

  `status` moves `:draft` → `:voting` → (`:completed` | `:cancelled`) through
  `Consensus.Activities.publish_group/2`, `complete_group/2` and `cancel_group/2`,
  never through this changeset directly — see that module for the transition rules
  (an empty pool or a missing deadline block publishing, a finished group cannot be
  cancelled, and so on).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_title_length 120
  @statuses [:draft, :voting, :completed, :cancelled]

  @doc "Longest title a group may have."
  def max_title_length, do: @max_title_length

  @doc "Every status a group can be in, in lifecycle order."
  def statuses, do: @statuses

  schema "activity_groups" do
    field :title, :string
    field :slug, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :activity_type, :string, default: "restaurant"
    field :deadline_at, :utc_datetime
    field :anonymous, :boolean, default: true
    field :veto_allowed, :boolean, default: true
    field :expected_voter_count, :integer
    field :completed_at, :utc_datetime
    field :cancelled_at, :utc_datetime

    belongs_to :organizer, Consensus.Accounts.User

    has_many :activities, Consensus.Activities.Activity, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or editing a group's own fields.

  `:organizer_id` is set programmatically by `Consensus.Activities` from the caller's
  scope and is deliberately absent from `cast/3` — the same shape `Consensus.Accounts`
  uses to keep `:is_admin` out of the registration changeset. `:status`, `:completed_at` and
  `:cancelled_at` are likewise absent: they only ever change through the lifecycle
  functions in `Consensus.Activities`, never through an organizer-facing form.

  When `:slug` is absent (always true on insert, since nothing prompts an organizer for
  one) a short, unguessable, URL-safe slug is generated.
  """
  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :title,
      :activity_type,
      :deadline_at,
      :anonymous,
      :veto_allowed,
      :expected_voter_count
    ])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: @max_title_length)
    |> validate_number(:expected_voter_count, greater_than: 0)
    |> put_slug()
    |> unique_constraint(:slug)
  end

  @doc """
  Changeset for a lifecycle transition — `:status` plus whichever timestamp goes with
  it (`:completed_at`, `:cancelled_at`).

  Kept separate from `changeset/2` so an organizer-facing edit form can never smuggle
  a status change through `attrs`; only `Consensus.Activities`' lifecycle functions
  (`publish_group/2`, `cancel_group/2`, `complete_group/2`, `maybe_complete_group/1`)
  call this.
  """
  def status_changeset(group, attrs) do
    cast(group, attrs, [:status, :completed_at, :cancelled_at])
  end

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil -> put_change(changeset, :slug, generate_slug())
      _ -> changeset
    end
  end

  defp generate_slug do
    :crypto.strong_rand_bytes(5) |> Base.url_encode64(padding: false)
  end
end
