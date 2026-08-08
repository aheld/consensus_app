defmodule Consensus.Activities.Activity do
  @moduledoc """
  One option in an activity group's pool — e.g. one restaurant.

  `position` is 1-based and contiguous within its group. `Consensus.Activities` is
  responsible for keeping it that way (append at `max(position) + 1`, renumber on
  delete); this changeset only validates that a position is a plain positive integer,
  it does not — and cannot, from a single row — check contiguity.

  `image_url` and `source_url` are URL-referenced only: there is no upload path.
  `metadata_fetched_at` is set by the (future) link-paste flow when it actually filled
  fields from `source_url`; a typed name with no link leaves both nil.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_name_length 120
  @max_description_length 140

  @doc "Longest name an activity may have."
  def max_name_length, do: @max_name_length

  @doc "Longest description an activity may have — the design's `62/140` counter."
  def max_description_length, do: @max_description_length

  schema "activities" do
    field :position, :integer
    field :name, :string
    field :description, :string
    field :image_url, :string
    field :source_url, :string
    field :metadata_fetched_at, :utc_datetime

    belongs_to :group, Consensus.Activities.Group
    belongs_to :added_by, Consensus.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or editing an activity.

  `:group_id`, `:added_by_id` and `:position` are set programmatically by
  `Consensus.Activities` (from the scope, the parent group, and the current pool size
  respectively) and are deliberately absent from `cast/3`.
  """
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:name, :description, :image_url, :source_url, :metadata_fetched_at])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> validate_length(:description, max: @max_description_length)
    |> validate_url(:image_url)
    |> validate_url(:source_url)
  end

  @doc """
  Changeset for setting an activity's position.

  Kept separate from `changeset/2` because reordering and renumbering never touch any
  other field, and because a public form must never be able to smuggle a position
  change through `attrs`.
  """
  def position_changeset(activity, position) when is_integer(position) do
    cast(activity, %{position: position}, [:position])
    |> validate_required([:position])
    |> validate_number(:position, greater_than: 0)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid http(s) URL"}]
      end
    end)
  end
end
