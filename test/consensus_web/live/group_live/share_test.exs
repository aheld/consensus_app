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
      assert flash["error"] =~ "Here is everything you organize."
      refute flash["error"] =~ group.title
    end

    # The sentence the chat receives names the organizer when there is a name to give.
    test "the share text names a signed-in organizer", %{conn: conn, group: group, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/share")

      assert has_element?(
               lv,
               ~s(#native-share[data-share-text="#{user.username} set up a vote. Tap to pick."])
             )
    end

    # An account already saves the session, so the warning would be false here.
    test "has no save warning for a signed-in organizer", %{conn: conn, group: group} do
      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/share")

      refute has_element?(lv, "#share-save-warning")
      refute html =~ "Without an account"
    end
  end

  # D-058: an organizer with no account reaches `04 share` through the organizer cookie.
  # The screen used to read `current_scope.user.username` and crashed the moment such an
  # organizer published.
  describe "a group owned by an organizer with no account" do
    # The describe-wide `conn` stays the signed-in user's, for the cross-owner case.
    setup do
      %{conn: conn, scope: scope} =
        create_anonymous_organizer(%{conn: Phoenix.ConnTest.build_conn()})

      %{anon_conn: conn, anon_scope: scope}
    end

    test "with a display name, the share text names them",
         %{anon_conn: conn, anon_scope: scope} do
      {:ok, _organizer} =
        Activities.update_organizer_display_name(scope, %{display_name: "Priya"})

      group = published_group(scope)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/share")

      assert html =~ "/join/#{group.slug}"
      assert html =~ "Priya set up a vote. Tap to pick."

      assert has_element?(
               lv,
               ~s(#native-share[data-share-text="Priya set up a vote. Tap to pick."])
             )
    end

    # The organizer sends this from their own phone, so an unnamed one gets no subject —
    # not "The organizer set up a vote.", which nobody would write about themselves.
    test "with no name, the share text has no subject", %{anon_conn: conn, anon_scope: scope} do
      group = published_group(scope)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/share")

      assert html =~ "A vote is open. Tap to pick."
      refute html =~ "The organizer"
      refute html =~ "the organizer"
      assert has_element?(lv, ~s(#native-share[data-share-text="A vote is open. Tap to pick."]))
    end

    test "a different organizer with no account is refused, without the promise about `/`",
         %{anon_scope: scope} do
      group = published_group(scope)

      %{conn: stranger_conn} = create_anonymous_organizer(%{conn: Phoenix.ConnTest.build_conn()})

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               live(stranger_conn, ~p"/groups/#{group}/share")

      assert flash["error"] == "That session isn't yours, or it no longer exists."
    end

    test "a signed-in user is refused it too", %{anon_scope: scope, conn: conn} do
      group = published_group(scope)

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/groups/#{group}/share")

      assert flash["error"] =~ "isn't yours, or it no longer exists"
    end

    # Plan §7.1: the cookie is the only key to an accountless session, so 04 says what
    # is lost without one, right above `Copy link`, and offers both doors.
    test "warns that the session lives in this browser, with both doors",
         %{anon_conn: conn, anon_scope: scope} do
      group = published_group(scope)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/share")

      assert text_of(lv, "#share-save-warning p") ==
               "Without an account, this session can only be managed from this browser. " <>
                 "If you clear your browser data or switch devices, you won't be able to " <>
                 "close it early, call it off or break a tie. Everyone can still vote and " <>
                 "see results at the link."

      assert has_element?(
               lv,
               ~s(#share-save-register[href="/users/register"]),
               "Create an account"
             )

      assert has_element?(
               lv,
               ~s(#share-save-log-in[href="/users/log-in?return_to=%2Fgroups%2F#{group.id}%2Fshare"]),
               "Already have one? Log in"
             )

      # The return trip must survive the same guard `UserAuth.store_return_to/2` applies.
      assert ConsensusWeb.CurrentPath.safe_return_to("/groups/#{group.id}/share") ==
               "/groups/#{group.id}/share"
    end
  end

  defp published_group(scope) do
    group = group_fixture(scope, %{deadline_at: future_deadline()})
    activity_fixture(group)
    {:ok, group} = Activities.publish_group(scope, group)
    group
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

  defp text_of(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end
end
