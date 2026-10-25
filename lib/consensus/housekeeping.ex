defmodule Consensus.Housekeeping do
  @moduledoc """
  Boot-time housekeeping: today, one sweep of abandoned anonymous organizers (D-058).

  A synchronous, run-once supervision child in the shape of `Consensus.Seeds`:
  `start_link/1` does its work during supervisor init and returns `:ignore`, so nothing
  is left in the tree. It sits directly **after** `Consensus.Seeds` in
  `Consensus.Application.children/0` — never between `Ecto.Migrator` and Seeds, which
  invariant 2 pins as adjacent — and before the caches and the endpoint.

  There is no scheduler (D-029) and the machine never auto-stops (invariant 4), so this
  may go months between runs. That is acceptable because nothing here is correctness:
  `Consensus.Activities.sweep_anonymous_organizers/1` only removes rows that own no
  group. It is also why **every** failure is rescued and logged rather than raised — a
  child that raises during init takes the node down before the endpoint binds a port,
  and losing a deploy over a cleanup is the wrong trade.
  """

  require Logger

  alias Consensus.Activities

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Inert, as on `Consensus.Seeds`: `start_link/1` returns `:ignore`, so the
      # supervisor never holds a process here to restart.
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Supervision-tree entry point.

  Runs the housekeeping synchronously and returns `:ignore` whatever happens. Pass
  `skip: true` to do nothing — `Consensus.Application` gates it on `skip_seeds?/0`, so
  it never runs under `mix test` or `mix phx.server`.
  """
  def start_link(opts \\ []) do
    if not Keyword.get(opts, :skip, false) do
      run()
    end

    :ignore
  end

  @doc """
  Runs every housekeeping step once and returns `:ok`. Never raises.
  """
  def run do
    count = Activities.sweep_anonymous_organizers()
    Logger.info("[housekeeping] swept #{count} abandoned anonymous organizer(s)")
    :ok
  rescue
    error ->
      Logger.warning("[housekeeping] sweep failed, boot continues: #{Exception.message(error)}")

      :ok
  catch
    # An exit is not caught by `rescue` — the `UserNotifier` lesson. A checkout that
    # times out exits rather than raising, and must not cost a boot either.
    kind, reason ->
      Logger.warning(
        "[housekeeping] sweep failed, boot continues: #{Exception.format_banner(kind, reason)}"
      )

      :ok
  end
end
