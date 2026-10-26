defmodule ConsensusWeb.ItemDetailsTest do
  @moduledoc """
  An option's details (D-060, design frame `t7`) on every screen they reach: the `02b`
  editor before and after publish (`t7-a`/`t7-b`/`t7-d`), the `02`/`03` cards
  (`t7-e`), the guest ballot (`t7-f`) and the `05` winner card (`t7-g`), plus the
  owner's 2026-10-25 rulings on the frame — no Website button beside the tangerine
  View →, Directions falling back to an address search, the credit opening in a new
  tab, and the enriching interval keeping its line.
  """
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.NominatimHTTPStub
  alias Consensus.Repo
  alias Consensus.Voting
  alias ConsensusWeb.ItemDetails
  alias ConsensusWeb.JoinAuth

  @moduletag :capture_log

  @zahav %{
    name: "Zahav",
    source_url: "https://www.zahavrestaurant.com/",
    phone: "+1-215-625-8800",
    address: "237 Saint James Place, Philadelphia",
    latitude: 39.946306,
    longitude: -75.145187,
    category: "israeli",
    osm_ref: "node/6374481270"
  }

  setup do
    Consensus.LinkPreview.Cache.flush()
    Consensus.Discovery.Cache.flush()
    Consensus.LinkPreviewStub.stub(fn _url, _opts -> {:error, :not_configured} end)
    NominatimHTTPStub.stub(fn _url, _opts -> {:error, :not_configured} end)
    :ok
  end

  defp with_details(%Activity{} = activity, attrs \\ @zahav) do
    activity |> Activity.lookup_changeset(attrs) |> Repo.update!()
  end

  defp stored(activity), do: Repo.get!(Activity, activity.id)

  describe "02b before publish (t7-a, t7-b)" do
    setup :register_and_log_in_user

    test "the Details section: website, phone, address and category with counters, located state",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = group |> activity_fixture() |> with_details()

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      assert has_element?(
               lv,
               ~s|input[name="activity[source_url]"][value="#{@zahav.source_url}"]|
             )

      assert has_element?(lv, ~s|input[name="activity[phone]"][type="tel"]|)
      assert html =~ "#{String.length(@zahav.address)}/200"
      assert html =~ "7/60"
      # The test registry's stub entry carries no `category_label:`, so the generic one.
      assert html =~ "Kind"
      assert has_element?(lv, "#edit-location", "On the map")
      assert has_element?(lv, ~s|#edit-location a[href*="openstreetmap.org/?mlat=39.946306"]|)
      refute html =~ "39.946306</"
      # Invariant 11: no maxlength on any of the new free-text fields.
      refute html =~ "maxlength"
      # The details came from OSM, so the credit is owed — in a new tab.
      assert has_element?(
               lv,
               ~s|a[href="https://opendatacommons.org/licenses/odbl/"][target="_blank"]|
             )
    end

    test "Save writes the name, description and details in one go", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "zahav"})

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      lv
      |> form("#edit-option-form",
        activity: %{
          name: "Zahav",
          phone: "(215) 625-8800",
          address: "237 St James Pl",
          category: "israeli"
        }
      )
      |> render_submit()

      saved = stored(activity)

      assert {saved.name, saved.phone, saved.address, saved.category} ==
               {"Zahav", "(215) 625-8800", "237 St James Pl", "israeli"}
    end

    test "an invalid phone saves nothing, not even the name", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "zahav"})

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      html =
        lv
        |> form("#edit-option-form", activity: %{name: "Zahav", phone: "call us"})
        |> render_submit()

      assert html =~ "must be a phone number"
      assert stored(activity).name == "zahav"
    end

    test "Find from address geocodes the typed address; Save stores the point",
         %{conn: conn, scope: scope} do
      test_pid = self()

      NominatimHTTPStub.stub(fn url, _opts ->
        send(test_pid, {:geocoded, url})

        {:ok,
         %{status: 200, body: Jason.encode!([%{"lat" => "39.9463060", "lon" => "-75.1451870"}])}}
      end)

      group = group_fixture(scope)
      activity = activity_fixture(group)
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      # Nothing to look up yet: the button waits for an address.
      assert has_element?(lv, "#find-location[disabled]")

      lv |> form("#edit-option-form", activity: %{address: "237 St James Pl"}) |> render_change()
      lv |> element("#find-location") |> render_click()
      render_async(lv)

      assert_received {:geocoded, url}
      assert url =~ "237"
      assert has_element?(lv, "#edit-location", "On the map")

      lv |> form("#edit-option-form") |> render_submit()
      assert {stored(activity).latitude, stored(activity).longitude} == {39.946306, -75.145187}
    end

    test "a failed Find from address says so — the one assist failure that is shown",
         %{conn: conn, scope: scope} do
      NominatimHTTPStub.stub_places([])
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "Grandma's"})
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      lv |> form("#edit-option-form", activity: %{address: "nowhere at all"}) |> render_change()
      lv |> element("#find-location") |> render_click()
      render_async(lv)

      assert has_element?(lv, "#locate-failed", "Couldn't find that address.")
      refute has_element?(lv, "#find-location[disabled]")
    end

    test "Remove clears the location on Save", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = group |> activity_fixture() |> with_details()
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      lv |> element(~s|#edit-location button[phx-click="clear_location"]|) |> render_click()
      assert has_element?(lv, "#edit-location", "Not on the map yet")

      lv |> form("#edit-option-form") |> render_submit()
      assert {stored(activity).latitude, stored(activity).longitude} == {nil, nil}
    end
  end

  describe "02b after publish (t7-d)" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      {group, [activity | _]} = voting_group_fixture(scope)
      %{group: group, activity: activity}
    end

    test "details save and return to 03 review; the name stays frozen",
         %{conn: conn, group: group, activity: activity} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      # A hand-pushed name is not a form field here, and update_activity_details/3
      # does not cast it either.
      lv
      |> form("#edit-option-form", activity: %{phone: "215 625 8800"})
      |> render_submit(%{activity: %{name: "Hijacked"}})

      assert_redirect(lv, ~p"/groups/#{group}/review")
      assert {stored(activity).phone, stored(activity).name} == {"215 625 8800", activity.name}
    end

    test "?from=results returns to the organizer's 05", %{
      conn: conn,
      group: group,
      activity: activity
    } do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}?from=results")

      assert has_element?(lv, ~s|#chrome-back[href="/groups/#{group.id}/results"]|)
      lv |> form("#edit-option-form", activity: %{category: "israeli"}) |> render_submit()
      assert_redirect(lv, ~p"/groups/#{group}/results")
    end

    test "no Refetch: it would refill the frozen photo and description",
         %{conn: conn, group: group, activity: activity} do
      activity |> Activity.changeset(%{source_url: "https://example.com/"}) |> Repo.update!()
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      refute has_element?(lv, ~s|button[phx-click="refetch"]|)
    end

    test "a live patch from the locked editor to the pool list bounces to 03 review",
         %{conn: conn, group: group, activity: activity} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      render_patch(lv, ~p"/groups/#{group}/options")
      assert_redirect(lv, ~p"/groups/#{group}/review")
    end

    test "03 review offers Fix details per row, into the locked editor",
         %{conn: conn, group: group, activity: activity} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      assert has_element?(
               lv,
               ~s|a[href="/groups/#{group.id}/options/#{activity.id}"]|,
               "Fix details"
             )
    end
  end

  describe "02 and 03 cards (t7-e)" do
    setup :register_and_log_in_user

    test "chip + address replace the provenance line; one credit at the foot of the list",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      _zahav = group |> activity_fixture() |> with_details()
      _bare = activity_fixture(group, %{name: "Osteria Mozza"})

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/options")

      assert html =~ "Israeli"
      assert html =~ "237 Saint James Place, Philadelphia"
      # The card without details keeps its provenance line.
      assert html =~ "no details yet"
      assert has_element?(lv, "#pool-osm-credit")
      assert html |> String.split("OpenStreetMap contributors") |> length() == 2

      {:ok, review, review_html} = live(conn, ~p"/groups/#{group}/review")
      assert review_html =~ "Israeli"
      assert has_element?(review, "#pool-osm-credit")
      # Draft review has no Fix details: the 02 editor is one tap back.
      refute review_html =~ "Fix details"
    end

    test "no OSM-derived details, no credit", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      group |> activity_fixture() |> with_details(%{address: "Typed St", category: "diner"})

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/options")
      assert html =~ "Typed St"
      refute has_element?(lv, "#pool-osm-credit")
    end
  end

  describe "the guest ballot (t7-f)" do
    test "category and address only — never a phone, a tel: link or a map link; the credit opens a new tab",
         %{conn: conn} do
      {group, [a, _b, _c]} = voting_group_fixture(user_scope_fixture())
      with_details(a)
      participant = participant_fixture(group, %{display_name: "Ada"})

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)

      {:ok, lv, html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert html =~ "Israeli"
      assert html =~ "237 Saint James Place"
      refute html =~ "625-8800"
      refute html =~ "tel:"
      refute html =~ "openstreetmap.org/?mlat"

      assert has_element?(
               lv,
               ~s|#ballot-osm-credit a[target="_blank"][rel="noopener noreferrer"]|
             )
    end
  end

  describe "the 05 winner card (t7-g)" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      winner = with_details(a)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.complete_group(scope, group)
      %{group: group, winner: winner, participant: participant}
    end

    test "organizer: Call · Directions, no Website button beside View →, Fix details, the credit",
         %{conn: conn, group: group, winner: winner} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")

      assert has_element?(lv, ~s|#winner-actions a[href="tel:+12156258800"]|, "Call")

      assert has_element?(
               lv,
               ~s|#winner-actions a[href^="https://www.openstreetmap.org/?mlat=39.946306&mlon=-75.145187"]|,
               "Directions"
             )

      refute has_element?(lv, "#winner-actions a", "Website")
      assert has_element?(lv, ~s|a[href="#{winner.source_url}"]|, "View Zahav")

      assert has_element?(
               lv,
               ~s|#winner-fix-details[href="/groups/#{group.id}/options/#{winner.id}?from=results"]|
             )

      assert has_element?(lv, "#winner-osm-credit")
    end

    test "participant: the same row, no Fix details", %{group: group, participant: participant} do
      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)

      {:ok, lv, _html} = live(conn, ~p"/join/#{group.slug}/results")

      assert has_element?(lv, "#winner-actions", "Call")
      refute has_element?(lv, "#winner-fix-details")
    end
  end

  describe "ItemDetails" do
    test "directions_href/1: the point, else an address search, else nothing" do
      assert ItemDetails.directions_href(%Activity{latitude: 39.946306, longitude: -75.145187}) ==
               "https://www.openstreetmap.org/?mlat=39.946306&mlon=-75.145187#map=18/39.946306/-75.145187"

      assert ItemDetails.directions_href(%Activity{address: "4648 Hollywood Blvd, Los Angeles"}) ==
               "https://www.openstreetmap.org/search?query=4648+Hollywood+Blvd%2C+Los+Angeles"

      assert ItemDetails.directions_href(%Activity{}) == nil
    end

    test "the action row is absent, not empty, with nothing to act on" do
      html = render_component(&ItemDetails.action_row/1, activity: %Activity{}, id: "row")
      refute html =~ "row"

      only_directions =
        render_component(&ItemDetails.action_row/1,
          activity: %Activity{address: "4648 Hollywood Blvd"}
        )

      assert only_directions =~ "Directions"
      refute only_directions =~ "Call"
    end
  end
end
