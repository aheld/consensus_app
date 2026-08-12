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

  `resolution`, `resolved_activity_id` and `resolved_at` record how a `:completed`
  group's endgame was settled when the tally alone could not settle it — a dead heat
  broken by the organizer or the app, or an all-vetoed pool rescued by a random pick.
  They are written only by `Consensus.Activities.resolve_group/4` and cleared only by
  `reopen_group/2`, through their own narrow changesets below — never through
  `changeset/2`, exactly like `status`.

  `search_area` and `search_bbox` are storage for the Assisted Add area prompt
  (`docs/design/assisted-add-ux-brief.md` F2): a human-typed neighbourhood/city
  string, and its geocoded bounding box as `"min_lat,min_lon,max_lat,max_lon"`
  (parsed by whatever reads it — see the migration
  `20260811172739_add_search_area_to_activity_groups.exs`). Stored on the group, not
  the organizer, per `docs/research/activity-discovery.md` §4.1. Written only by
  `Consensus.Activities.set_search_area/3`, through `search_area_changeset/2` below
  — never through `changeset/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_title_length 120
  @max_search_area_length 100
  @statuses [:draft, :voting, :completed, :cancelled]
  @resolutions ~w(organizer_pick app_pick app_rescue)

  @doc "Longest title a group may have."
  def max_title_length, do: @max_title_length

  @doc "Longest `search_area` string a group may have (invariant 11 — the changeset is the real limit)."
  def max_search_area_length, do: @max_search_area_length

  @doc "Every status a group can be in, in lifecycle order."
  def statuses, do: @statuses

  @doc """
  Every way a completed group's endgame can be resolved, as stored strings:
  `"organizer_pick"` and `"app_pick"` break a tie, `"app_rescue"` un-vetoes one
  option of an all-vetoed pool. Plain data, like `activity_type` — nothing branches
  on the value outside `Consensus.Voting.tally/1`'s reading of `"app_rescue"`.
  """
  def resolutions, do: @resolutions

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
    field :resolution, :string
    field :resolved_at, :utc_datetime
    field :search_area, :string
    field :search_bbox, :string

    belongs_to :organizer, Consensus.Accounts.User
    belongs_to :resolved_activity, Consensus.Activities.Activity

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

  @doc """
  Changeset for recording an endgame resolution — `:resolution`,
  `:resolved_activity_id` and `:resolved_at`, and nothing else.

  Only `Consensus.Activities.resolve_group/4` calls this. Kept apart from
  `changeset/2` for the same reason `status_changeset/2` is (the narrow-changeset
  rule CLAUDE.md invariant 6 states for `:is_admin`): an organizer-facing edit form
  must never be able to smuggle a resolution through `attrs`. The candidate-set rule
  — which activities a given resolution may legally land on — lives in
  `Consensus.Activities`, not here; this changeset only refuses an unknown
  resolution kind.
  """
  def resolution_changeset(group, attrs) do
    group
    |> cast(attrs, [:resolution, :resolved_activity_id, :resolved_at])
    |> validate_inclusion(:resolution, @resolutions)
  end

  @doc """
  Changeset for answering the Assisted Add area prompt — `:search_area` and
  `:search_bbox`, and nothing else.

  Only `Consensus.Activities.set_search_area/3` calls this. Kept apart from
  `changeset/2` for the same narrow-changeset reason `status_changeset/2` and
  `resolution_changeset/2` are. `:search_area` carries no `maxlength` anywhere it is
  rendered (invariant 11) — `validate_length/3` here, capped at
  `max_search_area_length/0` graphemes, is the real limit. `:search_bbox` is left
  unvalidated in shape: it is written by the geocoder, never typed by an organizer,
  so there is no untrusted input here to bound the way `:search_area` is bounded.
  """
  def search_area_changeset(group, attrs) do
    group
    |> cast(attrs, [:search_area, :search_bbox])
    |> validate_length(:search_area, max: @max_search_area_length)
  end

  @doc """
  Changeset that reopens an all-vetoed group's pool: status back to `:draft`, with
  `:completed_at`, `:deadline_at` and all three resolution columns cleared.

  Only `Consensus.Activities.reopen_group/2` calls this, inside the transaction that
  also deletes the group's votes. `:deadline_at` is cleared deliberately — the old
  deadline has passed, and leaving it set would let round 2 re-complete itself on the
  first read after publish (`maybe_complete_group/1` runs on every read); publishing
  again therefore requires a fresh deadline (`publish_group/2` refuses
  `:no_deadline`). No `cast/3`: every value is programmatic.

  Every column is written with `force_change/3`, not `change/2`: `change/2` drops a
  change equal to the struct's current value, so a stale struct that still reads
  `nil` for a column the database has since set would silently *not* clear it —
  `reopen_group/2` re-reads the row inside its transaction precisely to avoid
  holding a stale struct, and this changeset must not depend on the caller
  remembering that. The clears land regardless of what the struct in hand claims.
  """
  def reopen_changeset(group) do
    [
      status: :draft,
      completed_at: nil,
      deadline_at: nil,
      resolution: nil,
      resolved_activity_id: nil,
      resolved_at: nil
    ]
    |> Enum.reduce(change(group), fn {field, value}, changeset ->
      force_change(changeset, field, value)
    end)
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
