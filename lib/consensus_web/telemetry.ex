defmodule ConsensusWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("consensus.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("consensus.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("consensus.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("consensus.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("consensus.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Assisted Add lookup metrics (D-052 / D-056). These make the assist's
      # failure modes visible at /admin/dashboard without any external
      # collector: `outcome` separates a genuine miss from a 429 or a 504, and
      # `cache` is what says whether a lookup cost anybody a network request.
      # Every tag below is guaranteed present on the stop event by
      # Consensus.Discovery's own stop-metadata builders — a tag missing from
      # metadata makes Telemetry.Metrics drop the measurement silently.
      summary("consensus.discovery.search.stop.duration",
        tags: [:outcome, :cache],
        unit: {:native, :millisecond},
        description: "Assisted Add lookup, cache hit or provider round trip"
      ),
      counter("consensus.discovery.search.stop.duration",
        tags: [:outcome, :cache],
        description: "Assisted Add lookups, by outcome"
      ),
      summary("consensus.discovery.geocode.stop.duration",
        tags: [:outcome, :cache],
        unit: {:native, :millisecond},
        description: "Area geocode (Nominatim), cached ~a year on success"
      ),
      summary("consensus.discovery.provider_request.stop.duration",
        tags: [:outcome],
        unit: {:native, :millisecond},
        description: "Overpass round trip alone, excluding our own work"
      ),
      summary("consensus.link_preview.fetch.stop.duration",
        tags: [:outcome, :cache],
        unit: {:native, :millisecond},
        description: "Link enrichment, both the paste path and the assist"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {ConsensusWeb, :count_users, []}
    ]
  end
end
