defmodule Consensus.ActivityTypeInvariantTest do
  @moduledoc """
  Source-text pin for CLAUDE.md invariant 12: `activity_type` is data, never a branch.

  This is Stage 0a of docs/research/activity-discovery.md §5 — the research's own
  verdict is "if only one thing from this document is built, build that test". The
  invariant is easy to state and easy to erode: one `case group.activity_type do`
  in a LiveView, one `%{activity_type: "restaurant"}` function head in a context,
  and the engine stops being activity-agnostic while every behavioural test stays
  green. Nothing at runtime can notice, because with one real activity type the
  branch and the non-branch are extensionally identical. So we pin the *source*,
  in the same idiom as `deploy_config_test.exs`: read the files as text, assert
  the shape, fail with instructions.

  Two layers:

    1. **No branching construct on `activity_type` anywhere under `lib/`.** A
       `case` on it, a comparison against it, an `in`-list membership test, or a
       pattern match binding it to a string literal — each is the rejected shape
       research §4.4 spells out. The accepted shape is a `Map.get/3` over a
       config registry, which none of these patterns match.

    2. **A mention allowlist.** Files may say `activity_type` only if they are
       listed here. A new legitimate use (the Discovery registry lookup, a
       display helper) extends the allowlist *in the same commit*, which forces
       the diff to say out loud that a new file now knows the field exists —
       exactly the moment a reviewer should look for layer 1's patterns by hand.
       The literal `"restaurant"` gets the same treatment, tighter: only the
       schema that declares it as a default may spell it.

  Comment lines (leading `#`) are exempt from layer 1 — prose *about* the
  invariant may quote the rejected shape, and two files do.
  """

  use ExUnit.Case, async: true

  # Files that may mention `activity_type` at all. Extend deliberately, with a
  # reason, in the same commit that adds the mention.
  @mention_allowlist %{
    "lib/consensus/activities/group.ex" => "the schema: field, cast, moduledoc",
    "lib/consensus_web/live/group_live/options.ex" =>
      "display (String.capitalize/1) + the registry-lookup pattern: the value is handed " <>
        "opaquely to Consensus.Discovery (search/3's first argument, membership in " <>
        "available_types/0, attribution_for/1) for the Assisted Add — never compared, " <>
        "matched or branched on",
    "lib/consensus_web/live/endgame/all_vetoed.ex" => "a comment citing the invariant",
    "lib/consensus/discovery.ex" =>
      "the registry lookup itself: an opaque Map.get/3 key, per research §4.4",
    "lib/consensus/discovery/telemetry.ex" =>
      "observability only: the value is copied verbatim into :telemetry span " <>
        "metadata and rendered with to_string/1 into a log line — never compared, " <>
        "matched or branched on. A log line about a value is the weakest possible " <>
        "coupling to it"
  }

  # Files that may contain the string literal "restaurant". The column default
  # lives here and nowhere else in lib/ — per-type knowledge belongs in config
  # (the Discovery provider registry reads it as a Map key), never in code.
  @restaurant_literal_allowlist [
    "lib/consensus/activities/group.ex"
  ]

  # The rejected shapes from research §4.4, as line-level patterns. Kept
  # deliberately narrow: `Map.get(registry, type)` — the accepted shape — matches
  # none of them.
  @branch_patterns [
    {~r/\bcase\b[^\n]*activity_type/, "a `case` on activity_type"},
    {~r/activity_type\s*(==|!=|===|!==)/, "a comparison against activity_type"},
    {~r/(==|!=|===|!==)\s*\S*activity_type/, "a comparison against activity_type"},
    {~r/activity_type\s+in\s+\[/, "an `in`-list membership test on activity_type"},
    {~r/activity_type:\s*"/, "a pattern match binding activity_type to a literal"}
  ]

  defp lib_sources do
    Path.wildcard("lib/**/*.{ex,exs,heex}")
    |> Enum.map(&{&1, File.read!(&1)})
  end

  test "no code under lib/ branches on activity_type" do
    offences =
      for {path, source} <- lib_sources(),
          {line, number} <- numbered_code_lines(source),
          {pattern, label} <- @branch_patterns,
          Regex.match?(pattern, line),
          uniq: true do
        "#{path}:#{number}: #{label}\n      #{String.trim(line)}"
      end

    assert offences == [], """
    CLAUDE.md invariant 12: the engine is activity-agnostic — `activity_type` is
    data, never a branch. These lines look like the rejected shape from
    docs/research/activity-discovery.md §4.4:

    #{Enum.join(offences, "\n")}

    The accepted shape is a registry lookup — per-type behaviour lives as data in
    `config :consensus, Consensus.Discovery, providers: %{...}` and is read with
    `Map.get/3`. If a line above is genuinely not a branch (say, a new display
    helper), restructure it so it does not pattern-match or compare the value; do
    not add an exemption mechanism to this test.
    """
  end

  test "files mentioning activity_type stay on the allowlist" do
    mentioning =
      for {path, source} <- lib_sources(), String.contains?(source, "activity_type"), do: path

    unlisted = mentioning -- Map.keys(@mention_allowlist)

    assert unlisted == [], """
    New file(s) under lib/ mention `activity_type`:

    #{Enum.map_join(unlisted, "\n", &"    #{&1}")}

    That may be fine — a registry lookup, a display helper — but invariant 12
    says the mention must be deliberate. Read the new usage, confirm it treats
    the value as opaque data (no case/comparison/literal match; the sibling test
    checks the known shapes but cannot see every disguise), then add the file to
    @mention_allowlist in #{__ENV__.file |> Path.relative_to_cwd()} with a short
    reason, in this same commit.
    """

    stale = Map.keys(@mention_allowlist) -- mentioning

    assert stale == [], """
    Allowlisted file(s) no longer mention `activity_type` (or no longer exist):

    #{Enum.map_join(stale, "\n", &"    #{&1}")}

    Remove them from @mention_allowlist so the list stays an honest inventory.
    """
  end

  test "the literal \"restaurant\" appears only where the schema declares the default" do
    offending =
      for {path, source} <- lib_sources(),
          String.contains?(source, ~s("restaurant")),
          path not in @restaurant_literal_allowlist,
          do: path

    assert offending == [], """
    The string literal "restaurant" appeared under lib/ outside the schema:

    #{Enum.map_join(offending, "\n", &"    #{&1}")}

    Per-type knowledge is config data (the Discovery provider registry), never a
    literal in code — a spelled-out type name in lib/ is how a branch starts.
    UI copy saying the word (capital-R "Restaurant") is fine and does not match
    this check; a lowercase quoted literal is the machine-readable form and is
    what this test rejects.
    """
  end

  # Lines with their 1-based numbers, comment lines dropped: prose about the
  # invariant may quote the rejected shape (two files do, in # comments).
  # @moduledoc strings survive filtering, deliberately — a branch cannot hide in
  # one, and the patterns above do not match prose.
  defp numbered_code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim_leading(line), "#") end)
  end
end
