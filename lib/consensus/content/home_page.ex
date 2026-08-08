defmodule Consensus.Content.HomePage do
  @moduledoc """
  The editable message shown on the public home page.

  This is a singleton: exactly one row, with `id = 1`, enforced by a database
  check constraint (see the `create_home_page` migration).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @singleton_id 1
  @max_message_length 2_000
  @max_message_bytes 8_000

  @doc "The id of the one and only home page row."
  def singleton_id, do: @singleton_id

  @doc "Longest message an admin may save."
  def max_message_length, do: @max_message_length

  @primary_key {:id, :integer, autogenerate: false}
  schema "home_page" do
    field :message, :string

    belongs_to :updated_by, Consensus.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for editing the home page message.

  `:updated_by_id` is set by `Consensus.Content` from the current scope, never from
  user-supplied params.
  """
  def changeset(home_page, attrs) do
    home_page
    |> cast(attrs, [:message])
    # `cast/3` turns "" into nil, so this has to tolerate a nil change.
    |> update_change(:message, fn
      message when is_binary(message) -> String.trim(message)
      message -> message
    end)
    |> validate_required([:message])
    |> validate_length(:message, min: 1, max: @max_message_length)
    # `validate_length/3` counts graphemes by default, so 2 000 emoji would be ~8 KB of
    # TEXT. The byte cap is what actually bounds what reaches the database.
    |> validate_length(:message, max: @max_message_bytes, count: :bytes)
    |> check_constraint(:id, name: :home_page_is_a_singleton)
  end
end
