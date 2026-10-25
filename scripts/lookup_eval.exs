# The Assisted Add's live acceptance gate (docs/plans/nominatim-lookup.md §6).
#
#     ASSIST_LIVE=1 mix run scripts/lookup_eval.exs
#
# Calls Consensus.Discovery.search/3 through the REAL registry, cache and rate gate,
# against the real upstream, for a fixed set of names in two areas, and prints the hit
# rate. Committed so the next provider change re-runs the same set and the decision
# rests on a measurement rather than on anybody's account of one afternoon.
#
# Without ASSIST_LIVE=1 dev's registry is the scripted provider and the numbers mean
# nothing; the script refuses rather than print them. Needs network. Makes ~20 upstream
# requests, sequentially, inside the provider's own rate limit.
#
# A "hit" is the expected OSM name appearing anywhere in the (at most 3) results,
# compared case-insensitively. `:miss_expected` rows are names the plan predicts no
# provider can answer (§8: a typo, and free text around the name); they are reported
# but not counted against the bar.

alias Consensus.Discovery
alias Consensus.Discovery.Geocoder

unless System.get_env("ASSIST_LIVE") == "1" do
  IO.puts(:stderr, "Refusing: run with ASSIST_LIVE=1 so the real provider answers.")
  System.halt(1)
end

areas = %{
  "Philadelphia" => "Philadelphia, PA",
  "Fishtown" => "Fishtown, Philadelphia"
}

# {type, area key, typed name, expected OSM name, :hit_expected | :miss_expected}
fixtures = [
  {"restaurant", "Philadelphia", "Zahav", "Zahav", :hit_expected},
  {"restaurant", "Philadelphia", "Vernick", "Vernick Food & Drink", :hit_expected},
  {"restaurant", "Philadelphia", "Beddia Pizzeria", "Pizzeria Beddia", :hit_expected},
  {"restaurant", "Philadelphia", "Federal Donuts", "Federal Donuts", :hit_expected},
  {"restaurant", "Philadelphia", "Shake Shack", "Shake Shack", :hit_expected},
  {"restaurant", "Philadelphia", "Cafe La Maude", "Cafe La Maude", :hit_expected},
  {"restaurant", "Philadelphia", "Joes Pizza", "Joe's Pizza", :hit_expected},
  {"restaurant", "Philadelphia", "Dizengof", "Dizengoff", :miss_expected},
  {"restaurant", "Philadelphia", "dinner at Zahav", "Zahav", :miss_expected},
  {"restaurant", "Fishtown", "Suraya", "Suraya", :hit_expected},
  {"restaurant", "Fishtown", "Beddia", "Pizzeria Beddia", :hit_expected},
  {"restaurant", "Fishtown", "Mulherin's", "Wm. Mulherin's Sons", :hit_expected},
  {"bar", "Fishtown", "Johnny Brenda's", "Johnny Brenda's Tavern", :hit_expected}
]

provider =
  case Application.get_env(:consensus, Consensus.Discovery)[:providers]["restaurant"] do
    {module, _opts} -> inspect(module)
    other -> inspect(other)
  end

IO.puts("Provider: #{provider}\n")

resolved_areas =
  Map.new(areas, fn {key, string} ->
    case Geocoder.geocode(string) do
      {:ok, area} ->
        IO.puts("area #{key}: #{area.name} #{Consensus.Discovery.Area.encode_bbox(area)}")
        {key, area}

      {:error, reason} ->
        IO.puts("area #{key}: geocode FAILED #{inspect(reason)}")
        {key, nil}
    end
  end)

IO.puts("")

rows =
  for {type, area_key, typed, expected, expectation} <- fixtures do
    started = System.monotonic_time(:millisecond)
    answer = Discovery.search(type, typed, resolved_areas[area_key])
    elapsed = System.monotonic_time(:millisecond) - started

    {verdict, detail} =
      case answer do
        {:ok, results} ->
          names = Enum.map(results, & &1.name)
          hit? = Enum.any?(names, &(String.downcase(&1) == String.downcase(expected)))
          {if(hit?, do: :hit, else: :miss), inspect(names)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end

    mark = if verdict == :hit, do: "✅", else: "❌"

    IO.puts(
      "#{mark} #{String.pad_trailing(type, 10)} #{String.pad_trailing(area_key, 12)} " <>
        "#{String.pad_trailing(inspect(typed), 20)} #{String.pad_leading("#{elapsed}", 6)}ms  " <>
        detail
    )

    {expectation, verdict}
  end

counted = Enum.filter(rows, fn {expectation, _} -> expectation == :hit_expected end)
hits = Enum.count(counted, fn {_, verdict} -> verdict == :hit end)
errors = Enum.count(rows, fn {_, verdict} -> verdict == :error end)

surprises =
  Enum.count(rows, fn {expectation, verdict} ->
    expectation == :miss_expected and verdict == :hit
  end)

IO.puts("""

#{hits} of #{length(counted)} expected hits found \
(#{errors} upstream errors; #{surprises} expected misses hit anyway).
""")
