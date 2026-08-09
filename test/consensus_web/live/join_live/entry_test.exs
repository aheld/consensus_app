defmodule ConsensusWeb.JoinLive.EntryTest do
  # Nothing here issues DDL — safe under `max_cases: 1` (D-033), the point is sandbox
  # isolation, not concurrency (same reasoning as `join_auth_test.exs`).
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import Consensus.AccountsFixtures
  import Consensus.VotingFixtures

  alias Consensus.Voting
  alias ConsensusWeb.JoinAuth

  # Mirrors `ConsensusWeb.JoinLive.BallotTest`'s own private helper — each `/join` test
  # file builds its own rather than sharing one, which is the existing convention.
  defp join_conn(conn, group, participant) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)
  end

  describe "mount — nobody has joined yet" do
    setup do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope, 3)
      %{group: group, organizer: scope.user}
    end

    test "renders the invite pill, title, the three stat pills and the name form", %{
      conn: conn,
      group: group,
      organizer: organizer
    } do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}")

      assert html =~ "#{organizer.username} invited you"
      assert html =~ group.title
      assert html =~ "3 spots"
      # Derived from the pool, not a literal. It used to be a hardcoded `~10 sec` sitting
      # in a row of two computed pills, identical for a 3-option pool and a 30-option one.
      # Frame `1a-8` prints `5 SPOTS` beside `~10 SEC`, i.e. two seconds an option; three
      # options rounds to 5.
      assert html =~ "~5 sec"
      refute html =~ "10 sec"
      assert html =~ "Your first name"
      assert html =~ "skip"
      assert html =~ "Start voting"
      assert html =~ "No app"
      assert html =~ "no account"
      assert html =~ "no password"
    end

    # The point of deriving it: a bigger pool has to say a bigger number, or it is the same
    # unbacked claim it was before, just written as a function.
    test "the effort pill scales with the pool", %{conn: conn} do
      scope = user_scope_fixture()
      {big, _activities} = voting_group_fixture(scope, 9)

      {:ok, _view, html} = live(conn, ~p"/join/#{big.slug}")

      assert html =~ "9 spots"
      assert html =~ "~20 sec"
    end

    test "omits the voted-friends row when nobody has voted", %{conn: conn, group: group} do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}")

      refute html =~ "already voted"
    end

    test "a signed-out visitor gets no 'continue as' affordance", %{conn: conn, group: group} do
      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}")

      refute html =~ "Continue as"
    end

    test "a signed-in visitor gets a one-line 'continue as' affordance", %{group: group} do
      voter = user_fixture()
      conn = Phoenix.ConnTest.build_conn() |> log_in_user(voter)

      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}")

      assert html =~ "Continue as #{voter.username}"
      # Never required — the guest path is still fully usable.
      assert html =~ "Start voting"
    end
  end

  describe "mount — some friends have already voted" do
    test "shows the count and caption, with an overflow bubble past two avatars", %{conn: conn} do
      scope = user_scope_fixture()
      {group, activities} = voting_group_fixture(scope, 2)

      for _ <- 1..3 do
        participant = participant_fixture(group)
        {:ok, _participant} = Voting.cast_ballot(participant, [hd(activities).id])
      end

      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}")

      assert html =~ "3 friends already voted"
      assert html =~ "+1"
    end

    test "one voter reads as singular, with no overflow bubble", %{conn: conn} do
      scope = user_scope_fixture()
      {group, activities} = voting_group_fixture(scope, 1)
      participant = participant_fixture(group)
      {:ok, _participant} = Voting.cast_ballot(participant, [hd(activities).id])

      {:ok, _view, html} = live(conn, ~p"/join/#{group.slug}")

      assert html =~ "1 friend already voted"
      refute html =~ "+1"
    end
  end

  describe "the live character counter (CLAUDE.md invariant 11)" do
    test "has no maxlength attribute and updates as the visitor types", %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      {:ok, view, html} = live(conn, ~p"/join/#{group.slug}")

      refute html =~ "maxlength"
      assert html =~ "0/40"

      html = render_change(view, "validate_name", %{"display_name" => "Ada"})

      assert html =~ "3/40"
    end
  end

  describe "the primary path — a real POST, not a LiveView event" do
    test "typing a name and submitting creates a named guest and lands on the ballot", %{
      conn: conn
    } do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      {:ok, lv, _html} = live(conn, ~p"/join/#{group.slug}")

      form = form(lv, "#join-form", %{"display_name" => "Ada"})
      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      participant = Voting.get_participant_by_token(token)
      assert participant.display_name == "Ada"
      assert participant.kind == :guest
    end

    test "submitting with a blank name joins anonymously", %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      {:ok, lv, _html} = live(conn, ~p"/join/#{group.slug}")

      form = form(lv, "#join-form")
      conn = submit_form(form, conn)

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      assert Voting.get_participant_by_token(token).display_name == nil
    end
  end

  describe "skip →" do
    test "ignores whatever was typed and joins anonymously as a guest", %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      {:ok, lv, _html} = live(conn, ~p"/join/#{group.slug}")

      # Type something, then press skip instead of "Start voting" — skip must win.
      render_change(lv, "validate_name", %{"display_name" => "Ada"})
      render_click(lv, "skip")

      # Same convention `ConsensusWeb.UserLive.LoginTest` uses for its own
      # `phx-trigger-action` form: `submit_form/2` posts whatever the form's DOM
      # currently holds to its `action`, which is what actually proves "skip" rewrote
      # the field server-side before any real submission happened.
      form = form(lv, "#join-form")
      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      participant = Voting.get_participant_by_token(token)
      assert participant.display_name == nil
      assert participant.kind == :guest
    end

    # `skip →` starts 8px from the right edge of the `<label>` wrapping `#display_name`
    # (measured at 360×640: label ends x=264.4, the control starts x=272.4) and one tap on
    # it posts the join, mints the anonymous participant and navigates to the ballot — after
    # which `mount/3` bounces this screen straight to the ballot, so there is no way back to
    # retype the name. Armed only once there is something to lose, the shape
    # `JoinLive.Ballot.leave_confirm/2` uses.
    test "asks first once a name has been typed, and not before", %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      {:ok, lv, _html} = live(conn, ~p"/join/#{group.slug}")

      assert has_element?(lv, "button[phx-click='skip']")
      refute has_element?(lv, "button[phx-click='skip'][data-confirm]")

      # Whitespace is normalised to `nil` by `create_participant/2` anyway, so it is not a
      # typed name and must not raise a dialog.
      render_change(lv, "validate_name", %{"display_name" => "   "})
      refute has_element?(lv, "button[phx-click='skip'][data-confirm]")

      render_change(lv, "validate_name", %{"display_name" => "Ada"})
      assert has_element?(lv, "button[phx-click='skip'][data-confirm]")
    end
  end

  describe "'Continue as <username>' — joining as the signed-in account" do
    test "joins with kind: :user tied to the account, ignoring any typed name", %{conn: _conn} do
      voter = user_fixture()
      conn = Phoenix.ConnTest.build_conn() |> log_in_user(voter)
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      {:ok, lv, _html} = live(conn, ~p"/join/#{group.slug}")

      render_change(lv, "validate_name", %{"display_name" => "Someone else"})
      render_click(lv, "join_as_user")

      form = form(lv, "#join-form")
      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      participant = Voting.get_participant_by_token(token)
      assert participant.kind == :user
      assert participant.user_id == voter.id
    end
  end

  describe "mount — the ballot is already locked (D-036)" do
    test "a participant with voted_at set is sent to results, not shown the form again", %{
      conn: conn
    } do
      {group, activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [hd(activities).id])

      conn = join_conn(conn, group, participant)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/join/#{group.slug}")
      assert to == ~p"/join/#{group.slug}/results"
    end
  end

  describe "mount — already joined, not yet voted" do
    test "is sent straight to the ballot rather than re-shown the entry form", %{conn: conn} do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group, %{display_name: "Ada"})

      conn = join_conn(conn, group, participant)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/join/#{group.slug}")
      assert to == ~p"/join/#{group.slug}/vote"
    end
  end
end
