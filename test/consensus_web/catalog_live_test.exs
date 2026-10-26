defmodule ConsensusWeb.CatalogLiveTest do
  @moduledoc """
  The shared catalog in the browser (D-060, frames `t7-a`/`t7-c`): the **Let anyone
  find this** toggle on `02b`, and a catalog answer in the `02` assist slot.
  """
  # async: false — the assist case rewrites the Discovery provider registry.
  use ConsensusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Catalog
  alias Consensus.Catalog.CatalogItem
  alias Consensus.NominatimHTTPStub
  alias Consensus.Repo

  @moduletag :capture_log

  setup :register_and_log_in_user

  setup do
    Consensus.LinkPreview.Cache.flush()
    Consensus.Discovery.Cache.flush()
    Consensus.LinkPreviewStub.stub(fn _url, _opts -> {:error, :not_configured} end)
    NominatimHTTPStub.stub(fn _url, _opts -> {:error, :not_configured} end)
    :ok
  end

  defp stored(activity), do: Repo.get!(Activity, activity.id)

  describe "the share toggle (t7-c)" do
    test "disabled for a bare name, with the reason; the full copy names the description",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "Grandma's"})

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      assert has_element?(lv, ~s|#share-toggle input[type="checkbox"][disabled]|)
      assert has_element?(lv, "#share-toggle", "Add a website or address first.")

      assert html =~
               "Shares the name, description, website, phone, address, location, category and photo, so anyone planning nearby can find it."
    end

    test "typing an address enables it; Save shares what was just saved",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "Zahav"})
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      lv |> form("#edit-option-form", activity: %{address: "237 St James Pl"}) |> render_change()
      refute has_element?(lv, ~s|#share-toggle input[type="checkbox"][disabled]|)

      lv
      |> form("#edit-option-form", activity: %{address: "237 St James Pl", share: "true"})
      |> render_submit()

      shared = stored(activity)
      assert shared.shared_to_catalog_at
      row = Repo.get!(CatalogItem, shared.catalog_item_id)
      assert {row.name, row.address} == {"Zahav", "237 St James Pl"}
    end

    test "turning it off on Save unshares, and the row it created goes with it",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "Zahav"})

      {:ok, activity} =
        Activities.update_activity_details(scope, activity, %{address: "237 St James Pl"})

      {:ok, activity} = Catalog.share_activity(scope, activity)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")
      assert has_element?(lv, ~s|#share-toggle input[type="checkbox"][checked]|)

      lv |> form("#edit-option-form", activity: %{share: "false"}) |> render_submit()

      assert stored(activity).shared_to_catalog_at == nil
      refute Repo.get(CatalogItem, activity.catalog_item_id)
    end

    test "an edit and turning sharing off in one Save never publishes the edit",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "Zahav"})

      {:ok, activity} =
        Activities.update_activity_details(scope, activity, %{address: "237 St James Pl"})

      {:ok, activity} = Catalog.share_activity(scope, activity)
      row_id = activity.catalog_item_id

      # Watch every query the repo runs: the end state alone cannot tell the orders
      # apart (the row is deleted either way), but the wrong order writes the new address
      # into the public row first, where a lookup in that window would return it.
      test_pid = self()
      handler = "catalog-live-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:consensus, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.query =~ ~r/catalog_items/ and "12 My Home Rd" in List.wrap(meta.params),
            do: send(test_pid, :leaked)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      lv
      |> form("#edit-option-form", activity: %{address: "12 My Home Rd", share: "false"})
      |> render_submit()

      refute_received :leaked
      refute Repo.get(CatalogItem, row_id)
      refute Repo.get_by(CatalogItem, address: "12 My Home Rd")
      assert stored(activity).address == "12 My Home Rd"
    end

    test "after publish the toggle still works (t7-d)", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity = activity_fixture(group, %{name: "Zahav"})

      {:ok, activity} =
        Activities.update_activity_details(scope, activity, %{address: "237 St James Pl"})

      {:ok, _group} = Activities.publish_group(scope, group)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")
      lv |> form("#edit-option-form", activity: %{share: "true"}) |> render_submit()

      assert stored(activity).shared_to_catalog_at
    end
  end

  describe "a catalog answer in the assist slot" do
    setup %{scope: scope} do
      group = group_fixture(scope)

      {:ok, group} =
        Activities.set_search_area(scope, group, %{
          search_area: "Philadelphia",
          search_bbox: "39.867,-75.2803,40.1379,-74.9558"
        })

      original = Application.get_env(:consensus, Consensus.Discovery)

      Application.put_env(
        :consensus,
        Consensus.Discovery,
        Keyword.put(original, :providers, %{
          group.activity_type => [
            {Consensus.Catalog.Provider, activity_type: group.activity_type},
            {Consensus.DiscoveryStub, []}
          ]
        })
      )

      on_exit(fn -> Application.put_env(:consensus, Consensus.Discovery, original) end)

      # Someone else shared Joe's Pizza, typed by hand: no OSM in it.
      other = Consensus.AccountsFixtures.user_scope_fixture()
      theirs = other |> group_fixture() |> activity_fixture(%{name: "Joe's Pizza"})

      {:ok, theirs} =
        Activities.update_activity_details(other, theirs, %{
          address: "1 Main St, Philadelphia",
          latitude: 39.95,
          longitude: -75.16,
          phone: "2155550100"
        })

      {:ok, theirs} = Catalog.share_activity(other, theirs)
      %{group: group, theirs: theirs}
    end

    test "the typed misspelling finds it; Use this copies its details and links the row; no OSM credit",
         %{conn: conn, scope: scope, group: group, theirs: theirs} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options")

      lv |> form("#add-option-form", add_option: %{query: "Joes Pizza"}) |> render_submit()
      html = render_async(lv)

      [activity] = Activities.get_group!(scope, group.id).activities
      assert has_element?(lv, "#assist-slot-#{activity.id}", "Joe's Pizza")
      refute html =~ "OpenStreetMap contributors"

      lv
      |> element(~s|button[phx-click="assist_use"][phx-value-id="#{activity.id}"]|)
      |> render_click()

      used = stored(activity)

      assert {used.name, used.phone, used.catalog_item_id} ==
               {"Joe's Pizza", "2155550100", theirs.catalog_item_id}

      assert Repo.get!(CatalogItem, theirs.catalog_item_id).use_count == 1
    end
  end
end
