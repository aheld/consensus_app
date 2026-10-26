defmodule Consensus.Discovery.ResultTest do
  use ExUnit.Case, async: true

  alias Consensus.Discovery.Result

  @zahav %Result{
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
    category: "israeli"
  }

  describe "persistable_attrs/1 — the retention firewall (D-060)" do
    test "every retainable field maps onto its Activity field; the FULL address is stored" do
      result = %Result{@zahav | retainable: Result.retainable_fields()}

      assert Result.persistable_attrs(result) == %{
               name: "Zahav",
               source_url: "https://www.zahavrestaurant.com/",
               phone: "+1-215-625-8800",
               address: "237 Saint James Place, Philadelphia",
               latitude: 39.946306,
               longitude: -75.145187,
               category: "israeli",
               osm_ref: "node/6374481270"
             }
    end

    test "a provider retaining only name and website persists nothing else" do
      result = %Result{@zahav | osm_ref: nil, retainable: [:name, :website_url]}

      assert Result.persistable_attrs(result) == %{
               name: "Zahav",
               source_url: "https://www.zahavrestaurant.com/"
             }
    end

    test "the default retainable list keeps nothing but provenance" do
      assert Result.persistable_attrs(@zahav) == %{osm_ref: "node/6374481270"}
      assert Result.persistable_attrs(%Result{@zahav | osm_ref: nil}) == %{}
    end

    test "latitude and longitude travel together or not at all" do
      only_lat = %Result{@zahav | osm_ref: nil, retainable: [:latitude]}
      assert Result.persistable_attrs(only_lat) == %{}

      missing_lon = %Result{
        @zahav
        | osm_ref: nil,
          longitude: nil,
          retainable: [:latitude, :longitude]
      }

      assert Result.persistable_attrs(missing_lon) == %{}
    end

    test "nil values are left out rather than written as nil" do
      bare = %Result{name: "Grandma's", source: :osm, retainable: Result.retainable_fields()}

      assert Result.persistable_attrs(bare) == %{name: "Grandma's"}
    end

    test "there is no rating or price to retain" do
      refute :rating in Result.retainable_fields()
      refute :price in Result.retainable_fields()
      refute Map.has_key?(%Result{name: "x", source: :osm}, :rating)
    end
  end
end
