defmodule Consensus.Feedback.Entry do
  @moduledoc """
  One thing somebody told us, from the two faces in `ConsensusWeb.Chrome.footer/1`.

  There is no actor on the write path. The footer is on every screen this app renders,
  including screens a signed-out stranger can reach, so an entry is a message plus a
  mood plus whatever contact details the sender volunteered — and every one of those
  contact fields is optional. `name` and `email` are normalised blank-to-`nil` the way
  `Consensus.Voting.Participant`'s `display_name` is, so "left it blank" has exactly one
  representation in the database and no caller has to test for both.

  Three fields are **not** castable and are set on the struct by `Consensus.Feedback`:

    * `user_id` — read from the sender's `%Scope{}` when there is one. A client cannot
      claim to be somebody.
    * `page_path` — the screen the sender came from, and only when they left the
      "include the screen I was on" box ticked. `put_page_path/2` is what enforces that;
      see `include_page`.
    * `read_at` / `admin_note` — the admin queue's own columns, written by
      `Consensus.Feedback.set_read/3` and `annotate/3` through `admin_changeset/2`.

  `include_page` is a virtual field rather than something the LiveView keeps beside the
  form, because the promise the checkbox makes ("include the screen I was on") is a
  property of *this* submission and belongs in the same changeset as the rest of it. A
  default-on checkbox whose value the write path ignores is a lie, and keeping the
  decision here means the test that proves it is honoured is a context test.

  `message` gets **no `maxlength` attribute** anywhere it is rendered (CLAUDE.md
  invariant 11 / D-026): a browser's `maxlength` counts UTF-16 code units and silently
  truncates a paste, `validate_length/3` counts graphemes, and the two disagree on
  anything outside the BMP. `max_message_length/0` is the single number the changeset
  and the on-screen counter both read.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @moods [:happy, :sad]
  @max_message_length 600
  @max_name_length 60
  @max_email_length 160
  @max_admin_note_length 1000

  @doc "The two moods the footer's two faces send."
  def moods, do: @moods

  @doc """
  Longest message we will store — the design's `0/600` counter.

  A public zero-arg function for the same reason `Consensus.Activities.Activity.max_description_length/0`
  is one: the template's counter and this changeset must read the same number, or the
  screen and the database disagree about what fits.
  """
  def max_message_length, do: @max_message_length

  @doc "Longest name a sender may type."
  def max_name_length, do: @max_name_length

  @doc "Longest email address a sender may type."
  def max_email_length, do: @max_email_length

  @doc "Longest private admin note. Free text, so no `maxlength` on the textarea either."
  def max_admin_note_length, do: @max_admin_note_length

  schema "feedback" do
    field :mood, Ecto.Enum, values: @moods
    field :message, :string
    field :name, :string
    field :email, :string
    field :page_path, :string
    field :read_at, :utc_datetime
    field :admin_note, :string

    # Not a column. See the moduledoc: it is the checkbox's promise, and
    # `put_page_path/2` is where it is kept.
    field :include_page, :boolean, virtual: true, default: true

    belongs_to :user, Consensus.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the public form.

  Casts exactly `[:mood, :message, :name, :email, :include_page]`. `mood` is required
  because it is the cheapest signal in the whole record and it is one tap of two — the
  form renders both faces and a direct visit to `/feedback` with no `?mood=` simply
  starts with neither picked.

  The email format check is deliberately loose (`@` with something either side, no
  spaces). Nothing is ever sent to this address by the app — it exists so a human can
  write back by hand — so a strict RFC pattern would only reject real addresses in
  exchange for nothing.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:mood, :message, :name, :email, :include_page])
    |> update_change(:name, &blank_to_nil/1)
    |> update_change(:email, &blank_to_nil/1)
    |> update_change(:message, &blank_to_nil/1)
    |> validate_required([:mood], message: "tap a face so we know which way this went")
    |> validate_required([:message], message: "tell us what happened")
    |> validate_inclusion(:mood, @moods)
    |> validate_length(:message,
      max: @max_message_length,
      message: "that's a bit long — trim it to #{@max_message_length} characters"
    )
    # Both carry a `:message` for the same reason `:message` above does. The framework
    # default ("should be at most 60 character(s)") is passive, has a `(s)` plural
    # artefact, and — because these two fields deliberately have neither a `maxlength` nor
    # a counter — it is the *first* warning a sender ever gets that they are over. A
    # refusal on a public form has to say what to do about it.
    |> validate_length(:name,
      max: @max_name_length,
      message: "that's a bit long — trim it to #{@max_name_length} characters"
    )
    |> validate_length(:email,
      max: @max_email_length,
      message: "that's a bit long — trim it to #{@max_email_length} characters"
    )
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/, message: "needs an @ in it")
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Attaches the screen the sender came from — **only** when they left the box ticked.

  Called by `Consensus.Feedback.submit/2` after `changeset/2`, so `include_page` has
  already been cast from the form. A `nil` path (a direct visit to `/feedback` with no
  `return_to`) attaches nothing whatever the box says, because there is nothing to
  attach and the row is not rendered on that visit.
  """
  def put_page_path(changeset, path) do
    case get_field(changeset, :include_page) && safe_page_path(path) do
      path when is_binary(path) -> put_change(changeset, :page_path, path)
      _ -> put_change(changeset, :page_path, nil)
    end
  end

  @doc """
  The path when it is safe to store *and* to render as a link, `nil` otherwise.

  `page_path` is the one column here written from a query parameter, and it is the one
  that is later rendered as an `href` on `/admin/feedback` — so a hostile value planted by
  an unauthenticated stranger becomes an off-site link on a page an administrator is
  invited to click. This is the guard on the way in.

  `ConsensusWeb.CurrentPath.safe_return_to/1` already rejects a literal `//` and `/\\`
  prefix, and that is not sufficient on its own: the WHATWG URL parser strips every ASCII
  tab, LF and CR from a URL *before* resolving it, so `"/\\t/evil.example/x"` survives a
  prefix check and then resolves as `//evil.example/x` — protocol-relative, off-site.
  Nothing legitimate in this app produces a path containing whitespace, a control
  character or a backslash, so all three are refused outright rather than escaped.
  """
  def safe_page_path(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") -> nil
      # Whitespace, C0/C1 controls and DEL. Note this must not be a `\A/[^/\\]` shape
      # check: `"/"` on its own is the single most frequently captured path, since the
      # footer's faces are tapped from the home page more than anywhere else.
      String.match?(path, ~r/[\x00-\x20\x7F\\]/) -> nil
      String.starts_with?(path, "//") -> nil
      true -> path
    end
  end

  def safe_page_path(_path), do: nil

  @doc """
  Changeset for the two things `/admin/feedback` may write.

  Separate from `changeset/2`, and narrow, for the reason
  `Consensus.Accounts.User.admin_changeset/2` is: an admin-only endpoint must not be
  able to smuggle an edit to the sender's own words through the same `cast/3` that
  marks a row read.

  `read_at` is `nil`-able on purpose — that is how "mark as unread" works.
  """
  def admin_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:read_at, :admin_note])
    |> update_change(:admin_note, &blank_to_nil/1)
    |> validate_length(:admin_note, max: @max_admin_note_length)
  end

  @doc """
  What to show for the sender: the name they typed, or their account's username.

  The fallback is **not** "signed out": `/admin/feedback` already prints signed-in /
  signed-out on its own metadata line, and a card that says "signed out" twice is one
  slot carrying no information. This slot answers "who", the other answers "were they
  logged in".
  """
  def sender_label(%__MODULE__{name: name}) when is_binary(name), do: name
  def sender_label(%__MODULE__{user: %Consensus.Accounts.User{username: name}}), do: name
  def sender_label(%__MODULE__{}), do: "no name given"

  @doc "True once an admin has marked this read."
  def read?(%__MODULE__{read_at: nil}), do: false
  def read?(%__MODULE__{}), do: true

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
