defmodule ConsensusWeb.GroupLive.ReviewTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities

  setup :register_and_log_in_user

  defp index_of(html, text) do
    {pos, _len} = :binary.match(html, text)
    pos
  end

  defp positions(scope, group_id) do
    scope |> Activities.get_group!(group_id) |> Map.fetch!(:activities) |> Enum.map(& &1.id)
  end

  describe "rendering the pool" do
    test "renders the pool in stored order", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity_fixture(group, %{name: "Alpha"})
      activity_fixture(group, %{name: "Bravo"})
      activity_fixture(group, %{name: "Charlie"})

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/review")

      assert html =~ "Your pool"
      assert index_of(html, "Alpha") < index_of(html, "Bravo")
      assert index_of(html, "Bravo") < index_of(html, "Charlie")
    end

    test "a :voting group still renders — the organizer can come back to it", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/review")
      assert html =~ "Your pool"
    end

    test "raises for another user's group", %{conn: conn} do
      owner_scope = user_scope_fixture()
      group = group_fixture(owner_scope)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/groups/#{group}/review")
      end
    end
  end

  describe "reordering" do
    test "a drag reorder persists the new order", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      a = activity_fixture(group, %{name: "Alpha"})
      b = activity_fixture(group, %{name: "Bravo"})

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      html = render_hook(lv, "reorder", %{"ids" => [to_string(b.id), to_string(a.id)]})

      assert index_of(html, "Bravo") < index_of(html, "Alpha")
      assert positions(scope, group.id) == [b.id, a.id]
    end

    test "a bogus id list is rejected without corrupting the stored order", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope)
      a = activity_fixture(group, %{name: "Alpha"})
      b = activity_fixture(group, %{name: "Bravo"})

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      # The hook already reordered the DOM optimistically to [Bravo, Alpha] before this
      # push arrives; a foreign id in the list must be refused and the re-render must
      # snap the DOM back to what is actually stored, [Alpha, Bravo].
      html = render_hook(lv, "reorder", %{"ids" => [to_string(b.id), "999999"]})

      assert index_of(html, "Alpha") < index_of(html, "Bravo")
      assert positions(scope, group.id) == [a.id, b.id]
    end

    test "the ↑/↓ buttons move a row", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      a = activity_fixture(group, %{name: "Alpha"})
      b = activity_fixture(group, %{name: "Bravo"})

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      lv
      |> element(~s|button[phx-click="move_down"][phx-value-id="#{a.id}"]|)
      |> render_click()

      assert positions(scope, group.id) == [b.id, a.id]

      lv
      |> element(~s|button[phx-click="move_up"][phx-value-id="#{a.id}"]|)
      |> render_click()

      assert positions(scope, group.id) == [a.id, b.id]
    end
  end

  describe "anonymous voting" do
    # D-035: MVP voting is unconditionally anonymous, so this card states the rule
    # instead of offering a switch. A toggle here promised attribution that
    # `Consensus.Voting.tally/1` is structurally incapable of producing.
    test "is stated as a rule, not offered as a toggle", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      {:ok, lv, html} = live(conn, ~p"/groups/#{group}/review")

      assert html =~ "Anonymous voting"
      assert html =~ "ALWAYS ON"
      refute html =~ ~s|phx-click="toggle_anonymous"|
      assert lv |> element(~s|button[role="switch"]|) |> has_element?() == false
    end
  end

  describe "publishing" do
    test "an empty pool flashes and does not publish", %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      html = lv |> element(~s|button[phx-click="publish"]|) |> render_click()

      assert html =~ "Add at least one option first."
      assert Activities.get_group!(scope, group.id).status == :draft
    end

    test "no deadline flashes and does not publish", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity_fixture(group)
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      html = lv |> element(~s|button[phx-click="publish"]|) |> render_click()

      assert html =~ "Pick when voting closes first."
      assert Activities.get_group!(scope, group.id).status == :draft
    end

    test "publishing with options moves the group to :voting and redirects to share", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      lv |> element(~s|button[phx-click="publish"]|) |> render_click()

      assert_redirect(lv, ~p"/groups/#{group}/share")
      assert Activities.get_group!(scope, group.id).status == :voting
    end

    test "publishing an already-published group just navigates on", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")
      lv |> element(~s|button[phx-click="publish"]|) |> render_click()

      assert_redirect(lv, ~p"/groups/#{group}/share")
    end
  end

  describe "cancelling" do
    test "sets the group to :cancelled and returns home", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      lv |> element(~s|button[phx-click="cancel"]|) |> render_click()

      assert_redirect(lv, ~p"/")
      assert Activities.get_group!(scope, group.id).status == :cancelled
    end
  end
end
