defmodule ConsensusWeb.GroupLive.NewTest do
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Accounts.Scope
  alias Consensus.Activities
  alias Consensus.Deadlines
  alias Consensus.Deadlines.Clock

  setup :register_and_log_in_user

  # `Phoenix.LiveViewTest` sends no connect params, so the LiveView under test builds the
  # UTC clock (`%Clock{zone: nil, offset_minutes: 0}`). Tests that recompute an expected
  # instant have to use the same one.
  defp clock(offset_minutes), do: %Clock{offset_minutes: offset_minutes}

  describe "new" do
    test "renders three deadline chips plus a live Custom chip", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      assert has_element?(lv, "h1", "plan?")
      assert has_element?(lv, "#group-form", "Custom…")

      # The up-front warning that the chips are a *required* choice, not optional
      # filters — added after organizers hit the requirement only as a submit error.
      assert has_element?(
               lv,
               "#group-form p.text-tangerine",
               "Pick when votes close — the session can't run without an end time."
             )

      # The `!` badge beside it is decorative — the sentence is the accessible text, so
      # the badge must stay `aria-hidden` rather than being announced as a bare "!".
      assert has_element?(
               lv,
               "#group-form p.text-tangerine span[aria-hidden='true'].bg-tangerine",
               "!"
             )

      # Every chip carries an explicit `aria-pressed="false"` until it is chosen. This
      # assertion used to read `:not([aria-pressed])` and pass, because `aria-pressed={@selected}`
      # in HEEx renders a bare boolean attribute — `aria-pressed=""` when true, omitted when
      # false — and ARIA treats an empty value as unset. So the test was pinning the bug:
      # a screen-reader user got no pressed state from the selected chip *or* the others.
      # `ConsensusWeb.Sticker.chip/1` now stringifies it; this asserts the real contract.
      for key <- ~w(this_evening tomorrow next_thursday) do
        assert has_element?(
                 lv,
                 "#group-form button[phx-value-key='#{key}'][aria-pressed='false']"
               )
      end

      # Live since D-055. It shipped `disabled` with a `title="Coming soon"` and this
      # assertion pinned it that way; the picker is real now, so the pin inverts.
      assert has_element?(lv, "#group-form button[phx-click='toggle_custom']", "Custom…")
      refute has_element?(lv, "#group-form button[disabled][title='Coming soon']")
    end

    test "the custom picker is closed until the Custom chip is pressed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      refute has_element?(lv, "#custom-deadline-input")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()
      assert has_element?(lv, "#custom-deadline-input")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()
      refute has_element?(lv, "#custom-deadline-input")
    end

    # Invariant 18: iOS Safari zooms the page when a focused field computes under 16px and
    # never zooms back out. `text-base` is 16px; anything smaller here is a layout break on
    # the one platform this product is designed for, and a date field is the worst place
    # for it because the native picker opens over a page that has just jumped.
    test "the custom picker's field is at least 16px", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      html =
        lv |> element("button[phx-click='toggle_custom']") |> render_click()

      assert html =~ ~r/id="custom-deadline-input"[^>]*class="[^"]*\btext-base\b/s
    end

    test "a custom date and time is converted and saved", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()

      wall_clock =
        DateTime.utc_now()
        |> DateTime.add(9, :day)
        |> DateTime.truncate(:second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()
        |> String.slice(0, 16)

      lv
      |> form("#group-form", %{
        "group" => %{"title" => "Custom night"},
        "custom_deadline" => wall_clock
      })
      |> render_submit()

      assert [group] = Activities.list_groups(scope)
      assert group.title == "Custom night"

      # The test client sends no connect params, so the LiveView is on the UTC clock and
      # the wall clock above is read back verbatim.
      assert group.deadline_at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() =~ wall_clock
    end

    test "a custom deadline in the past is refused by the changeset, not the widget", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()

      # A `min` attribute is a client-side hint; the event can be pushed regardless, which
      # is why the refusal has to live in `Group.changeset/2` (D-055). This posts exactly
      # what a bypassed widget would.
      past =
        DateTime.utc_now()
        |> DateTime.add(-2, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()
        |> String.slice(0, 16)

      html =
        lv
        |> form("#group-form", %{
          "group" => %{"title" => "Yesterday"},
          "custom_deadline" => past
        })
        |> render_submit()

      assert html =~ "must be in the future"
      assert Activities.list_groups(scope) == []
    end

    test "a custom deadline more than a year out is refused", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()

      far =
        DateTime.utc_now()
        |> DateTime.add(400, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()
        |> String.slice(0, 16)

      html =
        lv
        |> form("#group-form", %{
          "group" => %{"title" => "Mistyped year"},
          "custom_deadline" => far
        })
        |> render_submit()

      assert html =~ "must be within a year"
      assert Activities.list_groups(scope) == []
    end

    test "an unparseable custom value leaves the picker showing what was typed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()

      html =
        lv
        |> form("#group-form", %{
          "group" => %{"title" => "Nonsense"},
          "custom_deadline" => "not-a-date"
        })
        |> render_change()

      # Kept on screen rather than silently discarded, so the organizer can see and fix it.
      assert html =~ ~s(value="not-a-date")
    end

    # The premise D-055 deleted: a blank `deadline_at` used to mean "the patch was lost"
    # unconditionally, because the chips were the only writers. Clearing the picker is a
    # blank that genuinely means "cleared", and it must not be restored from `@selected_at`.
    test "clearing the custom picker clears the deadline instead of restoring it", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()

      wall_clock =
        DateTime.utc_now()
        |> DateTime.add(9, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()
        |> String.slice(0, 16)

      lv
      |> form("#group-form", %{
        "group" => %{"title" => "Cleared"},
        "custom_deadline" => wall_clock
      })
      |> render_change()

      html =
        lv
        |> form("#group-form", %{
          "group" => %{"title" => "Cleared"},
          "custom_deadline" => ""
        })
        |> render_submit()

      assert html =~ "Pick when voting closes"
      assert Activities.list_groups(scope) == []
    end

    # The other half of the same rule: pressing a chip abandons the picker's value, and a
    # later `phx-change` (a keystroke in the title) must not resurrect it.
    test "pressing a chip after typing a custom value keeps the chip", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("button[phx-click='toggle_custom']") |> render_click()

      custom =
        DateTime.utc_now()
        |> DateTime.add(9, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()
        |> String.slice(0, 16)

      lv
      |> form("#group-form", %{
        "group" => %{"title" => "Chip wins"},
        "custom_deadline" => custom
      })
      |> render_change()

      lv |> element("button[phx-value-key='tomorrow']") |> render_click()

      # The browser re-renders the now-empty input and sends `""` with the next keystroke.
      lv
      |> form("#group-form", %{
        "group" => %{"title" => "Chip wins!"},
        "custom_deadline" => ""
      })
      |> render_submit()

      assert [group] = Activities.list_groups(scope)
      assert group.deadline_at == Deadlines.resolve(:tomorrow, DateTime.utc_now(), clock(0))
    end

    # The chips write `deadline_at` into a hidden input by patching the DOM from the server.
    # A change event that left the browser before that patch arrived carried the still-empty
    # hidden field, and the server took it over the selection it had just made — chip picked,
    # then title typed in the same tick, and the deadline was silently gone. Both events here
    # send `deadline_at: ""`, which is exactly the payload the browser sent in the race.
    test "a change event that races the chip's DOM patch does not wipe the deadline", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("#group-form button[phx-value-key='tomorrow']") |> render_click()

      # Pushed raw rather than through `form/3`: `form/3` refuses to send a hidden input a
      # value that is not in the rendered DOM, which is precisely the state the race puts the
      # browser in, so the harness cannot express it any other way.
      raced = %{"group" => %{"title" => "Dinner"}}

      render_change(lv, "validate", raced)

      assert has_element?(
               lv,
               "#group-form button[phx-value-key='tomorrow'][aria-pressed='true']"
             )

      render_submit(lv, "save", raced)

      assert [%{title: "Dinner", deadline_at: %DateTime{}}] = Activities.list_groups(scope)
    end

    test "submitting without a title shows an error and creates nothing", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("#group-form button[phx-value-key='tomorrow']") |> render_click()

      html =
        lv
        |> form("#group-form", group: %{title: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Activities.list_groups(scope) == []
    end

    test "submitting without a deadline shows an error and creates nothing", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      html =
        lv
        |> form("#group-form", group: %{title: "Dinner Friday?"})
        |> render_submit()

      assert html =~ "Pick when voting closes"
      assert Activities.list_groups(scope) == []
    end

    test "selecting a chip and submitting creates a draft and redirects to the options step",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> element("#group-form button[phx-value-key='tomorrow']") |> render_click()
      expected_deadline = Deadlines.resolve(:tomorrow, DateTime.utc_now(), clock(0))

      form = form(lv, "#group-form", group: %{title: "Dinner Friday?"})

      assert {:ok, _new_lv, _html} =
               form
               |> render_submit()
               |> follow_redirect(conn)

      assert [group] = Activities.list_groups(scope)
      assert group.title == "Dinner Friday?"
      assert group.status == :draft
      assert_in_delta DateTime.diff(group.deadline_at, expected_deadline, :second), 0, 5
    end

    test "a signed-out visitor is redirected to log in", %{} do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/groups/new")
      assert to == ~p"/users/log-in"
    end
  end

  describe "edit" do
    test "repopulates the title and pre-selects the matching chip", %{
      conn: conn,
      scope: scope
    } do
      deadline = Deadlines.resolve(:tomorrow, DateTime.utc_now(), clock(0))
      group = group_fixture(scope, title: "Old title", deadline_at: deadline)

      {:ok, lv, html} = live(conn, ~p"/groups/#{group.id}/edit")

      assert html =~ "Old title"
      assert has_element?(lv, "#group-form input[name='group[title]'][value='Old title']")

      assert has_element?(
               lv,
               "#group-form button[phx-value-key='tomorrow'][aria-pressed='true']"
             )
    end

    test "a stale stored deadline shows as a fourth, selected chip", %{conn: conn, scope: scope} do
      stale_deadline = DateTime.add(DateTime.utc_now(), 200, :day)
      group = group_fixture(scope, deadline_at: stale_deadline)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/edit")

      assert has_element?(
               lv,
               "#group-form button[phx-value-key='stored'][aria-pressed='true']"
             )
    end

    test "updating the title and deadline redirects to the options step", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope, title: "Old title")

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/edit")

      lv |> element("#group-form button[phx-value-key='next_thursday']") |> render_click()

      form = form(lv, "#group-form", group: %{title: "New title"})

      assert {:ok, _new_lv, _html} =
               form
               |> render_submit()
               |> follow_redirect(conn)

      updated = Activities.get_group!(scope, group.id)
      assert updated.title == "New title"
      assert updated.deadline_at != nil
    end

    test "another user's group redirects instead of crashing", %{conn: conn} do
      other_scope = Scope.for_user(user_fixture())
      other_group = group_fixture(other_scope)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/groups/#{other_group.id}/edit")

      assert to == ~p"/"
    end

    test "a non-numeric id redirects instead of crashing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/groups/not-a-real-id/edit")
      assert to == ~p"/"
    end
  end

  # D-045 — measured before this landed: typing a title, tapping the footer's About us and
  # pressing back returned an empty field.
  describe "the unsaved-draft guard" do
    test "is disarmed on an untouched form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      refute has_element?(lv, "#chrome-back[data-confirm]")
      refute has_element?(lv, "footer a[data-confirm]")
    end

    test "arms once a title is typed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      lv |> form("#group-form", group: %{"title" => "Dinner Friday?"}) |> render_change()

      assert has_element?(lv, "#chrome-back[data-confirm]")
      assert has_element?(lv, "footer a[data-confirm]")
    end

    test "arms once a deadline chip is picked, even with no title", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      render_click(lv, "select_deadline", %{"key" => "tomorrow"})

      assert has_element?(lv, "#chrome-back[data-confirm]")
    end

    # On `:edit` the form arrives pre-filled, so "non-empty" would arm the prompt on a
    # form nobody has touched. The comparison is against what is stored.
    test "is disarmed on an untouched edit form", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{title: "Already saved", deadline_at: future_deadline()})

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/edit")

      refute has_element?(lv, "#chrome-back[data-confirm]")
    end
  end
end
