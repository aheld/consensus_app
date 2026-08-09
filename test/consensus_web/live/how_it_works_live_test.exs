defmodule ConsensusWeb.HowItWorksLiveTest do
  @moduledoc """
  `/how-it-works` (design frame `00b`), plus the two standing pages that have no frame.

  The interesting half is the copy: `00b`'s own words promise three things this product
  does not do, and shipping them would be a lie a reader acts on. Those assertions are
  `refute`s, which are exactly the assertions that rot quietly — so each one names the
  decision it protects.
  """
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  describe "/how-it-works" do
    test "renders the frame's four steps, plus the first beat the frame leaves out",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/how-it-works")

      assert html =~ "How it works"
      assert html =~ "Add the options"
      assert html =~ "Share one link"
      assert html =~ "Everyone taps what works"
      assert html =~ "The deadline decides"
      assert html =~ "Good to know"
    end

    # The frame's four steps begin at "Add the options", so the page never said the
    # organizer names the session and sets the deadline — then step 4 opened "When the
    # timer runs out…", a definite article for an object nothing had introduced, and the
    # single tangerine CTA dropped the reader onto `/groups/new`, whose only two inputs
    # are a title and a deadline. Two assertions, because the fix is only half done if the
    # step exists but the last one still refers to an unnamed timer.
    test "names the deadline before the last step depends on it", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/how-it-works")

      assert html =~ "Name it and pick a deadline"
      assert html =~ "the deadline you set"
      refute html =~ "When the timer runs out"
    end

    test "does not ship the frame's three false promises", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/how-it-works")

      # Friends adding options to somebody else's pool is Post-MVP, and the pool freezes
      # when voting opens (invariant 16 / D-037).
      refute html =~ "throw theirs in"
      # The ballot is approval voting with veto elimination (D-034), not a ranked drag.
      refute html =~ "Drag your top three"
      refute html =~ "top three"
      # A cast ballot is locked (D-036).
      refute html =~ "Change your ranking any time"
    end

    test "states the two irreversible facts instead", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/how-it-works")

      assert html =~ "final once you send them"
      assert html =~ "locked from the"
    end

    test "the CTA sends a signed-out visitor to registration, and says what that costs",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/how-it-works")

      assert has_element?(lv, "#how-it-works-cta[href='/users/register']")
      assert html =~ "Voting in someone"
    end

    test "the CTA sends a signed-in organizer straight to a new session", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, lv, html} = live(conn, ~p"/how-it-works")

      assert has_element?(lv, "#how-it-works-cta[href='/groups/new']")
      refute html =~ "Voting in someone"
    end

    test "the back circle returns to wherever the footer link was tapped", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/how-it-works?return_to=/groups/12/options")
      assert has_element?(lv, "#chrome-back[href='/groups/12/options']")

      {:ok, plain, _html} = live(conn, ~p"/how-it-works")
      assert has_element?(plain, "#chrome-back[href='/']")
    end
  end

  describe "/about" do
    test "says what the product does not do rather than implying it does", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/about")

      assert html =~ "What it doesn&#39;t do"
      assert html =~ "doesn&#39;t search for restaurants"
      assert html =~ "doesn&#39;t send notifications"
    end
  end

  describe "/privacy" do
    test "names every category of data this app actually stores", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/privacy")

      assert html =~ "If you vote"
      assert html =~ "If you organize"
      # Was "Votes are anonymous", which is the heading D-049 had to correct: it sat over a
      # paragraph whose first job is to say the guest list is public. See the anonymity
      # test further down for the claim itself.
      assert html =~ "Who voted, and what they picked"
      assert html =~ "If you send feedback"
      assert html =~ "Cookies and other sites"
    end

    test "admits the one third-party request the app really makes", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/privacy")

      # `root.html.heex` loads two typefaces from Google Fonts. A privacy page claiming
      # "no third parties" while the browser calls out for them would be false.
      assert html =~ "Google Fonts"
      assert html =~ "no analytics"
    end

    test "counts the account among what feedback stores, because 'nothing else' is a closed list",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/privacy")

      # `ConsensusWeb.FeedbackLive` passes `user_id:` unconditionally and the sender
      # cannot decline it by leaving name and email blank, so a page that enumerated the
      # feedback columns and closed with "Nothing else" while omitting it was false.
      assert html =~ "which account it came from"
      assert html =~ "Nothing else"
    end

    test "does not claim an anonymity stronger than the schema provides", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/privacy")

      # D-035 is an *API-surface* property: no public context function maps a participant
      # to their approvals. The rows exist — `votes.participant_id` → `participants`,
      # which carries `display_name` and a nullable `user_id` that `JoinController` sets
      # to the real account for a signed-in voter. One SQL join produces "who approved
      # what", so "that is how it is built, not a setting somebody could switch" was a
      # promise the database does not keep.
      assert html =~ "no admin page shows who picked"
      assert html =~ "rows are still in the database"
      refute html =~ "not a setting somebody could switch."

      # And the vote section must say the individual picks are retained per person.
      assert html =~ "options you tapped"
    end

    # The other direction of the same honesty, and the one D-049 added: this page must not
    # let a heading or an unqualified "anonymous" imply that *joining* is private.
    # `ConsensusWeb.JoinLive.Results` renders the WHO'S VOTED row for a visitor holding no
    # participant token at all, so the guest list is readable by anyone with the link.
    test "says plainly that who has voted is public", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/privacy")

      assert html =~ "Who has voted is"
      assert html =~ "anyone holding the share link can open the results and read the"
      # The name a voter types is the thing that ends up in that list, so the section a
      # voter reads first has to point at it rather than leaving "optional" to stand alone.
      assert html =~ "it goes in the list of who has voted"
    end

    test "is honest about what asking for deletion does and does not do", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/privacy")

      # `feedback.user_id` is `nilify_all` so a bug report outlives the account that filed
      # it — deliberately (D-042) — and the name and email the sender typed are untouched
      # by the delete. A page headed "everything this app stores about you" promising
      # removal it does not perform is the failure this section had.
      assert html =~ "Feedback you already sent is kept"
      # There is no outbound mail for feedback and no notification of any kind, so the
      # page must not imply somebody is paged.
      assert html =~ "Nobody is notified automatically"
    end

    test "the feedback link does not pre-file a deletion request as a complaint",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/privacy?return_to=/groups/3/options")

      link = lv |> element("main a", "feedback form") |> render()

      # `mood=sad` filed "please close my account" in the admin queue as a complaint, and
      # made the arriving form caption read "From the footer" when nobody came from it.
      refute link =~ "mood=sad"
      # Its own path, not the one it inherited: handing an outgoing link the inherited
      # `return_to` made the form offer to attach a screen the sender was never on.
      assert link =~ "return_to=%2Fprivacy"
      refute link =~ "groups"
      # And it is a real tap target, not a 15px line box.
      assert link =~ "min-h-[44px]"
    end

    test "its forward action is not the one the footer already offers", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/privacy")

      # A second "How it works" button 53px above the footer's own "How it works" link,
      # with different back behaviour, is the "ambiguous duplication" confusion — and
      # pointing both at the same place does not fix it, because the footer's link is
      # built in `chrome.ex` from whatever `return_to` this page was handed.
      assert has_element?(lv, "#privacy-cta[href='/users/register']")
      refute lv |> element("#privacy-cta") |> render() =~ "how-it-works"
    end

    test "the back circle refuses a path a browser would resolve off-site", %{conn: conn} do
      # `CurrentPath.safe_return_to/1` rejects a literal `//` prefix but not a tab between
      # the slashes, and browsers strip tab/LF/CR before resolving — so this would be an
      # open redirect wearing this app's header.
      {:ok, lv, _html} = live(conn, ~p"/privacy?#{[return_to: "/\t/evil.example/x"]}")
      assert has_element?(lv, "#chrome-back[href='/']")

      {:ok, about, _html} = live(conn, ~p"/about?#{[return_to: "/\t/evil.example/x"]}")
      assert has_element?(about, "#chrome-back[href='/']")

      {:ok, hiw, _html} = live(conn, ~p"/how-it-works?#{[return_to: "//evil.example/x"]}")
      assert has_element?(hiw, "#chrome-back[href='/']")
    end
  end

  describe "the standing pages' outgoing links" do
    test "carry their own path, not the one they inherited", %{conn: conn} do
      # `@return_to` is for the header's `‹` alone. On an *outgoing* link it sends the
      # reader somewhere that believes they came from wherever this page was opened from,
      # so that page's `‹` skips the page they were just reading — and on /feedback it
      # made the capture row name a screen the sender was never on.
      {:ok, about, _html} = live(conn, ~p"/about?return_to=/groups/3/options")
      assert has_element?(about, "#chrome-back[href='/groups/3/options']")
      assert about |> element("main a[href*='how-it-works']") |> render() =~ "return_to=%2Fabout"
    end
  end

  describe "the multiple-voting caveat" do
    test "names the gap, the trade, and a way to answer", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/how-it-works")

      # The gap itself, in the terms a reader would hit it in.
      assert html =~ "private window"

      # The trade, not just the flaw. A limitation stated with no reasoning reads as an
      # apology; the point of this section is that the alternative costs something.
      assert html =~ "phone number"

      # And somewhere for an opinion to actually land. Sad-mood, because a reader who
      # disagrees with this call is reporting a problem, and `return_to` so the feedback
      # form's Cancel comes back here rather than dropping them on `/`.
      assert html =~ ~s(id="honest-limit-feedback")
      assert html =~ "/feedback?mood=sad&amp;return_to=%2Fhow-it-works"
    end

    test "does not spend the screen's one tangerine", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/how-it-works")

      # The caveat is a violet-tint card with an underlined link. `#how-it-works-cta` is
      # the forward action and owns the colour; a warning-coloured caveat would read as an
      # error the reader has to clear before proceeding.
      assert html =~ ~s(id="honest-limit")
      refute html =~ ~s(id="honest-limit-feedback" variant="primary")
    end
  end
end
