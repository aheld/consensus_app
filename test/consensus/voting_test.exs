defmodule Consensus.VotingTest do
  # `async: true` buys sandbox isolation, not concurrency — the suite runs
  # `max_cases: 1` (D-033). Nothing here issues DDL, so it is safe either way.
  use Consensus.DataCase, async: true

  import Ecto.Query
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Repo
  alias Consensus.Voting
  alias Consensus.Voting.Participant
  alias Consensus.Voting.Vote

  defp votes_for(%Participant{id: id}) do
    Repo.all(from(v in Vote, where: v.participant_id == ^id, order_by: [asc: v.activity_id]))
  end

  defp reload(%Participant{id: id}), do: Repo.get!(Participant, id)

  describe "create_participant/2" do
    test "creates a named guest and mints a token" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      assert {:ok, participant} = Voting.create_participant(group, %{display_name: "Ada"})
      assert participant.display_name == "Ada"
      assert participant.kind == :guest
      assert participant.user_id == nil
      assert participant.voted_at == nil
      assert is_binary(participant.token)
      assert byte_size(participant.token) >= 32
    end

    test "defaults to a guest and normalises a blank name to nil" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      assert {:ok, blank} = Voting.create_participant(group, %{display_name: "   "})
      assert blank.display_name == nil
      assert blank.kind == :guest

      assert {:ok, missing} = Voting.create_participant(group, %{})
      assert missing.display_name == nil
      assert missing.kind == :guest
    end

    test "trims a name that has one" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      assert {:ok, participant} = Voting.create_participant(group, %{display_name: "  Ada  "})
      assert participant.display_name == "Ada"
    end

    test "accepts string keys, as a form POST delivers them" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      voter = user_fixture()

      assert {:ok, participant} =
               Voting.create_participant(group, %{
                 "display_name" => "Grace",
                 "kind" => "user",
                 "user_id" => voter.id
               })

      assert participant.kind == :user
      assert participant.user_id == voter.id
    end

    test "mints a distinct token per participant, never one from attrs" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      {:ok, a} = Voting.create_participant(group, %{display_name: "A"})
      {:ok, b} = Voting.create_participant(group, %{display_name: "B", token: "chosen-by-client"})

      refute a.token == b.token
      refute b.token == "chosen-by-client"
    end

    test "voted_at is not castable" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      stamp = DateTime.utc_now(:second)

      assert {:ok, participant} =
               Voting.create_participant(group, %{display_name: "A", voted_at: stamp})

      assert participant.voted_at == nil
      refute Participant.voted?(participant)
    end

    test "group_id comes from the group, never from attrs" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      {other, _activities} = voting_group_fixture(scope)

      assert {:ok, participant} = Voting.create_participant(group, %{group_id: other.id})
      assert participant.group_id == group.id
    end

    test "kind :user requires a user_id" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      assert {:error, changeset} = Voting.create_participant(group, %{kind: :user})
      assert "is required for a signed-in participant" in errors_on(changeset).user_id
    end

    test "kind :guest is refused when a user_id is present" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      voter = user_fixture()

      assert {:error, changeset} =
               Voting.create_participant(group, %{kind: :guest, user_id: voter.id})

      assert "must be :user when a user_id is present" in errors_on(changeset).kind
    end

    test "caps the display name at the changeset, which is the real limit" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      too_long = String.duplicate("a", Participant.max_display_name_length() + 1)

      assert {:error, changeset} = Voting.create_participant(group, %{display_name: too_long})
      assert %{display_name: [_ | _]} = errors_on(changeset)
    end

    test "refuses a group that is not open" do
      scope = user_scope_fixture()
      draft = group_fixture(scope)

      assert {:error, :not_open} = Voting.create_participant(draft, %{display_name: "A"})

      {group, _activities} = voting_group_fixture(scope)
      {:ok, completed} = Activities.complete_group(scope, group)
      assert {:error, :not_open} = Voting.create_participant(completed, %{display_name: "A"})

      {other, _activities} = voting_group_fixture(scope)
      {:ok, cancelled} = Activities.cancel_group(scope, other)
      assert {:error, :not_open} = Voting.create_participant(cancelled, %{display_name: "A"})
    end

    test "a signed-in user cannot join the same group twice" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      voter = user_fixture()

      assert {:ok, _first} =
               Voting.create_participant(group, %{kind: :user, user_id: voter.id})

      assert {:error, changeset} =
               Voting.create_participant(group, %{kind: :user, user_id: voter.id})

      assert %{user_id: [_ | _]} = errors_on(changeset)
    end

    test "many anonymous guests may join the same group" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      for _ <- 1..3, do: assert({:ok, _} = Voting.create_participant(group, %{}))
      assert Voting.count_participants(group) == 3
    end

    test "broadcasts {:participant_joined, group_id} on the group's existing topic" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      Voting.subscribe(group.id)
      assert {:ok, _participant} = Voting.create_participant(group, %{display_name: "Ada"})

      assert_receive {:participant_joined, group_id}
      assert group_id == group.id
    end

    test "a refused join broadcasts nothing" do
      scope = user_scope_fixture()
      draft = group_fixture(scope)

      Voting.subscribe(draft.id)
      assert {:error, :not_open} = Voting.create_participant(draft, %{display_name: "A"})

      refute_receive {:participant_joined, _group_id}
    end
  end

  describe "get_participant_by_token/1 and get_participant_for_user/2" do
    test "resolves a participant from their token" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      participant = participant_fixture(group, %{display_name: "Ada"})

      assert %Participant{id: id} = Voting.get_participant_by_token(participant.token)
      assert id == participant.id
    end

    test "returns nil for an unknown or non-binary token" do
      refute Voting.get_participant_by_token("nope")
      refute Voting.get_participant_by_token(nil)
      refute Voting.get_participant_by_token(123)
    end

    test "a returning signed-in user resumes rather than duplicating" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      voter = user_fixture()

      {:ok, participant} = Voting.create_participant(group, %{kind: :user, user_id: voter.id})

      assert %Participant{id: id} = Voting.get_participant_for_user(group, voter.id)
      assert id == participant.id
      refute Voting.get_participant_for_user(group, user_fixture().id)
      refute Voting.get_participant_for_user(group, nil)
    end
  end

  describe "cast_ballot/3 — the happy path" do
    test "stamps voted_at and writes one row per mark" do
      scope = user_scope_fixture()
      {group, [a, b, c]} = voting_group_fixture(scope)
      participant = participant_fixture(group, %{display_name: "Ada"})

      assert {:ok, voted} = Voting.cast_ballot(participant, [a.id, b.id], c.id)
      assert %DateTime{} = voted.voted_at
      assert Participant.voted?(voted)
      assert Participant.voted?(reload(participant))

      assert [%Vote{kind: :approve}, %Vote{kind: :approve}, %Vote{kind: :veto}] =
               votes_for(participant)
    end

    test "accepts ids as strings, the way a form delivers them" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:ok, _voted} =
               Voting.cast_ballot(participant, [to_string(a.id)], to_string(b.id))

      assert length(votes_for(participant)) == 2
    end

    test "collapses duplicate approvals" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:ok, _voted} = Voting.cast_ballot(participant, [a.id, a.id, a.id])
      assert [%Vote{kind: :approve}] = votes_for(participant)
    end

    test "a veto with no approvals is a valid ballot" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:ok, _voted} = Voting.cast_ballot(participant, [], a.id)
      assert [%Vote{kind: :veto}] = votes_for(participant)
    end

    test "broadcasts {:ballot_cast, group_id} on the group's existing topic" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      # Deliberately subscribed through Activities: one subscription must see both
      # organizer edits and incoming ballots.
      :ok = Activities.subscribe_group(group.id)

      assert {:ok, _voted} = Voting.cast_ballot(participant, [a.id])
      assert_receive {:ballot_cast, group_id}
      assert group_id == group.id
    end

    test "the broadcast carries nothing about the ballot's contents" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group, %{display_name: "Ada"})

      :ok = Voting.subscribe(group.id)
      assert {:ok, _voted} = Voting.cast_ballot(participant, [a.id, b.id])

      group_id = group.id
      assert_receive {:ballot_cast, ^group_id} = message
      # Exactly two elements: the tag and the group id. Nothing about who voted, and
      # nothing about what they picked.
      assert tuple_size(message) == 2
    end
  end

  describe "cast_ballot/3 — the lock" do
    test "a second ballot from a stale struct is refused, and writes nothing" do
      scope = user_scope_fixture()
      {group, [a, b, c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      # The struct the caller keeps hold of: read before the cast, so its voted_at is
      # nil forever. This is exactly what a LiveView socket assign looks like.
      stale = participant

      assert {:ok, _voted} = Voting.cast_ballot(participant, [a.id])
      assert stale.voted_at == nil

      assert {:error, :already_voted} = Voting.cast_ballot(stale, [b.id, c.id])

      assert [%Vote{activity_id: only, kind: :approve}] = votes_for(participant)
      assert only == a.id
    end

    test "double submitting the same stale struct yields one ballot and one refusal" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      results = [
        Voting.cast_ballot(participant, [a.id]),
        Voting.cast_ballot(participant, [b.id])
      ]

      assert [{:ok, %Participant{}}, {:error, :already_voted}] = results
      assert length(votes_for(participant)) == 1
      assert Voting.count_voted(group) == 1
    end

    test "refuses a participant whose row is gone" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)
      Repo.delete!(participant)

      assert {:error, :not_found} = Voting.cast_ballot(participant, [a.id])
    end
  end

  describe "cast_ballot/3 — ids from the client" do
    test "an activity from another group is refused and nothing is written" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      {_other_group, [foreign | _]} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)

      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, [a.id, foreign.id])
      assert votes_for(participant) == []
      refute Participant.voted?(reload(participant))
    end

    test "a foreign activity used as the veto is refused too" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      {_other_group, [foreign | _]} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)

      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, [a.id], foreign.id)
      assert votes_for(participant) == []
    end

    test "an id that does not exist at all is refused" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, [-1])
    end

    test "a non-numeric id is refused rather than raising" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, ["drop table"])
      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, ["12abc"])
      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, [%{}])
      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, [], "nope")
    end
  end

  describe "cast_ballot/3 — the group must be open" do
    test "refuses once the group has completed" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)
      {:ok, _completed} = Activities.complete_group(scope, group)

      assert {:error, :not_open} = Voting.cast_ballot(participant, [a.id])
      assert votes_for(participant) == []
    end

    test "refuses once the group has been cancelled" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)
      {:ok, _cancelled} = Activities.cancel_group(scope, group)

      assert {:error, :not_open} = Voting.cast_ballot(participant, [a.id])
    end

    test "refuses a group pushed back to draft" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)
      force_group!(group, status: :draft)

      assert {:error, :not_open} = Voting.cast_ballot(participant, [a.id])
    end

    test "refuses once the deadline has passed" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)
      expire_deadline!(group)

      assert {:error, :deadline_passed} = Voting.cast_ballot(participant, [a.id])
      assert votes_for(participant) == []
      refute Participant.voted?(reload(participant))
    end
  end

  describe "cast_ballot/3 — ballot shape" do
    test "refuses an empty ballot" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:error, :empty_ballot} = Voting.cast_ballot(participant, [])
      assert {:error, :empty_ballot} = Voting.cast_ballot(participant, [], nil)
      refute Participant.voted?(reload(participant))
    end

    test "refuses a veto when the group does not allow one" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope, 3, %{veto_allowed: false})
      participant = participant_fixture(group)

      assert {:error, :veto_not_allowed} = Voting.cast_ballot(participant, [a.id], b.id)
      assert votes_for(participant) == []

      assert {:ok, _voted} = Voting.cast_ballot(participant, [a.id])
    end

    test "refuses a ballot that both approves and vetoes the same activity" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:error, :veto_conflict} = Voting.cast_ballot(participant, [a.id], a.id)
      assert votes_for(participant) == []
    end
  end

  # A LiveView is allowed to push `params["approved"]` straight through, and an unknown
  # session token resolves to `nil` — so the shapes below are what the screen actually
  # sends, not hypotheticals. Every one of them used to raise `FunctionClauseError` out
  # of the caller instead of returning a tuple.
  describe "cast_ballot/3 — client-shaped input never raises" do
    test "a nil participant is :not_found, not a crash" do
      scope = user_scope_fixture()
      {_group, [a, _b, _c]} = voting_group_fixture(scope)

      assert {:error, :not_found} = Voting.cast_ballot(nil, [a.id])
    end

    test "nil approvals — an untouched checkbox group — is an empty ballot" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:error, :empty_ballot} = Voting.cast_ballot(participant, nil)
      refute Participant.voted?(reload(participant))
    end

    test "a bare id rather than a list is a one-element ballot" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      assert {:ok, _voted} = Voting.cast_ballot(participant, a.id)
      assert [%Vote{activity_id: id, kind: :approve}] = votes_for(participant)
      assert id == a.id
    end

    test "an absurd id list is :unknown_activity, not :database_busy" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      participant = participant_fixture(group)

      # Forty thousand ids would blow SQLite's bind-variable limit if they reached an
      # `IN (?, ?, ...)`, and the busy rescue would then have told the voter to try again
      # later about input that can never succeed. The pool-size bound catches it first.
      absurd = [a.id | Enum.to_list(1_000_000..1_040_000)]

      assert {:error, :unknown_activity} = Voting.cast_ballot(participant, absurd)
      refute Participant.voted?(reload(participant))
    end
  end

  # `tally/1` alone cannot tell "everyone vetoed everything" from "nobody has voted yet":
  # both are a list with no `leader?` and no `winner?`. A results screen must not render
  # them the same way, so the distinction is `outcome/1`'s job. See D-034.
  describe "outcome/1" do
    test "names the leader while the vote is open, and the winner once it closes" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)

      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [b.id])
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [b.id, a.id])

      assert {:leader, row} = group |> Voting.tally() |> Voting.outcome()
      assert row.activity.id == b.id

      {:ok, completed} = Activities.complete_group(scope, group)

      assert {:winner, won} = completed |> Voting.tally() |> Voting.outcome()
      assert won.activity.id == b.id
    end

    test "reports :no_votes for an untouched pool" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      assert :no_votes = group |> Voting.tally() |> Voting.outcome()
      assert :no_votes = Voting.outcome([])
    end

    test "reports :no_consensus when every option has been vetoed" do
      scope = user_scope_fixture()
      {group, [a, b, c]} = voting_group_fixture(scope)

      # Nothing caps total vetoes — one per participant, unlimited across the pool — so
      # any group with as many participants as options can reach this.
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [], a.id)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [], b.id)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [], c.id)

      {:ok, completed} = Activities.complete_group(scope, group)
      tally = Voting.tally(completed)

      assert Enum.all?(tally, & &1.vetoed?)
      refute Enum.any?(tally, & &1.winner?)
      assert :no_consensus = Voting.outcome(tally)
    end

    # The case that used to fall through to `:no_votes` — with real ballots cast. A voter
    # may spend their veto and approve nothing, and `cast_ballot/3` takes that ballot; the
    # results screen then rendered "Voting closed before anyone cast a ballot." above a
    # `1/1 voted` avatar row and a struck-through option wearing a `VETOED` pill, i.e. the
    # screen contradicting itself twice in the reader's own line of sight.
    test "reports :vetoes_only when ballots were cast but nothing survived with an approval" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)

      participant = participant_fixture(group)
      {:ok, _} = Voting.cast_ballot(participant, [], a.id)

      {:ok, completed} = Activities.complete_group(scope, group)
      tally = Voting.tally(completed)

      refute Enum.all?(tally, & &1.vetoed?)
      assert Enum.any?(tally, & &1.vetoed?)
      assert :vetoes_only = Voting.outcome(tally)

      # And it is still distinguishable from the thing it used to be confused with.
      assert Consensus.Repo.get!(Consensus.Voting.Participant, participant.id).voted_at
    end

    # A ballot with no approvals *and* no veto is refused outright, which is what makes
    # `:no_votes` mean exactly "nobody voted" now that `:vetoes_only` has been split out.
    test "an empty ballot is refused, so :no_votes cannot mean 'voted for nothing'" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)

      assert {:error, :empty_ballot} = Voting.cast_ballot(participant_fixture(group), [], nil)
    end
  end

  describe "tally/1" do
    test "reports zeroes, and no leader, for a pool nobody has voted on" do
      scope = user_scope_fixture()
      {group, [a, b, c]} = voting_group_fixture(scope)

      assert [first, second, third] = Voting.tally(group)
      assert Enum.map([first, second, third], & &1.activity.id) == [a.id, b.id, c.id]
      assert Enum.all?([first, second, third], &(&1.approvals == 0))
      refute Enum.any?([first, second, third], & &1.leader?)
      refute Enum.any?([first, second, third], & &1.winner?)
    end

    test "ranks by approvals descending" do
      scope = user_scope_fixture()
      {group, [a, b, c]} = voting_group_fixture(scope)

      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [c.id, b.id])
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [c.id])
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [c.id, a.id])

      assert [top, next, last] = Voting.tally(group)
      assert top.activity.id == c.id
      assert top.approvals == 3
      assert top.leader?
      assert top.bar_percent == 100

      assert Enum.sort([next.activity.id, last.activity.id]) == Enum.sort([a.id, b.id])
      assert next.approvals == 1
      assert next.bar_percent == 33
      refute next.leader?
    end

    test "breaks ties by the organizer's position, ascending" do
      scope = user_scope_fixture()
      {group, [a, b, c]} = voting_group_fixture(scope)

      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [b.id, c.id])

      assert [first, second, third] = Voting.tally(group)
      # b and c both have one approval; b sits at the lower position, so it leads.
      assert first.activity.id == b.id
      assert first.leader?
      assert second.activity.id == c.id
      assert third.activity.id == a.id
      assert third.approvals == 0
    end

    test "one veto eliminates an option, however many approvals it had" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)

      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id])
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id])
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [b.id], a.id)

      tally = Voting.tally(group)
      vetoed = Enum.find(tally, &(&1.activity.id == a.id))
      survivor = Enum.find(tally, &(&1.activity.id == b.id))

      assert vetoed.vetoed?
      assert vetoed.vetoes == 1
      assert vetoed.approvals == 2
      refute vetoed.leader?
      assert vetoed.bar_percent == 0

      assert survivor.leader?
      assert survivor.approvals == 1

      # Eliminated options sort after every survivor.
      assert List.last(tally).activity.id == a.id
    end

    test "the leader becomes the winner only once the group is completed" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      {:ok, _} = Voting.cast_ballot(participant_fixture(group), [a.id])

      assert [leader | _] = Voting.tally(group)
      assert leader.leader?
      refute leader.winner?

      {:ok, completed} = Activities.complete_group(scope, group)

      assert [winner | _] = Voting.tally(completed)
      assert winner.activity.id == a.id
      assert winner.leader?
      assert winner.winner?
    end

    test "returns totals only — never who approved what" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope)
      alice = participant_fixture(group, %{display_name: "Alice"})
      bob = participant_fixture(group, %{display_name: "Bob"})

      {:ok, _} = Voting.cast_ballot(alice, [a.id])
      {:ok, _} = Voting.cast_ballot(bob, [b.id], a.id)

      tally = Voting.tally(group)

      expected_keys =
        MapSet.new([:activity, :approvals, :vetoes, :vetoed?, :leader?, :winner?, :bar_percent])

      for row <- tally do
        assert MapSet.new(Map.keys(row)) == expected_keys
      end

      # Nothing anywhere in the returned structure names a participant, carries a
      # participant id, or carries a token. The check is on the whole term, not on a
      # key list, because anonymity has to survive someone adding a field later.
      rendered = inspect(tally, limit: :infinity, structs: false)
      refute rendered =~ "Alice"
      refute rendered =~ "Bob"
      refute rendered =~ alice.token
      refute rendered =~ bob.token
      refute rendered =~ "participant"
    end

    test "ignores votes belonging to another group" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      {other, [x, _y, _z]} = voting_group_fixture(scope)

      {:ok, _} = Voting.cast_ballot(participant_fixture(other), [x.id])

      assert Enum.all?(Voting.tally(group), &(&1.approvals == 0))
      assert Enum.find(Voting.tally(other), &(&1.activity.id == x.id)).approvals == 1
      refute Enum.find(Voting.tally(group), &(&1.activity.id == a.id)).vetoed?
    end
  end

  describe "participants/1, count_participants/1 and count_voted/1" do
    test "report participation without reporting choices" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope)
      alice = participant_fixture(group, %{display_name: "Alice"})
      _anonymous = participant_fixture(group, %{})

      {:ok, _} = Voting.cast_ballot(alice, [a.id])

      assert [first, second] = Voting.participants(group)

      assert MapSet.new(Map.keys(first)) ==
               MapSet.new([:id, :display_name, :initial, :voted?])

      assert first.display_name == "Alice"
      assert first.initial == "A"
      assert first.voted?

      assert second.display_name == nil
      assert second.initial == "?"
      refute second.voted?

      assert Voting.count_participants(group) == 2
      assert Voting.count_voted(group) == 1
    end

    test "are scoped to their own group" do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope)
      {other, _activities} = voting_group_fixture(scope)
      _ = participant_fixture(group)

      assert Voting.participants(other) == []
      assert Voting.count_participants(other) == 0
      assert Voting.count_voted(other) == 0
    end
  end

  # D-035. `Group.anonymous` is a persisted column with a default of `true`, and the
  # engine ignores it on purpose: MVP voting is unconditionally anonymous, and `tally/1`
  # is structurally incapable of returning per-participant choices in either mode. These
  # tests exist so that is a pinned decision rather than an undocumented no-op — if
  # someone later wires attribution, they will have to come here and say so.
  describe "anonymity does not depend on group.anonymous" do
    test "tally/1 returns the same totals-only shape with the flag off" do
      scope = user_scope_fixture()
      {group, [a, b, _c]} = voting_group_fixture(scope, 3, %{anonymous: false})
      refute group.anonymous

      alice = participant_fixture(group, %{display_name: "Alice"})
      bob = participant_fixture(group, %{display_name: "Bob"})
      {:ok, _} = Voting.cast_ballot(alice, [a.id])
      {:ok, _} = Voting.cast_ballot(bob, [a.id, b.id])

      tally = Voting.tally(group)

      for row <- tally do
        assert MapSet.new(Map.keys(row)) ==
                 MapSet.new([
                   :activity,
                   :approvals,
                   :vetoes,
                   :vetoed?,
                   :leader?,
                   :winner?,
                   :bar_percent
                 ])
      end

      # Not "the template hides the names" — the names are not in the return value at
      # all, so no template can leak them.
      refute inspect(tally) =~ "Alice"
      refute inspect(tally) =~ "Bob"
      assert Enum.find(tally, &(&1.activity.id == a.id)).approvals == 2
    end

    test "participants/1 reports participation, never choices, with the flag off" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope, 3, %{anonymous: false})
      alice = participant_fixture(group, %{display_name: "Alice"})
      {:ok, _} = Voting.cast_ballot(alice, [a.id])

      assert [row] = Voting.participants(group)

      assert MapSet.new(Map.keys(row)) == MapSet.new([:id, :display_name, :initial, :voted?])
      assert row.display_name == "Alice"
      assert row.voted?
    end

    test "the broadcast carries no ballot contents in either mode" do
      scope = user_scope_fixture()
      {group, [a, _b, _c]} = voting_group_fixture(scope, 3, %{anonymous: false})
      :ok = Voting.subscribe(group.id)
      participant = participant_fixture(group, %{display_name: "Alice"})

      {:ok, _} = Voting.cast_ballot(participant, [a.id])

      group_id = group.id
      assert_receive {:ballot_cast, ^group_id}
      refute_receive {:ballot_cast, _, _}
    end
  end

  describe "deleting an organizer" do
    test "takes their groups, participants and votes with them" do
      admin_scope = admin_scope_fixture()
      organizer = user_fixture()
      organizer_scope = user_scope_fixture(organizer)
      {group, [a, _b, _c]} = voting_group_fixture(organizer_scope)
      participant = participant_fixture(group)
      {:ok, _} = Voting.cast_ballot(participant, [a.id])

      assert {:ok, {_deleted, _tokens}} = Consensus.Accounts.delete_user(admin_scope, organizer)

      refute Repo.get(Participant, participant.id)
      assert Repo.aggregate(Vote, :count) == 0
    end
  end
end
