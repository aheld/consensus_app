defmodule Consensus.VotingConcurrencyTest do
  @moduledoc """
  The one place in this repo where two ballots are actually cast **at the same time**.

  Everything else in the suite is sequential by construction: `max_cases: 1` (D-033) is a
  correctness fix, not a knob, and the Ecto sandbox hands every process in a test the
  *same* connection, so `[cast_ballot(p, [a]), cast_ballot(p, [b])]` is two calls one
  after another no matter how it is spelled. That is fine for every other invariant in
  `Consensus.Voting` and useless for the one the plan calls the correctness centre of the
  feature — five friends tapping "send my votes" as the deadline lands.

  So this case leaves the sandbox behind. It starts a **second, dynamic instance of
  `Consensus.Repo`** (`put_dynamic_repo/1`) against a throwaway SQLite file under the
  test's own `tmp_dir`, with production's `pool_size: 5`, `journal_mode: :wal` and
  `default_transaction_mode: :immediate`, and a real connection pool instead of
  `Ecto.Adapters.SQL.Sandbox`. Every task adopts the same dynamic repo, so N ballots run
  on N real connections against one real database file. The suite database is never
  touched.

  Two properties are asserted:

    * **N different voters, one group, all at once → N successes**, and a tally that adds
      up exactly. Nothing may be lost, refused or half-written.
    * **One voter, N tabs, all at once → exactly one ballot and N-1 `:already_voted`.**
      The lock is a conditional `UPDATE ... WHERE voted_at IS NULL`, which is correct
      under real contention rather than merely under sequential calls; this is the only
      test in the repo that can tell the difference.

  ## The one deliberate difference from production, and what it costs

  `busy_timeout` here is **500 ms, not production's 5_000**. That is not a fidelity
  shortcut, it makes the bar *harder*: SQLite's busy handler backs off unfairly under
  several writers, so a shorter timeout means more `SQLITE_BUSY` reaches
  `Consensus.Voting`'s own jittered retry instead of being absorbed by SQLite's sleep
  loop — and the assertion is still "every ballot lands". It also keeps the case at ~1–2 s
  instead of the ~11 s the full production timeout costs, which matters because
  `max_cases: 1` makes wall-clock the sum of every case (D-033).

  What that trades away, stated plainly: this case pins the **whole refusal-free chain**
  — short transaction, `insert_all`, the busy rescue and the bounded retry — but it
  cannot single out which link broke. Deleting the retry (`@busy_retries 0`) fails it
  reliably (measured: 5–6 of 8 ballots land, the rest `:database_busy`). Moving
  validation back inside `Repo.transact/1` does **not** fail it, because the retry
  absorbs the extra contention; that regression showed up in the original review as a 45%
  refusal rate at production's own five-second timeout. If the retry is ever removed,
  restore the longer timeout here or this case stops being the guard it is now.

  `async: false` and `@moduletag :tmp_dir`, per the rules in AGENTS.md for a case that
  reaches past the sandbox for a real database. `:capture_log` because a starved
  connection logs `Exqlite.Connection ... disconnected: database is locked` on its way to
  being retried, and that is the case working, not failing.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities
  alias Consensus.Voting
  alias Consensus.Voting.Participant
  alias Consensus.Voting.Vote

  # More voters than the pool has connections. Five friends tapping "send my votes" is
  # the stated core use case; eight is that plus enough headroom that some caller must
  # wait for a connection as well as for the write lock — which is where the original
  # review found `DBConnection.ConnectionError` escaping into a guest's LiveView.
  @voters 8

  setup %{tmp_dir: tmp} do
    # Each `Ecto.Migrator.run/4` recompiles the migration files, and
    # `Consensus.ReleaseTest` does the same thing in the same suite run.
    ignore_conflict? = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    {:ok, repo} =
      Consensus.Repo.start_link(
        name: nil,
        database: Path.join(tmp, "concurrency.db"),
        # Production's settings, not the suite's. `pool:` has to be named explicitly
        # because `config/test.exs` pins `Ecto.Adapters.SQL.Sandbox`, which would
        # serialise exactly the contention this case exists to produce.
        pool: DBConnection.ConnectionPool,
        pool_size: 5,
        journal_mode: :wal,
        # Deliberately shorter than production's 5_000 — see the moduledoc.
        busy_timeout: 500,
        default_transaction_mode: :immediate
      )

    Consensus.Repo.put_dynamic_repo(repo)

    Ecto.Migrator.run(
      Consensus.Repo,
      Ecto.Migrator.migrations_path(Consensus.Repo),
      :up,
      all: true,
      dynamic_repo: repo,
      log: false
    )

    on_exit(fn ->
      Code.put_compiler_option(:ignore_module_conflict, ignore_conflict?)

      if Process.alive?(repo) do
        try do
          Supervisor.stop(repo, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    scope = user_scope_fixture()
    group = group_fixture(scope, %{deadline_at: future_deadline()})
    activities = for _ <- 1..3, do: activity_fixture(group)
    {:ok, group} = Activities.publish_group(scope, group)

    %{repo: repo, group: group, activities: activities}
  end

  describe "cast_ballot/3 under real concurrency" do
    test "every one of #{@voters} simultaneous voters gets their ballot in",
         %{repo: repo, group: group, activities: [a, b, c]} do
      participants =
        for i <- 1..@voters do
          {:ok, participant} = Voting.create_participant(group, %{display_name: "Voter #{i}"})
          participant
        end

      results =
        at_the_same_time(repo, participants, fn p -> Voting.cast_ballot(p, [a.id, b.id]) end)

      assert Enum.all?(results, &match?({:ok, %Participant{}}, &1)),
             """
             Not every simultaneous ballot landed — a voter was refused or crashed under \
             ordinary burst load. Check, in this order (D-034): the bounded jittered \
             retry in `with_busy_retry/2`; the rescue covering BOTH `Exqlite.Error` and \
             `DBConnection.ConnectionError`; and the size of the `Repo.transact/1` block \
             in `commit_ballot/3`, which must stay at a group re-read, the conditional \
             UPDATE and one `insert_all`.

             Outcomes: #{inspect(tally_outcomes(results))}
             """

      assert Voting.count_voted(group) == @voters
      assert Consensus.Repo.aggregate(Vote, :count) == @voters * 2

      # And the tally the results screen would read is exactly right — no lost writes,
      # no half-committed ballots.
      tally = Voting.tally(group)
      assert Enum.find(tally, &(&1.activity.id == a.id)).approvals == @voters
      assert Enum.find(tally, &(&1.activity.id == b.id)).approvals == @voters
      assert Enum.find(tally, &(&1.activity.id == c.id)).approvals == 0
    end

    test "#{@voters} tabs submitting one participant's ballot produce exactly one ballot",
         %{repo: repo, group: group, activities: [a, _b, _c]} do
      {:ok, participant} = Voting.create_participant(group, %{display_name: "Double clicker"})

      results =
        at_the_same_time(repo, List.duplicate(participant, @voters), fn p ->
          Voting.cast_ballot(p, [a.id])
        end)

      assert Enum.count(results, &match?({:ok, %Participant{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_voted})) == @voters - 1

      assert Consensus.Repo.aggregate(Vote, :count) == 1
      assert Voting.count_voted(group) == 1
      assert Consensus.Repo.get!(Participant, participant.id).voted_at
    end
  end

  # Parks every task on a `:go` message first, so they contend rather than trickle. Each
  # task has to adopt the dynamic repo itself — `put_dynamic_repo/1` is per-process, and
  # a task that forgot would quietly talk to the sandboxed suite repo instead.
  defp at_the_same_time(repo, subjects, fun) do
    parent = self()

    tasks =
      for subject <- subjects do
        Task.async(fn ->
          Consensus.Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          try do
            fun.(subject)
          rescue
            error -> {:raised, error}
          end
        end)
      end

    for %Task{pid: pid} <- tasks do
      assert_receive {:ready, ^pid}, 5_000
    end

    for %Task{pid: pid} <- tasks, do: send(pid, :go)

    Task.await_many(tasks, 30_000)
  end

  defp tally_outcomes(results) do
    Enum.frequencies_by(results, fn
      {:ok, _} -> :ok
      {:error, {:database_busy, _}} -> :database_busy
      {:raised, error} -> {:raised, error.__struct__}
      other -> other
    end)
  end
end
