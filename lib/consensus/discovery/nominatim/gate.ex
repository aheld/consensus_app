defmodule Consensus.Discovery.Nominatim.Gate do
  @moduledoc """
  The one app-wide slot for Nominatim requests: at most one per `interval_ms`
  (1 000 by default), shared by `Consensus.Discovery.Geocoder` and
  `Consensus.Discovery.Provider.Nominatim` through `Consensus.Discovery.Nominatim`.

  Nominatim's usage policy allows **one request per second per application**
  (docs/research/activity-discovery.md trap F), not per module, which is why
  there is one gate and both callers go through it.

  The state is a single integer: the monotonic time of the next free slot.
  `reserve/2` either hands back how long the caller must wait for its slot and
  moves the slot forward, or refuses with `{:error, :busy}` when that wait would
  exceed `max_wait_ms`. **The caller sleeps, never this process**, so the gate
  never blocks and one slow caller cannot hold up another's answer. Callers are
  already inside `start_async` Tasks (CLAUDE.md invariant 13), so sleeping there
  costs nothing but the shimmer.

  This is not a scheduler (D-029 still holds): it does no work of its own.

  `config/test.exs` sets `interval_ms: 0` so the suite never sleeps; the gate's
  own test starts a private instance with an explicit interval.
  """

  use GenServer

  @default_interval_ms 1_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reserves the next slot if it is at most `max_wait_ms` away.

  Returns `{:ok, wait_ms}` (sleep that long, then send) or `{:error, :busy}`
  (do not send at all). A refusal does not move the slot.
  """
  @spec reserve(GenServer.server(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :busy}
  def reserve(server \\ __MODULE__, max_wait_ms) do
    GenServer.call(server, {:reserve, max_wait_ms})
  end

  @doc false
  # How many reservations this gate has granted. Only tests read it, to prove a
  # cache hit never reaches the gate.
  def granted(server \\ __MODULE__), do: GenServer.call(server, :granted)

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        Application.get_env(:consensus, __MODULE__, [])[:interval_ms] || @default_interval_ms
      end)

    {:ok, %{interval_ms: interval_ms, next_free: now(), granted: 0}}
  end

  @impl true
  def handle_call({:reserve, max_wait_ms}, _from, state) do
    now = now()
    slot = max(state.next_free, now)
    wait_ms = slot - now

    if wait_ms > max_wait_ms do
      {:reply, {:error, :busy}, state}
    else
      state = %{state | next_free: slot + state.interval_ms, granted: state.granted + 1}
      {:reply, {:ok, wait_ms}, state}
    end
  end

  def handle_call(:granted, _from, state), do: {:reply, state.granted, state}

  defp now, do: System.monotonic_time(:millisecond)
end
