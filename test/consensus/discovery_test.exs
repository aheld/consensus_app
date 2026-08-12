defmodule Consensus.DiscoveryTest do
  # async: false: the Discovery cache is a single named ETS table shared by the whole
  # app (a real child of Consensus.Application, not started per test), and several
  # cases below rewrite the provider registry in the application environment — both
  # are process-global state.
  use ExUnit.Case, async: false

  alias Consensus.Discovery
  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Provider.Overpass
  alias Consensus.Discovery.Result
  alias Consensus.DiscoveryStub
  alias Consensus.OverpassHTTPStub

  # do_search logs a provider's raise/exit at :error before degrading it to a tuple.
  @moduletag :capture_log

  setup do
    Discovery.Cache.flush()
    :ok
  end

  defp result(name) do
    %Result{name: name, source: :stub, address: "#{name} St"}
  end

  defp caching_policy(overrides \\ %{}) do
    Map.merge(
      %{ttl_ms: :timer.hours(1), error_ttl_ms: :timer.minutes(1), may_store_results?: true},
      overrides
    )
  end

  # Counting stub: every provider invocation sends {:searched, query} here.
  defp install_counting_stub(results_or_error) do
    test_pid = self()

    DiscoveryStub.stub_search(fn query, _area, _opts ->
      send(test_pid, {:searched, query})
      results_or_error
    end)
  end

  defp put_providers(providers) do
    original = Application.get_env(:consensus, Consensus.Discovery)

    Application.put_env(
      :consensus,
      Consensus.Discovery,
      Keyword.put(original, :providers, providers)
    )

    on_exit(fn -> Application.put_env(:consensus, Consensus.Discovery, original) end)
  end

  # For the integration describe below: the real Overpass adapter registered the
  # way config/config.exs registers it — module + per-type tag opts.
  @philly_area %Area{name: "Philadelphia", bbox: {39.867, -75.2803, 40.1379, -74.9558}}

  defp register_overpass_for_bowling do
    put_providers(%{"bowling" => {Overpass, tags: [{"leisure", "bowling_alley"}]}})
  end

  describe "search/3 — registry fallthrough" do
    test "a type with no registered provider is {:ok, []}, a normal state" do
      install_counting_stub({:ok, [result("Should never appear")]})

      assert Discovery.search("karaoke", "big hits", nil) == {:ok, []}
      refute_receive {:searched, _query}
    end

    test "a blank query short-circuits to {:ok, []} without touching the provider" do
      install_counting_stub({:ok, [result("Should never appear")]})

      assert Discovery.search("restaurant", "   ", nil) == {:ok, []}
      refute_receive {:searched, _query}
    end

    test "garbage input never raises" do
      assert Discovery.search(nil, "vernick", nil) == {:ok, []}
      assert Discovery.search("restaurant", nil, nil) == {:ok, []}
      assert Discovery.search("restaurant", "vernick", :not_an_area) == {:ok, []}
    end
  end

  describe "search/3 — results" do
    test "passes the query, area and registered opts through to the provider" do
      test_pid = self()
      area = %Area{name: "Fishtown", bbox: {39.96, -75.14, 39.98, -75.12}}

      DiscoveryStub.stub_search(fn query, got_area, opts ->
        send(test_pid, {:provider_saw, query, got_area, opts})
        {:ok, [result("Vernick")]}
      end)

      assert {:ok, [%Result{name: "Vernick"}]} = Discovery.search("restaurant", "vernick", area)

      # [] is what config/test.exs registers alongside the stub module.
      assert_receive {:provider_saw, "vernick", ^area, []}
    end

    test "a :unused provider never receives an area, whatever the caller passed" do
      test_pid = self()
      area = %Area{name: "Fishtown", bbox: {39.96, -75.14, 39.98, -75.12}}

      DiscoveryStub.stub_location_mode(:unused)

      DiscoveryStub.stub_search(fn query, got_area, opts ->
        send(test_pid, {:provider_saw, query, got_area, opts})
        {:ok, []}
      end)

      assert {:ok, []} = Discovery.search("restaurant", "vernick", area)
      assert_receive {:provider_saw, "vernick", nil, []}
    end

    test "results are capped at 3, keeping the provider's order" do
      five = Enum.map(1..5, &result("Place #{&1}"))
      DiscoveryStub.stub_results(five)

      assert {:ok, results} = Discovery.search("restaurant", "place", nil)
      assert length(results) == 3
      assert Enum.map(results, & &1.name) == ["Place 1", "Place 2", "Place 3"]
    end

    test "a provider's tagged error passes through" do
      DiscoveryStub.stub_search(fn _query, _area, _opts -> {:error, :overpass_down} end)

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :overpass_down}
    end
  end

  describe "search/3 — never raises" do
    test "a provider that raises becomes {:error, :search_failed}" do
      DiscoveryStub.stub_search(fn _query, _area, _opts -> raise "kaboom" end)

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :search_failed}
    end

    test "a provider that exits becomes {:error, :search_failed}" do
      DiscoveryStub.stub_search(fn _query, _area, _opts -> exit(:kaboom) end)

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :search_failed}
    end

    test "a provider answering garbage becomes {:error, :search_failed}" do
      DiscoveryStub.stub_search(fn _query, _area, _opts -> :banana end)

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :search_failed}
    end

    test "a provider returning a list of non-Result entries becomes {:error, :search_failed}" do
      # Adapters return %Result{} structs or they are wrong (research §4.4) —
      # {:ok, [...]} alone is not enough of a contract; every entry must be
      # the right struct or the whole answer degrades rather than reaching a
      # caller that renders whatever fields it happens to find.
      DiscoveryStub.stub_search(fn _query, _area, _opts -> {:ok, [:banana]} end)

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :search_failed}
    end

    test "one bad entry poisons the whole list, even alongside valid Results" do
      DiscoveryStub.stub_search(fn _query, _area, _opts ->
        {:ok, [result("Vernick"), %{name: "Not a Result"}]}
      end)

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :search_failed}
    end

    test "a malformed cache_policy becomes {:error, :search_failed}" do
      # An empty policy map has no :ttl_ms shape the engine recognises.
      DiscoveryStub.stub_cache_policy(%{})

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :search_failed}
    end

    test "a cache_policy missing may_store_results? degrades the search — the engine never guesses about storage" do
      # Pins the conservative behaviour c:Consensus.Discovery.Provider.cache_policy/0
      # documents: a real ttl_ms with the compliance flag absent is not "probably
      # fine", it is {:error, :search_failed} — the policy never reaches the
      # provider or the cache.
      DiscoveryStub.stub_cache_policy(%{ttl_ms: :timer.hours(1), error_ttl_ms: :timer.minutes(1)})
      install_counting_stub({:ok, [result("Should never appear")]})

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :search_failed}
      refute_receive {:searched, _query}
      assert Discovery.Cache.size() == 0
    end

    test "a cache_policy that raises becomes {:error, :search_failed}" do
      put_providers(%{"broken" => {Consensus.DiscoveryTest.RaisingPolicyProvider, []}})

      assert Discovery.search("broken", "anything", nil) == {:error, :search_failed}
    end

    test "a malformed registry entry degrades instead of raising" do
      put_providers(%{"weird" => :not_a_module_tuple})

      assert Discovery.search("weird", "anything", nil) == {:error, :search_failed}
    end
  end

  describe "search/3 — caching" do
    test "a success is cached per the adapter's ttl_ms: the provider runs once" do
      DiscoveryStub.stub_cache_policy(caching_policy())
      install_counting_stub({:ok, [result("Vernick")]})

      assert {:ok, [%Result{name: "Vernick"}]} = Discovery.search("restaurant", "vernick", nil)
      assert_receive {:searched, "vernick"}

      assert {:ok, [%Result{name: "Vernick"}]} = Discovery.search("restaurant", "vernick", nil)
      refute_receive {:searched, _query}
    end

    test "ttl_ms: :none bypasses the cache entirely" do
      # The stub's default policy is ttl_ms: :none — install it explicitly anyway
      # so this test still says what it means if the default ever changes.
      DiscoveryStub.stub_cache_policy(caching_policy(%{ttl_ms: :none}))
      install_counting_stub({:ok, [result("Vernick")]})

      assert {:ok, _} = Discovery.search("restaurant", "vernick", nil)
      assert_receive {:searched, "vernick"}

      assert {:ok, _} = Discovery.search("restaurant", "vernick", nil)
      assert_receive {:searched, "vernick"}

      assert Discovery.Cache.size() == 0
    end

    test "errors are cached on the separate error TTL and heal after it" do
      DiscoveryStub.stub_cache_policy(caching_policy(%{error_ttl_ms: 100}))
      install_counting_stub({:error, :overpass_down})

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :overpass_down}
      assert_receive {:searched, _query}

      # Within the (tiny) error TTL: cached, no second provider call.
      assert Discovery.search("restaurant", "vernick", nil) == {:error, :overpass_down}
      refute_receive {:searched, _query}

      Process.sleep(150)

      assert Discovery.search("restaurant", "vernick", nil) == {:error, :overpass_down}
      assert_receive {:searched, _query}
    end

    test "the cache key normalizes query case — \"Vernick\" and \"vernick\" hit one entry" do
      DiscoveryStub.stub_cache_policy(caching_policy())
      install_counting_stub({:ok, [result("Vernick")]})

      assert {:ok, _} = Discovery.search("restaurant", "Vernick", nil)
      # The provider itself sees the query exactly as typed, uppercase intact —
      # only the cache key is normalized.
      assert_receive {:searched, "Vernick"}

      assert {:ok, _} = Discovery.search("restaurant", "vernick", nil)
      refute_receive {:searched, _query}
    end

    test "a provider registered at runtime with may_store_results?: false is never cached" do
      # ForbiddenProvider's cache_policy declares a real ttl_ms alongside
      # may_store_results?: false. validate_registry!/0 would refuse this at
      # boot, but nothing re-runs that check when the application env changes
      # at runtime — the caching branch itself must also honour the flag
      # (research §4.5), not just match ttl_ms/error_ttl_ms's shape.
      put_providers(%{"forbidden" => {Consensus.DiscoveryTest.ForbiddenProvider, []}})

      assert Discovery.search("forbidden", "anything", nil) == {:ok, []}
      assert Discovery.Cache.size() == 0
    end

    test "the cache key distinguishes query and area" do
      DiscoveryStub.stub_cache_policy(caching_policy())
      install_counting_stub({:ok, []})

      area = %Area{name: "Fishtown", bbox: {39.96, -75.14, 39.98, -75.12}}

      assert {:ok, []} = Discovery.search("restaurant", "vernick", nil)
      assert_receive {:searched, "vernick"}

      assert {:ok, []} = Discovery.search("restaurant", "zahav", nil)
      assert_receive {:searched, "zahav"}

      assert {:ok, []} = Discovery.search("restaurant", "vernick", area)
      assert_receive {:searched, "vernick"}

      # All three now cached; repeats cost nothing.
      assert {:ok, []} = Discovery.search("restaurant", "vernick", nil)
      assert {:ok, []} = Discovery.search("restaurant", "zahav", nil)
      assert {:ok, []} = Discovery.search("restaurant", "vernick", area)
      refute_receive {:searched, _query}
    end
  end

  describe "search/3 — through the real Overpass adapter (integration, no network)" do
    # overpass_test.exs drives the adapter directly, and every other case in this
    # file drives Discovery through DiscoveryStub — this describe is the one
    # place the two layers run *together*: the registry lookup, the cache_policy
    # read, the results cap and the error boundary, all against the real
    # adapter's return contract, with canned Overpass JSON at the HTTP seam
    # (config/test.exs already points the adapter's HTTP module at the stub, so
    # nothing here can reach the network).

    test "registered opts reach the adapter's QL, Results come back capped, and its ttl_ms caches them" do
      register_overpass_for_bowling()

      test_pid = self()

      elements =
        for id <- 1..5 do
          %{
            "type" => "node",
            "id" => id,
            "tags" => %{"name" => "Lanes #{id}", "website" => "https://lanes#{id}.test/"}
          }
        end

      body = Jason.encode!(%{"elements" => elements})

      OverpassHTTPStub.stub(fn url, ql, _opts ->
        send(test_pid, {:posted, url, ql})
        {:ok, %{status: 200, body: body}}
      end)

      assert {:ok, results} = Discovery.search("bowling", "Lanes", @philly_area)

      # The adapter mapped five elements; Discovery's cap (the brief: never more
      # than 3 suggestion rows) trimmed them, keeping the provider's order.
      assert length(results) == Discovery.results_cap()

      assert [%Result{name: "Lanes 1", website_url: "https://lanes1.test/", source: :osm} | _] =
               results

      # The per-type opts registered alongside the module travelled through
      # Discovery into the generated QL — the registry is data, not a branch.
      assert_receive {:posted, "https://overpass-api.de/api/interpreter", ql}
      assert ql =~ ~s(["leisure"="bowling_alley"])
      assert ql =~ "Lanes"

      # A second identical search is served from the cache per the adapter's own
      # cache_policy (15-minute ttl_ms) — the adapter is not called again.
      assert {:ok, ^results} = Discovery.search("bowling", "Lanes", @philly_area)
      refute_receive {:posted, _url, _ql}
    end

    test "an adapter atom error crosses the boundary intact" do
      register_overpass_for_bowling()
      OverpassHTTPStub.stub(fn _url, _ql, _opts -> {:ok, %{status: 429, body: "busy"}} end)

      assert Discovery.search("bowling", "Lanes", @philly_area) == {:error, :rate_limited}
    end

    test "the adapter's non-atom {:http, status} tag degrades to :search_failed at the boundary" do
      # Pins the degradation Overpass's moduledoc promises: the adapter keeps
      # the status for direct callers and logging, Discovery's contract is
      # `{:error, atom}` — so the tuple tag flattens here, and nowhere else.
      register_overpass_for_bowling()
      OverpassHTTPStub.stub(fn _url, _ql, _opts -> {:ok, %{status: 400, body: "parse error"}} end)

      assert Discovery.search("bowling", "Lanes", @philly_area) == {:error, :search_failed}
    end
  end

  describe "available_types/0" do
    test "lists exactly the registered types" do
      assert Discovery.available_types() == ["restaurant"]
    end

    test "follows the registry" do
      put_providers(%{
        "bowling" => {Consensus.DiscoveryStub, []},
        "cinema" => {Consensus.DiscoveryStub, []}
      })

      assert Discovery.available_types() == ["bowling", "cinema"]
    end
  end

  describe "attribution_for/1" do
    test "returns the provider's attribution, prefix/text/url split intact" do
      attribution = %{
        prefix: "Places from ",
        text: "OpenStreetMap contributors",
        url: "https://opendatacommons.org/licenses/odbl/"
      }

      DiscoveryStub.stub_attribution(attribution)

      assert Discovery.attribution_for("restaurant") == attribution
    end

    test "is nil for a provider that declares none" do
      assert Discovery.attribution_for("restaurant") == nil
    end

    test "is nil for a type with no provider" do
      assert Discovery.attribution_for("karaoke") == nil
    end

    test "never raises when the provider's attribution/0 does" do
      DiscoveryStub.stub_attribution(nil)
      put_providers(%{"broken" => {Consensus.DiscoveryTest.RaisingAttributionProvider, []}})

      assert Discovery.attribution_for("broken") == nil
    end
  end

  describe "validate_registry!/0 — boot-time rejection (research §4.5)" do
    test "passes the test registry" do
      assert Discovery.validate_registry!() == :ok
    end

    test "an adapter declaring may_store_results?: false is un-registerable" do
      put_providers(%{"forbidden" => {Consensus.DiscoveryTest.ForbiddenProvider, []}})

      error = assert_raise ArgumentError, fn -> Discovery.validate_registry!() end

      assert error.message =~ "ForbiddenProvider"
      assert error.message =~ "may_store_results?: false"
    end

    test "the raise happens at the cache child's start, where boot dies with it" do
      put_providers(%{"forbidden" => {Consensus.DiscoveryTest.ForbiddenProvider, []}})

      assert_raise ArgumentError, ~r/may_store_results\?: false/, fn ->
        Consensus.Discovery.Cache.start_link([])
      end
    end

    test "with a valid registry the cache child start reaches the running instance" do
      # Validation passed and the wrapper delegated to the (already supervised)
      # parameterised cache — the only refusal left is the name registration.
      assert {:error, {:already_started, pid}} = Consensus.Discovery.Cache.start_link([])
      assert is_pid(pid)
    end

    test "a malformed registry entry is refused at boot" do
      put_providers(%{"weird" => :not_a_module_tuple})

      error = assert_raise ArgumentError, fn -> Discovery.validate_registry!() end

      assert error.message =~ ":not_a_module_tuple"
    end
  end
