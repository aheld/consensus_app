defmodule ConsensusWeb.GroupLive.NewTest do
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Accounts.Scope
  alias Consensus.Activities
  alias Consensus.Deadlines

  setup :register_and_log_in_user

  describe "new" do
    test "renders three enabled deadline chips plus a disabled Custom chip", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/groups/new")

      assert has_element?(lv, "h1", "plan?")
      assert has_element?(lv, "#group-form", "Custom…")

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

      assert has_element?(
               lv,
               "#group-form button[disabled][title='Coming soon']",
               "Custom…"
             )
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
      raced = %{"group" => %{"title" => "Dinner", "deadline_at" => ""}}

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
      expected_deadline = Deadlines.resolve(:tomorrow, DateTime.utc_now(), 0)

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
      deadline = Deadlines.resolve(:tomorrow, DateTime.utc_now(), 0)
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
