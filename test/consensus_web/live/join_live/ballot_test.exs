defmodule ConsensusWeb.JoinLive.BallotTest do
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting
  alias ConsensusWeb.JoinAuth

  defp join_conn(conn, group, participant) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)
  end

  describe "mount — no participant yet" do
    test "redirects to the entry screen rather than rendering an empty ballot", %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/join/#{group.slug}/vote")
      assert to == ~p"/join/#{group.slug}"
    end
  end

  describe "mount — the ballot is already locked (D-036)" do
    test "a participant with voted_at set is redirected to results, not the grid", %{conn: conn} do
      {group, activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [hd(activities).id])

      conn = join_conn(conn, group, participant)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/join/#{group.slug}/vote")
      assert to == ~p"/join/#{group.slug}/results"
    end
  end

  describe "mount — an unvoted participant" do
    setup %{conn: conn} do
      {group, activities} = voting_group_fixture(user_scope_fixture(), 3)
      participant = participant_fixture(group, %{display_name: "Ada"})
      conn = join_conn(conn, group, participant)
      %{conn: conn, group: group, activities: activities, participant: participant}
    end

    test "renders every activity in the pool with a starting count of zero", %{
      conn: conn,
      group: group,
      activities: activities
    } do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert html =~ "happy with"

      for activity <- activities do
        assert html =~ activity.name
      end

      assert html =~ "0 PICKED"
      assert html =~ "1 VETO LEFT"
    end

    test "a missing description falls back to a plain placeholder, not a blank line", %{
      conn: conn,
      group: group
    } do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}/vote")
      assert html =~ "No details yet"
    end

    test "clicking a card approves it, and clicking again un-approves it", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "1 PICKED"
      assert has_element?(view, "button[aria-pressed='true'][phx-value-id='#{first.id}']")

      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "0 PICKED"
    end

    test "the header's Create your own pill asks before it discards an unsent ballot", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      # The pill is a `navigate` to `/` and the loudest control on this screen, while
      # "Send my votes" is a disabled peach until something is tapped. `@approved` and
      # `@veto_id` live only in socket assigns, and a guest has no account and no route
      # back except the original share link in someone's chat app. `data-confirm` is
      # honoured on any clicked element by `phoenix_html.js` — it dispatches
      # `phoenix.link.click` and, if the confirm is declined, calls
      # `stopImmediatePropagation()`, which is what stops LiveView's own window-level
      # nav listener (registered later, same phase) from navigating.
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      # Nothing selected: no prompt. An empty ballot costs nothing and a confirm on it
      # would be an affordance that behaves unpredictably.
      assert html =~ ~s(id="chrome-create-your-own")
      refute html =~ "data-confirm"

      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "Leave without sending?"
      assert has_element?(view, "#chrome-create-your-own[data-confirm]")

      # And it goes away again when the ballot is emptied.
      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
        |> render_click()

      refute html =~ "Leave without sending?"
    end

    test "a veto alone is enough to arm the pill's confirm", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "Leave without sending?"
    end

    test "a non-numeric id pushed at toggle_approve is ignored, not a crash", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = render_click(view, "toggle_approve", %{"id" => "not-an-int"})

      assert html =~ "0 PICKED"
      assert Process.alive?(view.pid)
    end

    test "a non-numeric id pushed at toggle_veto is ignored, not a crash", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = render_click(view, "toggle_veto", %{"id" => "not-an-int"})

      assert html =~ "1 VETO LEFT"
      assert Process.alive?(view.pid)
    end

    # The in-card `Vetoed` pill is deliberately gone: it said the same word as the labelled
    # control 6px below it and put a second tangerine on a screen whose one forward action
    # is "Send my votes". The control itself is the state marker now.
    test "vetoing a card marks it VETOED on the control and strikes the name", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "0 VETOES LEFT"
      assert html =~ "line-through"

      assert view
             |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
             |> render() =~ "VETOED"

      # One tangerine inside the ballot itself, and it is the forward action — not the
      # veto state. (The disconnect banners in the layout's flash group are tangerine too
      # and are never on screen at the same time as anything, so measure below <main>.)
      ballot = html |> String.split("<main", parts: 2) |> List.last()
      assert length(String.split(ballot, "bg-tangerine")) - 1 == 1
      assert ballot =~ ~s(id="submit-ballot")
    end

    # The grid's veto used to be a 24px glyph-only circle positioned *inside* the approve
    # button's rect, with the word "veto" reachable only through an `aria-label`. Two
    # overlapping targets meaning opposite things, on a guest's single locked submission.
    test "the grid's veto is a labelled sibling of the approve card, not a badge inside it", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      # Sibling, not child: the approve button's markup closes before the veto opens.
      [_before, after_approve] =
        String.split(html, ~s(phx-click="toggle_approve" phx-value-id="#{first.id}"), parts: 2)

      approve_markup = after_approve |> String.split("</button>", parts: 2) |> hd()
      refute approve_markup =~ "toggle_veto"

      # And the mechanism is named on screen, not only to a screen reader.
      assert html =~ "it drops an option for everyone"

      veto =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render()

      assert veto =~ "VETO"
    end

    test "vetoing an already-approved card un-approves it — never both at once", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "0 PICKED"
      assert html =~ "0 VETOES LEFT"
    end

    test "the server ignores a pushed approve for a card currently vetoed", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
      |> render_click()

      html = render_click(view, "toggle_approve", %{"id" => to_string(first.id)})

      assert html =~ "0 PICKED"
      assert html =~ "0 VETOES LEFT"
    end

    test "there is only ever one veto — vetoing a second card moves it off the first", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{second.id}']")
        |> render_click()

      assert html =~ "0 VETOES LEFT"

      refute has_element?(
               view,
               "button[phx-click='toggle_veto'][phx-value-id='#{first.id}'][aria-pressed='true']"
             )

      assert has_element?(
               view,
               "button[phx-click='toggle_veto'][phx-value-id='#{second.id}'][aria-pressed='true']"
             )
    end

    test "clicking the same veto control again removes the veto", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
        |> render_click()

      assert html =~ "1 VETO LEFT"
      refute html =~ "Vetoed"
    end

    test "the submit button is disabled until something is picked or vetoed", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")
      assert html =~ ~s(id="submit-ballot")
      assert has_element?(view, "button#submit-ballot[disabled]")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      refute has_element?(view, "button#submit-ballot[disabled]")
    end

    test "submitting with nothing picked and nothing vetoed refuses and stays put", %{
      conn: conn,
      group: group,
      participant: participant
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = render_click(view, "submit_ballot", %{})

      assert html =~ "Pick at least one, or veto one"
      assert Voting.get_participant_by_token(participant.token).voted_at == nil
    end

    test "submitting a real ballot casts it and navigates to results", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest],
      participant: participant
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{second.id}']")
      |> render_click()

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> element("#submit-ballot")
        |> render_click()

      assert to == ~p"/join/#{group.slug}/results"

      voted = Voting.get_participant_by_token(participant.token)
      assert voted.voted_at

      tally = Voting.tally(group)
      first_row = Enum.find(tally, &(&1.activity.id == first.id))
      second_row = Enum.find(tally, &(&1.activity.id == second.id))

      assert first_row.approvals == 1
      assert second_row.vetoed?
    end

    test "re-submitting an already-locked ballot (double tab) redirects to results", %{
      conn: conn,
      group: group,
      participant: participant,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      # A second tab (or a retried request) casts the ballot first.
      {:ok, _voted} = Voting.cast_ballot(participant, [first.id])

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      # Its flash carries the "already in" message, but a `push_navigate` mid-session
      # ships the flash as an opaque signed token for the *next* mount to decode — not
      # a plain map here — so this asserts the redirect only. `handle_cast_error/3`'s
      # `:already_voted` clause (this file) is what sets that flash.
      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#submit-ballot")
               |> render_click()

      assert to == ~p"/join/#{group.slug}/results"
    end

    test "an id the client invented is refused as unknown_activity, not written", %{
      conn: conn,
      group: group,
      participant: participant
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      render_click(view, "toggle_approve", %{"id" => "999999999"})
      html = render_click(view, "submit_ballot", %{})

      # Not "something in the pool changed" — CLAUDE.md invariant 16 / D-037 makes that
      # impossible once voting opens, so the old flash sent a voter looking for a change
      # the app forbids.
      assert html =~ "We didn&#39;t recognise one of those options"
      refute html =~ "Something in the pool changed"
      assert Voting.get_participant_by_token(participant.token).voted_at == nil
    end

    test "voting has closed under the voter (deadline passed) sends them to results", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      expire_deadline!(group)

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#submit-ballot")
               |> render_click()

      assert to == ~p"/join/#{group.slug}/results"
    end

    test "the group closing under the voter (organizer ends it) sends them to results", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      force_group!(group, %{status: :completed, completed_at: DateTime.utc_now(:second)})

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#submit-ballot")
               |> render_click()

      assert to == ~p"/join/#{group.slug}/results"
    end
  end

  # D-044. The deck is a *view* of the ballot above, not a second ballot: every test here
  # asserts against the same `@approved` / `@veto_id` the grid drives and the same single
  # `Voting.cast_ballot/3` write. Nothing below touches `Consensus.Voting`.
  describe "the swipe deck — one ballot, two views (D-044)" do
    setup %{conn: conn} do
      {group, activities} = voting_group_fixture(user_scope_fixture(), 3)
      participant = participant_fixture(group, %{display_name: "Ada"})
      conn = join_conn(conn, group, participant)
      %{conn: conn, group: group, activities: activities, participant: participant}
    end

    defp show_deck(view) do
      view |> element("#view-deck") |> render_click()
    end

    defp show_grid(view) do
      view |> element("#view-grid") |> render_click()
    end

    test "the grid is the default view and the switch offers the deck", %{
      conn: conn,
      group: group
    } do
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert html =~ "happy with"
      assert has_element?(view, "#view-grid[aria-pressed='true']")
      assert has_element?(view, "#view-deck[aria-pressed='false']")
      refute has_element?(view, "#deck-approve")
    end

    test "the switch is on both views, so the deck is reversible from inside it", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      show_deck(view)
      assert has_element?(view, "#view-deck[aria-pressed='true']")
      assert has_element?(view, "#view-grid[aria-pressed='false']")

      html = show_grid(view)
      assert html =~ "happy with"
      assert has_element?(view, "#view-grid[aria-pressed='true']")
    end

    test "switching views loses nothing — the grid's picks are the deck's picks", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      for activity <- [first, second] do
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{activity.id}']")
        |> render_click()
      end

      deck_html = show_deck(view)
      assert deck_html =~ "2 PICKED"

      # Straight back again: still the same two, still marked as picked in the grid.
      grid_html = show_grid(view)
      assert grid_html =~ "2 PICKED"

      assert has_element?(
               view,
               "button[phx-click='toggle_approve'][phx-value-id='#{first.id}'][aria-pressed='true']"
             )

      assert has_element?(
               view,
               "button[phx-click='toggle_approve'][phx-value-id='#{second.id}'][aria-pressed='true']"
             )
    end

    test "the deck says how much more of it there is", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = show_deck(view)
      assert html =~ "1 / 3"

      html = view |> element("#deck-approve") |> render_click()
      assert html =~ "2 / 3"
      refute has_element?(view, "#deck-card-#{first.id}")
    end

    test "the ♥ button approves the face-up card and advances", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      assert has_element?(view, "#deck-card-#{first.id}")
      view |> element("#deck-approve") |> render_click()

      assert has_element?(view, "#deck-card-#{second.id}")
      assert show_grid(view) =~ "1 PICKED"
    end

    test "the ✕ button advances without approving — a pass is not a veto", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      view |> element("#deck-pass") |> render_click()
      assert has_element?(view, "#deck-card-#{second.id}")

      grid = show_grid(view)
      assert grid =~ "0 PICKED"
      assert grid =~ "1 VETO LEFT"

      refute has_element?(
               view,
               "button[phx-click='toggle_approve'][phx-value-id='#{first.id}'][aria-pressed='true']"
             )
    end

    test "the deck's veto is the same single veto the grid spends", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      assert render(view) =~ "1×"
      view |> element("#deck-veto") |> render_click()

      # Spent, and the next card's control says what pressing it would now do.
      html = render(view)
      assert html =~ "0×"
      assert html =~ "MOVE VETO"

      grid = show_grid(view)
      assert grid =~ "0 VETOES LEFT"

      assert has_element?(
               view,
               "button[phx-click='toggle_veto'][phx-value-id='#{first.id}'][aria-pressed='true']"
             )
    end

    test "vetoing a second card in the deck moves the veto, exactly as the grid does", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      view |> element("#deck-veto") |> render_click()
      view |> element("#deck-veto") |> render_click()

      grid = show_grid(view)
      assert grid =~ "0 VETOES LEFT"

      refute has_element?(
               view,
               "button[phx-click='toggle_veto'][phx-value-id='#{first.id}'][aria-pressed='true']"
             )

      assert has_element?(
               view,
               "button[phx-click='toggle_veto'][phx-value-id='#{second.id}'][aria-pressed='true']"
             )
    end

    test "approving a card that holds the veto releases it — never both at once", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      view |> element("#deck-veto") |> render_click()
      # Back to the same card and change the answer.
      view |> element("#deck-undo") |> render_click()
      assert has_element?(view, "#deck-card-#{first.id}")
      view |> element("#deck-approve") |> render_click()

      grid = show_grid(view)
      assert grid =~ "1 PICKED"
      assert grid =~ "1 VETO LEFT"
      refute grid =~ "Vetoed"
    end

    test "undo restores the card AND the selections it changed", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      # Nothing to undo on a fresh deck, so the control is not drawn at all.
      refute has_element?(view, "#deck-undo")

      view |> element("#deck-approve") |> render_click()
      assert has_element?(view, "#deck-undo")

      html = view |> element("#deck-undo") |> render_click()

      assert html =~ "1 / 3"
      assert has_element?(view, "#deck-card-#{first.id}")
      assert show_grid(view) =~ "0 PICKED"
    end

    test "a decision pushed for a card that is not face up is ignored", %{
      conn: conn,
      group: group,
      activities: [_first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      html =
        render_click(view, "deck_decide", %{"decision" => "approve", "id" => "#{second.id}"})

      assert html =~ "1 / 3"
      assert show_grid(view) =~ "0 PICKED"
    end

    test "a junk decision or a junk id is ignored, not a crash", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      render_click(view, "deck_decide", %{"decision" => "delete", "id" => "1"})
      render_click(view, "deck_decide", %{"decision" => "approve", "id" => "nope"})
      render_click(view, "deck_change", %{"index" => "nope"})
      render_click(view, "deck_change", %{"index" => "99"})
      render_click(view, "set_view", %{"view" => "nonsense"})

      assert render(view) =~ "1 / 3"
      assert Process.alive?(view.pid)
    end

    test "the end of the deck is a summary of what was chosen, with the same submit", %{
      conn: conn,
      group: group,
      activities: [first, second, third]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      view |> element("#deck-approve") |> render_click()
      view |> element("#deck-pass") |> render_click()
      html = view |> element("#deck-veto") |> render_click()

      assert html =~ "Your picks"
      assert html =~ "Picked"
      assert html =~ "Passed"
      assert html =~ "Vetoed"
      assert html =~ "1 PICKED · 0 VETOES LEFT"
      assert has_element?(view, "#submit-ballot")
      refute has_element?(view, "#submit-ballot[disabled]")

      for activity <- [first, second, third] do
        assert has_element?(view, "#deck-summary-#{activity.id}")
      end
    end

    test "reaching the end having picked nothing is not a dead end", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      for _card <- 1..3, do: view |> element("#deck-pass") |> render_click()

      html = render(view)
      assert html =~ "Nothing picked yet"
      assert html =~ "Nothing to send yet"
      assert has_element?(view, "#ballot-empty-hint")
      assert has_element?(view, "#submit-ballot[disabled]")
      # Three ways out: change a row, undo the last pass, or go back to the grid.
      assert has_element?(view, "button[phx-click='deck_change']")
      assert has_element?(view, "#deck-undo")
      assert has_element?(view, "#view-grid")

      # And the heading does not claim picks the voter does not have.
      refute html =~ "Change any of them before you send"
    end

    # The same inert button in the other view used to carry no explanation at all — the
    # sentence lived in the deck's summary only, and the grid is the default.
    test "the grid explains its inert Send button too", %{conn: conn, group: group} do
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert has_element?(view, "#submit-ballot[disabled]")
      assert html =~ "Nothing to send yet"
      assert html =~ "Tap the ones you&#39;d be happy with"
    end

    test "Change re-opens one card and comes straight back to the summary", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      for _card <- 1..3, do: view |> element("#deck-pass") |> render_click()

      html =
        view |> element("button[phx-click='deck_change'][phx-value-index='0']") |> render_click()

      assert html =~ "Changing this one"
      assert html =~ "You passed on this."
      assert has_element?(view, "#deck-card-#{first.id}")

      html = view |> element("#deck-approve") |> render_click()

      assert html =~ "Your picks"
      assert html =~ "1 PICKED"
    end

    test "Review picks reaches the summary early, and Keep going resumes the walk", %{
      conn: conn,
      group: group,
      activities: [_first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      view |> element("#deck-approve") |> render_click()
      html = view |> element("#deck-review") |> render_click()

      assert html =~ "Your picks"
      assert html =~ "Not looked at"

      html = view |> element("#deck-keep-going") |> render_click()
      assert html =~ "2 / 3"
      assert has_element?(view, "#deck-card-#{second.id}")
    end

    test "submitting from the summary casts the one ballot and locks it", %{
      conn: conn,
      group: group,
      activities: [first, second, _third],
      participant: participant
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)

      view |> element("#deck-approve") |> render_click()
      view |> element("#deck-veto") |> render_click()
      view |> element("#deck-pass") |> render_click()

      {:error, {:live_redirect, %{to: to}}} =
        view |> element("#submit-ballot") |> render_click()

      assert to == ~p"/join/#{group.slug}/results"

      voted = Voting.get_participant_by_token(participant.token)
      assert voted.voted_at

      tally = Voting.tally(group)
      assert Enum.find(tally, &(&1.activity.id == first.id)).approvals == 1
      assert Enum.find(tally, &(&1.activity.id == second.id)).vetoed?
    end

    # Frame `1c-1` scrolls the **pool**, not the page, and pins `Send my votes` under it:
    # `flex:1;min-height:0;overflow-y:auto` on the grid track inside a fixed-height device.
    # The app shipped the grid without a height-bounded ancestor, so `overflow-y-auto`
    # would have been inert even if it had been there and the page scrolled instead.
    # Measured at 360×640 on a five-option pool before the fix: `scrollHeight 934` against
    # `innerHeight 640`, `#submit-ballot` bottom at 851.86 — **212px below the fold** —
    # with `#ballot-status` below it too, so the first screenful ended mid-pool with
    # neither the counter nor the action on it and nothing saying they existed.
    #
    # After: `documentElement.scrollHeight === 640`, the grid track scrolls internally
    # (560 > 198) and `#submit-ballot` ends at 557.75. A LiveView test can only see the
    # markup, so it pins the three classes the browser measurement depends on — the
    # bounded ancestor is the one that is easy to delete by accident, because nothing about
    # the grid's own classes looks wrong without it.
    test "the grid scrolls its pool inside a viewport-bounded column, not the page",
         %{conn: conn, group: group} do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert html =~ "viewport-column"
      refute html =~ "min-h-dvh"

      [grid_classes] = Regex.run(~r/class="(grid [^"]*)"/, html, capture: :all_but_first)
      assert grid_classes =~ "overflow-y-auto"
      assert grid_classes =~ "flex-1"

      # A floor, not `min-h-0`, and the distinction is the whole regression. `min-h-0` is
      # what makes `overflow-y-auto` work at all, and any explicit `min-height` does that
      # job — but at `0` every `shrink-0` sibling wins and the pool is the only box left to
      # squeeze. Measured at 375×500 it floored at 58px, and at 667×375 (a phone in
      # landscape, one rotation away) at 16px, with `#submit-ballot` painting 59px past
      # `<main>` and on top of the footer.
      assert grid_classes =~ "min-h-[200px]"
      refute grid_classes =~ "min-h-0 "
    end

    # `.viewport-column` is a plain `min-height: 100dvh` below 600px of viewport height and
    # only clamps above it — see its rule in `assets/css/app.css`. A LiveView test cannot
    # resize a viewport, so this asserts the gate exists in the stylesheet at all: with the
    # clamp unconditional, the column has no fallback to page scrolling and the overflow is
    # painted over the footer rather than being reachable.
    test "the bounded column is gated on the viewport being tall enough for it" do
      css = File.read!("assets/css/app.css")

      assert css =~ "@media (min-height: 640px)"

      [gated] =
        Regex.run(~r/@media \(min-height: 640px\) \{\s*\.viewport-column \{([^}]*)\}/, css,
          capture: :all_but_first
        )

      assert gated =~ "height: 100dvh"
    end

    # The deck's *card* state stays on the ordinary page scroller: one card and a control
    # row, and no list to scroll.
    test "the deck's card view does not bound the column to the viewport", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      html = show_deck(view)

      assert html =~ "min-h-dvh"
      refute html =~ "viewport-column"
    end

    # The deck's summary does not, and this was fixed for the grid only the first time
    # round. It is the sole place a deck voter can submit, and it reproduced the original
    # blocker exactly: at 360×640 on this five-option pool `#submit-ballot` sat at 695–755
    # in a 640px viewport, entirely off-screen, with `#ballot-status` below the fold too.
    # The picks list is the scroll track and the submit block its `shrink-0` sibling, the
    # same shape frame `1c-1` gives the grid.
    test "the deck's summary bounds the column and scrolls its picks list", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      show_deck(view)
      html = view |> element("#deck-review") |> render_click()

      assert html =~ "viewport-column"
      refute html =~ "min-h-dvh"

      [list_classes] =
        Regex.run(~r/<ul class="([^"]*overflow-y-auto[^"]*)"/, html, capture: :all_but_first)

      assert list_classes =~ "flex-1"
      assert list_classes =~ "min-h-[110px]"
    end

    # Measured at 420×900 before the fix: a 150px drag to the right grew
    # `document.documentElement.scrollWidth` from 420 to 587, so the whole page scrolled
    # sideways. The card is `position: absolute` and the hook translates it, so nothing
    # about the layout bounds it — only this does.
    test "the deck clips a dragged card rather than letting the page scroll sideways", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")
      html = show_deck(view)

      assert html =~ "overflow-x-clip"
    end

    test "both views say submitting is final before the press (D-036)", %{
      conn: conn,
      group: group
    } do
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")
      assert html =~ "Sending is final"

      show_deck(view)
      for _card <- 1..3, do: view |> element("#deck-pass") |> render_click()
      assert render(view) =~ "Sending is final"
    end

    # --- the whole ballot lives in the URL ---------------------------------------------
    #
    # Selections held only in socket assigns are destroyed by ANY remount, silently: browser
    # Back, a reload, a restored background tab, and — the one that cannot be designed
    # around — a LiveView reconnect after a screen lock or a cell handoff. Measured before
    # the fix: two picks and a spent veto became `0 PICKED · 1 VETO LEFT` after a 400ms
    # disconnect, with no flash and no reload, and D-036 then locks the short ballot the
    # voter sends. These pin the fix: everything is in the URL, the URL is patched, and a
    # mount at that URL rebuilds the ballot.
    test "the view, the card position AND the selections are in the URL", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      show_deck(view)
      assert_patched(view, ~p"/join/#{group.slug}/vote?card=0&view=deck")

      view |> element("#deck-approve") |> render_click()

      assert_patched(
        view,
        ~p"/join/#{group.slug}/vote?card=1&picked=#{first.id}&seen=#{first.id}&view=deck"
      )

      show_grid(view)

      assert_patched(
        view,
        ~p"/join/#{group.slug}/vote?card=1&picked=#{first.id}&seen=#{first.id}&view=grid"
      )
    end

    # This is the reconnect, the reload and the restored tab, all of which arrive as a
    # fresh `mount/3` against whatever URL the browser is holding.
    test "a fresh mount at the current URL rebuilds the ballot instead of emptying it", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{second.id}']")
      |> render_click()

      # One patch per selection change; the browser is left holding the last of them.
      _after_approve = assert_patch(view)
      url = assert_patch(view)
      assert render(view) =~ "1 PICKED · 0 VETOES LEFT"

      {:ok, remounted, html} = live(conn, url)

      assert html =~ "1 PICKED · 0 VETOES LEFT"

      assert has_element?(
               remounted,
               "button[phx-click='toggle_approve'][phx-value-id='#{first.id}'][aria-pressed='true']"
             )

      assert has_element?(
               remounted,
               "button[phx-click='toggle_veto'][phx-value-id='#{second.id}'][aria-pressed='true']"
             )
    end

    # Junk in the query string must resolve, not crash and not invent a vote for an id from
    # some other pool.
    test "hand-typed selection params are filtered to ids that are in this pool", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, _view, html} =
        live(
          conn,
          ~p"/join/#{group.slug}/vote?#{[picked: "#{first.id},999999,nope", veto: "424242"]}"
        )

      assert html =~ "1 PICKED · 1 VETO LEFT"
    end

    # Switching Grid → Swipe restarted the deck at card 1, because the grid's URL dropped
    # `card` and `handle_params/3` clamped `nil` to 0. From the summary that also took
    # `#submit-ballot` off the screen and re-showed every card as already decided.
    test "switching views keeps the deck's position, not just the picks", %{
      conn: conn,
      group: group,
      activities: [_first, _second, third | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=2")

      assert render(view) =~ "3 / 3"
      show_grid(view)
      html = show_deck(view)

      assert html =~ "3 / 3"
      assert has_element?(view, "#deck-card-#{third.id}")
    end

    test "switching views from the end-of-deck summary comes back to the summary", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      view |> element("#deck-approve") |> render_click()
      view |> element("#deck-review") |> render_click()
      assert has_element?(view, "#submit-ballot")

      show_grid(view)
      show_deck(view)

      assert has_element?(view, "#deck-summary-heading")
      assert has_element?(view, "#submit-ballot")
      refute has_element?(view, "#deck-approve")
    end

    test "landing on a deck URL directly opens that card", %{
      conn: conn,
      group: group,
      activities: [_first, second | _rest]
    } do
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=1")

      assert html =~ "2 / 3"
      assert has_element?(view, "#deck-card-#{second.id}")
      assert has_element?(view, "#view-deck[aria-pressed='true']")
    end

    # This is what Back does: `handle_params/3` runs again with the previous URL. The
    # selections are assigns and are not in it, which is the whole point.
    test "stepping back to an earlier card keeps every selection", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      show_deck(view)
      view |> element("#deck-approve") |> render_click()
      view |> element("#deck-veto") |> render_click()
      assert render(view) =~ "1 PICKED · 0 VETOES LEFT"

      html = render_patch(view, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      assert html =~ "1 / 3"
      assert html =~ "1 PICKED · 0 VETOES LEFT"
    end

    test "a hand-typed card position out of range resolves rather than crashing", %{
      conn: conn,
      group: group
    } do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=99")
      # Clamped to the summary, which is a real screen.
      assert html =~ "Nothing picked yet"

      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=nope")
      assert html =~ "1 / 3"
      assert Process.alive?(view.pid)
    end

    # --- the veto is a toggle in BOTH views ------------------------------------------
    #
    # The deck's control has always been labelled "Remove veto on <name>" once that card
    # holds the veto. Before this it re-applied the same veto and advanced, so the one
    # control that promised to give a voter their veto back was the one that could not —
    # and D-044 asserted the two views behaved identically while they did not.
    test "pressing the deck's veto on the vetoed card releases it and stays put", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      view |> element("#deck-veto") |> render_click()
      # `Change` back onto the card that now holds the veto.
      view |> element("#deck-review") |> render_click()
      view |> element("button[phx-click='deck_change'][phx-value-index='0']") |> render_click()

      assert has_element?(view, "#deck-veto[aria-label='Remove veto on #{first.name}']")

      html = view |> element("#deck-veto") |> render_click()

      assert html =~ "1 VETO LEFT"
      assert html =~ "1 / 3"
      assert has_element?(view, "#deck-card-#{first.id}")
      refute render(view) =~ "You vetoed this."
    end

    # The grid moved the veto in total silence: the previous holder just stopped being
    # struck through, somewhere in a two-column list the voter was not looking at, while
    # four buttons still read a caption and the counter read `0 VETOES LEFT`.
    test "moving the veto in the GRID says so too, and the caption stops saying VETO", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_veto'][phx-value-id='#{first.id}']")
      |> render_click()

      # With the veto held elsewhere, the other cards offer to MOVE it rather than
      # advertising a `VETO` the counter has just said there is none of.
      assert view
             |> element("button[phx-click='toggle_veto'][phx-value-id='#{second.id}']")
             |> render() =~ "MOVE VETO"

      html =
        view
        |> element("button[phx-click='toggle_veto'][phx-value-id='#{second.id}']")
        |> render_click()

      assert has_element?(view, "#veto-note")
      assert html =~ "Your veto moved from #{first.name} to #{second.name}"
    end

    # `VETO 1×` printed once per option: a five-option pool drew it five times under a
    # counter that says the budget once.
    test "the grid does not print the veto budget once per option", %{
      conn: conn,
      group: group
    } do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert html =~ "1 VETO LEFT"
      refute html =~ "1×"
    end

    test "moving the veto in the deck says so, where the voter will see it", %{
      conn: conn,
      group: group,
      activities: [first, second | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      view |> element("#deck-veto") |> render_click()
      html = view |> element("#deck-veto") |> render_click()

      assert has_element?(view, "#veto-note")
      assert html =~ "Your veto moved from #{first.name} to #{second.name}"

      # And it is not sticky — the next decision clears it.
      html = view |> element("#deck-pass") |> render_click()
      refute html =~ "Your veto moved from"
    end

    # The other half of the same hazard, and the half that shipped without a note.
    # `decide/3` drops the veto whenever the card holding it is approved or passed — a
    # decision replaces whatever the last one was — and only the *move* case produced any
    # copy. Reproduced: a card reading "You vetoed this." under `0 VETOES LEFT`, one press
    # of PASS, and the summary row silently read `PASSED` with the counter back at
    # `1 VETO LEFT`. On a five-option pool at 360×640 that counter is the only trace and it
    # sits below the fold, so the voter's one veto came back with nothing saying so.
    for {control, verb} <- [{"#deck-pass", "passing on"}, {"#deck-approve", "approving"}] do
      test "#{verb} the card that holds the veto says the veto came back", %{
        conn: conn,
        group: group,
        activities: [first | _rest]
      } do
        {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

        # Vetoing advances the deck (a veto *is* an answer), so come back to the card that
        # now holds it — which is exactly what "Change" does from the summary.
        view |> element("#deck-veto") |> render_click()
        render_patch(view, ~p"/join/#{group.slug}/vote?view=deck&card=0")

        html = view |> element(unquote(control)) |> render_click()

        assert has_element?(view, "#veto-note")
        assert html =~ "Your veto came off #{first.name} — you have it back."
        assert html =~ "VETO LEFT"
      end
    end

    # Pressing veto on the card that already holds it is the deliberate exception: that
    # path stays on the card, whose own control flips back to `VETO` and whose status line
    # clears in front of the voter, so a note about it would narrate something visible.
    test "releasing the veto with the veto control itself needs no note", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      view |> element("#deck-veto") |> render_click()
      render_patch(view, ~p"/join/#{group.slug}/vote?view=deck&card=0")
      html = view |> element("#deck-veto") |> render_click()

      refute html =~ "you have it back"
      assert html =~ "1 VETO LEFT"
    end

    # **A card the veto came *off* must not claim the voter passed it.** `toggle_veto` ran
    # `mark_seen/2` unconditionally, and `decision_for/4` maps "seen, neither approved nor
    # vetoed" to `:passed` — so vetoing a card and then moving the veto elsewhere left the
    # first card's deck body reading "You passed on this." in the first person and its
    # summary row labelled `PASSED`, on the last screen before an irreversible send. The
    # voter never passed it; they vetoed it and then took the veto off.
    for {label, second_press} <- [
          {"moving the veto to another card", :move},
          {"taking the veto back off", :release}
        ] do
      test "#{label} leaves the first card undecided, not passed", %{
        conn: conn,
        group: group,
        activities: [first, second | _rest]
      } do
        {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

        show_grid(view)
        render_click(view, "toggle_veto", %{"id" => to_string(first.id)})

        target = if unquote(second_press) == :move, do: second.id, else: first.id
        render_click(view, "toggle_veto", %{"id" => to_string(target)})

        # `card=0` is `first`; the deck's own body is where the false claim was rendered.
        html = render_patch(view, ~p"/join/#{group.slug}/vote?view=deck&card=0")

        refute html =~ "You passed on this."
        refute html =~ "You vetoed this."

        # And the summary agrees — it is still waiting on an answer for this card, rather
        # than labelling it `PASSED`. (`decision_label/1`'s string; the row uppercases it
        # in CSS.)
        summary = view |> element("#deck-review") |> render_click()
        assert summary =~ "Not looked at"
        refute summary =~ "Passed"
      end
    end

    # --- Undo says what it costs, and does not double as navigation ------------------
    test "Undo names the card whose answer it will put back", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      html = view |> element("#deck-approve") |> render_click()

      assert html =~ "Undo last card"

      assert has_element?(
               view,
               "#deck-undo[aria-label='Undo — put back your answer on #{first.name}']"
             )
    end

    # Pressed from the summary it used to throw the voter back into the deck and take the
    # submit button off the screen with it — the visible effect read as the *navigation*
    # being undone, while the vote quietly went too.
    test "Undo pressed on the summary stays on the summary", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      view |> element("#deck-approve") |> render_click()
      html = view |> element("#deck-review") |> render_click()
      assert html =~ "1 PICKED"

      html = view |> element("#deck-undo") |> render_click()

      assert html =~ "0 PICKED"
      assert has_element?(view, "#submit-ballot")
      assert has_element?(view, "#deck-summary-heading")
      refute has_element?(view, "#deck-approve")
    end

    # `deck_review/2` and `deck_cancel_change/2` both patch to the summary with
    # `changing?: false`, so side by side they were two controls that appeared to do
    # different things and did not.
    test "Review picks is not offered beside Cancel change — they were the same control", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      assert has_element?(view, "#deck-review")

      view |> element("#deck-review") |> render_click()
      view |> element("button[phx-click='deck_change'][phx-value-index='0']") |> render_click()

      assert has_element?(view, "#deck-cancel-change")
      refute has_element?(view, "#deck-review")
    end

    # The heading branched on whether the ballot was *sendable*, and a veto alone makes it
    # sendable — so one veto and no picks was headed "Your picks" over "0 PICKED".
    test "a veto-only ballot is not headed Your picks", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      view |> element("#deck-veto") |> render_click()
      view |> element("#deck-review") |> render_click()

      heading = view |> element("#deck-summary-heading") |> render()

      assert heading =~ "Nothing picked, one vetoed"
      refute heading =~ "Your picks"
      # And the button is live, because a veto is a mark on the ballot.
      refute has_element?(view, "#submit-ballot[disabled]")
    end

    # `@deck_seen` was written only by the deck, so a voter who worked entirely in the grid
    # — the default view — was told by the summary that they had looked at nothing.
    test "a card answered in the grid is not reported as never looked at", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      show_deck(view)
      html = view |> element("#deck-review") |> render_click()

      assert html =~ "Picked"

      refute view
             |> element("#deck-summary-#{first.id}")
             |> render() =~ "Not looked at"
    end

    # Undo one tap after Change read as "cancel this change" and was not: it reversed a
    # decision made three actions earlier, dropped the change mode and jumped elsewhere.
    test "while a Change is open, Cancel change replaces Undo and costs nothing", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      view |> element("#deck-approve") |> render_click()
      view |> element("#deck-review") |> render_click()

      html =
        view |> element("button[phx-click='deck_change'][phx-value-index='1']") |> render_click()

      assert html =~ "Changing this one"
      assert has_element?(view, "#deck-cancel-change")
      refute has_element?(view, "#deck-undo")

      html = view |> element("#deck-cancel-change") |> render_click()

      assert html =~ "Your picks"
      assert html =~ "1 PICKED"
    end

    # A reload is the one way to lose an unsent ballot that no control on the page owns.
    test "an unsent ballot arms the beforeunload guard, and an empty one does not", %{
      conn: conn,
      group: group,
      activities: [first | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert has_element?(
               view,
               "#ballot-unsaved-guard[phx-hook='UnsavedBallot'][data-unsaved='false']"
             )

      view
      |> element("button[phx-click='toggle_approve'][phx-value-id='#{first.id}']")
      |> render_click()

      assert has_element?(view, "#ballot-unsaved-guard[data-unsaved='true']")
    end

    # The stack drew two ghost cards behind a card with nothing undecided after it,
    # because `behind` was a positional count rather than the undecided one it documents.
    test "the stack thins as the deck is worked through", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=0")

      # Everything decided, then re-opened from the summary: nothing is left behind it.
      for _card <- 1..3, do: view |> element("#deck-pass") |> render_click()

      html =
        view |> element("button[phx-click='deck_change'][phx-value-index='0']") |> render_click()

      refute html =~ "rotate-[3.5deg]"
      refute html =~ "-rotate-2"
    end
  end

  describe "veto_allowed: false" do
    test "hides the veto affordance entirely and reports picks only", %{conn: conn} do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline(), veto_allowed: false})
      activity = activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)

      conn = join_conn(conn, group, participant)
      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}/vote")

      refute html =~ "VETO"
      refute has_element?(view, "button[phx-click='toggle_veto']")

      html =
        view
        |> element("button[phx-click='toggle_approve'][phx-value-id='#{activity.id}']")
        |> render_click()

      assert html =~ "1 PICKED"
      refute html =~ "VETO"
    end

    # The one sentence whose job is unsticking a voter whose Send button is inert used to
    # send them hunting for a veto control that is not on the screen and that
    # `Voting.ensure_veto_permitted/2` would refuse anyway.
    test "the inert-button hint does not offer a veto that does not exist", %{conn: conn} do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline(), veto_allowed: false})
      _activity = activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)

      conn = join_conn(conn, group, participant)
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      hint = view |> element("#ballot-empty-hint") |> render()

      assert hint =~ "Tap the ones you&#39;d be happy with."
      refute hint =~ "veto"
    end

    test "the deck view has no veto affordance either", %{conn: conn} do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline(), veto_allowed: false})
      activity = activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)

      conn = join_conn(conn, group, participant)
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      html = view |> element("#view-deck") |> render_click()

      refute html =~ "VETO"
      refute has_element?(view, "#deck-veto")
      assert has_element?(view, "#deck-approve")
      assert has_element?(view, "#deck-pass")

      html = view |> element("#deck-approve") |> render_click()
      assert html =~ "1 PICKED"
      refute html =~ "VETO"
      assert has_element?(view, "#deck-summary-#{activity.id}")
    end

    test "a pushed veto event (bypassing the hidden UI) is still refused by the context", %{
      conn: conn
    } do
      scope = user_scope_fixture()
      group = group_fixture(scope, %{deadline_at: future_deadline(), veto_allowed: false})
      activity = activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)

      conn = join_conn(conn, group, participant)
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      render_click(view, "toggle_veto", %{"id" => to_string(activity.id)})
      html = render_click(view, "submit_ballot", %{})

      assert html =~ "allowed in this session"
      assert Voting.get_participant_by_token(participant.token).voted_at == nil
    end
  end

  # `Layouts.app/1`'s `fill_viewport` clamp is gated on the viewport being at least 640px
  # tall, so on anything shorter the page is the scroller and nothing was keeping the submit
  # button on screen. Measured on a five-option pool at **375×553** — the iPhone SE / iPhone
  # 8 Safari layout viewport — the grid track was 530px with `scrollHeight` 530 (no internal
  # scroll, exactly as the gate intends below its threshold) and `#submit-ballot` ended at
  # y=883.7 against a 553px viewport: 330.7px below the fold, with `#ballot-status` below it
  # again. The gate itself could not be lowered — the chrome at 375 wide is 436px and the
  # track's `min-h-[200px]` floor puts a clamped column at 636px, 83px past the viewport, so
  # the clamp would go straight back to painting the button over the footer.
  #
  # This is asserted in two halves, because neither half is worth anything alone: the markup
  # has to carry the class, and the stylesheet has to make the class cover **exactly** the
  # range the clamp does not. `assets/css/app.css` is read as text here for the same reason
  # `deploy_config_test.exs` reads `fly.toml` as text — there is nothing else in this suite
  # that can observe a media query, and a browser is where the numbers above came from.
  describe "the submit block stays reachable below the fill_viewport gate" do
    setup %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture(), 5)
      participant = participant_fixture(group, %{display_name: "Ada"})
      %{conn: join_conn(conn, group, participant), group: group}
    end

    test "the counter and the button share one sticky block, in both views", %{
      conn: conn,
      group: group
    } do
      {:ok, view, _html} = live(conn, ~p"/join/#{group.slug}/vote")

      assert has_element?(view, ".ballot-actions #submit-ballot")
      assert has_element?(view, ".ballot-actions #ballot-status")

      # The deck's end-of-deck summary is the deck's only route to Send, and it reaches the
      # same `submit_block/1`.
      {:ok, deck, _html} = live(conn, ~p"/join/#{group.slug}/vote?view=deck&card=5")

      assert has_element?(deck, ".ballot-actions #submit-ballot")
      assert has_element?(deck, ".ballot-actions #ballot-status")
    end

    test "app.css pins .ballot-actions sticky, and off at exactly the clamp's threshold" do
      css = File.read!("assets/css/app.css")

      # The base rule is shared with `.results-actions` (`ResultsComponents.results_panel/1`
      # has the same shape and the same defect), so it is a selector list.
      assert css =~ ~r/\n\.ballot-actions,\n\.results-actions \{[^}]*position: sticky;/,
             "the base rule must be sticky and unlayered, so it applies below the gate"

      assert css =~ ~r/\n\.ballot-actions,\n\.results-actions \{[^}]*bottom: 0;/

      # Both overrides are written base-first and switched off in a `min-height` block, so
      # the two ranges are complementary by construction. If someone tunes one threshold,
      # this fails rather than leaving a band of viewports with neither mechanism.
      thresholds =
        ~r/@media \(min-height: (?<px>\d+)px\) \{\s*\.(?<selector>[a-z-]+) \{/
        |> Regex.scan(css, capture: :all_names)
        |> Map.new(fn [px, selector] -> {selector, px} end)

      assert thresholds["viewport-column"] == "640"
      assert thresholds["ballot-actions"] == thresholds["viewport-column"]

      assert css =~
               ~r/@media \(min-height: 640px\) \{\s*\.ballot-actions \{[^}]*position: static;/
    end
  end
end
