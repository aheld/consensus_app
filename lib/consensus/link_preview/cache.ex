defmodule Consensus.LinkPreview.Cache do
  @moduledoc """
  ETS-backed cache for `Consensus.LinkPreview.fetch/1` results, keyed by the
  normalised URL.

  Both `{:ok, _}` and `{:error, _}` results are cached — a broken link pasted five
  times must cost one outbound request, not five — but on different TTLs: `:ok`
  entries live for `cache_ttl_ms` (`config :consensus, Consensus.LinkPreview,
  cache_ttl_ms:`, default 6 hours); `:error` entries live for `cache_error_ttl_ms`
  (same config key, default 5 minutes) so a transient failure heals itself quickly.
  Both keys are read fresh from `Application.get_env/2` on every `put/2`, which is
  what lets a test shrink `cache_error_ttl_ms` for one case without restarting this
  process.

  Eviction is lazy: `get/1` deletes and reports `:miss` for an entry whose TTL has
  passed rather than anything running on a timer. The table is also capped at
  `@max_entries`; a `put/2` that would exceed the cap first deletes the single oldest
  entry (by insertion time, not by expiry — a short-TTL error inserted a minute ago is
  younger than a long-TTL success inserted an hour ago, and the cap should evict the
  latter first).

  Started as a supervised child of `Consensus.Application`, after `Consensus.Repo` and
  before `ConsensusWeb.Endpoint` — see the comment at that child and
  `test/consensus/application_test.exs`. The ETS table is `:public`: the owning
  GenServer exists to give the table a lifetime tied to the supervision tree, not to
  serialise access, so `get/1`, `put/2`, `flush/0` and `size/0` all touch the table
  directly from the calling process rather than going through a `GenServer.call/2`.
  """

  use GenServer

  @table __MODULE__
  @max_entries 2000
  @default_ttl_ms :timer.hours(6)
  @default_error_ttl_ms :timer.minutes(5)

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up `key`. `{:hit, value}` for a live entry, `:miss` for an absent or expired
  one — an expired entry is deleted as a side effect of the lookup.
  """
  @spec get(term()) :: {:hit, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _inserted_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:hit, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Stores `value` for `key`. `value` must be `{:ok, _}` or `{:error, _}`; the TTL is
  picked accordingly (see module doc).
  """
  @spec put(term(), {:ok, term()} | {:error, term()}) :: :ok
  def put(key, value) do
    now = System.monotonic_time(:millisecond)
    evict_oldest_if_at_cap()
    :ets.insert(@table, {key, value, now + ttl_ms(value), now})
    :ok
  end

  @doc "Empties the cache. For tests."
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Current entry count, including any not-yet-lazily-evicted expired ones. For tests."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  ## Internal

  defp ttl_ms({:ok, _}), do: config()[:cache_ttl_ms] || @default_ttl_ms
  defp ttl_ms({:error, _}), do: config()[:cache_error_ttl_ms] || @default_error_ttl_ms

  defp config, do: Application.get_env(:consensus, Consensus.LinkPreview, [])

  defp evict_oldest_if_at_cap do
    if :ets.info(@table, :size) >= @max_entries do
      case oldest_key() do
        nil -> :ok
        key -> :ets.delete(@table, key)
      end
    end
  end

  defp oldest_key do
    :ets.foldl(
      fn {key, _value, _expires_at, inserted_at}, best ->
        case best do
          {_best_key, best_inserted_at} when best_inserted_at <= inserted_at -> best
          _ -> {key, inserted_at}
        end
      end,
      nil,
      @table
    )
    |> case do
      {key, _inserted_at} -> key
      nil -> nil
    end
  end
end
