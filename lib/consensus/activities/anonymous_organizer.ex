defmodule Consensus.Activities.AnonymousOrganizer do
  @moduledoc """
  An organizer with no account: one browser, one row, any number of groups (D-058).

  *Anonymous* here means **has no account**. It is unrelated to
  `Consensus.Activities.Group`'s `anonymous` field, which is voting secrecy (D-035).

  The browser holds a server-minted 32-byte token in its own signed cookie; this row
  holds only `:crypto.hash(:sha256, token)` in `token_hash`, and lookups go by digest —
  the `users_tokens` precedent. That is deliberately **unlike** `participants.token`,
  which is stored raw: D-045 calls a participant token a ballot receipt that authorizes
  nothing an attacker wants, while this one can cancel a session, close it early, break
  a tie or reopen it. Do not "fix" the inconsistency. `token_hash` is `redact: true` so
  it never reaches an inspected struct or a log line.

  `display_name` is optional and self-chosen — not unique, not verified, and no screen
  may present it as verified. `nil` means guests see "the organizer". It lives on the
  person rather than the group so a third session does not ask again, and it is
  therefore retroactive across that organizer's unclaimed sessions (D-058).

  A row is **claimed** when `claimed_at` is set, never when `claimed_by_user_id` is:
  that column is `on_delete: :nilify_all`, so deleting the claiming account would
  otherwise make a claimed row look unclaimed again. After a claim the row owns nothing;
  it is history.

  Every field here is written programmatically by `Consensus.Activities` except
  `display_name`, which is the only thing `display_name_changeset/2` casts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_display_name_length 40
  @token_hash_bytes 32

  # Every control (Cc: C0, DEL, C1) and every format character (Cf), plus the Hangul
  # fillers and the Braille blank, which are letters or symbols to Unicode but render as
  # nothing. Cf covers the bidi controls (ALM, LRM/RLM, the LRE…RLO embeddings and
  # overrides, the LRI…PDI isolates) and every zero-width character — ZWSP, ZWNJ, word
  # joiner, BOM, soft hyphen, the Mongolian vowel separator. A name is rendered to guests
  # on the invite page and in the link preview: a right-to-left override in it can make
  # the surrounding sentence read as something else, and an invisible one can make it
  # read as no name at all, or as somebody else's. The same spirit as
  # `Consensus.Feedback.Entry.safe_page_path/1`: nothing a person legitimately types as
  # their name contains one, so they are refused rather than stripped.
  #
  # Also the combining grapheme joiner (U+034F) and every variation selector (U+FE00–FE0F,
  # U+E0100–E01EF). Those are marks (Mn), not format characters, so `\p{Cf}` misses them,
  # but they draw nothing either: alone they render as a blank name, and after a letter
  # they ride along unseen and can carry hidden bytes. The two a keyboard produces — the
  # text and emoji presentation selectors U+FE0E/U+FE0F — are let back in below, inside an
  # emoji or a keycap only.
  @forbidden ~r/[\p{Cc}\p{Cf}\x{115F}\x{1160}\x{3164}\x{FFA0}\x{2800}\x{034F}\x{FE00}-\x{FE0F}\x{E0100}-\x{E01EF}]/u

  # The two Cf characters a person *does* type: the zero-width joiner (U+200D), which is
  # how a keyboard spells a family emoji, and the tag characters (U+E0020–U+E007F), which
  # spell the flag of Scotland. A ZWJ is allowed only inside a grapheme that starts with a
  # pictograph — between two letters it is exactly the invisible character the rule above
  # exists to refuse. Tags are narrower still: they draw something only in the one form
  # Unicode defines, a black flag (U+1F3F4) followed by tags and closed by the cancel tag
  # (U+E007F). After any other emoji they draw nothing and would carry hidden text.
  @zero_width_joiner ~r/\x{200D}/u
  @tag_characters ~r/[\x{E0020}-\x{E007F}]/u
  @tag_flag ~r/\A\x{1F3F4}[\x{E0020}-\x{E007E}]+\x{E007F}\z/u
  @pictograph_first ~r/\A\p{Extended_Pictographic}/u
  @presentation_selectors ~r/[\x{FE0E}\x{FE0F}]/u
  @keycap ~r/\A[0-9#*]\x{FE0F}?\x{20E3}\z/u

  # The grapheme cap alone does not bound size: one grapheme can carry any number of
  # combining marks (a "Zalgo" stack that draws over the lines around it) and still count
  # as one. So the name is also capped in codepoints, and each grapheme in how many
  # codepoints it may hold. The longest emoji a keyboard produces — a skin-toned couple
  # or family — is 10–11 codepoints; the deepest real stack of marks on a letter
  # (Vietnamese, Tibetan, an Indic conjunct) stays well under 8.
  @max_display_name_codepoints 4 * @max_display_name_length
  @max_text_grapheme_codepoints 8
  @max_emoji_grapheme_codepoints 12

  # Separators String.split/1 does not treat as whitespace: the no-break spaces (U+00A0,
  # U+2007, U+202F) are Zs to Unicode but not whitespace to Elixir.
  @separators ~r/[\s\p{Z}]+/u

  @doc """
  Longest display name an anonymous organizer may set, in graphemes.

  Its own constant, deliberately not `Consensus.Voting.Participant.max_display_name_length/0`
  even though both are 40 today: the two names are shown in different places and need
  not move together. Public for the same reason `Activity.max_description_length/0` is —
  the on-screen counter and this changeset must read the same number (invariant 11).
  """
  def max_display_name_length, do: @max_display_name_length

  schema "anonymous_organizers" do
    field :token_hash, :binary, redact: true
    field :display_name, :string
    field :claimed_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    belongs_to :claimed_by_user, Consensus.Accounts.User

    has_many :groups, Consensus.Activities.Group

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for minting a new identity from the digest of its token.

  Takes the hash, not attrs: the token is generated by `Consensus.Activities`, never
  typed, so there is nothing to `cast/3`. The 32-byte length is enforced here because
  ecto_sqlite3 ignores `size:` on a `:binary` column — a hash of any other length means
  the caller hashed the wrong thing (or did not hash at all), and storing it would make
  the identity unreachable by digest lookup. `last_seen_at` starts at now.
  """
  def creation_changeset(organizer \\ %__MODULE__{}, token_hash) do
    organizer
    |> change(token_hash: token_hash, last_seen_at: DateTime.utc_now(:second))
    |> validate_required([:token_hash, :last_seen_at])
    |> validate_change(:token_hash, fn :token_hash, hash ->
      if is_binary(hash) and byte_size(hash) == @token_hash_bytes,
        do: [],
        else: [token_hash: "must be a #{@token_hash_bytes}-byte digest"]
    end)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Changeset for the optional name guests see, and nothing else.

  Casts exactly `[:display_name]`. The value is trimmed and every run of internal
  whitespace or Unicode separator (a pasted tab, newline or no-break space included)
  collapses to one space; a value that is blank after that becomes `nil`, so "left it
  blank" has one representation. A value that still contains a control, format,
  zero-width or other invisible character (outside an emoji sequence), or is not valid
  UTF-8, is refused rather than silently cleaned — so no stored name renders as nothing.
  `validate_length/3` counts graphemes, and it is the real cap — the field carries no
  `maxlength` (invariant 11). Because one grapheme can hold unboundedly many combining
  marks, a codepoint cap and a per-grapheme codepoint cap sit behind it; nothing a person
  types as a name reaches either.
  """
  def display_name_changeset(organizer, attrs) do
    organizer
    |> cast(attrs, [:display_name])
    |> update_change(:display_name, &normalize_display_name/1)
    |> validate_change(:display_name, fn :display_name, name ->
      if String.valid?(name) and not invisible_characters?(name),
        do: [],
        else: [display_name: "can't contain invisible or text-direction characters"]
    end)
    |> validate_change(:display_name, fn :display_name, name ->
      if String.valid?(name) and overloaded_grapheme?(name),
        do: [display_name: "can't stack that many marks on one character"],
        else: []
    end)
    |> validate_length(:display_name, max: @max_display_name_length)
    |> validate_length(:display_name,
      max: @max_display_name_codepoints,
      count: :codepoints,
      message: "is too long"
    )
  end

  # Invalid UTF-8 is passed through untouched so the validation above refuses it;
  # `String.split/1` on it would not split where a reader expects.
  defp normalize_display_name(name) when is_binary(name) do
    if String.valid?(name) do
      case name |> String.split(@separators, trim: true) |> Enum.join(" ") do
        "" -> nil
        collapsed -> collapsed
      end
    else
      name
    end
  end

  defp normalize_display_name(name), do: name

  defp invisible_characters?(name) do
    name
    |> String.graphemes()
    |> Enum.any?(fn grapheme ->
      grapheme =
        cond do
          String.match?(grapheme, @tag_flag) ->
            String.replace(grapheme, @tag_characters, "")

          String.match?(grapheme, @pictograph_first) ->
            grapheme
            |> String.replace(@zero_width_joiner, "")
            |> String.replace(@presentation_selectors, "")

          String.match?(grapheme, @keycap) ->
            String.replace(grapheme, @presentation_selectors, "")

          true ->
            grapheme
        end

      String.match?(grapheme, @forbidden)
    end)
  end

  defp overloaded_grapheme?(name) do
    name
    |> String.graphemes()
    |> Enum.any?(fn grapheme ->
      max =
        if String.match?(grapheme, @pictograph_first),
          do: @max_emoji_grapheme_codepoints,
          else: @max_text_grapheme_codepoints

      length(String.codepoints(grapheme)) > max
    end)
  end
end
