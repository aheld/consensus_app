defmodule Consensus.Discovery do
  @moduledoc """
  Name lookup against a free places index, powering the assisted-add flow on
  `02 add options` (docs/design/assisted-add-ux-brief.md; architecture from
  docs/research/activity-discovery.md §4.2–§4.4).

  Which adapter answers for a given activity type is **data in config**, read
  with `Map.get/3` and never branched on — CLAUDE.md product invariant 2, pinned
  by `test/consensus/activity_type_invariant_test.exs`:

      config :consensus, Consensus.Discovery,
        providers: %{
          "bowling" => {SomeProvider, tags: [{"leisure", "bowling_alley"}]}
        }

  In dev/prod the registry resolves four types to
  `Consensus.Discovery.Provider.Overpass` — one module, four different tag
  lists (see `config/config.exs`) — and a type with no entry is a
  **normal state, not an error**:
  `search/3` answers `{:ok, []}` and the typed/paste path stands, which is what
  makes the whole feature optional (research §4.1, "Discovery is never
  load-bearing").

  `search/3` never raises. Every failure — an adapter that raises, a malformed
  registry entry, a provider answering garbage — comes back as a tagged tuple,
  per `Consensus.LinkPreview.fetch/1`'s contract. Results are capped at
  3 before return (the brief: never more than 3 suggestion rows), and cached
  in `Consensus.Discovery.Cache` per the adapter's `cache_policy/0` — a
  `ttl_ms: :none` policy bypasses the cache entirely, and errors are cached on
  the policy's separate (shorter) error TTL.

  Like `Consensus.LinkPreview.fetch/1`, `search/3` and
  `Consensus.Discovery.Geocoder.geocode/1` make network requests with
  multi-second budgets: CLAUDE.md invariant 13 applies verbatim — call them from
  `start_async/3`, never inline in a `handle_event`.
  """

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Cache
  alias Consensus.Discovery.Result

  require Logger

  @results_cap 3

  @doc "The most suggestion rows a search may return (the brief: never more than 3)."
  def results_cap, do: @results_cap

  @doc """
  Searches the provider registered for `activity_type`. Never raises.

  Returns `{:ok, [%Result{}]}` (at most `results_cap/0` of them, in the
  provider's order) or `{:error, atom}`. `{:ok, []}` covers both "nothing
  matched" and "no provider registered for this type" — the caller cannot and
  must not tell them apart, because both mean *show nothing* (the brief:
  failure is silence). A blank `query` short-circuits to `{:ok, []}` without
  touching the provider.
  """
  @spec search(String.t(), String.t(), Area.t() | nil) :: {:ok, [Result.t()]} | {:error, atom()}
  def search(activity_type, query, area \\ nil)

  def search(activity_type, query, area)
      when is_binary(activity_type) and is_binary(query) and
             (is_nil(area) or is_struct(area, Area)) do
    trimmed = String.trim(query)

    if trimmed == "" do
      {:ok, []}
    else
      activity_type
      |> provider_for()
      |> run_search(activity_type, trimmed, area)
    end
  end

  # Never raises, whatever the caller holds: a nil type, a charlist query, an
  # area of the wrong shape. Nothing to look up means nothing to show.
  def search(_activity_type, _query, _area), do: {:ok, []}

  @doc """
  The activity types with a registered provider, sorted. Drives UI like the `02`
  chip row deriving which chips are live *by data* (research §4.4) — a type
  absent here renders disabled without anything comparing type strings.
  """
  @spec available_types() :: [String.t()]
  def available_types do
    registry() |> Map.keys() |> Enum.sort()
  end

  @doc """
  The attribution line owed wherever results for `activity_type` render —
  `%{prefix: ..., text: ..., url: ...}`, pre-split so the UI links only `text`
  and renders `prefix` as plain text (see
  `c:Consensus.Discovery.Provider.attribution/0`) — or `nil` when the type has
  no provider (or the provider requires none). Never raises.
  """
  @spec attribution_for(String.t()) ::
          %{prefix: String.t(), text: String.t(), url: String.t()} | nil
  def attribution_for(activity_type) do
    with {module, _opts} <- provider_for(activity_type),
         %{prefix: prefix, text: text, url: url} <- safe_attribution(module) do
      %{prefix: prefix, text: text, url: url}
    else
      _ -> nil
    end
  end

  @doc """
  Boot-time registry validation, run by `Consensus.Discovery.Cache.start_link/1`
  before the cache table exists (research §4.5).

  Raises `ArgumentError` if any registered adapter declares
  `may_store_results?: false` — a provider whose terms forbid server-side result
  storage must be un-registerable, so "not allowed" is a fact the supervision
  tree enforces rather than a memo. Also raises (loudly, at boot, when it is
  cheap) on a registry entry that is not `{module, opts}` or an adapter whose
  `cache_policy/0` is malformed.
  """
  @spec validate_registry!() :: :ok
  def validate_registry! do
    Enum.each(registry(), &validate_registration!/1)
    :ok
  end

  ## Search plumbing

  defp run_search(:none, _type, _query, _area), do: {:ok, []}

  defp run_search({module, provider_opts}, type, query, area)
       when is_atom(module) and is_list(provider_opts) do
    # location_mode/0's doc promises a :unused adapter never receives an area
    # (movies, recipes — no location concept). Normalized once, here, so both
    # the cache key below and the call to the adapter agree.
    area = normalize_area(module, area)

    case safe_cache_policy(module) do
      %{ttl_ms: :none} ->
        do_search(module, provider_opts, query, area)

      # may_store_results?: false marks a provider whose terms forbid
      # server-side storage (research §4.5). validate_registry!/0 refuses such
      # a provider at boot, but the application env is mutable at runtime —
      # this is the second enforcement, so a runtime-registered forbidden
      # provider still never gets written to Cache.
      %{may_store_results?: false} ->
        do_search(module, provider_opts, query, area)

      %{ttl_ms: ttl_ms, error_ttl_ms: error_ttl_ms, may_store_results?: true}
      when is_integer(ttl_ms) and is_integer(error_ttl_ms) ->
        # Downcased for the cache key only — "Vernick" and "vernick" are the
        # same lookup, matching Geocoder.geocode/1's normalization, but the
        # text sent to the provider stays exactly as the caller typed it.
        cache_key = {:search, type, String.downcase(query), area}

        case Cache.get(cache_key) do
          {:hit, result} ->
            result

          :miss ->
            result = do_search(module, provider_opts, query, area)
            Cache.put(cache_key, result, ttl_ms: ttl_ms, error_ttl_ms: error_ttl_ms)
            result
        end

      _malformed ->
        {:error, :search_failed}
    end
  end

  # A malformed registry entry (validate_registry!/1 would have refused it at
  # boot, but the application env is mutable at runtime): degrade, don't raise.
  defp run_search(_malformed_entry, _type, _query, _area), do: {:error, :search_failed}

  defp do_search(module, provider_opts, query, area) do
    case module.search(query, area, provider_opts) do
      {:ok, results} when is_list(results) ->
        # Adapters return %Result{} structs or they are wrong (research §4.4,
        # Consensus.Discovery.Provider's contract) — a single non-Result entry
        # degrades the whole answer rather than silently reaching a caller
        # that will render whatever fields it happens to find.
        if Enum.all?(results, &is_struct(&1, Result)) do
          {:ok, Enum.take(results, @results_cap)}
        else
          {:error, :search_failed}
        end

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _other ->
        {:error, :search_failed}
    end
  rescue
    exception ->
      Logger.error(
        "Consensus.Discovery: #{inspect(module)}.search/3 raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :search_failed}
  catch
    kind, reason ->
      Logger.error(
        "Consensus.Discovery: #{inspect(module)}.search/3 exited: " <> inspect({kind, reason})
      )

      {:error, :search_failed}
  end

  # A :unused adapter (per Provider.location_mode/0's doc) must never receive
  # an area, whatever the caller passed in — :required and :optional (and any
  # unrecognised return, or a location_mode/0 that raises) leave area alone.
  defp normalize_area(module, area) do
    case safe_location_mode(module) do
      :unused -> nil
      _other -> area
    end
  end

  defp safe_location_mode(module) do
    module.location_mode()
  rescue
    _exception -> :optional
  catch
    _kind, _reason -> :optional
  end

  defp safe_cache_policy(module) do
    module.cache_policy()
  rescue
    _exception -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  defp safe_attribution(module) do
    module.attribution()
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  ## Registry

  defp registry do
    case Application.get_env(:consensus, __MODULE__, [])[:providers] do
      %{} = providers -> providers
      _other -> %{}
    end
  end

  defp provider_for(activity_type), do: Map.get(registry(), activity_type, :none)

  defp validate_registration!({type, {module, opts}}) when is_atom(module) and is_list(opts) do
    policy = module.cache_policy()

    case Map.fetch!(policy, :may_store_results?) do
      true ->
        :ok

      false ->
        raise ArgumentError, """
        #{inspect(module)} (registered for #{inspect(type)} in the
        `config :consensus, Consensus.Discovery, providers:` registry) declares
        `may_store_results?: false` in its cache_policy/0.

        That marks a provider whose terms forbid storing search results
        server-side, and such a provider must be un-registerable
        (docs/research/activity-discovery.md §4.5): this raise, at
        Consensus.Discovery.Cache child start, is what turns that rule from a
        memo into a fact the supervision tree enforces. Remove the registration;
        do not weaken this check.
        """
    end
  end

  defp validate_registration!({type, other}) do
    raise ArgumentError, """
    The `config :consensus, Consensus.Discovery, providers:` registry entry for
    #{inspect(type)} is #{inspect(other)} — every entry must be
    `{provider_module, opts}` (see Consensus.Discovery.Provider).
    """
  end
end
