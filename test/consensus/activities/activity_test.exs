defmodule Consensus.Activities.ActivityTest do
  use ExUnit.Case, async: true

  alias Consensus.Activities.Activity

  defp details(attrs), do: Activity.details_changeset(%Activity{}, attrs)

  defp errors_on(changeset, field) do
    for {^field, {message, _opts}} <- changeset.errors, do: message
  end

  describe "details_changeset/2 — phone" do
    test "accepts digits, spaces and + ( ) - . with at least 7 digits, stored as typed" do
      for phone <- ["+1-215-625-8800", "(215) 625 8800", "215.625.8800", "6258800"] do
        changeset = details(%{phone: phone})
        assert changeset.valid?, "expected #{inspect(phone)} to be accepted"
        assert Ecto.Changeset.get_change(changeset, :phone) == phone
      end
    end

    test "refuses letters, too few digits and anything over 32 characters" do
      for phone <- ["call us", "215-CALL-NOW", "911", "123 45", String.duplicate("1", 33)] do
        refute details(%{phone: phone}).valid?, "expected #{inspect(phone)} to be refused"
      end
    end

    test "a blank phone clears the detail" do
      changeset = Activity.details_changeset(%Activity{phone: "6258800"}, %{phone: "  "})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :phone) == nil
    end
  end

  describe "details_changeset/2 — location" do
    test "both or neither" do
      assert details(%{latitude: 39.9, longitude: -75.1}).valid?
      assert details(%{}).valid?
      # The error lands on the half that is missing.
      assert errors_on(details(%{latitude: 39.9}), :longitude) != []
      assert errors_on(details(%{longitude: -75.1}), :latitude) != []
    end

    test "in range" do
      refute details(%{latitude: 90.5, longitude: 0.0}).valid?
      refute details(%{latitude: 0.0, longitude: -180.5}).valid?
      assert details(%{latitude: -90.0, longitude: 180.0}).valid?
    end

    test "rounded to 7 decimals (OSM's precision)" do
      changeset = details(%{latitude: 39.946306012345, longitude: -75.145187098765})

      assert Ecto.Changeset.get_change(changeset, :latitude) == 39.946306
      assert Ecto.Changeset.get_change(changeset, :longitude) == -75.1451871
    end
  end

  describe "details_changeset/2 — address and category" do
    test "caps graphemes, not bytes" do
      at_cap = String.duplicate("é", Activity.max_address_length())
      assert details(%{address: at_cap}).valid?
      refute details(%{address: at_cap <> "é"}).valid?

      assert details(%{category: String.duplicate("x", Activity.max_category_length())}).valid?

      refute details(%{category: String.duplicate("x", Activity.max_category_length() + 1)}).valid?
    end

    test "the website is source_url and must be http(s)" do
      assert details(%{source_url: "https://zahavrestaurant.com"}).valid?
      refute details(%{source_url: "javascript:alert(1)"}).valid?
    end
  end

  describe "the two write paths stay separate" do
    test "changeset/2 cannot set a detail" do
      changeset =
        Activity.changeset(%Activity{}, %{
          name: "Zahav",
          phone: "6258800",
          address: "237 St James Pl",
          latitude: 1.0,
          longitude: 1.0,
          category: "israeli",
          osm_ref: "node/1"
        })

      assert Map.keys(changeset.changes) == [:name]
    end

    test "details_changeset/2 cannot set a name, description, image or osm_ref" do
      changeset =
        details(%{
          name: "Renamed",
          description: "new",
          image_url: "https://example.com/a.png",
          osm_ref: "node/1",
          phone: "6258800"
        })

      assert Map.keys(changeset.changes) == [:phone]
    end

    test "lookup_changeset/2 writes the name, a catalog row's description, the details and the provenance together" do
      changeset =
        Activity.lookup_changeset(%Activity{name: "zahav"}, %{
          name: "Zahav",
          source_url: "https://zahavrestaurant.com",
          phone: "+1-215-625-8800",
          osm_ref: "node/6374481270",
          catalog_item_id: 7,
          description: "Shared by whoever put it in the catalog.",
          group_id: 999,
          position: 9
        })

      assert changeset.valid?

      assert Enum.sort(Map.keys(changeset.changes)) ==
               [:catalog_item_id, :description, :name, :osm_ref, :phone, :source_url]
    end
  end

  describe "tel_href/1" do
    test "is built from + and digits only" do
      assert Activity.tel_href("+1 (215) 625-8800") == "tel:+12156258800"
      assert Activity.tel_href("215.625.8800") == "tel:2156258800"
    end

    test "is nil for nothing dialable" do
      assert Activity.tel_href(nil) == nil
      assert Activity.tel_href("") == nil
      assert Activity.tel_href("()") == nil
    end
  end
end
