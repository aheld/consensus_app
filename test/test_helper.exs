# `max_cases: 1` — the suite runs its cases one at a time, and this is a SQLite
# constraint, not a preference.
#
# SQLite permits exactly one write transaction across the whole database file. The Ecto
# sandbox holds each test's transaction open for the *entire* test, so two concurrent
# write-touching cases collide by construction. SQLite cannot make the loser wait, either:
# a connection that is already inside a transaction and asks to upgrade to a write would
# deadlock if it blocked, so SQLite returns `SQLITE_BUSY` immediately and the `busy_timeout`
# handler never runs. The failure surfaces as `** (Exqlite.Error) Database busy` on an
# ordinary `INSERT INTO users`, in whichever unlucky test happened to be second.
#
# Measured on 2026-08-08 at 430 tests: ~50 failures a run at the default `max_cases: 20`,
# still ~46 at `--max-cases 2`, zero at `--max-cases 1`. `journal_mode: :wal` and
# `default_transaction_mode: :immediate` were both tried in `config/test.exs` and neither
# helped, because the transaction in question is opened by the sandbox rather than by us.
# The suite runs in about 2.7 s serially, so there is nothing to buy back. See D-033.
#
# `async: true` on a case is still meaningful and still worth setting: under the sandbox it
# means "own connection, own transaction, rolled back at exit" — the isolation, which we
# keep — rather than "runs at the same time as its neighbours", which we no longer do.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Consensus.Repo, :manual)
