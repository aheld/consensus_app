defmodule Consensus.DiscoveryStub do
  @moduledoc """
  The test implementation of `Consensus.Discovery.Provider`, registered for
  `"restaurant"` by `config/test.exs`.

  Same idiom as `Consensus.LinkPreviewStub` (read its moduledoc for the full
  why): no Mox in this project, so a test installs behaviour per facet with the
  `stub_*` functions below, and every callback walks `$callers` to find it —
  which is what keeps an installed stub visible inside a `start_async` `Task`
  when the assisted-add UI lands, exactly as the LinkPreview stub already is.

  Defaults, when a test installs nothing (including at application boot, where
  no test process exists):

    * `search/3` — `{:ok, []}`, the "no match, show nothing" outcome, so
      unrelated tests never see a suggestion.
    * `cache_policy/0` — `%{ttl_ms: :none, error_ttl_ms: 1, may_store_results?: true}`.
      `ttl_ms: :none` keeps `Consensus.Discovery.search/3` off the (globally
      named, app-wide) cache table by default, so tests stay hermetic unless one
      opts in via `stub_cache_policy/1`; `may_store_results?: true` is what lets
      the boot-time registry validation pass in test.
    * `attribution/0` — `nil`.
    * `location_mode/0` — `:optional`.
  """

  @behaviour Consensus.Discovery.Provider

  @default_cache_policy %{ttl_ms: :none, error_ttl_ms: 1, may_store_results?: true}

  @impl true
  def search(query, area, opts) do
    case lookup(:search) do
      {:ok, fun} -> fun.(query, area, opts)
      nil -> {:ok, []}
    end
  end

  @impl true
  def cache_policy do
    case lookup(:cache_policy) do
      {:ok, policy} -> policy
      nil -> @default_cache_policy
    end
  end

  @impl true
  def attribution do
    case lookup(:attribution) do
      {:ok, attribution} -> attribution
      nil -> nil
    end
  end

  @impl true
  def location_mode do
    case lookup(:location_mode) do
      {:ok, mode} -> mode
      nil -> :optional
    end
  end

  @doc """
  Installs the search function for this process and anything it spawns. It
  receives `(query, area, opts)` and returns what `c:Consensus.Discovery.Provider.search/3`
  is specified to return.
  """
  def stub_search(fun) when is_function(fun, 3), do: install(:search, fun)

  @doc "Convenience: always answer `search/3` with `{:ok, results}`."
  def stub_results(results) when is_list(results) do
    stub_search(fn _query, _area, _opts -> {:ok, results} end)
  end

  @doc "Installs a `cache_policy/0` return for this process and anything it spawns."
  def stub_cache_policy(%{} = policy), do: install(:cache_policy, policy)

  @doc "Installs an `attribution/0` return (a `%{prefix:, text:, url:}` map, or nil)."
  def stub_attribution(attribution), do: install(:attribution, attribution)

  @doc "Installs a `location_mode/0` return."
  def stub_location_mode(mode) when mode in [:required, :optional, :unused] do
    install(:location_mode, mode)
  end

  defp install(facet, value), do: Process.put({__MODULE__, facet}, {:ok, value})

  defp lookup(facet) do
    key = {__MODULE__, facet}

    Enum.find_value([self() | callers()], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          case List.keyfind(dict, key, 0) do
            {^key, {:ok, _value} = installed} -> installed
            nil -> nil
          end

        nil ->
          nil
      end
    end)
  end

  defp callers, do: Process.get(:"$callers", [])
end
