defmodule ConsensusWeb.JoinAuthTest do
  # Nothing here issues DDL, so async is safe even under `max_cases: 1` (D-033) —
  # sandbox isolation is the point, not concurrency.
  use Consensus.DataCase, async: true

  alias Phoenix.LiveView

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting
  alias ConsensusWeb.JoinAuth

  describe "participant_session_key/1" do
    test "is keyed by group id, so two groups never collide" do
      assert JoinAuth.participant_session_key(42) == "participant_token:42"
      assert JoinAuth.participant_session_key(1) != JoinAuth.participant_session_key(2)
    end
  end

  describe "on_mount :resolve_participant — an open (:voting) group" do
    test "assigns the group and a nil participant when nobody has joined yet" do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      assert {:cont, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group.slug},
                 %{},
                 %LiveView.Socket{view: ConsensusWeb.JoinLive.Entry}
               )

      assert socket.assigns.group.id == group.id
      assert socket.assigns.participant == nil
    end

    test "resolves the session's participant token (keyed by group id) into @participant" do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group, %{display_name: "Ada"})
      session = %{JoinAuth.participant_session_key(group.id) => participant.token}

      assert {:cont, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group.slug},
                 session,
                 %LiveView.Socket{view: ConsensusWeb.JoinLive.Ballot}
               )

      assert socket.assigns.participant.id == participant.id
    end

    test "ignores a token that belongs to a different group" do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      {other_group, _activities} = voting_group_fixture(user_scope_fixture())
      other_participant = participant_fixture(other_group)

      # Deliberately stored under group's own key but pointing at another group's
      # participant row — this must never happen via the real controller, but the
      # on_mount hook re-checks `participant.group_id == group.id` regardless (the same
      # "don't trust it, re-check" idiom `Voting.get_participant_by_token/1`'s docs call
      # for), so it is refused rather than trusted.
      session = %{JoinAuth.participant_session_key(group.id) => other_participant.token}

      assert {:cont, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group.slug},
                 session,
                 %LiveView.Socket{view: ConsensusWeb.JoinLive.Ballot}
               )

      assert socket.assigns.participant == nil
    end

    test "ignores an unknown token instead of raising" do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      session = %{JoinAuth.participant_session_key(group.id) => "not-a-real-token"}

      assert {:cont, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group.slug},
                 session,
                 %LiveView.Socket{view: ConsensusWeb.JoinLive.Ballot}
               )

      assert socket.assigns.participant == nil
    end

    test "a token stored under a different group's session key is not found for this group" do
      {group_a, _activities} = voting_group_fixture(user_scope_fixture())
      {group_b, _activities} = voting_group_fixture(user_scope_fixture())
      participant_a = participant_fixture(group_a)

      # The session carries group_a's key/token only — group_b's mount must not see it.
      session = %{JoinAuth.participant_session_key(group_a.id) => participant_a.token}

      assert {:cont, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group_b.slug},
                 session,
                 %LiveView.Socket{view: ConsensusWeb.JoinLive.Ballot}
               )

      assert socket.assigns.participant == nil
    end
  end

  describe "on_mount :resolve_participant — an unknown slug" do
    test "halts and sends the visitor home with a flash" do
      assert {:halt, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => "does-not-exist"},
                 %{},
                 halting_socket()
               )

      assert socket.assigns.flash["error"] =~ "doesn't look right"
      assert socket.redirected == {:redirect, %{to: "/", status: 302}}
    end
  end

  describe "on_mount :resolve_participant — a :draft group" do
    test "halts and sends the visitor home with a flash, before it is published" do
      group = group_fixture(user_scope_fixture())
      assert group.status == :draft

      assert {:halt, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group.slug},
                 %{},
                 halting_socket()
               )

      assert socket.assigns.flash["error"] =~ "isn't open yet"
      assert socket.redirected == {:redirect, %{to: "/", status: 302}}
    end
  end

  describe "on_mount :resolve_participant — a finished group" do
    test "redirects Entry and Ballot straight to results" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.complete_group(scope, group)

      for view <- [ConsensusWeb.JoinLive.Entry, ConsensusWeb.JoinLive.Ballot] do
        assert {:halt, socket} =
                 JoinAuth.on_mount(
                   :resolve_participant,
                   %{"slug" => group.slug},
                   %{},
                   halting_socket(view)
                 )

        assert socket.redirected ==
                 {:redirect, %{to: "/join/#{group.slug}/results", status: 302}}
      end
    end

    test "a cancelled group behaves the same way as completed" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      {:ok, group} = Activities.cancel_group(scope, group)

      assert {:halt, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group.slug},
                 %{},
                 halting_socket(ConsensusWeb.JoinLive.Entry)
               )

      assert socket.redirected == {:redirect, %{to: "/join/#{group.slug}/results", status: 302}}
    end

    test "does not redirect Results to itself, and still assigns group/participant" do
      scope = user_scope_fixture()
      {group, activities} = voting_group_fixture(scope)
      participant = participant_fixture(group)
      {:ok, participant} = Voting.cast_ballot(participant, [hd(activities).id])
      {:ok, group} = Activities.complete_group(scope, group)

      session = %{JoinAuth.participant_session_key(group.id) => participant.token}

      assert {:cont, socket} =
               JoinAuth.on_mount(
                 :resolve_participant,
                 %{"slug" => group.slug},
                 session,
                 %LiveView.Socket{view: ConsensusWeb.JoinLive.Results}
               )

      refute socket.redirected
      assert socket.assigns.group.id == group.id
      assert socket.assigns.participant.id == participant.id
    end
  end

  defp halting_socket(view \\ nil) do
    %LiveView.Socket{
      endpoint: ConsensusWeb.Endpoint,
      view: view,
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end
end
