defmodule Consensus.Discovery.Cache do
  @moduledoc """
  The Discovery instance of the parameterised `Consensus.LinkPreview.Cache` —
  a second supervised child of the same module, owning this module's own ETS
  table, rather than ~120 duplicated lines (docs/research/activity-discovery.md
  §4.5 recommends exactly this).

  Two kinds of entry share the table, in disjoint tagged-tuple key spaces:
  `Consensus.Discovery.search/3` results under `{:search, type, query, area}`,
  and `Consensus.Discovery.Geocoder.geocode/1` answers under `{:geocode, query}`.
  TTLs are always passed per put — the adapter's `cache_policy/0` for searches,
  the geocoder's own constants for areas — never read from the LinkPreview
  config keys.

  **Starting this child validates the provider registry** (research §4.5):
  `Consensus.Discovery.validate_registry!/0` runs before the cache comes up, so
  an adapter whose `cache_policy/0` declares `may_store_results?: false` — a
  provider whose terms forbid server-side result storage — is un-registerable:
  the supervision tree refuses to boot with it in config. Not ETS trivia but the
  enforcement point, which is why the raise lives at child start and
  `test/consensus/discovery_test.exs` pins it.
  """

  alias Consensus.LinkPreview.Cache

  @table __MODULE__

  def start_link(opts) do
    Consensus.Discovery.validate_registry!()
    Cache.start_link(Keyword.put(opts, :table, @table))
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "See `Consensus.LinkPreview.Cache.get/2` — this table."
  @spec get(term()) :: {:hit, term()} | :miss
  def get(key), do: Cache.get(@table, key)

  @doc "See `Consensus.LinkPreview.Cache.put/4` — this table."
  @spec put(term(), {:ok, term()} | {:error, term()}, keyword()) :: :ok
  def put(key, value, opts \\ []), do: Cache.put(@table, key, value, opts)

  @doc "Empties this instance's table (the LinkPreview one is untouched). For tests."
  @spec flush() :: :ok
  def flush, do: Cache.flush(@table)

  @doc "Entry count of this instance's table. For tests."
  @spec size() :: non_neg_integer()
  def size, do: Cache.size(@table)
end
