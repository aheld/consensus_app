defmodule ConsensusWeb.GroupLive.ShareTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities

  setup :register_and_log_in_user

  describe "a published group" do
    setup %{scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      %{group: group}
    end

    test "renders the slug-based join url, the organizer's username and the option count", %{
      conn: conn,
      group: group,
      user: user
    } do
      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/share")

      assert html =~ "/join/#{group.slug}"
      assert html =~ user.username
      assert html =~ group.title
      assert html =~ "2 spots"
    end

    # Still refused by `Activities.get_group!/2`'s organizer scoping; the raise is now
    # rescued into a named redirect rather than surfacing as a bare 404. See the sibling
    # case in `ConsensusWeb.GroupLive.ResultsTest` for why.
    test "another user's group is refused with a named redirect, not a bare 404", %{group: group} do
      stranger_conn = Phoenix.ConnTest.build_conn() |> log_in_user(user_fixture())

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               live(stranger_conn, ~p"/groups/#{group}/share")

      assert flash["error"] =~ "isn't yours, or it no longer exists"
      refute flash["error"] =~ group.title
    end
  end

  describe "a draft group" do
    test "is redirected back to review — there is no live link yet", %{conn: conn, scope: scope} do
      group = group_fixture(scope)

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/groups/#{group}/share")

      assert to == ~p"/groups/#{group}/review"

      # It used to bounce silently: the organizer asked for the share link and got a
      # different screen with no account of why, which on a wizard reads as a failure
      # (D-045). The flash names the state and the control that fixes it.
      assert flash["info"] =~ "no share link yet"
      assert flash["info"] =~ group.title
      assert flash["info"] =~ "Get the share link"
    end
  end

  describe "the one forward control on this screen" do
    # `See live results →` measured 324×18.8 and is the only forward or recovery control
    # here — a tangerine sweep of this screen returns an empty array. Padded to the 44px
    # touch minimum with a negative margin so the text does not move.
    test "is padded to the 44px touch minimum", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/share")

      assert lv |> element("#share-see-results") |> render() =~ "min-h-[44px]"
    end

    # **The share-sheet control is server-rendered `hidden` and the hook *removes* it.**
    # It shipped the other way round — visible in the markup, `NativeShare.mounted()` set
    # `el.hidden = true` where `navigator.share` was missing — and LiveView's DOM patch put
    # the server's markup back on the first re-render, which this screen's own `Copy link`
    # triggers (both outcomes push an event and flash). Measured on desktop Chrome:
    # correct on load, then a 384×105 card of four app tiles with a hover state,
    # `elementFromPoint` at its centre returning `native-share`, whose listener calls an
    # undefined `navigator.share` and throws. A dead control on the one screen whose entire
    # job is sending the link. `mounted()` fires once; only the server's markup survives a
    # patch, so the default has to live here.
    test "the share sheet is hidden in the markup, not by the hook", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/share")

      assert has_element?(lv, "#native-share[hidden]")
      assert has_element?(lv, "#native-share[phx-hook='NativeShare']")

      # And it survives a re-render, because it is what the server sends every time.
      render_click(lv, "copied", %{})
      assert has_element?(lv, "#native-share[hidden]")
    end
  end
end
