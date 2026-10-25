defmodule Consensus.ActivitiesClaimConcurrencyTest do
  @moduledoc """
  Two accounts claiming one anonymous organizer **at the same time** (D-058, plan §9).

  `Consensus.Activities.claim_anonymous_groups/2` is guarded by a compare-and-swap —
  `UPDATE anonymous_organizers SET claimed_by_user_id … WHERE claimed_at IS NULL` — and
  the zero-row branch re-reads the row to tell "claimed by me" (`{:ok, 0}`) from "claimed
  by someone else" (`{:error, :already_claimed}`). Every claim test in
  `Consensus.ActivitiesAnonymousTest` runs inside the sandbox, where `max_cases: 1` and a
  shared connection make two calls sequential however they are spelled, so none of them
  can tell the CAS from a plain `UPDATE`.

  This case uses `Consensus.VotingConcurrencyTest`'s recipe: a **second, dynamic instance
  of `Consensus.Repo`** on a throwaway SQLite file under the test's `tmp_dir`, with a real
  `DBConnection.ConnectionPool`, `journal_mode: :wal` and `default_transaction_mode:
  :immediate`, and two tasks released from one barrier. The suite database is never
  touched.

  Unlike the voting case, `busy_timeout` is production's 5_000: two short claims must
  queue rather than fail, so the second one actually reaches the CAS and the assertion
  exercises it instead of being satisfied by a `:database_busy`. `{:database_busy, _}` is
  still an accepted outcome for the loser — the caller keeps the cookie and retries on
  the next log-in — it is just not expected here.

  Mutation-checked: drop `and is_nil(o.claimed_at)` from the CAS in `claim_organizer/3`
  and the loser's call comes back `{:ok, 0}` with `claimed_by_user_id` overwritten, which
  fails this case.

  `async: false`, `@moduletag :tmp_dir` and `:capture_log` for the same reasons as
  `Consensus.VotingConcurrencyTest`; read its moduledoc before changing either file.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Accounts.Scope
  alias Consensus.Activities
  alias Consensus.Activities.AnonymousOrganizer
  alias Consensus.Activities.Group

  @groups 3

  setup %{tmp_dir: tmp} do
    # Each `Ecto.Migrator.run/4` recompiles the migration files, and
    # `Consensus.ReleaseTest` and `Consensus.VotingConcurrencyTest` do the same.
    ignore_conflict? = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    {:ok, repo} =
      Consensus.Repo.start_link(
        name: nil,
        database: Path.join(tmp, "claim_concurrency.db"),
        # `config/test.exs` pins the sandbox pool, which would serialise the race.
        pool: DBConnection.ConnectionPool,
        pool_size: 5,
        journal_mode: :wal,
        busy_timeout: 5_000,
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

    {raw_token, organizer} = anonymous_organizer_fixture()
    scope = Scope.for_anonymous_organizer(organizer)
    groups = for _ <- 1..@groups, do: group_fixture(scope)

    %{repo: repo, raw_token: raw_token, organizer: organizer, groups: groups}
  end

  test "two accounts claiming one identity at once: exactly one wins, and wins everything",
       %{repo: repo, raw_token: raw_token, organizer: organizer, groups: groups} do
    claimants = [user_fixture(), user_fixture()]

    results =
      at_the_same_time(repo, claimants, fn user ->
        {user.id, Activities.claim_anonymous_groups(user, raw_token)}
      end)

    assert [{winner_id, {:ok, @groups}}] =
             Enum.filter(results, &match?({_, {:ok, @groups}}, &1)),
           "expected exactly one claim to move all #{@groups} groups: #{inspect(results)}"

    assert [{_loser_id, loser_result}] = Enum.reject(results, &match?({^winner_id, _}, &1))

    assert match?({:error, :already_claimed}, loser_result) or
             match?({:error, {:database_busy, _}}, loser_result),
           "the losing claim must be refused, not succeed: #{inspect(loser_result)}"

    for %Group{id: id} <- groups do
      group = Consensus.Repo.get!(Group, id)
      assert group.organizer_id == winner_id
      assert group.anonymous_organizer_id == nil
    end

    claimed = Consensus.Repo.get!(AnonymousOrganizer, organizer.id)
    assert claimed.claimed_by_user_id == winner_id
    assert claimed.claimed_at
  end

  # Parks every task on a `:go` message so they contend rather than trickle; each task
  # adopts the dynamic repo itself, because `put_dynamic_repo/1` is per-process.
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
            error -> {subject.id, {:raised, error}}
          end
        end)
      end

    for %Task{pid: pid} <- tasks do
      assert_receive {:ready, ^pid}, 5_000
    end

    for %Task{pid: pid} <- tasks, do: send(pid, :go)

    Task.await_many(tasks, 30_000)
  end
end
