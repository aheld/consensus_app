defmodule Consensus.Discovery.AreaTest do
  # Pure functions over values — no database, no global state.
  use ExUnit.Case, async: true

  alias Consensus.Discovery.Area

  describe "encode_bbox/1" do
    test "encodes as min_lat,min_lon,max_lat,max_lon — the Group.search_bbox format" do
      area = %Area{name: "Fishtown", bbox: {39.9615, -75.14, 39.9782, -75.12}}

      assert Area.encode_bbox(area) == "39.9615,-75.14,39.9782,-75.12"
    end

    test "tolerates integer coordinates" do
      area = %Area{name: "Testville", bbox: {1, 2, 3, 4}}

      assert Area.encode_bbox(area) == "1,2,3,4"
    end
  end

  describe "decode/2" do
    test "round-trips what encode_bbox/1 produced" do
      area = %Area{name: "Fishtown", bbox: {39.9615, -75.14, 39.9782, -75.12}}

      assert Area.decode("Fishtown", Area.encode_bbox(area)) == {:ok, area}
    end

    test "parses integer-looking parts as floats" do
      assert {:ok, %Area{bbox: {1.0, 2.0, 3.0, 4.0}}} = Area.decode("Testville", "1,2,3,4")
    end

    test "tolerates whitespace around the parts" do
      assert {:ok, %Area{bbox: {1.0, 2.0, 3.0, 4.0}}} = Area.decode("Testville", "1, 2, 3, 4")
    end

    test "refuses anything that is not four numbers" do
      for bad <- ["", "1,2,3", "1,2,3,4,5", "1,2,3,north", "a,b,c,d"] do
        assert Area.decode("Testville", bad) == {:error, :invalid_bbox}
      end
    end

    test "refuses nil in either position — a group that never answered the prompt" do
      assert Area.decode(nil, "1,2,3,4") == {:error, :invalid_bbox}
      assert Area.decode("Testville", nil) == {:error, :invalid_bbox}
      assert Area.decode(nil, nil) == {:error, :invalid_bbox}
    end
  end
end
