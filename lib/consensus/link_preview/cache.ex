defmodule Consensus.LinkPreview.Cache do
  @moduledoc """
  ETS-backed result cache, keyed by any term. Born as (and still named for) the
  `Consensus.LinkPreview.fetch/1` cache; the mechanics were always generic —
  separate ok/error TTLs, lazy expiry, a size cap evicting by insertion time — so
  the table name is now a `start_link/1` option and the app runs **two instances**
  of this module rather than a ~120-line copy (docs/research/activity-discovery.md
  §4.5): the default one for `Consensus.LinkPreview`, and one owning
  `Consensus.Discovery.Cache`'s table for the Discovery/Geocoder layer.

  Both `{:ok, _}` and `{:error, _}` values are cached — a broken link pasted five
  times must cost one outbound request, not five — but on different TTLs. For the
  default instance the TTLs come from config, unchanged: `:ok` entries live for
  `cache_ttl_ms` (`config :consensus, Consensus.LinkPreview, cache_ttl_ms:`,
  default 6 hours); `:error` entries live for `cache_error_ttl_ms` (same config
  key, default 5 minutes) so a transient failure heals itself quickly. Both keys
  are read fresh from `Application.get_env/2` on every put, which is what lets a
  test shrink `cache_error_ttl_ms` for one case without restarting this process.
  A caller may instead pass `:ttl_ms` / `:error_ttl_ms` per put (`put/4`), which
  is how the Discovery layer honours a per-adapter `cache_policy/0` whose TTL is
  a compliance constant, not a config knob.

  Eviction is lazy: a get deletes and reports `:miss` for an entry whose TTL has
  passed rather than anything running on a timer. Each table is also capped at
  `@max_entries`; a put that would exceed the cap first deletes the single oldest
  entry (by insertion time, not by expiry — a short-TTL error inserted a minute
  ago is younger than a long-TTL success inserted an hour ago, and the cap should
  evict the latter first).

  Started as a supervised child of `Consensus.Application` (once per instance),
  after `Consensus.Repo` and before `ConsensusWeb.Endpoint` — see the comments at
  those children and `test/consensus/application_test.exs`. Each ETS table is
  `:public`: the owning GenServer exists to give the table a lifetime tied to the
  supervision tree, not to serialise access, so gets, puts, `flush` and `size`
  all touch the table directly from the calling process rather than going through
  a `GenServer.call/2`. The GenServer is registered under the table name, so two
  instances never collide on either namespace.
  """

  use GenServer

  @table __MODULE__
  @max_entries 2000
  @default_ttl_ms :timer.hours(6)
  @default_error_ttl_ms :timer.minutes(5)

  ## Public API

  @doc """
  Starts an instance. `opts` may carry `:table`, the atom naming both the ETS
  table and the GenServer (default `#{inspect(__MODULE__)}` — the LinkPreview
  instance). Two children of this module must use distinct tables, and their
  child specs distinct ids — see `Consensus.Discovery.Cache` for the second
  instance's wrapper.
  """
  def start_link(opts) do
    table = Keyword.get(opts, :table, @table)
    GenServer.start_link(__MODULE__, table, name: table)
  end

  @doc """
  Looks up `key` (in `table`, default the LinkPreview instance). `{:hit, value}`
  for a live entry, `:miss` for an absent or expired one — an expired entry is
  deleted as a side effect of the lookup.
  """
  @spec get(term()) :: {:hit, term()} | :miss
  def get(key), do: get(@table, key)

  @spec get(atom(), term()) :: {:hit, term()} | :miss
  def get(table, key) when is_atom(table) do
    case :ets.lookup(table, key) do
      [{^key, value, expires_at, _inserted_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:hit, value}
        else
          :ets.delete(table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Stores `value` for `key`. `value` must be `{:ok, _}` or `{:error, _}`; the TTL
  is picked accordingly (see module doc).
  """
  @spec put(term(), {:ok, term()} | {:error, term()}) :: :ok
  def put(key, value), do: put(@table, key, value, [])

  @doc """
  Same, against an explicit `table`, with optional per-put TTLs: `:ttl_ms` for an
  `{:ok, _}` value, `:error_ttl_ms` for an `{:error, _}` one. An absent option
  falls back to the config keys and defaults the module doc describes.
  """
  @spec put(atom(), term(), {:ok, term()} | {:error, term()}, keyword()) :: :ok
  def put(table, key, value, opts \\ []) when is_atom(table) do
    now = System.monotonic_time(:millisecond)
    evict_oldest_if_at_cap(table)
    :ets.insert(table, {key, value, now + ttl_ms(value, opts), now})
    :ok
  end

  @doc "Empties the cache (default: the LinkPreview instance's table). For tests."
  @spec flush(atom()) :: :ok
  def flush(table \\ @table) do
    :ets.delete_all_objects(table)
    :ok
  end

  @doc "Current entry count, including any not-yet-lazily-evicted expired ones. For tests."
  @spec size(atom()) :: non_neg_integer()
  def size(table \\ @table), do: :ets.info(table, :size)

  ## GenServer

  @impl true
  def init(table) do
    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  ## Internal

  defp ttl_ms({:ok, _}, opts) do
    opts[:ttl_ms] || config()[:cache_ttl_ms] || @default_ttl_ms
  end

  defp ttl_ms({:error, _}, opts) do
    opts[:error_ttl_ms] || config()[:cache_error_ttl_ms] || @default_error_ttl_ms
  end

  defp config, do: Application.get_env(:consensus, Consensus.LinkPreview, [])

  defp evict_oldest_if_at_cap(table) do
    if :ets.info(table, :size) >= @max_entries do
      case oldest_key(table) do
        nil -> :ok
        key -> :ets.delete(table, key)
      end
    end
  end

  defp oldest_key(table) do
    :ets.foldl(
      fn {key, _value, _expires_at, inserted_at}, best ->
        case best do
          {_best_key, best_inserted_at} when best_inserted_at <= inserted_at -> best
          _ -> {key, inserted_at}
        end
      end,
      nil,
      table
    )
    |> case do
      {key, _inserted_at} -> key
      nil -> nil
    end
  end
end
