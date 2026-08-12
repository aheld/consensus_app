defmodule Consensus.Discovery.Provider.OverpassTest do
  # async: true is safe here: the adapter is called directly (never through
  # Consensus.Discovery, so the shared cache table is untouched), and the HTTP
  # double is installed in this test's own process dictionary.
  use ExUnit.Case, async: true

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Provider.Overpass
  alias Consensus.Discovery.Result
  alias Consensus.OverpassHTTPStub, as: StubHTTP

  # safe_search logs a double's raise at :error before degrading it to a tuple.
  @moduletag :capture_log

  @philly_bbox {39.8670, -75.2803, 40.1379, -74.9558}
  @philly_area %Area{name: "Philadelphia", bbox: @philly_bbox}
  @tags [tags: [{"amenity", "restaurant"}]]

  setup do
    StubHTTP.stub(fn _url, _ql, _opts -> {:error, :not_configured} end)
    :ok
  end

  defp node_el(id, tags), do: %{"type" => "node", "id" => id, "tags" => tags}
  defp way_el(id, tags), do: %{"type" => "way", "id" => id, "tags" => tags}

  # A stub that records the request and answers with zero elements.
  defp install_recording_stub do
    test_pid = self()

    StubHTTP.stub(fn url, ql, opts ->
      send(test_pid, {:posted, url, ql, opts})
      {:ok, %{status: 200, body: Jason.encode!(%{"elements" => []})}}
    end)
  end

  describe "search/3 — the generated QL" do
    test "carries [out:json], the 10s server timeout, node+way clauses with the configured tags, the name regex and the bbox" do
      install_recording_stub()

      assert {:ok, []} = Overpass.search("Zahav", @philly_area, @tags)
      assert_receive {:posted, _url, ql, _opts}

      assert ql =~ "[out:json][timeout:10];"

      # Overpass bbox order: (south, west, north, east) = Area's
      # {min_lat, min_lon, max_lat, max_lon}.
      bbox = "(39.867,-75.2803,40.1379,-74.9558)"

      assert ql =~ ~S(node["amenity"="restaurant"]["name"~"Zahav",i]) <> bbox <> ";"
      assert ql =~ ~S(way["amenity"="restaurant"]["name"~"Zahav",i]) <> bbox <> ";"

      # The server-side cap: Discovery displays at most 3; the QL asks for a
      # bounded handful so dropped unnamed elements cannot starve the list.
      # `tags` verbosity: the mapper reads only type/id/tags, so geometry and
      # way member lists are never requested.
      assert ql =~ "out tags 10;"
    end

    test "every configured tag pair lands as its own filter" do
      install_recording_stub()

      assert {:ok, []} =
               Overpass.search("Lanes", @philly_area,
                 tags: [{"leisure", "bowling_alley"}, {"amenity", "cinema"}]
               )

      assert_receive {:posted, _url, ql, _opts}
      assert ql =~ ~S(node["leisure"="bowling_alley"]["amenity"="cinema"]["name"~"Lanes",i])
    end

    test "regex metacharacters in the query are escaped to literals, through both escaping layers" do
      install_recording_stub()

      assert {:ok, []} = Overpass.search(~S{Crab "Shack" (South).* [b]}, @philly_area, @tags)
      assert_receive {:posted, _url, ql, _opts}

      # Regex layer first (\( \) \. \* \[ \]), then the QL string layer doubles
      # those backslashes and escapes the quotes.
      assert ql =~ ~S{["name"~"Crab \"Shack\" \\(South\\)\\.\\* \\[b\\]",i]}
    end

    test "a query built to break out of the QL string cannot: quotes and brackets arrive escaped" do
      install_recording_stub()

      assert {:ok, []} = Overpass.search(~S{Zahav",i](0,0,0,0);}, @philly_area, @tags)
      assert_receive {:posted, _url, ql, _opts}

      # The injected quote is \"-escaped, so the name filter still terminates
      # where the adapter's template says it does — no smuggled statements.
      assert ql =~ ~S{["name"~"Zahav\",i\\]\\(0,0,0,0\\);",i]}
      refute ql =~ "out body"
    end

    test "control characters are flattened before either escaping layer" do
      install_recording_stub()

      assert {:ok, []} = Overpass.search("Za\nhav\x01", @philly_area, @tags)
      assert_receive {:posted, _url, ql, _opts}

      assert ql =~ ~S{["name"~"Za hav",i]}
    end
  end

  describe "search/3 — refusals that never touch the network" do
    test "a nil area is {:ok, []} (location_mode is :required; the rule for a non-answer is silence)" do
      install_recording_stub()

      assert Overpass.search("Zahav", nil, @tags) == {:ok, []}
      refute_receive {:posted, _url, _ql, _opts}
    end

    test "an empty tag list is {:ok, []} — a misconfigured registry entry must not match everything in the bbox" do
      install_recording_stub()

      assert Overpass.search("Zahav", @philly_area, tags: []) == {:ok, []}
      assert Overpass.search("Zahav", @philly_area, []) == {:ok, []}
      refute_receive {:posted, _url, _ql, _opts}
    end

    test "a query that sanitises to nothing is {:ok, []} — never a match-everything regex" do
      install_recording_stub()

      assert Overpass.search("\x01\x02", @philly_area, @tags) == {:ok, []}
      refute_receive {:posted, _url, _ql, _opts}
    end

    test "invalid UTF-8 input is {:ok, []}, never a raise — the sanitiser must be bytewise-safe" do
      # The control-character regex sanitize_query/1 runs is `~r/.../u`, which
      # requires valid UTF-8 and raises ArgumentError otherwise — outside
      # safe_search's rescue, since sanitize_query/1 runs before that
      # boundary. A query is attacker-influenceable input (a paste), so this
      # must degrade like every other refusal here, not crash the caller.
      install_recording_stub()

      assert Overpass.search(<<255, 34, 59>>, @philly_area, @tags) == {:ok, []}
      refute_receive {:posted, _url, _ql, _opts}
    end
  end

  describe "search/3 — the request" do
    test "POSTs to the Overpass interpreter with an identifying User-Agent and the ~10s receive budget" do
      install_recording_stub()

      assert {:ok, []} = Overpass.search("Zahav", @philly_area, @tags)
      assert_receive {:posted, url, _ql, opts}

      assert url == "https://overpass-api.de/api/interpreter"

      assert {"user-agent", user_agent} =
               List.keyfind(Keyword.fetch!(opts, :headers), "user-agent", 0)

      assert user_agent =~ "Consensus"

      # Research §4.6: measured Overpass latency is 1.5–14s, so LinkPreview's
      # 5s receive timeout is too tight here.
      assert Keyword.fetch!(opts, :receive_timeout_ms) == 10_000
    end
  end

  describe "search/3 — element mapping" do
    test "maps a node with the full tag set: name, website, address, cuisine chip, external_ref, source" do
      StubHTTP.stub_elements([
        node_el(5_678_901, %{
          "name" => "Zahav",
          "website" => "https://www.zahavrestaurant.test/",
          "addr:housenumber" => "237",
          "addr:street" => "Saint James Place",
          "cuisine" => "middle_eastern;israeli"
        })
      ])

      assert {:ok, [%Result{} = result]} = Overpass.search("Zahav", @philly_area, @tags)

      assert result.name == "Zahav"
      assert result.website_url == "https://www.zahavrestaurant.test/"
      assert result.address == "237 Saint James Place"
      assert result.chips == [{"cuisine", "middle eastern"}]
      assert result.external_ref == "node/5678901"
      assert result.source == :osm
    end

    test "a way gets a way/<id> external_ref" do
      StubHTTP.stub_elements([way_el(42, %{"name" => "North Bowl"})])

      assert {:ok, [%Result{external_ref: "way/42"}]} =
               Overpass.search("North Bowl", @philly_area, @tags)
    end

    test "unnamed, blank-named, tagless and relation elements are dropped; named ones survive in order" do
      StubHTTP.stub_elements([
        node_el(1, %{"amenity" => "restaurant"}),
        node_el(2, %{"name" => "   "}),
        %{"type" => "node", "id" => 3},
        %{"type" => "relation", "id" => 4, "tags" => %{"name" => "A Relation"}},
        node_el(5, %{"name" => "First"}),
        way_el(6, %{"name" => "Second"})
      ])

      assert {:ok, results} = Overpass.search("anything", @philly_area, @tags)
      assert Enum.map(results, & &1.name) == ["First", "Second"]
    end

    test "website is picked from website | contact:website | url, first valid" do
      StubHTTP.stub_elements([
        node_el(1, %{
          "name" => "Both",
          "website" => "https://first.test/",
          "url" => "https://second.test/"
        }),
        node_el(2, %{"name" => "Contact only", "contact:website" => "https://contact.test/"}),
        node_el(3, %{"name" => "Url only", "url" => "https://url-tag.test/"}),
        node_el(4, %{"name" => "None"})
      ])

      assert {:ok, results} = Overpass.search("anything", @philly_area, @tags)

      assert Enum.map(results, & &1.website_url) == [
               "https://first.test/",
               "https://contact.test/",
               "https://url-tag.test/",
               nil
             ]
    end

    test "an invalid earlier candidate falls through to a later valid one" do
      StubHTTP.stub_elements([
        node_el(1, %{
          "name" => "Fallthrough",
          "website" => "javascript:alert(1)",
          "contact:website" => "http://10.0.0.1/intranet",
          "url" => "https://legit.test/"
        })
      ])

      assert {:ok, [%Result{website_url: "https://legit.test/"}]} =
               Overpass.search("anything", @philly_area, @tags)
    end

    test "SSRF (trap J): a private-IP website is nulled, the result survives" do
      StubHTTP.stub_elements([
        node_el(1, %{
          "name" => "Crafted",
          "website" => "http://192.168.1.1/",
          "addr:street" => "Frankford Ave"
        })
      ])

      assert {:ok, [%Result{} = result]} = Overpass.search("anything", @philly_area, @tags)
      assert result.website_url == nil
      assert result.name == "Crafted"
      assert result.address == "Frankford Ave"
    end

    test "SSRF (trap J): non-http schemes, relative URLs, loopback and the metadata host are all rejected" do
      StubHTTP.stub_elements([
        node_el(1, %{"name" => "JS", "website" => "javascript:alert(1)"}),
        node_el(2, %{"name" => "FTP", "website" => "ftp://files.test/menu.pdf"}),
        node_el(3, %{"name" => "Relative", "website" => "/menu"}),
        node_el(4, %{"name" => "Loopback", "website" => "http://127.0.0.1/"}),
        node_el(5, %{"name" => "Metadata", "website" => "http://metadata.google.internal/"}),
        node_el(6, %{"name" => "Link-local", "website" => "https://169.254.169.254/"})
      ])

      assert {:ok, results} = Overpass.search("anything", @philly_area, @tags)
      assert length(results) == 6
      assert Enum.all?(results, &is_nil(&1.website_url))
    end

    test "SSRF (trap J): IPv4-mapped IPv6 spellings of the same targets are rejected too" do
      # These three were the demonstrated blind spot: an OSM website tag of
      # http://[::ffff:169.254.169.254]/ used to be KEPT, stored as source_url,
      # and later fetched by LinkPreview through the identical hole. The shared
      # guard now unwraps the embedded IPv4, so both callers reject it at once.
      StubHTTP.stub_elements([
        node_el(1, %{"name" => "Mapped loopback", "website" => "http://[::ffff:127.0.0.1]/"}),
        node_el(2, %{"name" => "Mapped RFC1918", "website" => "http://[::ffff:10.0.0.1]/"}),
        node_el(3, %{
          "name" => "Mapped metadata",
          "website" => "https://[::ffff:169.254.169.254]/",
          "addr:street" => "Frankford Ave"
        })
      ])

      assert {:ok, results} = Overpass.search("anything", @philly_area, @tags)
      assert length(results) == 3
      assert Enum.all?(results, &is_nil(&1.website_url))
      # Nulled, never dropped: the name + address suggestion still stands.
      assert Enum.at(results, 2).address == "Frankford Ave"
    end

    test "address shapes: housenumber+street, street alone, neither" do
      StubHTTP.stub_elements([
        node_el(1, %{"name" => "Full", "addr:housenumber" => "237", "addr:street" => "Main St"}),
        node_el(2, %{"name" => "Street only", "addr:street" => "Main St"}),
        node_el(3, %{"name" => "Number only", "addr:housenumber" => "237"}),
        node_el(4, %{"name" => "Neither"})
      ])

      assert {:ok, results} = Overpass.search("anything", @philly_area, @tags)
      assert Enum.map(results, & &1.address) == ["237 Main St", "Main St", nil, nil]
    end

    test "cuisine humanisation: first semicolon value, underscores to spaces; absent means no chips" do
      StubHTTP.stub_elements([
        node_el(1, %{"name" => "Multi", "cuisine" => "middle_eastern;israeli"}),
        node_el(2, %{"name" => "Plain", "cuisine" => "thai"}),
        node_el(3, %{"name" => "Blank", "cuisine" => "  "}),
        node_el(4, %{"name" => "None"})
      ])

      assert {:ok, results} = Overpass.search("anything", @philly_area, @tags)

      assert Enum.map(results, & &1.chips) == [
               [{"cuisine", "middle eastern"}],
               [{"cuisine", "thai"}],
               nil,
               nil
             ]
    end
  end

  describe "search/3 — the error taxonomy (trap L)" do
    test "HTTP 429 is {:error, :rate_limited} — a first-class, expected outcome" do
      StubHTTP.stub(fn _url, _ql, _opts -> {:ok, %{status: 429, body: "rate limited"}} end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :rate_limited}
    end

    test "HTTP 504 is {:error, :gateway_timeout} — distinct from 429, per the research" do
      StubHTTP.stub(fn _url, _ql, _opts -> {:ok, %{status: 504, body: "timeout"}} end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :gateway_timeout}
    end

    test "a transport timeout is {:error, :timeout} — both the bare atom and the Req/Mint struct shape" do
      StubHTTP.stub(fn _url, _ql, _opts -> {:error, :timeout} end)
      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :timeout}

      StubHTTP.stub(fn _url, _ql, _opts -> {:error, %{reason: :timeout}} end)
      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :timeout}
    end

    test "an unparseable body is {:error, :malformed}" do
      StubHTTP.stub(fn _url, _ql, _opts -> {:ok, %{status: 200, body: "<html>not json"}} end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :malformed}
    end

    test "valid JSON without an elements list is {:error, :malformed} too" do
      StubHTTP.stub(fn _url, _ql, _opts ->
        {:ok, %{status: 200, body: Jason.encode!(%{"remark" => "runtime error"})}}
      end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :malformed}

      StubHTTP.stub(fn _url, _ql, _opts ->
        {:ok, %{status: 200, body: Jason.encode!(%{"elements" => "nope"})}}
      end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :malformed}
    end

    test "any other non-200 is {:error, {:http, status}}" do
      StubHTTP.stub(fn _url, _ql, _opts -> {:ok, %{status: 400, body: "parse error"}} end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, {:http, 400}}
    end

    test "a non-timeout transport error is {:error, :search_failed}" do
      StubHTTP.stub(fn _url, _ql, _opts -> {:error, :econnrefused} end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :search_failed}
    end

    test "an HTTP double that raises is {:error, :search_failed} — never raises" do
      StubHTTP.stub(fn _url, _ql, _opts -> raise "kaboom" end)

      assert Overpass.search("Zahav", @philly_area, @tags) == {:error, :search_failed}
    end
  end

  describe "the Provider contract" do
    test "cache_policy/0: 15-minute TTL, a shorter error TTL, and results may be stored" do
      policy = Overpass.cache_policy()

      assert policy.ttl_ms == :timer.minutes(15)
      assert policy.error_ttl_ms < policy.ttl_ms
      assert policy.may_store_results? == true
    end

    test "attribution/0 credits OpenStreetMap contributors with the ODbL link, prefix split off" do
      # The split matters to the UI: only :text becomes the link (the frame links
      # nothing but the contributors phrase), and the href is the ODbL licence —
      # the brief's constraint 3, not osm.org/copyright.
      assert Overpass.attribution() == %{
               prefix: "Places from ",
               text: "OpenStreetMap contributors",
               url: "https://opendatacommons.org/licenses/odbl/"
             }
    end

    test "location_mode/0 is :required" do
      assert Overpass.location_mode() == :required
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
    # "through the real Overpass adapter" describe in
    # test/consensus/discovery_test.exs registers Overpass at runtime and drives
    # the two layers together against the HTTP stub. What that cannot prove is
    # which registry the OTHER envs actually load, so this describe reads it
    # through Config.Reader from the same files `mix release`/`mix phx.server`
    # read, not from this env's Application env (which config/test.exs
    # deliberately points at DiscoveryStub).
    test "config.exs registers four types on this one module with different tag data" do
      config = Config.Reader.read!("config/config.exs", env: :prod)
      providers = config[:consensus][Consensus.Discovery][:providers]

      assert providers == %{
               "restaurant" => {Overpass, tags: [{"amenity", "restaurant"}]},
               "bar" => {Overpass, tags: [{"amenity", "bar"}]},
               "bowling" => {Overpass, tags: [{"leisure", "bowling_alley"}]},
               "cinema" => {Overpass, tags: [{"amenity", "cinema"}]}
             }

      # The invariant-12 proof, stated as data: one module, four tag lists —
      # there is no per-type code for a branch to live in.
      modules = providers |> Map.values() |> Enum.map(fn {module, _opts} -> module end)
      assert Enum.uniq(modules) == [Overpass]

      tag_lists = providers |> Map.values() |> Enum.map(fn {_module, opts} -> opts[:tags] end)
      assert length(Enum.uniq(tag_lists)) == map_size(providers)

      # And the boot-time registry validation would accept it: the adapter may
      # store results, so Consensus.Discovery.Cache's start-up check passes.
      assert Overpass.cache_policy().may_store_results? == true
    end

    test "the test env keeps the stub registry — which is why the assertion above reads config files, not Application env" do
      providers = Application.get_env(:consensus, Consensus.Discovery)[:providers]

      refute Overpass in (providers |> Map.values() |> Enum.map(fn {module, _} -> module end))
      assert providers["restaurant"] == {Consensus.DiscoveryStub, []}
    end
  end
end
