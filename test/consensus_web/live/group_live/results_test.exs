defmodule ConsensusWeb.GroupLive.ResultsTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting

  setup :register_and_log_in_user

  describe "mount" do
    # Scoping still refuses — `Activities.get_group!/2` raises for a group that is not this
    # signed-in user's — but the *raise* no longer reaches the browser as a bare 404. It is
    # rescued into a named redirect, because two ordinary paths land on it: an organizer who
    # pastes `/groups/:id/results` into the group chat instead of the share link, and
    # `UserAuth`'s stored `:user_return_to` surviving a log-in as a different identity (that
    # one was measured landing a brand-new account on Not Found as the very first screen
    # after "Account created"). Nothing about the authorization changed: no tally, no title
    # and no participant of the other user's group is rendered.
    test "another user's group is refused with a named redirect, not a bare 404", %{conn: conn} do
      owner_scope = user_scope_fixture()
      group = group_fixture(owner_scope)

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/groups/#{group}/results")

      assert flash["error"] =~ "isn't yours, or it no longer exists"
      refute flash["error"] =~ group.title
    end

    test "a group id that does not exist is refused the same way", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/groups/999999/results")

      assert flash["error"] =~ "isn't yours, or it no longer exists"
    end

    test "a :draft group redirects to the review screen — nothing has published yet",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/groups/#{group}/results")

      assert to == ~p"/groups/#{group}/review"
      # Not a silent redirect: the organizer asked for results and got a different
      # screen, so the screen says why (D-045).
      assert flash["info"] =~ "no results yet"
      assert flash["info"] =~ group.title
    end
  end

  describe "rendering an open (:voting) group" do
    test "shows the countdown header, avatar row, running tally and organizer footer",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant_fixture(group, %{display_name: "Ada"})

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ group.title
      assert html =~ "LIVE"
      assert html =~ "Running tally"
      assert html =~ a.name
      assert html =~ "0/1 voted"
      assert html =~ "Nudge"
      assert html =~ "Close now"
      # Was "Anonymous session — totals only, no names.", on a page that renders every
      # participant's typed name in a `title` and an `sr-only` span half a screen above.
      # The caption now claims only what the tally it sits under actually does (D-049).
      assert html =~ "nothing here shows who picked what"
      refute html =~ "no names"
    end

    test "a vetoed option renders struck-through with the VETOED pill, not a winner card",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [], a.id)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Vetoed"
      refute html =~ "We have a winner"
    end

    # `Voting.tally/1` gives `leader?` to exactly one survivor and breaks ties by
    # `activity.position` — the order the organizer dragged the pool into on `03 review`,
    # which no voter has seen and cannot reason about. So "Alpha 1 ★ / Beta 1 / Gamma 0"
    # asserted that Alpha was ahead of Beta with nothing on screen making that true. While
    # the vote is open the star is a claim about the count, so everyone on the top count
    # gets one and the legend says which case it is.
    test "a tie for the lead stars every tied option and says so", %{conn: conn, scope: scope} do
      {group, [a, b, _c]} = voting_group_fixture(scope, 3)

      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id])
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [b.id])

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert has_element?(lv, "#tally-star-legend")
      assert html =~ "TIED FOR THE LEAD"
      refute html =~ "LEADING RIGHT NOW"
      # Two stars in the tally, not one. (The legend carries a third.)
      assert length(String.split(html, "★")) - 1 == 3
    end

    test "a single front-runner still reads LEADING RIGHT NOW", %{conn: conn, scope: scope} do
      {group, [a, _b, _c]} = voting_group_fixture(scope, 3)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id])

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "LEADING RIGHT NOW"
      refute html =~ "TIED FOR THE LEAD"
      assert length(String.split(html, "★")) - 1 == 2
    end

    # An untouched pool has no leader, which is `tally/1`'s own rule — every option is
    # "tied" at zero and starring all of them would announce a race nobody has entered.
    test "a pool nobody has voted on has no star and no legend", %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope, 3)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      refute has_element?(lv, "#tally-star-legend")
      refute html =~ "★"
    end
  end

  describe "live updates — the acceptance bar" do
    test "a ballot cast in a second session appears without this session navigating",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "0/1 voted" || html =~ "0/0 voted"

      participant = participant_fixture(group, %{display_name: "Guest"})
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])

      # Force this test to wait for the already-processed :ballot_cast broadcast
      # before asserting, instead of sleeping (AGENTS.md).
      _ = :sys.get_state(lv.pid)
      html = render(lv)

      assert html =~ "1/1 voted"
    end

    test "a guest joining (not yet voting) in a second session appears without this session navigating",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope, 2)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "0/0 voted"

      participant_fixture(group, %{display_name: "Guest"})

      # Force this test to wait for the already-processed :participant_joined broadcast
      # before asserting, instead of sleeping (AGENTS.md).
      _ = :sys.get_state(lv.pid)
      html = render(lv)

      assert html =~ "0/1 voted"
    end
  end

  describe "close_now" do
    test "closes the vote and the shared panel announces the winner",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")
      html = lv |> element("button", "Close now") |> render_click()

      assert html =~ "We have a winner"
      assert html =~ a.name
      assert html =~ "Voting closed"
      refute html =~ "Nudge"
      assert Activities.get_group!(scope, group.id).status == :completed
    end

    # **A completed, unresolved dead heat declares nothing** (`Voting.outcome/2`,
    # `docs/plans/endgame-screens.md`). The first version of this screen crowned
    # `tally/1`'s position tie-break as "We have a winner"; the second kept the card
    # honest ("Tied at the top … takes it because it was first in the pool") but still
    # *settled* the tie by a rule no voter has seen; the third named the standoff and
    # picked nobody. What renders now is the designed tie takeover
    # (`ConsensusWeb.Endgame.Tie` — its own acceptance script is
    # `endgame/tie_test.exs`): the whole panel is replaced, no winner card, no tally,
    # no summary to paste, and the organizer is handed the two ways to actually break
    # it. This test pins the *screen-level* facts: the takeover renders on a Close-now
    # tie exactly as on a deadline one, and nothing on the page asserts a winner.
    test "closing on a tie flips to the dead-heat takeover, and picks nobody",
         %{conn: conn, scope: scope} do
      {group, [a, b, _c]} = voting_group_fixture(scope, 3)

      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id, b.id])

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "TIED FOR THE LEAD"

      html = lv |> element("button", "Close now") |> render_click()

      refute html =~ "We have a winner"
      assert html =~ "dead heat"
      assert html =~ "TIED FOR FIRST"
      assert has_element?(lv, "button#endgame-tie-row-#{a.id}")
      assert has_element?(lv, "button#endgame-tie-row-#{b.id}")
      assert has_element?(lv, "#endgame-lock", "Pick a winner above")
      assert has_element?(lv, "#chrome-context.text-violet", "DEAD HEAT")

      # The position rule no longer settles anything on an unresolved tie — nothing
      # does, and nobody is demoted to a runner-up they never were.
      refute html =~ "takes it because it was first in the pool"
      refute html =~ "Also tied"
      refute html =~ "Runner-up"

      # The takeover replaces the whole panel: no tally, no paste-to-chat summary of a
      # standoff the organizer is being asked to settle, no completed-footer under it.
      refute html =~ "Final tally"
      refute html =~ "copy-summary"
      refute html =~ "Start another session"
      refute html =~ "you have a winner"
    end

    # The other side of `Voting.outcome/2`'s split: a **resolved** tie is `{:winner, row}`
    # again — `Consensus.Activities.resolve_group/4` recorded who broke it — and the card
    # says there is a winner *and* names the tie-breaker (the organizer by username),
    # never the pool order. This drives the context directly rather than through the tie
    # takeover's Lock button; `ConsensusWeb.Endgame.TieTest` covers the button path.
    test "a resolved tie names its tie-breaker, not the pool order",
         %{conn: conn, scope: scope, user: user} do
      {group, [a, b, _c]} = voting_group_fixture(scope, 3)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id, b.id])
      {:ok, group} = Activities.complete_group(scope, group)
      {:ok, _group} = Activities.resolve_group(scope, group, b.id, "organizer_pick")

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "We have a winner"
      refute html =~ "Tied at the top"
      assert has_element?(lv, "#winner-tie-note")
      assert html =~ "2 options finished level on 1 approval"

      # By username — the guest waiting copy names the human, so the exit artifact is
      # at least as specific. "The organizer" survives only as the no-name fallback.
      assert html =~ "#{user.username} picked #{b.name} to break the tie"
      refute html =~ "The organizer picked"
      refute html =~ "first in the pool"

      # The row that drew is still "Also tied", not demoted to a runner-up it never was.
      assert html =~ "Also tied"
      refute html =~ "Runner-up"

      # The paste-to-chat string carries the tie and its breaker out of the app.
      assert has_element?(lv, ~s(#copy-summary[data-copy*="ended in a tie at 1"]))

      assert has_element?(
               lv,
               ~s(#copy-summary[data-copy*="#{user.username} picked #{b.name} to break the tie."])
             )

      # The footer agrees: the tie is settled, so there is a winner to announce.
      assert html =~ "you have a winner"
      refute html =~ "it ended in a tie"
    end

    test "a clear winner is still announced as one, with no tie language",
         %{conn: conn, scope: scope} do
      {group, [a, _b, _c]} = voting_group_fixture(scope, 3)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/results")
      html = lv |> element("button", "Close now") |> render_click()

      assert html =~ "We have a winner"
      refute html =~ "Tied at the top"
      refute has_element?(lv, "#winner-tie-note")
      refute has_element?(lv, "#tally-star-legend")
      assert html =~ "Runner-up"
      assert has_element?(lv, ~s(#copy-summary[data-copy*="won"]))

      # The other side of the footer headline: an actual winner still gets told so.
      assert html =~ "you have a winner"
      refute html =~ "it ended in a tie"
    end

    # Plan ruling 9 / D-041: the header's context slot is state, never the page's name.
    # `ResultsComponents.results_header/1` prints `RESULTS` and `CANCELLED` in the violet
    # band 47px below the header, in the same DM Mono 10.5px uppercase, so `header_context/1`
    # returning those strings printed each one twice on one screen. `LIVE SESSION` stays:
    # the band says something else there.
    test "the header's context slot does not repeat the violet band's own status",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope, 2)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")
      assert html =~ "LIVE SESSION"

      {:ok, group} = Activities.complete_group(scope, group)
      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      # The band still says it, exactly once — and the slot 47px above it says nothing.
      assert html =~ "RESULTS"
      assert html =~ "Voting closed"
      refute lv |> element("#chrome-context") |> render() =~ "RESULTS"

      # A cancelled session is the other half of the same duplication, and it needs its own
      # group — `cancel_group/2` refuses one that has already finished.
      {cancelled, _activities} = voting_group_fixture(scope, 2)
      {:ok, cancelled} = Activities.cancel_group(scope, cancelled)
      {:ok, lv, html} = live(conn, ~p"/groups/#{cancelled}/results")

      assert html =~ "CANCELLED"
      refute lv |> element("#chrome-context") |> render() =~ "CANCELLED"
    end

    test "refuses on an already-finished group and the footer offers nothing to click",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")
      refute html =~ "Close now"
      refute html =~ "Nudge"
    end
  end

  describe "nudge" do
    # It used to be a live, enabled, sticker-styled button whose handler did nothing but
    # flash "there's no notification system yet" — i.e. the screen invited the press and
    # then said no. It now follows the two existing precedents for an unbuilt control
    # (`QR`/`Soon` on `04 share`, the dashed `Bars`/`Movies` chips on `02 add options`).
    test "is drawn as unbuilt rather than inviting a press that does nothing",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)
      participant_fixture(group)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Nudge 1 friend"
      assert lv |> element("button[disabled]", "Nudge") |> has_element?()
      refute html =~ "TAP TO NUDGE"
    end

    # A sentence, not a `disabled` box. "Everyone has voted / ALL IN" was a *status* stacked
    # over an availability marker inside a control that can never be pressed, with the only
    # hint that it was an unbuilt nudge control living in a hover `title` — which does not
    # exist on a phone. Same rule the empty-participant case below already follows: when a
    # control cannot do what it appears to offer, stop rendering the control.
    test "says so instead of offering to nudge nobody once everyone has voted",
         %{conn: conn, scope: scope} do
      {group, [a | _]} = voting_group_fixture(scope)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id], nil)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert has_element?(lv, "p#results-all-voted")
      assert html =~ "Everyone who joined has voted"
      refute html =~ "Nudge 0"
      refute has_element?(lv, "button[disabled]", "Nudge")
      # And no `title`, for the reason `04 share`'s QR button lost its own in the same
      # round: an explanation only a mouse can reach is not an explanation.
      refute html =~ "Everyone waiting has already voted"
    end

    # An **empty** participant list satisfies `waiting_count == 0` exactly as a
    # fully-voted one does, so the first thing an organizer saw after publishing — before
    # anyone had even opened the link — was `0/0 voted` over "Everyone has voted".
    # Both tests above create a participant first, which is why neither could see it.
    test "a freshly published group with nobody in it says nobody has opened the link",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert has_element?(lv, "p#results-nobody-yet")
      assert html =~ "Nobody has opened the link yet"

      # **Above** the button it motivates, not below it. Printed underneath, the sentence
      # was read after the decision it should have informed, and a bare line sandwiched
      # between "Get the share link again" and "Close now" reads as a caption belonging to
      # whichever of the two the eye lands on. State, then action.
      assert :binary.match(html, "results-nobody-yet") <
               :binary.match(html, "results-share-again")

      refute html =~ "Everyone has voted"
      # The first fix kept the disabled box and only changed its two lines, to "Nobody has
      # opened the link yet / SHARE THE LINK" — an imperative printed on a control that
      # cannot be pressed, 100px below the real `Get the share link again →`, explained
      # only by a hover `title` that does not exist on touch. A state with nothing to press
      # gets no control at all.
      refute has_element?(lv, "button[disabled]")
      refute html =~ "SHARE THE LINK"
      refute html =~ "Share the link"
      # "Everyone has voted / SOON" — a status sentence stacked over an availability
      # marker — read as gibberish even when the count was right.
      refute html =~ "Soon"
      # The working share affordance is still there and is now the only one on the screen.
      assert html =~ "Get the share link again"
      # "Close now" survives: an organizer who published to nobody must still be able to
      # end the session.
      assert has_element?(lv, "button[phx-click=close_now]")
    end
  end

  # The `<:footer>` slot had branches for `:voting` and `:cancelled` only, so a
  # `:completed` group rendered nothing at all below the tally — and with an outcome of
  # `:no_consensus` or `:no_votes` there was no winner card above it either, leaving the
  # organizer of a finished session with no control anywhere on the page.
  describe "a finished group still offers the organizer something to do" do
    test "a completed group with a winner names the state and offers the next session",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Voting is closed and you have a winner."
      assert has_element?(lv, "#results-start-another")
      assert html =~ "Start another session"
    end

    # This cell used to render the `:completed` footer's "no winner" note; since the
    # endgame screens landed it renders the All Vetoed takeover, whose two exits — Add
    # new options and Let the app pick one at random — are the controls. The takeover's
    # own behaviour is pinned in `endgame/all_vetoed_test.exs`; this test keeps pinning
    # that the organizer of this dead-end state is never left without a control.
    test "a completed group with no consensus still has a control on the page",
         %{conn: conn, scope: scope} do
      {group, [a]} = voting_group_fixture(scope, 1)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [], a.id)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Nobody wanted anything."
      assert has_element?(lv, "#endgame-add-options")
      assert has_element?(lv, "#endgame-rescue")
    end

    # The state that used to render as `:no_votes`: ballots really were cast, part of the
    # pool survived them, and nothing that survived has an approval. The screen said
    # "Voting is closed and nobody voted" over an avatar row showing `1/1 voted` and a
    # struck-through option wearing a VETOED pill.
    test "a completed group where the only marks were vetoes does not claim nobody voted",
         %{conn: conn, scope: scope} do
      {group, [a, _b, _c]} = voting_group_fixture(scope, 3)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [], a.id)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Voting is closed with no winner."
      refute html =~ "nobody voted"
      refute html =~ "before anyone cast a ballot"
      # Two different sentences, not one repeated: the panel says what happened, the
      # footer says what to do about it.
      assert html =~ "Votes came in, but nothing survived them"
      assert html =~ "Nothing left standing picked up an approval"
      assert has_element?(lv, "#results-start-another")
    end

    test "a completed group nobody voted in still has a control on the page",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Voting is closed and nobody voted."
      # `complete_group/2` is what **Close now** calls, so this is the early-close shape:
      # `completed_at` earlier than `deadline_at`. The note used to say "the deadline
      # passed with an empty ballot box" on a session whose countdown had read "1d 12h
      # left" seconds before the organizer pressed the button.
      assert html =~ "You closed this before anyone sent their votes in."
      refute html =~ "The deadline passed"
      # Vacuous on a session nobody voted in.
      refute html =~ "everyone who voted can still open the link"
      assert has_element?(lv, "#results-start-another")
    end

    # The other way into `:completed` — the lazy deadline sweep in
    # `Activities.maybe_complete_group/1`, which stamps `completed_at` at or after
    # `deadline_at`. Same outcome, different sentence.
    test "a group nobody voted in that ran out of time says the deadline passed",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)

      {:ok, group} =
        group
        |> Ecto.Changeset.change(%{
          status: :completed,
          deadline_at: DateTime.add(DateTime.utc_now(:second), -60, :minute),
          completed_at: DateTime.utc_now(:second)
        })
        |> Consensus.Repo.update()

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "The deadline passed with an empty ballot box."
      refute html =~ "You closed this before"
    end

    test "a cancelled group says it cannot be reopened and offers the next session",
         %{conn: conn, scope: scope} do
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.cancel_group(scope, group)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "cannot be reopened"
      assert has_element?(lv, "#results-start-another-cancelled")
    end
  end

  describe "outcomes on a finished group" do
    # Since the endgame screens landed, an unresolved all-vetoed completed group renders
    # the All Vetoed takeover (`ConsensusWeb.Endgame.AllVetoed`) instead of the muted
    # "no consensus this time" card — see `endgame/all_vetoed_test.exs` for the takeover
    # itself. What this test keeps pinning is the honesty half: nothing on the screen
    # claims a winner.
    test "everyone vetoing everything is reported honestly, not as an empty winner card",
         %{conn: conn, scope: scope} do
      {group, [a]} = voting_group_fixture(scope, 1)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [], a.id)
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "Every single option got vetoed."
      refute html =~ "We have a winner"
    end

    test "a cancelled group shows a cancelled notice, not a winner", %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.cancel_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "cancelled"
      refute html =~ "We have a winner"
      # `Voting.tally/1` gates only `winner?` on `:completed`, so `leader?` survives a
      # cancellation and `Sticker.tally_bar/1` paints its ★ from `leader?` — this screen
      # rendered a starred front-runner under **Final tally** while saying twice, in the
      # panel and the footer, that nobody won. `presentable_tally/2` takes the crown off.
      assert html =~ "Final tally"
      refute html =~ "★"
    end

    test "the winner card links out to the winning option's own source_url",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      a = activity_fixture(group, %{source_url: "https://example.com/booking"})
      {:ok, group} = Activities.publish_group(scope, group)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [a.id])
      {:ok, group} = Activities.complete_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/results")

      assert html =~ "https://example.com/booking"
      assert html =~ "copy-summary"
    end
  end
end
