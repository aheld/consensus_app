defmodule Consensus.Dev.ScriptedProvider do
  @moduledoc """
  A dev-only `Consensus.Discovery.Provider` that answers from canned,
  **query-keyed** data, for driving the Assisted Add UI in a browser without
  hitting (and without the latency/flakiness of) the public Overpass instance.

  It is the registered `"restaurant"` provider in `config/dev.exs`. Start the
  app (`mix phx.server`), create a group, and on `02 add options` type one of
  the queries below and press Add. Every state the frame draws — and every
  silent failure it deliberately doesn't — is reachable by typing alone, so a
  pixel pass never needs IEx or a config edit.

  ## Query vocabulary

  Matching is case-insensitive substring on the typed name, first hit in this
  order wins:

  | Type…                  | Get…                                                        |
  |------------------------|-------------------------------------------------------------|
  | anything with `slow`   | the three-match trio after `slow_ms` (default 5000ms) — holds the 02b shimmer long enough to screenshot it |
  | anything with `error`  | `{:error, :provider_error}` — must render NOTHING           |
  | anything with `timeout`| `{:error, :timeout}` — must render NOTHING                  |
  | anything with `zahav`  | one match: Zahav · 237 St James Pl · israeli · real website |
  | anything with `trio`   | three matches (frame 02d, exact): Vernick Food & Drink / Vernick Fish / Vernick Coffee Bar |
  | anything with `vernick`| one match (frame 02c, exact): Vernick Food & Drink · American chip · 2031 Walnut St · real website |
  | anything else          | `{:ok, []}` — no match, the silence path                    |

  (Typing plain `Vernick` — the frame's own typed card — reproduces the 02c
  one-match state with the exact canonical name `Vernick Food & Drink`; the full
  canonical name contains `vernick` too, so it lands on the same state. The 02d
  trio moved to `trio` so both frame states stay reachable by typing alone.)

  Every non-`slow` answer waits `delay_ms` first (default 900ms — long enough to
  see the 02b shimmer at all). Both delays are config, overridable at runtime:

      Application.put_env(:consensus, Consensus.Dev.ScriptedProvider,
        delay_ms: 0, slow_ms: 10_000)

  The two `website_url`s (`vernickphilly.com`, `zahavrestaurant.com`) are the
  venues' real sites, so `Use this` on either one-match state drives the real
  `Consensus.LinkPreview` enrichment — the 02e violet interval settles into a
  genuinely fetched photo/description.

  The area prompt (02f) still geocodes against the real Nominatim in dev — one
  submit-only request, within its usage policy.

  To drive the **real** Overpass adapter instead, start dev with `ASSIST_LIVE=1`
  (`config/runtime.exs` swaps the registry back to
  `Consensus.Discovery.Provider.Overpass`).

  Compiled in `:dev` only (`elixirc_paths` in `mix.exs`) — this module does not
  exist in prod or test.
  """

  @behaviour Consensus.Discovery.Provider

  alias Consensus.Discovery.Result

  # Frame 02c/02d's exact sample content (frame-review §c): name + street address
  # (+ a cuisine chip that only the one-match shape renders), nothing the licence
  # forbids. Philadelphia venues, like the frame's.
  @vernick_food %Result{
    name: "Vernick Food & Drink",
    website_url: "https://www.vernickphilly.com",
    source: :scripted,
    external_ref: nil,
    chips: [{"cuisine", "american"}],
    address: "2031 Walnut St"
  }

  @vernick_trio [
    @vernick_food,
    %Result{
      name: "Vernick Fish",
      website_url: nil,
      source: :scripted,
      external_ref: nil,
      chips: [{"cuisine", "seafood"}],
      address: "1 N 19th St"
    },
    %Result{
      name: "Vernick Coffee Bar",
      website_url: nil,
      source: :scripted,
      external_ref: nil,
      chips: nil,
      address: "1 N 19th St"
    }
  ]

  @zahav %Result{
    name: "Zahav",
    website_url: "https://www.zahavrestaurant.com",
    source: :scripted,
    external_ref: nil,
    chips: [{"cuisine", "israeli"}],
    address: "237 St James Pl"
  }

  @impl true
  def search(query, _area, _opts) do
    normalized = query |> String.trim() |> String.downcase()

    cond do
      normalized =~ "slow" ->
        Process.sleep(slow_ms())
        {:ok, @vernick_trio}

      normalized =~ "error" ->
        answer({:error, :provider_error})

      normalized =~ "timeout" ->
        answer({:error, :timeout})

      normalized =~ "zahav" ->
        answer({:ok, [@zahav]})

      normalized =~ "trio" ->
        answer({:ok, @vernick_trio})

      # Plain "Vernick" is the frame's own typed card, and 02c is the state it
      # draws for it: ONE match, canonical name "Vernick Food & Drink".
      normalized =~ "vernick" ->
        answer({:ok, [@vernick_food]})

      true ->
        answer({:ok, []})
    end
  end

  @impl true
  def cache_policy do
    # :none keeps every dev interaction fresh — the same query re-runs its state
    # on the very next Add instead of answering from a cache TTL.
    %{ttl_ms: :none, error_ttl_ms: 1_000, may_store_results?: true}
  end

  @impl true
  def attribution do
    # Mirrors the design frame's attribution line so pixel work matches 02c–02f:
    # only the contributors phrase is the link, the prefix stays plain text.
    %{
      prefix: "Places from ",
      text: "OpenStreetMap contributors",
      url: "https://opendatacommons.org/licenses/odbl/"
    }
  end

  @impl true
  def location_mode, do: :optional

  defp answer(reply) do
    case delay_ms() do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end

    reply
  end

  defp delay_ms, do: config(:delay_ms, 900)
  defp slow_ms, do: config(:slow_ms, 5_000)

  defp config(key, default) do
    :consensus
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
