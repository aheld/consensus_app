defmodule Consensus.Discovery.GeocoderTest do
  # async: false: geocode/1 caches into the app-wide Consensus.Discovery.Cache ETS
  # table, which these tests flush.
  use ExUnit.Case, async: false

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Geocoder
  alias Consensus.GeocoderHTTPStub, as: StubHTTP

  # safe_lookup logs a double's raise at :error before degrading it to a tuple.
  @moduletag :capture_log

  setup do
    Consensus.Discovery.Cache.flush()
    StubHTTP.stub(fn _url, _opts -> {:error, :not_configured} end)
    :ok
  end

  defp fishtown_place(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Fishtown",
        "display_name" => "Fishtown, Philadelphia, Philadelphia County, Pennsylvania",
        # Nominatim order: [min_lat, max_lat, min_lon, max_lon] (south, north, west, east)
        "boundingbox" => ["39.9615", "39.9782", "-75.1400", "-75.1200"]
      },
      overrides
    )
  end

  describe "geocode/1 — parsing" do
    test "parses a jsonv2 answer into an Area, reordering the bbox" do
      StubHTTP.stub_places([fishtown_place()])

      assert {:ok, %Area{} = area} = Geocoder.geocode("Fishtown")
      assert area.name == "Fishtown"
      # {min_lat, min_lon, max_lat, max_lon} — not Nominatim's [S, N, W, E] order.
      assert area.bbox == {39.9615, -75.14, 39.9782, -75.12}
    end

    test "the parsed bbox round-trips through Area.encode_bbox/1 and decode/2" do
      StubHTTP.stub_places([fishtown_place()])

      assert {:ok, area} = Geocoder.geocode("Fishtown")
      encoded = Area.encode_bbox(area)
      assert {:ok, decoded} = Area.decode(area.name, encoded)
      assert decoded == area
    end

    test "falls back to display_name, then to the query, for the name" do
      StubHTTP.stub_places([Map.delete(fishtown_place(), "name")])

      assert {:ok, %Area{name: "Fishtown, Philadelphia" <> _}} = Geocoder.geocode("fishtown pa")

      Consensus.Discovery.Cache.flush()
      StubHTTP.stub_places([fishtown_place(%{"name" => "", "display_name" => " "})])

      assert {:ok, %Area{name: "fishtown pa"}} = Geocoder.geocode("fishtown pa")
    end

    test "only the first result counts (limit=1 is also requested)" do
      StubHTTP.stub_places([
        fishtown_place(),
        fishtown_place(%{"name" => "Fishtown II", "boundingbox" => ["1", "2", "3", "4"]})
      ])

      assert {:ok, %Area{name: "Fishtown"}} = Geocoder.geocode("Fishtown")
    end
  end

  describe "geocode/1 — error tagging" do
    test "zero results is {:error, :not_found}" do
      StubHTTP.stub_places([])

      assert Geocoder.geocode("nowhereville-xyz") == {:error, :not_found}
    end

    test "a non-200 is {:error, :geocode_failed}" do
      StubHTTP.stub(fn _url, _opts -> {:ok, %{status: 429, body: "slow down"}} end)

      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}
    end

    test "a transport error is {:error, :geocode_failed}" do
      StubHTTP.stub(fn _url, _opts -> {:error, :timeout} end)

      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}
    end

    test "an unparseable body is {:error, :geocode_failed}" do
      StubHTTP.stub(fn _url, _opts -> {:ok, %{status: 200, body: "<html>not json"}} end)

      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}
    end

    test "a malformed boundingbox is {:error, :geocode_failed}" do
      StubHTTP.stub_places([fishtown_place(%{"boundingbox" => ["north-ish", "2", "3", "4"]})])
      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}

      Consensus.Discovery.Cache.flush()
      StubHTTP.stub_places([Map.delete(fishtown_place(), "boundingbox")])
      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}
    end

    test "an HTTP double that raises is {:error, :geocode_failed} — never raises" do
      StubHTTP.stub(fn _url, _opts -> raise "kaboom" end)

      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}
    end

    test "blank or non-string input is {:error, :invalid_area} without an HTTP call" do
      test_pid = self()

      StubHTTP.stub(fn url, _opts ->
        send(test_pid, {:requested, url})
        {:error, :not_configured}
      end)

      assert Geocoder.geocode("") == {:error, :invalid_area}
      assert Geocoder.geocode("   ") == {:error, :invalid_area}
      assert Geocoder.geocode(nil) == {:error, :invalid_area}
      assert Geocoder.geocode(42) == {:error, :invalid_area}

      refute_receive {:requested, _url}
    end
  end

  describe "geocode/1 — the request itself" do
    test "hits Nominatim's search endpoint with q, format=jsonv2, limit=1 and a User-Agent" do
      test_pid = self()

      StubHTTP.stub(fn url, opts ->
        send(test_pid, {:requested, url, opts})
        {:ok, %{status: 200, body: Jason.encode!([fishtown_place()])}}
      end)

      assert {:ok, _area} = Geocoder.geocode("Fishtown, Philadelphia")
      assert_receive {:requested, url, opts}

      uri = URI.parse(url)
      assert uri.scheme == "https"
      assert uri.host == "nominatim.openstreetmap.org"
      assert uri.path == "/search"

      assert URI.decode_query(uri.query) == %{
               "q" => "Fishtown, Philadelphia",
               "format" => "jsonv2",
               "limit" => "1"
             }

      # Nominatim's usage policy requires an identifying User-Agent.
      assert {"user-agent", user_agent} =
               List.keyfind(Keyword.fetch!(opts, :headers), "user-agent", 0)

      assert user_agent =~ "Consensus"
    end
  end

  describe "geocode/1 — caching (Nominatim policy requires it)" do
    test "a success is cached: two lookups cost one request" do
      test_pid = self()

      StubHTTP.stub(fn url, _opts ->
        send(test_pid, {:requested, url})
        {:ok, %{status: 200, body: Jason.encode!([fishtown_place()])}}
      end)

      assert {:ok, area} = Geocoder.geocode("Fishtown")
      assert_receive {:requested, _url}

      assert {:ok, ^area} = Geocoder.geocode("Fishtown")
      refute_receive {:requested, _url}
    end

    test "the cache key normalises case and whitespace" do
      test_pid = self()

      StubHTTP.stub(fn url, _opts ->
        send(test_pid, {:requested, url})
        {:ok, %{status: 200, body: Jason.encode!([fishtown_place()])}}
      end)

      assert {:ok, area} = Geocoder.geocode("Fishtown")
      assert_receive {:requested, _url}

      assert {:ok, ^area} = Geocoder.geocode("  fishtown  ")
      refute_receive {:requested, _url}
    end

    test "failures are cached too, so a flapping endpoint is not hammered" do
      test_pid = self()

      StubHTTP.stub(fn url, _opts ->
        send(test_pid, {:requested, url})
        {:error, :timeout}
      end)

      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}
      assert_receive {:requested, _url}

      assert Geocoder.geocode("Fishtown") == {:error, :geocode_failed}
      refute_receive {:requested, _url}
    end
  end
end
