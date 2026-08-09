defmodule ConsensusWeb.FeedbackLiveTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  alias Consensus.Feedback

  defp submit(lv, params) do
    lv |> form("#feedback-form", entry: params) |> render_submit()
  end

  describe "the form" do
    test "arrives with the face the footer sent already picked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=sad")

      assert has_element?(lv, "#feedback-mood-sad input[checked]")
      refute has_element?(lv, "#feedback-mood-happy input[checked]")
    end

    test "the other face is one tap away, not locked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=happy")
      assert has_element?(lv, "#feedback-mood-happy input[checked]")

      # Both faces are always on screen — frame `00c`'s "tap to switch".
      assert has_element?(lv, "#feedback-mood-sad")

      html = lv |> form("#feedback-form", entry: %{"mood" => "sad"}) |> render_change()
      assert html =~ "feedback-mood-sad"
      assert has_element?(lv, "#feedback-mood-sad input[checked]")
    end

    test "a direct visit with no mood renders both faces unpicked and still works",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback")

      refute has_element?(lv, "#feedback-mood-happy input[checked]")
      refute has_element?(lv, "#feedback-mood-sad input[checked]")

      html = submit(lv, %{"message" => "no mood picked"})
      assert html =~ "tap a face so we know which way this went"
      assert Feedback.list_entries() == []
    end

    test "an unknown mood falls back to none instead of crashing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=%F0%9F%99%83")
      refute has_element?(lv, "#feedback-mood-happy input[checked]")
      refute has_element?(lv, "#feedback-mood-sad input[checked]")
    end

    test "the message field carries no maxlength and the counter reads the changeset's cap",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/feedback?mood=sad")

      # CLAUDE.md invariant 11 / D-026: a browser counts UTF-16 code units and silently
      # truncates a paste, so the attribute must not be there at all.
      refute html =~ "maxlength"
      assert has_element?(lv, "#feedback-counter", "0/600")

      lv |> form("#feedback-form", entry: %{"message" => "hello"}) |> render_change()
      assert has_element?(lv, "#feedback-counter", "5/600")
    end

    test "the counter turns tangerine past the cap and the save refuses", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=sad")
      over = String.duplicate("a", 601)

      html = lv |> form("#feedback-form", entry: %{"message" => over}) |> render_change()
      assert html =~ "text-tangerine"
      assert has_element?(lv, "#feedback-counter", "601/600")

      submit(lv, %{"mood" => "sad", "message" => over})
      assert Feedback.list_entries() == []
    end

    test "a signed-in sender's name is pre-filled", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/feedback?mood=happy")
      assert html =~ user.username
    end

    test "the mood caption is keyed on the mood, not on where the visitor came from",
         %{conn: conn} do
      # A `return_to` with no mood used to be told to "switch" a selection that did not
      # exist, hiding the fact that a mood is required until the send was refused.
      {:ok, _lv, html} = live(conn, ~p"/feedback?#{[return_to: "/groups/12/review"]}")
      assert html =~ "Tap one"
      refute html =~ "tap to switch"

      {:ok, _lv2, html2} = live(conn, ~p"/feedback?mood=happy")
      assert html2 =~ "From the footer — tap to switch"
      refute html2 =~ "Tap one"
    end

    test "a face picked in the page is not described as having come from the footer",
         %{conn: conn} do
      # The mirror of the case above, and it shipped wrong: load `/feedback` bare, tap a
      # face, and the caption claimed "From the footer" although nobody came from the
      # footer and the URL still said so.
      {:ok, lv, _html} = live(conn, ~p"/feedback")

      html = lv |> form("#feedback-form", entry: %{"mood" => "happy"}) |> render_change()

      assert html =~ "Tap to switch"
      refute html =~ "From the footer"
      refute html =~ "Tap one"
    end

    test "a signed-out sender is told, truthfully, that blank means anonymous",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/feedback?mood=happy")
      assert html =~ "Leave it blank to stay anonymous"
    end

    test "a signed-in sender is not promised an anonymity the write path cannot deliver",
         %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/feedback?mood=happy")

      # `submit/2` is passed `user_id:` unconditionally, so clearing name and email
      # changes nothing about who the queue shows this as.
      refute html =~ "Leave it blank to stay anonymous"
      assert html =~ "signed in, so this arrives under your account"

      submit(lv, %{"mood" => "happy", "message" => "blank name", "name" => "", "email" => ""})

      assert [entry] = Feedback.list_entries()
      assert entry.name == nil
      assert entry.user_id == user.id
      assert Consensus.Feedback.Entry.sender_label(Feedback.get_entry(entry.id)) == user.username
    end
  end

  describe "the screen you were on" do
    test "the row is rendered, names the exact path, and is ticked by default",
         %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/options"]}")

      assert has_element?(lv, "#feedback-context", "/groups/12/options")
      assert has_element?(lv, "#feedback-context input[type=checkbox][checked]")
    end

    # **The row lives inside the pinned action bar, not in the scroll body**, and that is
    # what makes "default-on and honoured" honest rather than a technicality. `Send
    # feedback` is `sticky bottom-0`, so it is reachable without ever scrolling; measured
    # at 420×700 with the row in the frame's own position (last child of the body), its top
    # was at 663.6 in a 700px viewport with everything below 606 behind the opaque bar,
    # and `elementFromPoint` aimed at the label's centre returned the bar. A sender could
    # submit without ever seeing what was ticked — the same lie as a box the app ignores,
    # from the other side. Consent has to be on screen whenever the action is.
    test "the consent row sits inside the pinned bar, beside the button it qualifies",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?#{[return_to: "/groups/12/options"]}")

      assert has_element?(lv, "form > div.sticky #feedback-context")
      assert has_element?(lv, "form > div.sticky button[type=submit]")
    end

    # The other half of the same failure, and the one that is invisible in markup: the bar
    # is opaque and the body reserved no space for it, so wherever the bar was stuck it
    # deleted that much live content with nothing scrollable underneath to recover it.
    # Measured at `scrollY === 0` against the 110px textarea: **16.4px of 110 visible at
    # 360×640**, 40.4 at 390×664, 76.4 at 420×700 — and focusing it did not scroll, because
    # Chrome knows nothing about the overlay, so the caret line stayed occluded while
    # typing. Verified after the fix at 360×640: `documentElement.scrollHeight` 1099 against
    # `innerHeight` 640, and at the bottom of the scroll the textarea is 138 of 138 visible
    # and entirely clear of the bar.
    test "the scroll body reserves the pinned bar's height", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/feedback")

      assert html =~ "pb-[172px]"
    end

    test "the row names the screen in words, not only as a path", %{conn: conn} do
      # From the home page — where the footer's faces are tapped most — the whole
      # evidence used to be the single character `/` floating in a dashed box, which a
      # first-time reader cannot tell from a rendering bug.
      {:ok, home, _html} = live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/"]}")
      assert has_element?(home, "#feedback-context", "Include the screen I was on (Home)")

      {:ok, deep, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/options"]}")

      assert has_element?(deep, "#feedback-context", "Adding options")
      # The label is a description; the path is what actually gets stored, so both show.
      assert has_element?(deep, "#feedback-context", "/groups/12/options")
    end

    test "the label is derived from the path and never reads the database", %{conn: conn} do
      # A group id that does not exist. Resolving the frame's `(Dinner Friday? · voting)`
      # would mean a query on a path any visitor can type, printing a stranger's session
      # title onto a signed-out page; the route name leaks nothing and needs no row.
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/999999/review"]}")

      assert has_element?(lv, "#feedback-context", "Reviewing the pool")
    end

    test "there is no row, and nothing captured, when there was no origin", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=sad")

      refute has_element?(lv, "#feedback-context")

      submit(lv, %{"mood" => "sad", "message" => "typed the URL"})
      assert [entry] = Feedback.list_entries()
      assert entry.page_path == nil
    end

    test "unticking the box really stops the path being stored", %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/options"]}")

      submit(lv, %{
        "mood" => "sad",
        "message" => "left it unticked",
        "include_page" => "false"
      })

      assert [entry] = Feedback.list_entries()
      assert entry.page_path == nil
    end

    test "leaving it ticked stores exactly that path and nothing else", %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/options"]}")

      submit(lv, %{"mood" => "sad", "message" => "left it ticked", "include_page" => "true"})

      assert [entry] = Feedback.list_entries()
      assert entry.page_path == "/groups/12/options"
    end

    test "an off-site return_to is refused, so it can neither be stored nor navigated to",
         %{conn: conn} do
      {:ok, lv, html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "https://elsewhere.example/x"]}")

      refute html =~ "elsewhere.example"
      refute has_element?(lv, "#feedback-context")

      submit(lv, %{"mood" => "sad", "message" => "open redirect attempt"})
      assert [entry] = Feedback.list_entries()
      assert entry.page_path == nil
      assert has_element?(lv, "#feedback-done[href='/']")
    end

    test "a control character between the slashes is refused too", %{conn: conn} do
      # The scheme form above is the easy one. `CurrentPath.safe_return_to/1` rejects a
      # literal `//` prefix, but an ASCII tab *between* the slashes survives it — and the
      # WHATWG URL parser strips tab/LF/CR before resolving, so `/\t/evil.example/x`
      # resolves as `//evil.example/x`, off-site. Stored, that becomes an `href` on
      # /admin/feedback: an off-site link planted by an unauthenticated stranger on a
      # control an administrator is invited to click.
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/\t/evil.example/x"]}")

      # Not `refute html =~ "evil.example"`: the footer hangs the raw parameter off its own
      # links to the other standing pages, and those pages refuse it on arrival by the same
      # guard. What must not exist is a control that *resolves* off-site.
      refute has_element?(lv, "#feedback-context")
      assert has_element?(lv, "#chrome-back[href='/']")

      submit(lv, %{"mood" => "sad", "message" => "tab smuggled in the path"})
      assert [entry] = Feedback.list_entries()
      assert entry.page_path == nil
    end
  end

  describe "after sending" do
    test "the form is replaced by a full-page thank-you, not a flash over the form",
         %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "happy", return_to: "/groups/12/review"]}")

      html = submit(lv, %{"mood" => "happy", "message" => "the share sheet is lovely"})

      # The premise of this whole piece: a flash strip over a screen that still looks
      # like the form reads as "nothing happened".
      refute has_element?(lv, "#feedback-form")
      assert has_element?(lv, "#feedback-sent")
      assert html =~ "Your note is saved."
    end

    test "it says what happened, including whether the screen was included", %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/review"]}")

      html = submit(lv, %{"mood" => "sad", "message" => "stuck"})
      assert html =~ "/groups/12/review"

      {:ok, lv2, _html} = live(conn, ~p"/feedback?mood=sad")
      html2 = submit(lv2, %{"mood" => "sad", "message" => "stuck"})
      assert html2 =~ "No screen was included"
    end

    test "it promises no reply the app cannot deliver", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=sad")
      html = submit(lv, %{"mood" => "sad", "message" => "stuck"})

      assert html =~ "emailed to anyone"
      refute html =~ "We'll get back to you"
    end

    test "the one way onward goes back where the face was tapped", %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/review"]}")

      submit(lv, %{"mood" => "sad", "message" => "stuck"})
      assert has_element?(lv, "#feedback-done[href='/groups/12/review']")
    end

    test "the header's back circle is dropped there, so there is one way back not two",
         %{conn: conn} do
      {:ok, lv, html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/review"]}")

      assert html =~ "chrome-back"

      submit(lv, %{"mood" => "sad", "message" => "stuck"})
      refute has_element?(lv, "#chrome-back")
      assert has_element?(lv, "#feedback-done")
    end

    test "the thank-you survives a reload rather than becoming an empty form again",
         %{conn: conn} do
      {:ok, lv, _html} =
        live(conn, ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/review"]}")

      submit(lv, %{"mood" => "sad", "message" => "stuck"})

      path = assert_patch(lv)
      assert path =~ "sent=1"

      # Reload (or Back after tapping through) used to land on a blank form with no
      # evidence anything had been sent, which is the same "reads as nothing happened"
      # failure this screen exists to remove — one action later.
      {:ok, reloaded, html} = live(conn, path)

      assert has_element?(reloaded, "#feedback-sent")
      refute has_element?(reloaded, "#feedback-form")
      assert has_element?(reloaded, "#feedback-done[href='/groups/12/review']")

      # It cannot honestly name a row it no longer holds, so it says nothing about one —
      # and it does not assert that one exists either. See the cold-visit test below.
      refute html =~ "Your note is saved."
      refute html =~ "Included the screen you were on"
      refute html =~ "No screen was included"
    end

    test "browser Back from the thank-you does not resurrect the filled-in form",
         %{conn: conn} do
      from = ~p"/feedback?#{[mood: "sad", return_to: "/groups/12/review"]}"
      {:ok, lv, _html} = live(conn, from)

      submit(lv, %{"mood" => "sad", "message" => "the very same words"})
      assert_patch(lv)

      # `render_patch/2` is what LiveView runs on a browser popstate. Without
      # `replace: true` the pre-submit URL sat in history underneath the thank-you, so one
      # press of Back restored the form with every word still in the textarea and a live
      # tangerine Send feedback — measured in review as byte-identical duplicate rows 35
      # seconds apart.
      html = render_patch(lv, from)

      refute html =~ "the very same words"
      refute has_element?(lv, "#feedback-form")
      assert has_element?(lv, "#feedback-sent")

      assert [_only_one] = Feedback.list_entries()
    end

    test "a cold visit to ?sent=1 thanks you without claiming a note was stored",
         %{conn: conn} do
      # A bookmark, a typed URL, a restored tab. Indistinguishable from a reload after a
      # real send, so it still renders a thank-you — but "Your note is saved." is a claim
      # about a row, and on this path there is none.
      {:ok, lv, html} = live(conn, ~p"/feedback?sent=1")

      assert has_element?(lv, "#feedback-sent")
      refute html =~ "Your note is saved."
      assert html =~ "Feedback lands with the people building this"

      # And it is not a dead end: the card says the form is one tap away, so the tap is
      # there.
      assert has_element?(lv, "#feedback-again[href='/feedback']")
      assert Feedback.list_entries() == []
    end

    test "a signed-in sender's account is recorded", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=happy")
      submit(lv, %{"mood" => "happy", "message" => "signed in"})

      assert [entry] = Feedback.list_entries()
      assert entry.user_id == user.id
    end
  end

  # D-045. Measured before this landed: 54 characters into WHAT HAPPENED, a tap on the
  # footer's Privacy discarded the draft with no prompt and `history.back()` returned an
  # empty textarea. `show_mood_pair?/2` had only ever closed the mood-pair half of that,
  # and this module's moduledoc over-claimed it as the whole thing.
  describe "the unsaved-draft guard" do
    test "is disarmed on an untouched form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback")

      refute has_element?(lv, "#chrome-back[data-confirm]")
      refute has_element?(lv, "footer a[data-confirm]")
    end

    test "arms once a message is typed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback")

      lv
      |> form("#feedback-form", entry: %{"message" => "the deck ate my vote"})
      |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
      assert has_element?(lv, "footer a[data-confirm]")
    end

    # **The hole this describe block did not cover.** Signed out, `/feedback` renders the
    # `:marketing` header, which carries a `Log in` link — a `navigate`, so it destroys the
    # draft exactly as the `‹` and the footer links do. Measured with 100 characters typed:
    # every escape control on the page carried the prompt except this one, and clicking it
    # then pressing Back returned `#entry_message.value === ""`. Asserted as a **count** so
    # a future control cannot slip in unguarded the way this one did: every anchor and
    # button that leaves this screen, everywhere on it, must carry it.
    test "arms every exit in the chrome, including the marketing header's Log in",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback")

      # Signed out, so the header is `:marketing` and the link is there to begin with.
      assert has_element?(lv, "#chrome-sign-in")
      refute has_element?(lv, "#chrome-sign-in[data-confirm]")

      lv
      |> form("#feedback-form", entry: %{"message" => "the deck ate my vote"})
      |> render_change()

      assert has_element?(lv, "#chrome-sign-in[data-confirm]")

      # Stated as "no unguarded exit" rather than as a list, so a control added to the
      # chrome later fails here instead of shipping the way this one did.
      refute has_element?(lv, "header a:not([data-confirm])")
      refute has_element?(lv, "footer a:not([data-confirm])")
    end

    # A signed-in sender's Name field is seeded from their username by `seed_params/2`, so
    # an untouched form must compare equal to itself rather than looking like typing.
    test "stays disarmed on a signed-in visitor's seeded name", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      {:ok, lv, _html} = live(conn, ~p"/feedback")

      refute has_element?(lv, "#chrome-back[data-confirm]")
    end

    # A mood that arrived in the URL is not typing, and it comes back on its own from the
    # same `?mood=` on the way in.
    test "stays disarmed when the mood came from the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback?mood=sad")

      refute has_element?(lv, "#chrome-back[data-confirm]")
    end

    test "is disarmed again on the thank-you screen, where nothing is at risk", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/feedback")

      submit(lv, %{"mood" => "happy", "message" => "this worked well enough to say so"})

      refute has_element?(lv, "footer a[data-confirm]")
    end
  end
end
