defmodule Consensus.CatalogTest do
  # async: false — several cases rewrite the Discovery provider registry in the
  # application environment, which is process-global.
  use Consensus.DataCase, async: false

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Catalog
  alias Consensus.Catalog.CatalogItem
  alias Consensus.Discovery
  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Result
  alias Consensus.NominatimHTTPStub
  alias Consensus.Repo

  @moduletag :capture_log

  doctest Consensus.Catalog

  # Written from docs/plans/item-details-and-catalog.md §3 (D-060).

  @philly %Area{name: "Philadelphia", bbox: {39.867, -75.2803, 40.1379, -74.9558}}
  @zahav_point %{latitude: 39.946306, longitude: -75.145187}

  setup do
    Discovery.Cache.flush()
    NominatimHTTPStub.stub(fn _url, _opts -> {:error, :not_configured} end)
    :ok
  end

  defp detailed(group, attrs) do
    group
    |> activity_fixture(Map.take(attrs, [:name]))
    |> Activity.lookup_changeset(Map.delete(attrs, :name))
    |> Repo.update!()
  end

  defp row!(%Activity{catalog_item_id: id}), do: Repo.get!(CatalogItem, id)

  defp put_chain(chain) do
    original = Application.get_env(:consensus, Discovery)
    Application.put_env(:consensus, Discovery, Keyword.put(original, :providers, chain))
    on_exit(fn -> Application.put_env(:consensus, Discovery, original) end)
  end

  describe "search_name/1" do
    test "folds apostrophes, accents, & and punctuation the same way for names and queries" do
      assert Catalog.search_name("Joe's Pizza") == Catalog.search_name("Joes Pizza")
      assert Catalog.search_name("Joe’s Pizza") == "joes pizza"
      assert Catalog.search_name("Café La Maude") == "cafe la maude"
      assert Catalog.search_name("Fish & Chips") == "fish and chips"
      assert Catalog.search_name("Night+Market!!") == "night market"
      assert Catalog.search_name("   ") == ""
    end
  end

  describe "share_activity/2" do
    test "creates a row from the snapshot, description included, with the sharer recorded" do
      scope = user_scope_fixture()
      group = group_fixture(scope)

      activity =
        detailed(group, %{
          name: "Zahav",
          description: "Get the hummus.",
          address: "237 Saint James Place, Philadelphia",
          phone: "+1-215-625-8800",
          osm_ref: "node/6374481270"
        })

      assert {:ok, shared} = Catalog.share_activity(scope, activity)
      assert shared.shared_to_catalog_at

      row = row!(shared)
      assert {row.name, row.search_name, row.description} == {"Zahav", "zahav", "Get the hummus."}
      assert {row.activity_type, row.osm_ref} == {group.activity_type, "node/6374481270"}
      assert {row.shared_from_activity_id, row.shared_by_user_id} == {activity.id, scope.user.id}
      assert row.shared_by_anonymous_organizer_id == nil
    end

    test "an organizer with no account can share; the identity is the provenance" do
      {scope, group} = anonymous_group_fixture()
      activity = detailed(group, %{name: "Zahav", address: "237 St James Pl"})

      assert {:ok, shared} = Catalog.share_activity(scope, activity)
      row = row!(shared)

      assert {row.shared_by_user_id, row.shared_by_anonymous_organizer_id} ==
               {nil, scope.anonymous_organizer.id}
    end

    test "a bare name has nothing to find and is refused" do
      scope = user_scope_fixture()
      activity = scope |> group_fixture() |> activity_fixture(%{name: "Grandma's"})

      assert Catalog.share_activity(scope, activity) == {:error, :nothing_to_find}
      assert Repo.aggregate(CatalogItem, :count) == 0
    end

    test "someone else's option is refused, both kinds of owner" do
      {anon_scope, anon_group} = anonymous_group_fixture()
      user_scope = user_scope_fixture()
      user_activity = user_scope |> group_fixture() |> detailed(%{name: "A", address: "1 St"})
      anon_activity = detailed(anon_group, %{name: "B", address: "2 St"})

      assert Catalog.share_activity(anon_scope, user_activity) == {:error, :unauthorized}
      assert Catalog.share_activity(user_scope, anon_activity) == {:error, :unauthorized}
      assert Catalog.unshare_activity(anon_scope, user_activity) == {:error, :unauthorized}
      assert Repo.aggregate(CatalogItem, :count) == 0
    end

    test "is allowed after publish: it does not change the option" do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity = detailed(group, %{name: "Zahav", address: "237 St James Pl"})
      {:ok, _group} = Activities.publish_group(scope, group)

      assert {:ok, _shared} = Catalog.share_activity(scope, activity)
    end

    test "dedupes by osm_ref: links to the other organizer's row and does not rewrite it" do
      first_scope = user_scope_fixture()
      second_scope = user_scope_fixture()

      first =
        first_scope
        |> group_fixture()
        |> detailed(%{
          name: "Zahav",
          phone: "+1 215 555 0100",
          osm_ref: "node/1",
          address: "A St"
        })

      second =
        second_scope
        |> group_fixture()
        |> detailed(%{
          name: "ZAHAV!!",
          phone: "+1 215 555 0199",
          osm_ref: "node/1",
          address: "B St"
        })

      {:ok, first} = Catalog.share_activity(first_scope, first)
      {:ok, second} = Catalog.share_activity(second_scope, second)

      assert first.catalog_item_id == second.catalog_item_id
      assert Repo.aggregate(CatalogItem, :count) == 1
      assert row!(first).phone == "+1 215 555 0100"
    end

    test "dedupes by normalised name within ~50 m; farther away is a different place" do
      scope = user_scope_fixture()
      group = group_fixture(scope)

      a = detailed(group, Map.merge(%{name: "Joe's Pizza"}, @zahav_point))
      # ~30 m north.
      b = detailed(group, %{name: "Joes Pizza", latitude: 39.94658, longitude: -75.145187})
      # ~1.1 km north.
      c = detailed(group, %{name: "Joe's Pizza", latitude: 39.9563, longitude: -75.145187})

      {:ok, a} = Catalog.share_activity(scope, a)
      {:ok, b} = Catalog.share_activity(scope, b)
      {:ok, c} = Catalog.share_activity(scope, c)

      assert a.catalog_item_id == b.catalog_item_id
      refute c.catalog_item_id == a.catalog_item_id
    end
  end

  describe "the sync rules" do
    setup do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity = detailed(group, %{name: "Zahav", address: "237 St James Pl"})
      {:ok, activity} = Catalog.share_activity(scope, activity)
      %{scope: scope, group: group, activity: activity}
    end

    test "the row an option created follows its later detail edits", ctx do
      {:ok, _} =
        Activities.update_activity_details(ctx.scope, ctx.activity, %{phone: "2156258800"})

      assert row!(ctx.activity).phone == "2156258800"
    end

    test "an admin edit stops the sync", ctx do
      row!(ctx.activity)
      |> Ecto.Changeset.change(admin_edited_at: DateTime.utc_now(:second))
      |> Repo.update!()

      {:ok, _} =
        Activities.update_activity_details(ctx.scope, ctx.activity, %{phone: "2156258800"})

      assert row!(ctx.activity).phone == nil
    end

    test "a row someone else created never follows this option", ctx do
      other_scope = user_scope_fixture()

      other =
        other_scope
        |> group_fixture()
        |> detailed(%{name: "Zahav", address: "237 St James Pl", osm_ref: "node/9"})

      {:ok, other} = Catalog.share_activity(other_scope, other)

      mine = detailed(ctx.group, %{name: "Zahav", osm_ref: "node/9", address: "x"})
      {:ok, mine} = Catalog.share_activity(ctx.scope, mine)
      assert mine.catalog_item_id == other.catalog_item_id

      {:ok, _} = Activities.update_activity_details(ctx.scope, mine, %{phone: "2156258800"})
      assert row!(other).phone == nil
    end

    test "unsharing deletes a row nothing else links to", ctx do
      row_id = ctx.activity.catalog_item_id
      {:ok, unshared} = Catalog.unshare_activity(ctx.scope, ctx.activity)

      assert {unshared.catalog_item_id, unshared.shared_to_catalog_at} == {nil, nil}
      refute Repo.get(CatalogItem, row_id)
    end

    test "unsharing deletes the row even when others used it — they hold their own copies",
         ctx do
      other_scope = user_scope_fixture()
      other = other_scope |> group_fixture() |> activity_fixture()

      {:ok, used} =
        Activities.adopt_lookup_result(other_scope, other, %{
          name: "Zahav",
          catalog_item_id: ctx.activity.catalog_item_id
        })

      row_id = ctx.activity.catalog_item_id
      {:ok, _unshared} = Catalog.unshare_activity(ctx.scope, ctx.activity)

      refute Repo.get(CatalogItem, row_id)
      assert Repo.get!(Activity, used.id).name == "Zahav"
    end

    test "a row another organizer shared into passes to them, with none of this option's data",
         ctx do
      ctx.activity |> Ecto.Changeset.change(osm_ref: "node/77") |> Repo.update!()

      row!(ctx.activity)
      |> Ecto.Changeset.change(osm_ref: "node/77", description: "Mine.")
      |> Repo.update!()

      other_scope = user_scope_fixture()

      theirs =
        other_scope
        |> group_fixture()
        |> detailed(%{name: "Zahav", osm_ref: "node/77", address: "Their St"})

      {:ok, theirs} = Catalog.share_activity(other_scope, theirs)
      assert theirs.catalog_item_id == ctx.activity.catalog_item_id

      {:ok, _unshared} = Catalog.unshare_activity(ctx.scope, Repo.get!(Activity, ctx.activity.id))

      row = Repo.get!(CatalogItem, theirs.catalog_item_id)

      assert {row.shared_from_activity_id, row.shared_by_user_id} ==
               {theirs.id, other_scope.user.id}

      assert {row.address, row.description} == {"Their St", nil}
    end

    test "an edit that leaves nothing to find it by ends the share", ctx do
      row_id = ctx.activity.catalog_item_id

      {:ok, _} =
        Activities.update_activity_details(ctx.scope, ctx.activity, %{address: "", source_url: ""})

      refute Repo.get(CatalogItem, row_id)
      assert Repo.get!(Activity, ctx.activity.id).shared_to_catalog_at == nil
    end

    test "deleting the option deletes the row it shared", ctx do
      row_id = ctx.activity.catalog_item_id
      {:ok, _} = Activities.delete_activity(ctx.scope, ctx.activity)

      refute Repo.get(CatalogItem, row_id)
    end

    test "adopting another catalog row ends this option's own share first", ctx do
      own_row = ctx.activity.catalog_item_id
      other_scope = user_scope_fixture()

      theirs =
        other_scope
        |> group_fixture()
        |> detailed(Map.merge(%{name: "Kismet"}, @zahav_point))

      {:ok, theirs} = Catalog.share_activity(other_scope, theirs)

      {:ok, relinked} =
        Activities.adopt_lookup_result(ctx.scope, ctx.activity, %{
          name: "Kismet",
          catalog_item_id: theirs.catalog_item_id
        })

      refute Repo.get(CatalogItem, own_row)

      assert {relinked.catalog_item_id, relinked.shared_to_catalog_at} ==
               {theirs.catalog_item_id, nil}
    end
  end

  describe "search/3 — matching (§3.3)" do
    setup do
      scope = user_scope_fixture()
      %{scope: scope, group: group_fixture(scope)}
    end

    defp share!(ctx, attrs) do
      activity = detailed(ctx.group, attrs)
      {:ok, shared} = Catalog.share_activity(ctx.scope, activity)
      row!(shared)
    end

    test "every query token is a prefix of a name token, in any order", ctx do
      share!(ctx, Map.merge(%{name: "Pizzeria Beddia"}, @zahav_point))

      assert [%CatalogItem{name: "Pizzeria Beddia"}] =
               Catalog.search(ctx.group.activity_type, "beddia pizz", @philly)

      assert [] = Catalog.search(ctx.group.activity_type, "beddia pasta", @philly)
    end

    test "Joes Pizza finds Joe's Pizza — D-059's recorded miss", ctx do
      share!(ctx, Map.merge(%{name: "Joe's Pizza"}, @zahav_point))

      assert [%CatalogItem{name: "Joe's Pizza"}] =
               Catalog.search(ctx.group.activity_type, "Joes Pizza", @philly)
    end

    test "a located row must fall inside the group's (widened) area", ctx do
      share!(ctx, %{name: "Kismet", latitude: 34.0981, longitude: -118.3250})

      assert [] = Catalog.search(ctx.group.activity_type, "kismet", @philly)
      assert [_] = Catalog.search(ctx.group.activity_type, "kismet", nil)
    end

    test "an unlocated row never answers inside a group area — it would stop the local lookup",
         ctx do
      share!(ctx, %{name: "Joe's Pizza", address: "somewhere else entirely"})

      assert [] = Catalog.search(ctx.group.activity_type, "joes pizza", @philly)
    end

    test "with no area an unlocated row answers only on the exact name, after located ones",
         ctx do
      share!(ctx, %{name: "Joe's Pizza", address: "somewhere"})
      located = share!(ctx, %{name: "Joe's Pizza Express", latitude: 39.95, longitude: -75.16})

      assert [%CatalogItem{id: id}] = Catalog.search(ctx.group.activity_type, "joe", nil)
      assert id == located.id
      assert [first, second] = Catalog.search(ctx.group.activity_type, "joes pizza", nil)
      assert first.id == located.id
      assert second.latitude == nil
    end

    test "hidden rows and other types are never returned; at most three, most-used first", ctx do
      rows = for n <- 1..4, do: share!(ctx, Map.merge(%{name: "Vernick #{n}"}, @zahav_point))
      [hidden | _] = rows
      hidden |> CatalogItem.status_changeset("hidden") |> Repo.update!()
      favourite = List.last(rows)
      favourite |> Ecto.Changeset.change(use_count: 5) |> Repo.update!()

      results = Catalog.search(ctx.group.activity_type, "vernick", @philly)
      assert length(results) == 3
      refute Enum.any?(results, &(&1.id == hidden.id))
      assert hd(results).id == favourite.id

      assert [] = Catalog.search("some-other-type", "vernick", @philly)
    end
  end

  describe "the lookup chain (§3.4)" do
    setup do
      scope = user_scope_fixture()
      group = group_fixture(scope)

      chain = [
        {Consensus.Catalog.Provider, activity_type: group.activity_type},
        {Consensus.Discovery.Provider.Nominatim, categories: [{"amenity", "restaurant"}]}
      ]

      put_chain(%{group.activity_type => chain})
      %{scope: scope, group: group}
    end

    defp counting_nominatim(places) do
      test_pid = self()

      NominatimHTTPStub.stub(fn url, _opts ->
        send(test_pid, {:nominatim, url})
        {:ok, %{status: 200, body: Jason.encode!(places)}}
      end)
    end

    test "a catalog hit answers and Nominatim is never asked", ctx do
      activity =
        detailed(ctx.group, Map.merge(%{name: "Joe's Pizza", osm_ref: "node/5"}, @zahav_point))

      {:ok, shared} = Catalog.share_activity(ctx.scope, activity)
      counting_nominatim([])
      granted = Discovery.Nominatim.Gate.granted()

      assert {:ok, [%Result{} = hit]} =
               Discovery.search(ctx.group.activity_type, "Joes Pizza", @philly)

      assert {hit.source, hit.catalog_item_id} == {:catalog, shared.catalog_item_id}

      assert hit.retainable == Result.retainable_fields()
      # An OSM-derived row owes the OSM credit; one an organizer typed would not.
      assert Discovery.attribution_for_results([hit]).text == "OpenStreetMap contributors"

      refute_received {:nominatim, _}
      assert Discovery.Nominatim.Gate.granted() == granted
    end

    test "an organizer-entered row owes no credit", ctx do
      activity = detailed(ctx.group, Map.merge(%{name: "Grandma's Kitchen"}, @zahav_point))
      {:ok, _} = Catalog.share_activity(ctx.scope, activity)

      assert {:ok, [hit]} = Discovery.search(ctx.group.activity_type, "grandmas kitchen", @philly)
      assert Discovery.attribution_for_results([hit]) == nil
    end

    test "a catalog miss falls through to Nominatim", ctx do
      counting_nominatim([
        %{
          "osm_type" => "node",
          "osm_id" => 1,
          "category" => "amenity",
          "type" => "restaurant",
          "name" => "Zahav"
        }
      ])

      assert {:ok, [%Result{source: :osm}]} =
               Discovery.search(ctx.group.activity_type, "zahav", @philly)

      assert_received {:nominatim, _}
    end

    test "using a catalog result links the option and counts the use; its later edits stay local",
         ctx do
      shared =
        detailed(
          ctx.group,
          Map.merge(%{name: "Zahav", description: "Shared blurb."}, @zahav_point)
        )

      {:ok, shared} = Catalog.share_activity(ctx.scope, shared)

      other_scope = user_scope_fixture()
      other_group = group_fixture(other_scope)
      typed = activity_fixture(other_group, %{name: "zahav"})

      {:ok, [hit]} = Discovery.search(ctx.group.activity_type, "zahav", @philly)

      {:ok, used} =
        Activities.adopt_lookup_result(other_scope, typed, Result.persistable_attrs(hit))

      assert {used.name, used.description, used.catalog_item_id} ==
               {"Zahav", "Shared blurb.", shared.catalog_item_id}

      assert used.shared_to_catalog_at == nil
      assert row!(shared).use_count == 1

      {:ok, _} = Activities.update_activity_details(other_scope, used, %{phone: "2156258800"})
      assert row!(shared).phone == nil
    end
  end
end