end

defmodule Consensus.DiscoveryTest.ForbiddenProvider do
  @moduledoc """
  A provider whose terms forbid server-side result storage — the shape
  `Consensus.Discovery.validate_registry!/0` exists to refuse (think Foursquare's
  no-caching tier, research trap C).
  """
  @behaviour Consensus.Discovery.Provider

  @impl true
  def search(_query, _area, _opts), do: {:ok, []}

  @impl true
  def cache_policy, do: %{ttl_ms: :timer.hours(1), error_ttl_ms: 1, may_store_results?: false}

  @impl true
  def attribution, do: nil

  @impl true
  def location_mode, do: :unused
end

defmodule Consensus.DiscoveryTest.RaisingAttributionProvider do
  @moduledoc "A provider whose attribution/0 raises — attribution_for/1 must shrug, not crash."
  @behaviour Consensus.Discovery.Provider

  @impl true
  def search(_query, _area, _opts), do: {:ok, []}

  @impl true
  def cache_policy, do: %{ttl_ms: :none, error_ttl_ms: 1, may_store_results?: true}

  @impl true
  def attribution, do: raise("no attribution today")

  @impl true
  def location_mode, do: :unused
end

defmodule Consensus.DiscoveryTest.RaisingPolicyProvider do
  @moduledoc "A provider whose cache_policy/0 raises — search/3 must degrade, not crash."
  @behaviour Consensus.Discovery.Provider

  @impl true
  def search(_query, _area, _opts), do: {:ok, []}

  @impl true
  def cache_policy, do: raise("no policy today")

  @impl true
  def attribution, do: nil

  @impl true
  def location_mode, do: :unused
end
