defmodule ConsensusWeb.GroupLive.ReviewTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

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

    # A destructive, irreversible control rendered as 97.8×18px of plain 12px text whose
    # only distinguishing style was `hover:`, which does not exist on touch. Same remedy
    # the `/admin/users` Delete button got.
    test "the control is a 44px target that acknowledges a tap", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      html = lv |> element(~s|button[phx-click="cancel"]|) |> render()

      assert html =~ "min-h-[44px]"
      assert html =~ "active:text-tangerine"
      assert html =~ "underline"
    end

    # `Consensus.Voting` publishes on the same `"activity_group:<id>"` topic this screen
    # subscribes to, and this LiveView had no clause for its two messages — so an organizer
    # sitting on the review screen of a live group crashed the moment anybody joined.
    test "a participant joining does not crash the organizer's open review screen",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      participant = participant_fixture(group)
      {:ok, _participant} = Consensus.Voting.cast_ballot(participant, [a.id])

      _ = :sys.get_state(lv.pid)
      assert render(lv) =~ "1 person has already voted"
    end

    # `/admin/users`' Delete confirm enumerates its whole cascade. This one said only
    # "This cannot be undone" while discarding strangers' ballots.
    test "the confirm names the ballots it discards, and only when there are any",
         %{conn: conn, scope: scope} do
      {group, [a, _b]} = voting_group_fixture(scope, 2)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")
      html = lv |> element(~s|button[phx-click="cancel"]|) |> render()
      assert html =~ "This cannot be undone."
      refute html =~ "already voted"

      participant = participant_fixture(group)
      {:ok, _participant} = Consensus.Voting.cast_ballot(participant, [a.id])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")
      html = lv |> element(~s|button[phx-click="cancel"]|) |> render()
      assert html =~ "1 person has already voted"
      assert html =~ "their ballot is discarded"
    end
  end

  # D-045. The warning named the wrong trigger: "Once you share this…" says the lock
  # happens when the link is sent, and it does not — `handle_event("publish", ...)` flips
  # the group to `:voting` the instant the button 12px below it is pressed, and D-037
  # freezes the pool on that status change, before any link has left the screen.
  describe "the pre-publish warning" do
    test "names the button press, not the sharing, and says the deadline closes itself",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/review")

      assert html =~ "Tapping this opens voting"
      assert html =~ "the options lock now"
      refute html =~ "Once you share this"

      # Product invariant 3, said out loud at the moment it becomes binding.
      assert html =~ "closes itself at the deadline"
    end

    test "is dropped once the group is live — there is nothing left to lock",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      activity_fixture(group)
      {:ok, group} = Activities.publish_group(scope, group)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/review")

      refute html =~ "Tapping this opens voting"
    end
  end

  # Measured at 360×640 before this landed: ▲/▼ hit boxes of 8×11.5 and 8×13 with a 2.0px
  # gap between them, and a 16×24 remove ✕ with `data-confirm` null — the smaller,
  # harder-to-hit copy of the same destructive action `/groups/:id/options` renders at
  # 28×36 *with* a confirmation, on the screen immediately before publishing.
  describe "touch targets on the pool rows" do
    setup %{scope: scope} do
      group = group_fixture(scope, %{deadline_at: future_deadline()})
      a = activity_fixture(group, %{name: "Kismet"})
      activity_fixture(group, %{name: "Superiority Burger"})
      %{group: group, activity: a}
    end

    test "the reorder buttons are 44px boxes", %{conn: conn, group: group, activity: a} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      up = lv |> element(~s(button[aria-label="Move #{a.name} up"])) |> render()
      down = lv |> element(~s(button[aria-label="Move #{a.name} down"])) |> render()

      assert up =~ "size-11"
      assert down =~ "size-11"
    end

    # Side by side, the 44px pair took 92px out of a 360px row and left the option name at
    # 120px — narrower than "Superiority Burger" (123px at the row's own 700/14px), so
    # ordinary names ellipsised on the last screen before an irreversible publish. Stacked
    # in one 44px column the name gets ~172px back and the row grows vertically instead.
    test "the reorder pair stacks into one column rather than eating the name",
         %{conn: conn, group: group} do
      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/review")

      assert html =~ "flex shrink-0 flex-col items-center gap-1"
      refute html =~ "flex shrink-0 items-center gap-1\""
    end

    test "the remove ✕ confirms, and matches the wording used on the options screen",
         %{conn: conn, group: group, activity: a} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group}/review")

      html = lv |> element(~s(button[aria-label="Remove #{a.name}"])) |> render()

      assert html =~ "Remove #{a.name} from the pool?"
      # The pseudo-element hit area, so the glyph keeps painting at 16px.
      assert html =~ "before:-inset-[14px]"
    end

    # `Sortable` binds HTML5 drag events only and no mobile browser fires those from a
    # finger, so "Drag to reorder" was an unfollowable instruction on the device this app
    # is designed for.
    test "the subhead leads with the buttons that work everywhere", %{conn: conn, group: group} do
      {:ok, _lv, html} = live(conn, ~p"/groups/#{group}/review")

      assert html =~ "Tap ▲▼ to reorder"
      refute html =~ "Drag to reorder."
    end
  end
end
