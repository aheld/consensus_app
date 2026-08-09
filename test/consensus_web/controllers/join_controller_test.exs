defmodule ConsensusWeb.JoinControllerTest do
  use ConsensusWeb.ConnCase

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting
  alias ConsensusWeb.JoinAuth

  describe "POST /join/:slug/enter — an unknown slug" do
    test "redirects home with a flash and creates nothing", %{conn: conn} do
      conn = post(conn, ~p"/join/does-not-exist/enter", %{})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "doesn't look right"
    end
  end

  describe "POST /join/:slug/enter — a :draft group" do
    test "refuses, redirects home, and mints no participant", %{conn: conn} do
      group = group_fixture(user_scope_fixture())

      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => "Ada"})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't open yet"
      assert Voting.count_participants(group) == 0
    end
  end

  describe "POST /join/:slug/enter — a finished group" do
    test "a completed group redirects straight to results and mints nothing", %{conn: conn} do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.complete_group(scope, group)

      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => "Ada"})

      assert redirected_to(conn) == ~p"/join/#{group.slug}/results"
      assert Voting.count_participants(group) == 0
    end

    test "a cancelled group behaves the same way", %{conn: conn} do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.cancel_group(scope, group)

      conn = post(conn, ~p"/join/#{group.slug}/enter", %{})

      assert redirected_to(conn) == ~p"/join/#{group.slug}/results"
    end
  end

  describe "POST /join/:slug/enter — a guest joining an open group" do
    setup do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      %{group: group}
    end

    test "a named guest is created, keyed into the session by group, and sent to the ballot",
         %{conn: conn, group: group} do
      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => "Ada"})

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      assert is_binary(token)

      participant = Voting.get_participant_by_token(token)
      assert participant.group_id == group.id
      assert participant.display_name == "Ada"
      assert participant.kind == :guest
      assert participant.user_id == nil
    end

    test "a name over the length cap names the field and the limit instead of a generic flash, and mints nothing",
         %{conn: conn, group: group} do
      too_long =
        String.duplicate("a", Consensus.Voting.Participant.max_display_name_length() + 20)

      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => too_long})

      assert redirected_to(conn) == ~p"/join/#{group.slug}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "too long"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "#{Consensus.Voting.Participant.max_display_name_length()} characters max"

      assert Voting.count_participants(group) == 0
    end

    test "a blank name joins anonymously — the same as the 'skip' affordance",
         %{conn: conn, group: group} do
      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => "   "})

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      participant = Voting.get_participant_by_token(token)
      assert participant.display_name == nil
      assert participant.kind == :guest
    end

    test "no display_name param at all also joins anonymously", %{conn: conn, group: group} do
      conn = post(conn, ~p"/join/#{group.slug}/enter", %{})

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      assert Voting.get_participant_by_token(token).display_name == nil
    end

    test "a signed-out visitor cannot spoof kind=user into an account-bound participant",
         %{conn: conn, group: group} do
      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"kind" => "user", "display_name" => "x"})

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      participant = Voting.get_participant_by_token(token)
      assert participant.kind == :guest
      assert participant.user_id == nil
    end

    test "a second POST from the same browser session resumes the same guest participant instead of duplicating it",
         %{conn: conn, group: group} do
      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"display_name" => "Zoe"})
      first_token = get_session(conn, JoinAuth.participant_session_key(group.id))

      # Simulate the same browser resubmitting — a double-click, or a back-then-resubmit
      # on the plain browser `<form>` `06` posts through. `recycle/1` carries the cookies
      # (and therefore the session) from the first response into the second request, the
      # same way `Phoenix.ConnTest` models a real browser's second request.
      conn =
        conn
        |> recycle()
        |> post(~p"/join/#{group.slug}/enter", %{"display_name" => "Zoe"})

      second_token = get_session(conn, JoinAuth.participant_session_key(group.id))

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"
      assert first_token == second_token
      assert Voting.count_participants(group) == 1
    end
  end

  describe "POST /join/:slug/enter — joining as a signed-in account" do
    setup %{conn: conn} do
      voter = user_fixture()
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      %{conn: log_in_user(conn, voter), group: group, voter: voter}
    end

    test "creates a user-kind participant tied to the account", %{
      conn: conn,
      group: group,
      voter: voter
    } do
      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"kind" => "user"})

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"

      token = get_session(conn, JoinAuth.participant_session_key(group.id))
      participant = Voting.get_participant_by_token(token)
      assert participant.kind == :user
      assert participant.user_id == voter.id
    end

    test "joining a second time resumes the same participant instead of duplicating", %{
      conn: conn,
      group: group
    } do
      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"kind" => "user"})
      first_token = get_session(conn, JoinAuth.participant_session_key(group.id))

      conn = post(conn, ~p"/join/#{group.slug}/enter", %{"kind" => "user"})
      second_token = get_session(conn, JoinAuth.participant_session_key(group.id))

      assert redirected_to(conn) == ~p"/join/#{group.slug}/vote"
      assert first_token == second_token
      assert Voting.count_participants(group) == 1
    end
  end

  describe "POST /join/:slug/enter — the session is keyed by group" do
    test "joining two different groups in one browser session keeps two distinct tokens",
         %{conn: conn} do
      scope = user_scope_fixture()
      {group_a, _} = voting_group_fixture(scope)
      {group_b, _} = voting_group_fixture(scope)

      conn = post(conn, ~p"/join/#{group_a.slug}/enter", %{"display_name" => "A"})
      conn = post(conn, ~p"/join/#{group_b.slug}/enter", %{"display_name" => "B"})

      token_a = get_session(conn, JoinAuth.participant_session_key(group_a.id))
      token_b = get_session(conn, JoinAuth.participant_session_key(group_b.id))

      assert is_binary(token_a)
      assert is_binary(token_b)
      assert token_a != token_b
      assert Voting.get_participant_by_token(token_a).display_name == "A"
      assert Voting.get_participant_by_token(token_b).display_name == "B"
    end
  end
end
