defmodule Consensus.RepoConfigTest do
  @moduledoc """
  Guards on the SQLite connection settings that are load-bearing and easy to "tidy" away.

  These are all one-line edits that look harmless, break nothing locally, and fail only
  under a burst of simultaneous voters in production — the one moment this product is
  designed around (five friends tapping "send my votes" as the deadline chip turns red).
  `mix test` cannot observe them: the suite runs `max_cases: 1` by design (D-033), so
  nothing in it ever contends for the write lock.

  The measurements behind each value are recorded in D-038 and
  `docs/sqlite-capacity-review.md`. The headline: at `pool_size: 5`, fifteen voters
  arriving inside a two-second window produced a p95 of 25,762ms and lost ballots to the
  five-second busy timeout; at `pool_size: 1` the same burst ran at a p95 of 10.6ms with
  no refusals at all, and the *read* tail improved from 5,431ms to 15.6ms.

  Why one connection is faster than five: SQLite permits exactly one write transaction
  across the whole database file. Extra pool slots cannot buy write concurrency because
  there is no concurrency to buy — they only add contenders for a lock that was never
  shareable, and SQLite's busy handler is documented to make no fairness guarantee about
  which waiter wins, so a loser can burn its whole timeout while later arrivals slip past.

  `config/test.exs` is deliberately exempt and is not asserted here: it uses
  `Ecto.Adapters.SQL.Sandbox`, an entirely different pool implementation whose size
  governs sandbox checkouts rather than production write contention.
  """

  use ExUnit.Case, async: true

  @dev "config/dev.exs"
  @runtime "config/runtime.exs"

  describe "the single-writer settings" do
    test "dev holds one connection, and says why" do
      source = File.read!(@dev)

      assert source =~ ~r/^\s*pool_size:\s*1,/m, """
      config/dev.exs no longer pins `pool_size: 1`.

      Dev exists to make a production failure reproducible locally. Raising this hides
      exactly the contention D-038 measured, and hides it in the environment where you
      would otherwise have caught it. If you are raising it on purpose, bring a
      measurement and amend D-038 rather than deleting this test.
      """
    end

    test "production defaults to one connection" do
      source = File.read!(@runtime)

      assert source =~
               ~r/pool_size:\s*String\.to_integer\(System\.get_env\("POOL_SIZE"\)\s*\|\|\s*"1"\)/,
             """
             The production POOL_SIZE default is no longer "1".

             This is the value D-038 measured: a 15-voter deadline burst went from a p95 of
             25,762ms with lost ballots at 5, to 10.6ms with none at 1. The env var is still
             there to raise it — but raise it with a measurement, and amend D-038.
             """
    end

    test "both environments take the write lock at BEGIN, not at first write" do
      for {file, source} <- [{@dev, File.read!(@dev)}, {@runtime, File.read!(@runtime)}] do
        assert source =~ ~r/default_transaction_mode:\s*:immediate/, """
        #{file} no longer sets `default_transaction_mode: :immediate`.

        With ecto_sqlite3's default `BEGIN DEFERRED`, a transaction takes no write lock at
        BEGIN and asks for one on its first write. By then it already holds a read snapshot,
        so SQLite cannot make it wait — blocking could deadlock the pair — and it returns
        SQLITE_BUSY immediately. The `busy_timeout` handler never runs at all. D-033.
        """
      end
    end

    test "both environments pin synchronous explicitly rather than inheriting it" do
      for {file, source} <- [{@dev, File.read!(@dev)}, {@runtime, File.read!(@runtime)}] do
        assert source =~ ~r/synchronous:\s*:normal/, """
        #{file} no longer pins `synchronous: :normal`.

        `:normal` is already the ecto_sqlite3/exqlite default, so this is not about changing
        behaviour — it is about the durability trade being a decision somebody made rather
        than one nobody noticed. Under WAL, `:normal` fsyncs at checkpoint instead of at
        every commit: a BEAM crash or a `fly deploy` cannot lose a committed ballot, but a
        host power loss can lose the tail of the WAL. D-038.
        """
      end
    end

    test "the busy timeout is still set in both environments" do
      for {file, source} <- [{@dev, File.read!(@dev)}, {@runtime, File.read!(@runtime)}] do
        assert source =~ ~r/busy_timeout:\s*5_000/, """
        #{file} no longer sets `busy_timeout: 5_000`.

        Without it a contended write returns "** (Exqlite.Error) database is locked"
        immediately instead of waiting its turn.
        """
      end
    end
  end

  describe "the settings the running Repo actually has" do
    # The tests above read source text, which is what CI can check on a pull request
    # without booting anything. This one asserts values that actually reached the started
    # Repo, so a typo in a key name — which those regexes would happily match — cannot
    # pass unnoticed.
    #
    # Only the two settings `config/test.exs` shares with dev and prod can be asserted
    # here, because this runs against the *test* Repo. `default_transaction_mode` is
    # deliberately absent from the test config: D-033 records that setting it did not make
    # concurrent cases safe (~50 of 430 still failed), and `max_cases: 1` is the fix
    # instead. Asserting it here would be asserting something test env is right not to have.
    test "the journal mode and busy timeout survive into the loaded config" do
      config = Consensus.Repo.config()

      assert config[:journal_mode] == :wal
      assert config[:busy_timeout] == 5_000
    end
  end
end
