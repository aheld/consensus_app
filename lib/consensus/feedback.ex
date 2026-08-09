defmodule Consensus.Feedback do
  @moduledoc """
  What people tell us from the two faces in the global footer, and the admin queue that
  reads it (D-042, D-043).

  ## Two halves, two authorization shapes

  **Writing is public and has no actor at all.** `ConsensusWeb.Chrome.footer/1` puts the
  pair on every screen this app renders, including screens a signed-out stranger reaches
  from a shared link, so `submit/2` takes **no `%Scope{}`** — it is shaped like
  `Consensus.Voting.create_participant/2`, not like `Consensus.Activities`, which proves
  ownership by binding a scope's `user_id` and a row's `organizer_id` to the same
  variable in the function head. There is nothing here to own. When the sender happens to
  be signed in, the caller passes `user_id:` and it is written to a column the form
  cannot cast.

  Because it is a public, unauthenticated write, `submit/2` **rescues SQLite**:

      rescue
        error in [Exqlite.Error, DBConnection.ConnectionError] ->
          {:error, {:database_busy, Exception.message(error)}}

  copied verbatim from `create_participant/2` (CLAUDE.md invariant 17). It deliberately
  does **not** retry the way `Consensus.Voting.cast_ballot/3` does: a ballot has a
  deadline that makes every voter in a group press submit at the same instant, and
  feedback has no stampede to absorb. One refusal, one honest error on screen, the
  sender's typing still in the form.

  **Reading and annotating is admin-only, and the guard is the function head.**
  `list_entries/0` and `count_unread/0` take no actor because `/admin/feedback` is
  already behind the router's `:require_admin_user` plug *and* the `:require_admin`
  on_mount hook (a plug pipeline does not run for the LiveView socket, so both are
  required — CLAUDE.md invariant 1). `set_read/3` and `annotate/3` take the actor's
  `%Scope{}` first and match `%Scope{user: %User{is_admin: true}}` **in the head**, so a
  non-admin caller raises `FunctionClauseError` rather than being refused at runtime.

  That is the shape invariant 1 describes as "the right shape for a *non-destructive*
  admin-only write if one is ever added — precondition, not runtime branch", which had
  no living example after `Consensus.Content.update_home_page/2` was deleted with the
  home page (D-027). These two are that example. **Neither re-reads the actor and neither
  requires sudo mode, and that is deliberate**: sudo protects
  `Consensus.Accounts.set_admin/3` and `delete_user/2`, which change privileges and
  destroy accounts. Marking a message read and typing a note beside it are recoverable
  in one click and change nothing outside their own row. Putting them behind a
  re-authentication prompt would train administrators to type their password to triage a
  bug report, which is how a real sudo prompt stops being read.

  **Both admin writes rescue SQLite too**, with the same two-clause `rescue` as `submit/2`.
  Invariant 17's letter binds public unauthenticated writes, so this is a gap rather than a
  violation of it — but SQLite *raises* rather than returning a tuple when a write cannot
  take the lock, and a raise walks straight past the `with/else` in
  `ConsensusWeb.AdminLive.Feedback`'s friendly catch-all. The effect would be that a busy
  database crashes the admin's LiveView and takes every unsaved note on the page with it,
  which is the one thing that module's whole `load_entries/2` design exists to prevent.
  """

  import Ecto.Query, warn: false

  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Feedback.Entry
  alias Consensus.Repo

  @doc """
  A blank changeset for the public form.

  `mood` seeds the form from `?mood=happy` / `?mood=sad` in the footer link, so the
  face the sender tapped is already picked when the page renders. Pass `nil` for a
  direct visit with no mood: both faces render unpicked and `changeset/2` requires one
  before it will store anything.
  """
  def change_entry(%Entry{} = entry \\ %Entry{}, attrs \\ %{}) do
    Entry.changeset(entry, attrs)
  end

  @doc """
  Stores one piece of feedback. Public — any visitor, signed in or not, from any screen.

  `opts`:

    * `:user_id` — the sender's account when there is one. Never cast from the form.
    * `:page_path` — the screen they came from. Attached **only** when the form's
      "include the screen I was on" box was left ticked; see `Entry.put_page_path/2`.

  Returns `{:ok, %Entry{}}`, `{:error, %Ecto.Changeset{}}`, or
  `{:error, {:database_busy, message}}` when SQLite refuses the write.
  """
  def submit(attrs, opts \\ []) do
    %Entry{user_id: Keyword.get(opts, :user_id)}
    |> Entry.changeset(attrs)
    |> Entry.put_page_path(Keyword.get(opts, :page_path))
    |> Repo.insert()
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      {:error, {:database_busy, Exception.message(error)}}
  end

  @doc """
  Every entry, newest first, with the sender's account preloaded when there was one.

  Admin-only by the router and the on_mount hook; see the moduledoc.
  """
  def list_entries do
    from(f in Entry, order_by: [desc: f.inserted_at, desc: f.id], preload: [:user])
    |> Repo.all()
  end

  @doc "How many entries no administrator has marked read yet."
  def count_unread do
    Repo.aggregate(from(f in Entry, where: is_nil(f.read_at)), :count)
  end

  @doc "One entry by id, with its sender preloaded, or `nil`."
  def get_entry(id) when is_integer(id) do
    Repo.get(Entry, id) |> Repo.preload(:user)
  end

  def get_entry(_id), do: nil

  @doc """
  Marks an entry read or unread. **Reversible** — that is the whole point of the pair.

  Authorized by the function head: a scope that is not an administrator's matches no
  clause. Not destructive, so no actor re-read and no sudo gate; see the moduledoc.
  """
  def set_read(%Scope{user: %User{is_admin: true}}, %Entry{} = entry, read?)
      when is_boolean(read?) do
    read_at = if read?, do: DateTime.utc_now(:second), else: nil

    entry
    |> Entry.admin_changeset(%{read_at: read_at})
    |> Repo.update()
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      {:error, {:database_busy, Exception.message(error)}}
  end

  @doc """
  Writes the private admin note beside an entry, replacing whatever was there.

  A blank note clears it (`Entry.admin_changeset/2` normalises blank to `nil`), so this
  is as reversible as `set_read/3`. **Nothing else happens**: no mail leaves the app, no
  webhook fires, the sender is never told. `/admin/feedback` says that on screen rather
  than only here, because an administrator typing "emailed them back" needs to know the
  app did not.
  """
  def annotate(%Scope{user: %User{is_admin: true}}, %Entry{} = entry, note) do
    entry
    |> Entry.admin_changeset(%{admin_note: note})
    |> Repo.update()
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      {:error, {:database_busy, Exception.message(error)}}
  end
end
