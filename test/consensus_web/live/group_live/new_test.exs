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
end
