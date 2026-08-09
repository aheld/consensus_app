defmodule ConsensusWeb.AdminLive.FeedbackTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.FeedbackFixtures

  alias Consensus.Feedback
  alias Consensus.Feedback.Entry

  setup %{conn: conn} do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  describe "the guards" do
    test "a signed-out visitor is bounced", %{} do
      conn = build_conn()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin/feedback")
    end

    test "a signed-in non-admin is bounced", %{} do
      conn = build_conn() |> log_in_user(user_fixture())
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/feedback")
      assert to == "/"
    end
  end

  describe "the queue" do
    test "says so plainly when there is nothing in it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      assert has_element?(lv, "#feedback-empty")
      assert has_element?(lv, "h1", "Feedback")
    end

    test "lists newest first with the mood, the words and when", %{conn: conn} do
      older = feedback_fixture(%{"mood" => "happy", "message" => "older one"})
      newer = feedback_fixture(%{"mood" => "sad", "message" => "newer one"})

      {:ok, lv, html} = live(conn, ~p"/admin/feedback")

      assert has_element?(lv, "#feedback-#{older.id}", "older one")
      assert has_element?(lv, "#feedback-#{newer.id}", "newer one")

      newer_at = :binary.match(html, "feedback-#{newer.id}")
      older_at = :binary.match(html, "feedback-#{older.id}")
      assert elem(newer_at, 0) < elem(older_at, 0)
    end

    test "unread is legible without reading a pill, and the pill is there too",
         %{conn: conn, admin: admin} do
      scope = Consensus.Accounts.Scope.for_user(admin)
      unread = feedback_fixture(%{"message" => "unread one"})
      read = read_feedback_fixture(scope, %{"message" => "read one"})

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      # Colour is never the only signal: tinted card *and* an "unread" pill. Violet and
      # not yellow — a full `--yellow` fill already means "warning" on /admin/users, and
      # ten unread rows read as ten alarms.
      assert has_element?(lv, "#feedback-#{unread.id} .bg-violet-tint")
      assert has_element?(lv, "#feedback-#{unread.id}", "unread")
      refute has_element?(lv, "#feedback-#{read.id} .bg-violet-tint")
      refute has_element?(lv, "#feedback-#{unread.id} .bg-yellow")
    end

    test "never claims a sender was signed out, because it cannot know that", %{conn: conn} do
      user = user_fixture()
      anon = feedback_fixture(%{"message" => "from a stranger"})
      known = feedback_fixture(%{"message" => "from an account"}, user_id: user.id)

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      assert has_element?(lv, "#feedback-#{known.id}", "signed in")
      assert has_element?(lv, "#feedback-#{known.id}", user.username)

      # `feedback.user_id` is `nilify_all` on purpose (D-042), so a nil there means
      # "signed out" *or* "their account was deleted afterwards" and the screen cannot
      # tell which. It used to print "signed out" for both, asserting something false on
      # a screen whose whole posture is that it prints only what is true.
      assert has_element?(lv, "#feedback-#{anon.id}", "no account linked")
      refute lv |> element("#feedback-#{anon.id}") |> render() =~ "signed out"
    end

    test "the name slot and the account line carry different facts", %{conn: conn} do
      anon = feedback_fixture(%{"message" => "no name typed"})

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      # The card used to print "signed out" twice — once as the sender's name and once
      # on the metadata line — so one of the two slots carried no information.
      assert has_element?(lv, "#feedback-#{anon.id}", "no name given")

      card = lv |> element("#feedback-#{anon.id}") |> render()
      assert length(String.split(card, "no account linked")) == 2
    end

    test "a pasted link in a message wraps instead of pushing the card sideways",
         %{conn: conn} do
      url = "https://dinner.isourthing.com/join/" <> String.duplicate("a", 60)
      entry = feedback_fixture(%{"message" => "the link is broken: " <> url})

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      # `overflow-wrap: normal` painted the URL through the card's 2px right border and
      # made the whole document scroll sideways. A pasted share link is the single most
      # likely thing to appear in a bug report.
      assert has_element?(lv, "#feedback-#{entry.id} p.break-words", url)
    end

    test "every control on a row clears the phone tap minimum", %{conn: conn} do
      entry = feedback_fixture(%{}, page_path: "/")

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      assert lv |> element("#feedback-#{entry.id} button", "Mark read") |> render() =~
               "min-h-[44px]"

      assert lv |> element("#note-toggle-#{entry.id}") |> render() =~ "min-h-[44px]"

      open_note(lv, entry)

      assert lv |> element("#feedback-#{entry.id} button", "Save note") |> render() =~
               "min-h-[44px]"

      # `/` is the most common captured path, and set in 10.5px mono it is a 6px-wide
      # target unless the whole row is the link.
      assert lv |> element("#feedback-#{entry.id} a[href='/']") |> render() =~ "min-h-[44px]"
    end

    test "shows the captured screen as a link when there is one", %{conn: conn} do
      with_page = feedback_fixture(%{}, page_path: "/groups/12/options")
      without = feedback_fixture(%{"include_page" => "false"}, page_path: "/groups/12/options")

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      assert has_element?(lv, "#feedback-#{with_page.id} a[href='/groups/12/options']")
      refute has_element?(lv, "#feedback-#{without.id} a[href='/groups/12/options']")
    end

    test "the captured screen opens in a new tab, so the queue is never unloaded",
         %{conn: conn} do
      entry = feedback_fixture(%{}, page_path: "/groups/12/options")

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      # Followed in this tab it stranded the admin — the destination's `‹` goes to `/`,
      # not back here — and unloading this page throws away every unsaved note on it.
      link = lv |> element("#feedback-#{entry.id} a[href='/groups/12/options']") |> render()
      assert link =~ ~s(target="_blank")
      assert link =~ ~s(rel="noopener")
      assert link =~ "opens a new tab"
    end

    test "links across to the other admin screen, in both directions", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      assert has_element?(lv, "#admin-users-link[href='/admin/users']")

      {:ok, users, _html} = live(conn, ~p"/admin/users")
      assert has_element?(users, "#admin-feedback-link[href='/admin/feedback']")
    end

    test "the cross-link from /admin/users says how many are waiting", %{conn: conn} do
      # Without the count an admin who never taps the link never learns anything is
      # there, and `/admin/feedback` is still not in the header's `⋯` menu (D-043).
      {:ok, empty, _html} = live(conn, ~p"/admin/users")
      refute empty |> element("#admin-feedback-link") |> render() =~ "unread"

      feedback_fixture()
      feedback_fixture()

      {:ok, users, _html} = live(conn, ~p"/admin/users")
      assert users |> element("#admin-feedback-link") |> render() =~ "2 unread"
    end

    test "says on screen that nothing here notifies anybody", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, html} = live(conn, ~p"/admin/feedback")

      # Once, in the page summary — it used to be repeated beside all fifteen rows.
      assert html =~ "nobody is emailed either way"

      # And again beside the note itself, where an admin typing "replied to them" is
      # looking. Only for the row whose editor is actually open.
      assert open_note(lv, entry) =~ "Saving emails nobody"
    end
  end

  describe "mark read" do
    test "is reversible from the same place", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      lv |> element("#feedback-#{entry.id} button", "Mark read") |> render_click()
      assert Entry.read?(Feedback.get_entry(entry.id))
      assert has_element?(lv, "#feedback-#{entry.id} button", "Mark unread")

      lv |> element("#feedback-#{entry.id} button", "Mark unread") |> render_click()
      refute Entry.read?(Feedback.get_entry(entry.id))
      assert has_element?(lv, "#feedback-#{entry.id} button", "Mark read")
    end

    test "a forged id is refused rather than crashing the LiveView", %{conn: conn} do
      feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      html = render_click(lv, "set_read", %{"id" => "not-a-number", "read" => "true"})
      assert html =~ "Could not update that message"
    end
  end

  describe "the note editor is collapsed until it is wanted" do
    test "a closed row renders no textarea, and the toggle opens it", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      # Expanded on every row this screen cost 460px a row — 11 viewport heights for 15
      # messages at 360×640, 44% of it empty textarea — on the one screen whose entire
      # job is scanning.
      refute has_element?(lv, "#note-form-#{entry.id}")
      assert has_element?(lv, "#note-toggle-#{entry.id}", "Add a note")

      open_note(lv, entry)
      assert has_element?(lv, "#note-form-#{entry.id} textarea")
      assert has_element?(lv, "#note-toggle-#{entry.id}", "Hide note")

      lv |> element("#note-toggle-#{entry.id}") |> render_click()
      refute has_element?(lv, "#note-form-#{entry.id}")
    end

    test "a row that already carries a note opens with it showing", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      open_note(lv, entry)
      lv |> form("#note-form-#{entry.id}", note: %{"body" => "did the thing"}) |> render_submit()

      # A fresh mount: the note is the record of what was done, so hiding it behind a
      # click on first load would be the "invisible state" confusion.
      {:ok, reloaded, _html} = live(conn, ~p"/admin/feedback")
      assert has_element?(reloaded, "#note-form-#{entry.id} textarea", "did the thing")
    end

    test "a closed row still says whether anything was written on it", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      open_note(lv, entry)
      lv |> form("#note-form-#{entry.id}", note: %{"body" => "abcde"}) |> render_submit()
      lv |> element("#note-toggle-#{entry.id}") |> render_click()

      refute has_element?(lv, "#note-form-#{entry.id}")
      assert has_element?(lv, "#note-toggle-#{entry.id}", "Note · 5 characters")
    end

    test "a row the admin collapsed stays collapsed through another row's event",
         %{conn: conn} do
      a = feedback_fixture(%{"message" => "row a"})
      b = feedback_fixture(%{"message" => "row b"})
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      open_note(lv, a)
      lv |> form("#note-form-#{a.id}", note: %{"body" => "noted"}) |> render_submit()
      lv |> element("#note-toggle-#{a.id}") |> render_click()

      # Re-deriving `open` from the stored note on every event would spring this back
      # open on the next keystroke anywhere on the page.
      lv |> element("#feedback-#{b.id} button", "Mark read") |> render_click()
      refute has_element?(lv, "#note-form-#{a.id}")
    end
  end

  describe "the private admin note" do
    test "saves, survives a reload, and can be cleared again", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      open_note(lv, entry)

      lv
      |> form("#note-form-#{entry.id}", note: %{"body" => "emailed them by hand"})
      |> render_submit()

      assert Feedback.get_entry(entry.id).admin_note == "emailed them by hand"

      {:ok, reloaded, _html} = live(conn, ~p"/admin/feedback")
      assert has_element?(reloaded, "#note-form-#{entry.id} textarea", "emailed them by hand")

      reloaded |> form("#note-form-#{entry.id}", note: %{"body" => ""}) |> render_submit()
      assert Feedback.get_entry(entry.id).admin_note == nil
    end

    test "the textarea has no maxlength and the counter tracks what is typed",
         %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      refute open_note(lv, entry) =~ "maxlength"
      assert has_element?(lv, "#note-counter-#{entry.id}", "0/1000")

      lv |> form("#note-form-#{entry.id}", note: %{"body" => "abcde"}) |> render_change()
      assert has_element?(lv, "#note-counter-#{entry.id}", "5/1000")
    end

    test "saving one says out loud that nobody was emailed", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      open_note(lv, entry)

      html =
        lv |> form("#note-form-#{entry.id}", note: %{"body" => "done"}) |> render_submit()

      assert html =~ "Nobody was emailed"
    end

    test "a draft survives marking that same row read", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      open_note(lv, entry)

      lv
      |> form("#note-form-#{entry.id}", note: %{"body" => "HALFTYPEDNOTE"})
      |> render_change()

      # "Read it, write down what I did, mark it read" is the natural triage order, so
      # this is the *normal* path — and it used to empty the textarea with no warning,
      # no flash and no undo.
      html = lv |> element("#feedback-#{entry.id} button", "Mark read") |> render_click()

      assert html =~ "HALFTYPEDNOTE"
      assert has_element?(lv, "#note-counter-#{entry.id}", "13/1000")
    end

    test "a draft in one row survives saving another row's note", %{conn: conn} do
      a = feedback_fixture(%{"message" => "row a"})
      b = feedback_fixture(%{"message" => "row b"})
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      open_note(lv, a)
      open_note(lv, b)

      lv |> form("#note-form-#{a.id}", note: %{"body" => "DRAFTINA"}) |> render_change()
      html = lv |> form("#note-form-#{b.id}", note: %{"body" => "saved b"}) |> render_submit()

      assert html =~ "DRAFTINA"
      assert Feedback.get_entry(b.id).admin_note == "saved b"
      assert Feedback.get_entry(a.id).admin_note == nil
    end

    test "the row that was written reseeds from the database, so clearing still lands",
         %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      open_note(lv, entry)

      lv |> form("#note-form-#{entry.id}", note: %{"body" => "  padded  "}) |> render_submit()

      assert Feedback.get_entry(entry.id).admin_note == "padded"
      assert has_element?(lv, "#note-counter-#{entry.id}", "6/1000")
    end

    test "an over-long note names the real limit and keeps what was typed", %{conn: conn} do
      entry = feedback_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      open_note(lv, entry)
      over = String.duplicate("z", 1001)

      lv |> form("#note-form-#{entry.id}", note: %{"body" => over}) |> render_change()
      html = lv |> form("#note-form-#{entry.id}", note: %{"body" => over}) |> render_submit()

      assert html =~ "That note is 1001 characters and the limit is 1000"
      # The old copy told the admin to reload, which was the one action that would also
      # have destroyed the text — and the text had already been wiped by then anyway.
      refute html =~ "Reload the page and try again"
      assert html =~ over
      assert has_element?(lv, "#note-counter-#{entry.id}", "1001/1000")
      assert Feedback.get_entry(entry.id).admin_note == nil
    end

    test "cannot edit what the sender wrote", %{conn: conn} do
      entry = feedback_fixture(%{"message" => "the original words"})
      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")
      open_note(lv, entry)

      lv |> form("#note-form-#{entry.id}", note: %{"body" => "note"}) |> render_submit()

      assert Feedback.get_entry(entry.id).message == "the original words"
    end
  end

  # The note editor is collapsed by default, so every note test opens the row the way an
  # admin does. Returns the rendered page so a caller can assert on it directly.
  defp open_note(lv, entry) do
    lv |> element("#note-toggle-#{entry.id}") |> render_click()
  end

  # D-045. D-041 already states as a rule that "an unsaved admin note is never thrown
  # away"; `load_entries/2`'s `reseed_ids` kept that true across this screen's own events
  # and it was still false across a *navigation*. Measured: a note typed into a row, a tap
  # on the footer's About us, `‹` back — and the field held the previously **saved** value.
  describe "the unsaved-note guard" do
    test "is disarmed with no notes open and nothing typed", %{conn: conn} do
      feedback_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      refute has_element?(lv, "#chrome-back[data-confirm]")
      refute has_element?(lv, "footer a[data-confirm]")
    end

    # Deliberately not the brief's fallback ("prompt whenever `@open_notes` is non-empty"):
    # `open_notes/2` seeds itself open for every row that already carries a note, so on a
    # triaged inbox that would prompt on every navigation with nothing at stake — and a
    # warning that is usually wrong is one people learn to dismiss.
    test "stays disarmed on a row whose saved note is merely visible", %{conn: conn, admin: admin} do
      entry = feedback_fixture()

      {:ok, _} =
        Feedback.annotate(Consensus.Accounts.Scope.for_user(admin), entry, "already saved")

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      refute has_element?(lv, "#chrome-back[data-confirm]")
    end

    test "arms once a note draft differs from what is stored", %{conn: conn} do
      entry = feedback_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      render_click(lv, "toggle_note", %{"id" => to_string(entry.id)})

      lv
      |> form("#note-form-#{entry.id}", note: %{"body" => "Triaged: this is the note."})
      |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
      assert has_element?(lv, "footer a[data-confirm]")
    end

    # **Enumerated, not named.** The first sweep put the prompt on the header `‹` and all
    # six footer controls and missed the one in-page link — `Go to Admin → Users`, a
    # `navigate` that remounts this LiveView and takes every open draft with it. It was
    # missed because the tests asserted the controls somebody thought of. This asserts the
    # *complement*: with a draft open, no anchor on the page may be without the prompt.
    #
    # `target="_blank"` links are the deliberate exception and the reason the filter is
    # here rather than in the assertion message: the "was on" link and the outbound credit
    # open a new tab, so they never unload this page — that is how the "was on" link closed
    # this same hazard before the confirm existed.
    test "with a draft open, every in-page link carries the prompt", %{conn: conn} do
      entry = feedback_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/feedback")

      render_click(lv, "toggle_note", %{"id" => to_string(entry.id)})

      lv
      |> form("#note-form-#{entry.id}", note: %{"body" => "Triaged: this is the note."})
      |> render_change()

      anchors = ~r/<a\s[^>]*>/ |> Regex.scan(render(lv)) |> Enum.map(&hd/1)

      # Or the enumeration is vacuous and passes by finding nothing, which is the failure
      # mode of every "assert the complement" test.
      assert length(anchors) >= 8, "the anchor scan found nothing to enumerate"

      unguarded =
        anchors
        |> Enum.reject(&(&1 =~ ~s(target="_blank")))
        |> Enum.reject(&(&1 =~ "data-confirm="))

      assert unguarded == [],
             "these links leave the page and discard every unsaved note: #{inspect(unguarded)}"

      # And the specific one the sweep missed, so a future refactor that drops the
      # enumeration above still fails loudly on the known case.
      assert has_element?(lv, "#admin-users-link[data-confirm]")
    end
  end
end
