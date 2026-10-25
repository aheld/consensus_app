defmodule Consensus.Activities.AnonymousOrganizerTest do
  # Changesets only; nothing here touches the database. DataCase for `errors_on/1`.
  use Consensus.DataCase, async: true

  alias Consensus.Activities.AnonymousOrganizer

  # Every invisible character below is written as an escape, never pasted literally: a
  # test about characters a reader cannot see should not itself contain any.

  describe "creation_changeset/2" do
    test "accepts a SHA-256 digest and starts last_seen_at at now" do
      changeset = AnonymousOrganizer.creation_changeset(:crypto.hash(:sha256, "x"))

      assert changeset.valid?
      assert %DateTime{} = last_seen_at = get_change(changeset, :last_seen_at)
      assert DateTime.diff(DateTime.utc_now(), last_seen_at) in 0..5
    end

    # Anything else is a caller that hashed the wrong thing or did not hash at all, and a
    # row stored with it could never be found again by digest lookup.
    test "refuses anything that is not a 32-byte digest" do
      raw_token = :crypto.strong_rand_bytes(32)

      for hash <- [
            :crypto.strong_rand_bytes(31),
            :crypto.strong_rand_bytes(33),
            Base.encode64(raw_token),
            Base.url_encode64(raw_token, padding: false)
          ] do
        assert %{token_hash: ["must be a 32-byte digest"]} =
                 errors_on(AnonymousOrganizer.creation_changeset(hash)),
               "a #{byte_size(hash)}-byte value was accepted"
      end
    end

    test "refuses a missing digest" do
      assert %{token_hash: ["can't be blank"]} =
               errors_on(AnonymousOrganizer.creation_changeset(nil))
    end
  end

  describe "display_name_changeset/2" do
    defp display_name(value) do
      AnonymousOrganizer.display_name_changeset(%AnonymousOrganizer{}, %{display_name: value})
    end

    test "trims and collapses whitespace, including no-break spaces" do
      changeset = display_name("  Ada \t\n Lovelace\u00A0\u202FJr  ")

      assert changeset.valid?
      assert get_change(changeset, :display_name) == "Ada Lovelace Jr"
    end

    test "a blank value becomes nil, however it is spelled" do
      for blank <- ["", "   ", "\t\n", "\u00A0", "\u2007\u3000"] do
        changeset =
          AnonymousOrganizer.display_name_changeset(
            %AnonymousOrganizer{display_name: "Ada"},
            %{display_name: blank}
          )

        assert changeset.valid?, "#{inspect(blank)} was refused"
        assert get_change(changeset, :display_name) == nil, "#{inspect(blank)} was kept"
      end
    end

    # The blank-means-nil rule only works if a name nobody can see cannot be stored: a
    # guest would otherwise read " invited you" with no name and no "the organizer".
    test "refuses a name made only of invisible characters" do
      for invisible <- [
            "\u200B",
            "\u200B\u2060\uFEFF",
            "\u3164",
            "\u115F\u1160",
            "\uFFA0",
            "\u2800",
            "\u00AD",
            "\u200D",
            "\u{E0041}"
          ] do
        assert %{display_name: ["can't contain invisible or text-direction characters"]} =
                 errors_on(display_name(invisible)),
               "#{inspect(invisible)} was accepted"
      end
    end

    # The invariant itself, independent of which branch a character takes: PCRE counts
    # U+180E as whitespace (so it collapses to nil) where Unicode now calls it Cf (so it
    # would be refused). Either is fine; a stored name that renders as nothing is not.
    test "never stores a name that renders as nothing" do
      for invisible <- ["\u180E", "\u200B", "\u3164", "\u00A0\u200D", "\u2800\u00A0"] do
        changeset = display_name(invisible)

        refute changeset.valid? and get_change(changeset, :display_name) != nil,
               "#{inspect(invisible)} was stored"
      end
    end

    test "refuses an invisible character hidden inside a real-looking name" do
      for name <- ["Al\u200Bice", "Al\u200Dice", "Alice\u2060", "\uFEFFAlice", "Ali\u00ADce"] do
        refute display_name(name).valid?, "#{inspect(name)} was accepted"
      end
    end

    test "refuses control and text-direction characters" do
      for name <- ["Ada\u0000", "Ada\u0007", "Ada\u009B", "Ada\u202Eevil", "\u2066Ada\u2069"] do
        refute display_name(name).valid?, "#{inspect(name)} was accepted"
      end
    end

    test "accepts an emoji sequence joined by ZWJ or tag characters" do
      family = "\u{1F469}\u200D\u{1F469}\u200D\u{1F467}"
      scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"

      for name <- ["Ada #{family}", scotland, "Jos\u00E9", "\u674E\u96F7", "\uD55C\uAD6D"] do
        changeset = display_name(name)
        assert changeset.valid?, "#{inspect(name)} was refused"
        assert get_change(changeset, :display_name) == name
      end
    end

    # Variation selectors and the combining grapheme joiner are marks, not format
    # characters, so a Cf-only rule misses them — yet they draw nothing.
    test "refuses variation selectors and the grapheme joiner outside an emoji" do
      for name <- [
            "️",
            "͏",
            "Sam️",
            "S͏am",
            "Sam︀",
            "Sam\u{E0100}\u{E0101}",
            "\u{1F600}\u{E0100}"
          ] do
        assert %{display_name: ["can't contain invisible or text-direction characters"]} =
                 errors_on(display_name(name)),
               "#{inspect(name)} was accepted"
      end
    end

    test "accepts presentation selectors where a keyboard puts them" do
      for name <- ["Ada ❤️", "Team 1️⃣", "☺︎ Bo"] do
        changeset = display_name(name)
        assert changeset.valid?, "#{inspect(name)} was refused"
      end
    end

    # Tag characters draw something only as a black flag closed by the cancel tag. After
    # any other emoji they render as nothing and would smuggle text into the name.
    test "refuses tag characters outside the flag form" do
      for name <- [
            "\u{1F600}\u{E0041}\u{E0042}",
            "Sam\u{1F600}\u{E0068}\u{E0069}\u{E0064}\u{E0065}\u{E007F}",
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}",
            "\u{1F3F4}\u{E007F}"
          ] do
        assert %{display_name: ["can't contain invisible or text-direction characters"]} =
                 errors_on(display_name(name)),
               "#{inspect(name)} was accepted"
      end
    end

    # One grapheme can hold any number of combining marks or tags and still count as one
    # against the grapheme cap, so the cap alone would let a name of any size through.
    test "refuses a grapheme carrying an unbounded run of marks or tags" do
      zalgo = "a" <> String.duplicate("́", 1000)
      tag_run = "\u{1F600}" <> String.duplicate("\u{E0041}", 1000)

      for name <- [zalgo, tag_run, "Ada " <> zalgo] do
        changeset = display_name(name)
        assert String.length(name) <= AnonymousOrganizer.max_display_name_length()
        refute changeset.valid?, "a #{byte_size(name)}-byte name was accepted"
      end

      assert "can't stack that many marks on one character" in errors_on(display_name(zalgo)).display_name
    end

    test "refuses a name too long in codepoints even when no grapheme is overloaded" do
      # 40 graphemes of base + 7 marks: each under the per-grapheme cap, 320 codepoints.
      name = String.duplicate("a" <> String.duplicate("́", 7), 40)

      assert String.length(name) == AnonymousOrganizer.max_display_name_length()
      assert "is too long" in errors_on(display_name(name)).display_name
    end

    test "accepts real stacked marks and long emoji sequences" do
      skin_toned_kiss =
        "\u{1F469}\u{1F3FB}‍❤️‍\u{1F48B}‍\u{1F468}\u{1F3FC}"

      for name <- [
            "Nguyễn",
            "न्त्र",
            "Ada #{skin_toned_kiss}"
          ] do
        assert display_name(name).valid?, "#{inspect(name)} was refused"
      end
    end

    test "refuses invalid UTF-8" do
      refute display_name(<<0xFF, 0xFE>>).valid?
    end

    test "caps the name at the public maximum, in graphemes" do
      max = AnonymousOrganizer.max_display_name_length()

      assert display_name(String.duplicate("\u00E9", max)).valid?
      refute display_name(String.duplicate("a", max + 1)).valid?
    end
  end
end
