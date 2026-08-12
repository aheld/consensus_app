defmodule Consensus.Discovery.TelemetryTest do
  @moduledoc """
  Pins the operator-facing half of the Assisted Add: that the chain is emitted at
  all, that it survives a cache hit, and that the correlation id crosses the
  `start_async` process boundary.

  The last one is the reason this file exists. Everything else here would stay
  green if `Logger.metadata(cid: ...)` were dropped from the closure in
  `ConsensusWeb.GroupLive.Options`, and the chain would silently stop being a
  chain — every line still logged, none of them tied together.
  """

  # async: false — the Discovery cache is one named ETS table shared app-wide,
  # these cases rewrite the provider registry, and the :telemetry handler table
  # is process-global too.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Consensus.Discovery
  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Result
  alias Consensus.DiscoveryStub

  setup do
    # config/test.exs pins the primary logger level to :warning, which discards
    # an :info message before any handler — including capture_log's — can see
    # it. capture_log's own :level option filters what it keeps; it does not
    # raise the primary level. So the level moves here and is put back after.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    Discovery.Cache.flush()
    Logger.metadata(cid: nil)
    :ok
  end

  defp area, do: %Area{name: "Philadelphia", bbox: {39.8, -75.2, 40.1, -74.9}}

  defp stub_results(results) do
    DiscoveryStub.stub_search(fn _query, _area, _opts -> results end)
  end

  defp capture_info(fun), do: capture_log(fun)

  describe "the search span" do
    test "logs the query, the provider and the result count" do
      stub_results({:ok, [%Result{name: "Vernick Food & Drink", source: :stub}]})

      log = capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end)

      assert log =~ ~s(search   type=restaurant q="vernick" area="Philadelphia")
      assert log =~ "provider="
      assert log =~ "-> ok 1 result"
    end

    test "pluralises the result count" do
      stub_results({:ok, [%Result{name: "A", source: :stub}, %Result{name: "B", source: :stub}]})

      assert capture_info(fn -> Discovery.search("restaurant", "a", area()) end) =~
               "-> ok 2 results"
    end

    test "reports a cache hit as an outcome rather than as an absence" do
      # This is the reason the span wraps the cache rather than the HTTP call:
      # instrumented at the transport, the second lookup below would emit
      # nothing at all and read as "it never ran".
      DiscoveryStub.stub_cache_policy(%{
        ttl_ms: :timer.hours(1),
        error_ttl_ms: 1_000,
        may_store_results?: true
      })

      stub_results({:ok, [%Result{name: "Vernick", source: :stub}]})

      first = capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end)
      second = capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end)

      assert first =~ "cache=miss"
      assert second =~ "cache=hit"
    end

    test "a provider whose policy disables caching reports cache=off, not a false miss" do
      # ttl_ms: :none and may_store_results?: false both bypass the cache. Calling
      # that a "miss" would imply a cache that could have answered.
      stub_results({:ok, []})

      assert capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end) =~
               "cache=off"
    end

    test "an error outcome carries its reason" do
      stub_results({:error, :rate_limited})

      log = capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end)

      assert log =~ "-> ERR error"
      assert log =~ "reason=:rate_limited"
    end

    test "a type with no registered provider still logs, with provider=none" do
      log = capture_info(fn -> Discovery.search("bowling", "lanes", area()) end)

      assert log =~ "provider=none"
      assert log =~ "-> ok 0 results"
    end
  end

  describe "the correlation id" do
    test "prefixes every line when Logger metadata carries one" do
      stub_results({:ok, []})
      Logger.metadata(cid: "7Kd2")

      assert capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end) =~
               "[lookup 7Kd2] search"
    end

    test "renders as a bare [lookup] when nothing set one" do
      stub_results({:ok, []})

      log = capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end)

      assert log =~ "[lookup] search"
      refute log =~ "[lookup ]"
    end

    test "does NOT leak across a process boundary unless the closure sets it" do
      # This is the whole reason the LiveView sets metadata inside the closure
      # rather than before start_async: a Task does not inherit it. If this ever
      # starts failing because the id DID cross, the closure's Logger.metadata
      # call has become redundant — check before deleting it.
      stub_results({:ok, []})
      Logger.metadata(cid: "parent")

      log =
        capture_info(fn ->
          task = Task.async(fn -> Discovery.search("restaurant", "vernick", area()) end)
          Task.await(task)
        end)

      refute log =~ "[lookup parent]"
      assert log =~ "[lookup]"
    end

    test "a closure that sets it explicitly is correlated, which is what the LiveView does" do
      stub_results({:ok, []})

      log =
        capture_info(fn ->
          task =
            Task.async(fn ->
              Logger.metadata(cid: "abc1")
              Discovery.search("restaurant", "vernick", area())
            end)

          Task.await(task)
        end)

      assert log =~ "[lookup abc1] search"
    end
  end

  describe "configuration" do
    test "level: nil attaches nothing, so the chain goes quiet without a deploy" do
      Consensus.Discovery.Telemetry.detach()
      Application.put_env(:consensus, Consensus.Discovery.Telemetry, level: nil)

      on_exit(fn ->
        Application.put_env(:consensus, Consensus.Discovery.Telemetry, level: :info)
        Consensus.Discovery.Telemetry.attach()
      end)

      assert :ok = Consensus.Discovery.Telemetry.attach()

      stub_results({:ok, []})

      refute capture_info(fn -> Discovery.search("restaurant", "vernick", area()) end) =~
               "[lookup"
    end

    test "attach/0 is idempotent" do
      assert :ok = Consensus.Discovery.Telemetry.attach()
      assert :ok = Consensus.Discovery.Telemetry.attach()
    end
  end
end
