defmodule Consensus.Discovery.Provider.NominatimTest do
  # async: true is safe here: the adapter is called directly (never through
  # Consensus.Discovery, so the shared cache table is untouched), the HTTP double
  # is installed in this test's own process dictionary, and the app-wide rate
  # gate runs at interval 0 in test (config/test.exs).
  use ExUnit.Case, async: true

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Provider.Nominatim
  alias Consensus.Discovery.Result
  alias Consensus.NominatimHTTPStub, as: StubHTTP

  # The client logs a double's raise at :error before degrading it to a tuple.
  @moduletag :capture_log

  @philly_bbox {39.8670, -75.2803, 40.1379, -74.9558}
  @philly_area %Area{name: "Philadelphia", bbox: @philly_bbox}
  @restaurant [
    categories: [
      {"amenity", "restaurant"},
      {"amenity", "fast_food"},
      {"amenity", "cafe"},
      {"amenity", "pub"},
      {"amenity", "food_court"},
      {"amenity", "biergarten"}
    ],
    category_tag: "cuisine",
    category_label: "Cuisine"
  ]
  @bar [
    categories: [
      {"amenity", "bar"},
      {"amenity", "pub"},
      {"amenity", "biergarten"},
      {"amenity", "nightclub"}
    ]
  ]

  setup do
    StubHTTP.stub(fn _url, _opts -> {:error, :not_configured} end)
    :ok
  end

  # A minimal Nominatim jsonv2 element, for the shape-by-shape cases below. The
  # end-to-end cases use recorded real responses instead (test/fixtures/nominatim).
  defp place(id, name, overrides \\ %{}) do
    Map.merge(
      %{
        "osm_type" => "node",
        "osm_id" => id,
        "category" => "amenity",
        "type" => "restaurant",
        "name" => name,
        "address" => %{},
        "extratags" => %{}
      },
      overrides
    )
  end

  defp install_recording_stub(places \\ []) do
    test_pid = self()
    body = Jason.encode!(places)

    StubHTTP.stub(fn url, opts ->
      send(test_pid, {:requested, url, opts})
      {:ok, %{status: 200, body: body}}
    end)
  end

  defp stub_recorded(name) do
    body = StubHTTP.recorded!(name)
    StubHTTP.stub(fn _url, _opts -> {:ok, %{status: 200, body: body}} end)
  end

  defp query_of(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  describe "the query" do
    test "one GET to /search with the typed name, layer=poi, a bounded viewbox, limit=10 and the detail flags" do
      install_recording_stub()

      assert {:ok, []} = Nominatim.search("Zahav", @philly_area, @restaurant)
      assert_receive {:requested, url, opts}

      uri = URI.parse(url)
      assert uri.scheme == "https"
      assert uri.host == "nominatim.openstreetmap.org"
      assert uri.path == "/search"

      assert query_of(url) == %{
               "q" => "Zahav",
               "format" => "jsonv2",
               "layer" => "poi",
               "viewbox" => "-75.2803,40.1379,-74.9558,39.867",
               "bounded" => "1",
               "limit" => "10",
               "addressdetails" => "1",
               "extratags" => "1"
             }

      assert {"user-agent", user_agent} =
               List.keyfind(Keyword.fetch!(opts, :headers), "user-agent", 0)

      assert user_agent =~ "Consensus"
      assert Keyword.fetch!(opts, :receive_timeout_ms) == 10_000
      assert Keyword.fetch!(opts, :connect_timeout_ms) == 5_000
    end

    test "the categories are NOT sent — they are an allowlist over the answer" do
      install_recording_stub()

      assert {:ok, []} = Nominatim.search("Zahav", @philly_area, @restaurant)
      assert_receive {:requested, url, _opts}

      refute url =~ "restaurant"
      refute url =~ "amenity"
    end

    test "control characters are flattened before the query is sent" do
      install_recording_stub()

      assert {:ok, []} = Nominatim.search("Za\nhav\x01", @philly_area, @restaurant)
      assert_receive {:requested, url, _opts}

      assert query_of(url)["q"] == "Za hav"
    end

    test "quotes, ampersands and brackets reach Nominatim as text, encoded, never as structure" do
      install_recording_stub()

      typed = ~S{Crab "Shack" & Co (South)&limit=50}
      assert {:ok, []} = Nominatim.search(typed, @philly_area, @restaurant)
      assert_receive {:requested, url, _opts}

      assert query_of(url)["q"] == typed
      assert query_of(url)["limit"] == "10"
    end
  end

  describe "viewbox/1" do
    test "reorders Area's {min_lat, min_lon, max_lat, max_lon} into left,top,right,bottom" do
      # Philadelphia is wider than the minimum span on both axes: no widening.
      assert Nominatim.viewbox(@philly_bbox) == "-75.2803,40.1379,-74.9558,39.867"
    end

    test "widens a point-sized neighbourhood box to 0.04° on each axis, around its centre" do
      # Fishtown as Nominatim's geocoder actually returns it: a ±0.01° box.
      fishtown = {39.9632555, -75.1404082, 39.9832555, -75.1204082}

      assert Nominatim.viewbox(fishtown) == "-75.1504082,39.9932555,-75.1104082,39.9532555"
    end

    test "widens only the axis that is too narrow" do
      # 0.1° of latitude (kept), 0.001° of longitude (widened around -75.1505).
      assert Nominatim.viewbox({39.9, -75.151, 40.0, -75.15}) == "-75.1705,40.0,-75.1305,39.9"
    end

    test "integer coordinates are accepted" do
      assert Nominatim.viewbox({39, -76, 41, -74}) == "-76.0,41.0,-74.0,39.0"
    end
  end

  describe "refusals that never touch the network" do
    test "a nil area is {:ok, []} (location_mode is :required; the rule for a non-answer is silence)" do
      install_recording_stub()

      assert Nominatim.search("Zahav", nil, @restaurant) == {:ok, []}
      refute_receive {:requested, _url, _opts}
    end

    test "an empty category list is {:ok, []} — a misconfigured registry entry asks nothing" do
      install_recording_stub()

      assert Nominatim.search("Zahav", @philly_area, categories: []) == {:ok, []}
      assert Nominatim.search("Zahav", @philly_area, []) == {:ok, []}
      refute_receive {:requested, _url, _opts}
    end

    test "a query that sanitises to nothing is {:ok, []}" do
      install_recording_stub()

      assert Nominatim.search("\x01\x02", @philly_area, @restaurant) == {:ok, []}
      refute_receive {:requested, _url, _opts}
    end

    test "invalid UTF-8 input is {:ok, []}, never a raise — the sanitiser must be bytewise-safe" do
      install_recording_stub()

      assert Nominatim.search(<<255, 34, 59>>, @philly_area, @restaurant) == {:ok, []}
      refute_receive {:requested, _url, _opts}
    end
  end

  describe "recorded responses (real Nominatim answers, 2026-10-25)" do
    test "Zahav: name, website, street and full address, phone, location, cuisine, node ref" do
      stub_recorded("zahav")

      assert {:ok, [%Result{} = zahav]} = Nominatim.search("Zahav", @philly_area, @restaurant)

      assert zahav == %Result{
               name: "Zahav",
               website_url: "https://www.zahavrestaurant.com/",
               source: :osm,
               external_ref: "node/6374481270",
               osm_ref: "node/6374481270",
               address: "237 Saint James Place",
               full_address: "237 Saint James Place, Philadelphia",
               phone: "+1-215-625-8800",
               latitude: 39.946306,
               longitude: -75.145187,
               category: "israeli",
               # Discovery stamps this from retained_fields/0; the adapter never does.
               retainable: []
             }
    end

    test "Vernick under restaurant: the restaurant and the cafe both survive, in Nominatim's order" do
      stub_recorded("vernick")

      assert {:ok, results} = Nominatim.search("Vernick", @philly_area, @restaurant)

      assert Enum.map(results, &{&1.name, &1.address}) == [
               {"Vernick Food & Drink", "2031 Walnut Street"},
               {"Vernick Coffee Bar", "1800 Arch Street"}
             ]

      assert hd(results).website_url == "https://www.vernickphilly.com/"
      assert List.last(results).category == "coffee shop"
    end

    test "Vernick under bar: neither is a bar, so the allowlist drops both" do
      stub_recorded("vernick")

      assert Nominatim.search("Vernick", @philly_area, @bar) == {:ok, []}
    end

    test "Federal Donuts: restaurant and fast_food branches, a way and nodes, one without a website" do
      stub_recorded("federal_donuts")

      assert {:ok, results} = Nominatim.search("Federal Donuts", @philly_area, @restaurant)

      assert length(results) == 4
      assert Enum.all?(results, &(&1.name == "Federal Donuts"))
      assert hd(results).external_ref == "way/1253791238"
      # The way carries no website tag: nulled, never dropped.
      assert hd(results).website_url == nil
      assert hd(results).category == "new american"
      assert Enum.at(results, 1).address == "1776 Benjamin Franklin Parkway"
      assert Enum.at(results, 1).category == "donut"
    end
  end

  describe "the category allowlist" do
    test "a cafe is dropped under bar and kept under restaurant, with the drop counted on the span" do
      places = [
        place(1, "Corner Cafe", %{"type" => "cafe"}),
        place(2, "Corner Bar", %{"type" => "bar"})
      ]

      install_recording_stub(places)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:consensus, :discovery, :provider_request, :stop]
        ])

      assert {:ok, [%Result{name: "Corner Bar"}]} = Nominatim.search("Corner", @philly_area, @bar)

      assert_receive {[:consensus, :discovery, :provider_request, :stop], ^ref, _measurements,
                      %{outcome: :ok, status: 200, count: 1, filtered: 1}}

      assert {:ok, [%Result{name: "Corner Cafe"}]} =
               Nominatim.search("Corner", @philly_area, @restaurant)

      assert_receive {[:consensus, :discovery, :provider_request, :stop], ^ref, _measurements,
                      %{count: 1, filtered: 1}}
    end

    test "a different key with the same value is not a match" do
      install_recording_stub([place(1, "Bowl", %{"category" => "shop", "type" => "restaurant"})])

      assert Nominatim.search("Bowl", @philly_area, @restaurant) == {:ok, []}
    end

    test "an element with no category or type is dropped, not crashed on" do
      install_recording_stub([Map.drop(place(1, "Odd"), ["category", "type"])])

      assert Nominatim.search("Odd", @philly_area, @restaurant) == {:ok, []}
    end
  end

  describe "element mapping" do
    test "ways and relations get their own external_ref prefixes" do
      install_recording_stub([
        place(42, "North Bowl", %{"osm_type" => "way"}),
        place(43, "Big Hall", %{"osm_type" => "relation"})
      ])

      assert {:ok, [%Result{external_ref: "way/42"}, %Result{external_ref: "relation/43"}]} =
               Nominatim.search("anything", @philly_area, @restaurant)
    end

    test "unnamed, blank-named and malformed elements are dropped; named ones survive in order" do
      install_recording_stub([
        place(1, "") |> Map.delete("name"),
        place(2, "   "),
        place(3, "No id") |> Map.delete("osm_id"),
        place(4, "Bad type", %{"osm_type" => "area"}),
        place(5, "First"),
        place(6, "Second")
      ])

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)
      assert Enum.map(results, & &1.name) == ["First", "Second"]
    end

    test "website is picked from website | contact:website | url, first valid" do
      install_recording_stub([
        place(1, "Both", %{
          "extratags" => %{"website" => "https://first.test/", "url" => "https://second.test/"}
        }),
        place(2, "Contact only", %{"extratags" => %{"contact:website" => "https://contact.test/"}}),
        place(3, "Url only", %{"extratags" => %{"url" => "https://url-tag.test/"}}),
        place(4, "None"),
        place(5, "Null extratags", %{"extratags" => nil})
      ])

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)

      assert Enum.map(results, & &1.website_url) == [
               "https://first.test/",
               "https://contact.test/",
               "https://url-tag.test/",
               nil,
               nil
             ]
    end

    test "an invalid earlier candidate falls through to a later valid one" do
      install_recording_stub([
        place(1, "Fallthrough", %{
          "extratags" => %{
            "website" => "javascript:alert(1)",
            "contact:website" => "http://10.0.0.1/intranet",
            "url" => "https://legit.test/"
          }
        })
      ])

      assert {:ok, [%Result{website_url: "https://legit.test/"}]} =
               Nominatim.search("anything", @philly_area, @restaurant)
    end

    test "SSRF (trap J): private, loopback, metadata and non-http websites are nulled; results survive" do
      websites = [
        "http://192.168.1.1/",
        "javascript:alert(1)",
        "ftp://files.test/menu.pdf",
        "/menu",
        "http://localhost/",
        "http://127.0.0.1/",
        "http://metadata.google.internal/",
        "https://169.254.169.254/",
        "http://[::ffff:127.0.0.1]/",
        "https://[::ffff:169.254.169.254]/"
      ]

      places =
        websites
        |> Enum.with_index(1)
        |> Enum.map(fn {website, id} ->
          place(id, "Crafted #{id}", %{
            "extratags" => %{"website" => website},
            "address" => %{"road" => "Frankford Ave"}
          })
        end)

      install_recording_stub(places)

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)
      assert length(results) == length(websites)
      assert Enum.all?(results, &is_nil(&1.website_url))
      assert Enum.all?(results, &(&1.address == "Frankford Ave"))
    end

    test "address shapes: house number + road, road alone, number alone, neither" do
      install_recording_stub([
        place(1, "Full", %{"address" => %{"house_number" => "237", "road" => "Main St"}}),
        place(2, "Road only", %{"address" => %{"road" => "Main St"}}),
        place(3, "Number only", %{"address" => %{"house_number" => "237"}}),
        place(4, "Neither"),
        place(5, "No address map", %{"address" => nil})
      ])

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)
      assert Enum.map(results, & &1.address) == ["237 Main St", "Main St", nil, nil, nil]
    end

    test "cuisine humanisation: first semicolon value, underscores to spaces; absent means no category" do
      install_recording_stub([
        place(1, "Multi", %{"extratags" => %{"cuisine" => "middle_eastern;israeli"}}),
        place(2, "Plain", %{"extratags" => %{"cuisine" => "thai"}}),
        place(3, "Blank", %{"extratags" => %{"cuisine" => "  "}}),
        place(4, "None")
      ])

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)

      assert Enum.map(results, & &1.category) == ["middle eastern", "thai", nil, nil]
    end

    test "without a category_tag the category is Nominatim's own type, humanised" do
      install_recording_stub([
        place(1, "Lanes", %{
          "category" => "leisure",
          "type" => "bowling_alley",
          "extratags" => %{"cuisine" => "pizza"}
        })
      ])

      bowling = [categories: [{"leisure", "bowling_alley"}]]
      assert {:ok, [lanes]} = Nominatim.search("anything", @philly_area, bowling)
      assert lanes.category == "bowling alley"
    end

    test "an over-long category is dropped rather than failing a later Use this" do
      long = String.duplicate("x", Consensus.Activities.Activity.max_category_length() + 1)
      install_recording_stub([place(1, "Long", %{"extratags" => %{"cuisine" => long}})])

      assert {:ok, [result]} = Nominatim.search("anything", @philly_area, @restaurant)
      assert result.category == nil
    end
  end

  describe "details (D-060)" do
    test "phone: the first value of phone | contact:phone that passes the Activity rule" do
      install_recording_stub([
        place(1, "Multi", %{"extratags" => %{"phone" => "+1 215 555 0100;+1 267 555 0101"}}),
        place(2, "Contact", %{"extratags" => %{"contact:phone" => "(215) 555-0102"}}),
        place(3, "Junk first", %{
          "extratags" => %{"phone" => "call us!", "contact:phone" => "215.555.0103"}
        }),
        place(4, "Too short", %{"extratags" => %{"phone" => "911"}}),
        place(5, "None")
      ])

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)

      assert Enum.map(results, & &1.phone) == [
               "+1 215 555 0100",
               "(215) 555-0102",
               "215.555.0103",
               nil,
               nil
             ]
    end

    test "coordinates: jsonv2's strings parsed, both or neither, in range" do
      install_recording_stub([
        place(1, "Good", %{"lat" => "39.9463060", "lon" => "-75.1451870"}),
        place(2, "Lat only", %{"lat" => "39.9"}),
        place(3, "Garbage", %{"lat" => "north", "lon" => "-75.1"}),
        place(4, "Out of range", %{"lat" => "91.0", "lon" => "-75.1"})
      ])

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)

      assert Enum.map(results, &{&1.latitude, &1.longitude}) == [
               {39.946306, -75.145187},
               {nil, nil},
               {nil, nil},
               {nil, nil}
             ]
    end

    test "full address: street plus the first locality; no street, no stored address" do
      install_recording_stub([
        place(1, "City", %{"address" => %{"road" => "Main St", "city" => "Philadelphia"}}),
        place(2, "Town", %{"address" => %{"road" => "Main St", "town" => "Media"}}),
        place(3, "Street only", %{"address" => %{"road" => "Main St"}}),
        place(4, "City only", %{"address" => %{"city" => "Philadelphia"}})
      ])

      assert {:ok, results} = Nominatim.search("anything", @philly_area, @restaurant)

      assert Enum.map(results, & &1.full_address) == [
               "Main St, Philadelphia",
               "Main St, Media",
               "Main St",
               nil
             ]
    end

    test "osm_ref is the element ref, and every retainable field is declared (ODbL)" do
      install_recording_stub([place(42, "Ref")])

      assert {:ok, [result]} = Nominatim.search("anything", @philly_area, @restaurant)
      assert result.osm_ref == "node/42"
      assert Nominatim.retained_fields() == Result.retainable_fields()
    end
  end

  describe "the error taxonomy" do
    test "HTTP 429 is {:error, :rate_limited}" do
      StubHTTP.stub(fn _url, _opts -> {:ok, %{status: 429, body: "slow down"}} end)

      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, :rate_limited}
    end

    test "HTTP 403 (Nominatim's block for a policy breach) keeps its status for the log" do
      StubHTTP.stub(fn _url, _opts -> {:ok, %{status: 403, body: "blocked"}} end)

      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, {:http, 403}}
    end

    test "any other non-200 is {:error, {:http, status}}" do
      StubHTTP.stub(fn _url, _opts -> {:ok, %{status: 503, body: "down"}} end)

      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, {:http, 503}}
    end

    test "a transport timeout is {:error, :timeout} — both the bare atom and the Req/Mint struct shape" do
      StubHTTP.stub(fn _url, _opts -> {:error, :timeout} end)
      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, :timeout}

      StubHTTP.stub(fn _url, _opts -> {:error, %{reason: :timeout}} end)
      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, :timeout}
    end

    test "a body that is not a JSON list is {:error, :malformed}" do
      StubHTTP.stub(fn _url, _opts -> {:ok, %{status: 200, body: "<html>not json"}} end)
      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, :malformed}

      StubHTTP.stub(fn _url, _opts ->
        {:ok, %{status: 200, body: Jason.encode!(%{"error" => "Unable to geocode"})}}
      end)

      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, :malformed}
    end

    test "a non-timeout transport error is {:error, :search_failed}" do
      StubHTTP.stub(fn _url, _opts -> {:error, :econnrefused} end)

      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, :search_failed}
    end

    test "an HTTP double that raises is {:error, :search_failed} — never raises" do
      StubHTTP.stub(fn _url, _opts -> raise "kaboom" end)

      assert Nominatim.search("Zahav", @philly_area, @restaurant) == {:error, :search_failed}
    end
  end

  describe "the Provider contract" do
    test "cache_policy/0: 24-hour TTL, a 1-minute error TTL, and results may be stored" do
      assert Nominatim.cache_policy() == %{
               ttl_ms: :timer.hours(24),
               error_ttl_ms: :timer.minutes(1),
               may_store_results?: true
             }
    end

    test "attribution/0 credits OpenStreetMap contributors with the ODbL link, prefix split off" do
      # The split matters to the UI: only :text becomes the link (the frame links
      # nothing but the contributors phrase), and the href is the ODbL licence —
      # the brief's constraint 3, not osm.org/copyright.
      assert Nominatim.attribution() == %{
               prefix: "Places from ",
               text: "OpenStreetMap contributors",
               url: "https://opendatacommons.org/licenses/odbl/"
             }
    end

    test "location_mode/0 is :required" do
      assert Nominatim.location_mode() == :required
    end
  end

  describe "the SSRF guard stays shared (trap J)" do
    test "Consensus.LinkPreview.check_host/1 is exported — re-privatising it would silently un-guard every adapter" do
      Code.ensure_loaded!(Consensus.LinkPreview)
      assert function_exported?(Consensus.LinkPreview, :check_host, 1)
    end
  end

  describe "the prod registry (invariant 12)" do
    # Discovery.search/3 reaching this adapter IS covered in the test env — the
    # "through the real Nominatim adapter" describe in
    # test/consensus/discovery_test.exs registers it at runtime and drives the
    # two layers together against the HTTP stub. What that cannot prove is which
    # registry the OTHER envs actually load, so this describe reads it through
    # Config.Reader from the same files `mix release`/`mix phx.server` read, not
    # from this env's Application env (which config/test.exs points at
    # DiscoveryStub).
    test "config.exs registers four types, each the catalog then this one module, with different category data" do
      config = Config.Reader.read!("config/config.exs", env: :prod)
      providers = config[:consensus][Consensus.Discovery][:providers]
      catalog = Consensus.Catalog.Provider

      assert Map.keys(providers) |> Enum.sort() == ["bar", "bowling", "cinema", "restaurant"]

      assert providers["restaurant"] ==
               [{catalog, activity_type: "restaurant"}, {Nominatim, @restaurant}]

      assert providers["bar"] == [{catalog, activity_type: "bar"}, {Nominatim, @bar}]

      assert providers["bowling"] ==
               [
                 {catalog, activity_type: "bowling"},
                 {Nominatim, categories: [{"leisure", "bowling_alley"}]}
               ]

      assert providers["cinema"] ==
               [
                 {catalog, activity_type: "cinema"},
                 {Nominatim, categories: [{"amenity", "cinema"}]}
               ]

      # The invariant-12 proof, stated as data: the same two modules in the same order
      # for every type, with the type and the category lists as the only difference —
      # there is no per-type code for a branch to live in. The catalog is first so a
      # catalog hit never reaches Nominatim (D-060 §3.4).
      chains =
        providers |> Map.values() |> Enum.map(fn chain -> Enum.map(chain, &elem(&1, 0)) end)

      assert Enum.uniq(chains) == [[catalog, Nominatim]]

      lists =
        providers
        |> Map.values()
        |> Enum.map(fn chain -> elem(List.last(chain), 1)[:categories] end)

      assert length(Enum.uniq(lists)) == map_size(providers)

      # And the boot-time registry validation would accept it.
      assert Nominatim.cache_policy().may_store_results? == true
    end

    test "ASSIST_LIVE=1 in dev loads the same map as config.exs" do
      prod = Config.Reader.read!("config/config.exs", env: :prod)

      System.put_env("ASSIST_LIVE", "1")

      live =
        try do
          Config.Reader.read!("config/runtime.exs", env: :dev)
        after
          System.delete_env("ASSIST_LIVE")
        end

      assert live[:consensus][Consensus.Discovery][:providers] ==
               prod[:consensus][Consensus.Discovery][:providers]
    end

    test "the test env keeps the stub registry — which is why the assertions above read config files" do
      providers = Application.get_env(:consensus, Consensus.Discovery)[:providers]

      refute Nominatim in (providers |> Map.values() |> Enum.map(fn {module, _} -> module end))
      assert providers["restaurant"] == {Consensus.DiscoveryStub, []}
    end
  end
end
