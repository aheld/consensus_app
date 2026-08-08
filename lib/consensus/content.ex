defmodule Consensus.Content do
  @moduledoc """
  Site content that administrators can edit at runtime.

  Today that is exactly one thing: the message on the public home page. Reads are
  safe from anywhere; writes require an admin `Consensus.Accounts.Scope`, and every
  successful write is broadcast over `Phoenix.PubSub` so open home pages update
  without a refresh.
  """

  import Ecto.Query, warn: false

  alias Consensus.Accounts
  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Content.HomePage
  alias Consensus.Repo

  @topic "content:home_page"

  # Every byte of this string is user-visible. The home page renders it inside a
  # `whitespace-pre-wrap` paragraph, so a line break here is a line break in the
  # browser — one source line per rendered line, and do not reflow it to fit the
  # source margin. `Consensus.Seeds` persists it on first boot, which makes it the
  # first prose every visitor to a fresh install reads.
  #
  # It is a list rather than a heredoc so the line structure is a data decision
  # instead of a formatting accident: a stray indent inside a heredoc reads like
  # whitespace and survives `mix format`, whereas here it would sit visibly inside
  # quotes. Behaviour-guarded by "default_message/0" in
  # test/consensus/content_test.exs — no surrounding whitespace on any line, and no
  # non-empty line stopping mid-sentence.
  @default_message_lines [
    "Welcome to Consensus.",
    "",
    "An admin can edit this message from the admin area: sign in, then open Admin → Home page.",
    "Whatever you type there shows up here for everyone, live."
  ]

  @doc "The message a brand-new installation starts with."
  def default_message, do: Enum.join(@default_message_lines, "\n")

  @doc """
  Subscribes the calling process to home page updates.

  Subscribers receive `{:home_page_updated, %HomePage{}}`.
  """
  def subscribe_home_page do
    Phoenix.PubSub.subscribe(Consensus.PubSub, @topic)
  end

  @doc """
  Returns the home page.

  Falls back to an unsaved struct carrying `default_message/0` so that the public home
  page still renders on a database that has not been seeded yet.
  """
  def get_home_page do
    Repo.get(HomePage, HomePage.singleton_id()) ||
      %HomePage{id: HomePage.singleton_id(), message: default_message()}
  end

  @doc """
  Inserts the home page row with the default message if it does not exist yet.

  Idempotent — safe to call on every boot. Returns the persisted `%HomePage{}`.
  """
  def ensure_home_page! do
    case Repo.get(HomePage, HomePage.singleton_id()) do
      nil ->
        %HomePage{id: HomePage.singleton_id()}
        |> HomePage.changeset(%{message: default_message()})
        |> Repo.insert!(on_conflict: :nothing)
        |> case do
          # `on_conflict: :nothing` can return a struct with no id when another node
          # won the race; re-read so callers always get the row that is actually stored.
          %HomePage{id: nil} -> Repo.get!(HomePage, HomePage.singleton_id())
          home_page -> home_page
        end

      home_page ->
        home_page
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking home page changes.
  """
  def change_home_page(%HomePage{} = home_page, attrs \\ %{}) do
    HomePage.changeset(home_page, attrs)
  end

  @doc """
  Updates the home page message.

  Only an admin scope may call this — anything else raises `FunctionClauseError`,
  which is deliberate: authorization is a precondition, not a runtime branch.

  The role is then re-read from the database. A `%Scope{}` handed in by a LiveView is
  a snapshot taken at mount, and an admin whose role was revoked while they had the
  editor open would otherwise keep write access to the public home page for as long as
  that tab stayed open. `Consensus.Accounts.set_admin/3` makes the same check for the
  same reason. A revoked admin gets `{:error, :unauthorized}`.

  On success, broadcasts `{:home_page_updated, home_page}` to `subscribe_home_page/0`.
  """
  def update_home_page(%Scope{user: %User{is_admin: true} = user}, attrs) do
    case Accounts.get_user(user.id) do
      %User{is_admin: true} -> do_update_home_page(user, attrs)
      _ -> {:error, :unauthorized}
    end
  end

  defp do_update_home_page(%User{} = user, attrs) do
    result =
      ensure_home_page!()
      |> HomePage.changeset(attrs)
      |> Ecto.Changeset.put_change(:updated_by_id, user.id)
      |> Repo.update()

    with {:ok, home_page} <- result do
      Phoenix.PubSub.broadcast(Consensus.PubSub, @topic, {:home_page_updated, home_page})
      {:ok, home_page}
    end
  end
end
