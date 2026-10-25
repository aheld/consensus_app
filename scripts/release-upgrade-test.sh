#!/usr/bin/env bash
# Mirrors the "Boot twice on one volume, migrating a populated database" step of
# .github/workflows/ci.yml (CLAUDE.md invariant 10). This is the upgrade rehearsal:
# everything else in the repo starts from an empty database, which is what every deploy
# after the first is not.
set -uo pipefail
cd "$(dirname "$0")/.."

SKB="$(head -c 64 /dev/urandom | base64 | tr -d '\n')"
PHX_HOST=$(sed -n "s/^[[:space:]]*PHX_HOST[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" fly.toml)

cleanup() { docker rm -f consensus-upgrade-1 consensus-upgrade-2 >/dev/null 2>&1; }
fail() { echo "FAIL: $*"; cleanup; docker volume rm consensus-upgrade >/dev/null 2>&1; exit 1; }
rpc_int() { docker exec "$1" /app/bin/consensus rpc "$2" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1; }

cleanup
docker volume rm consensus-upgrade >/dev/null 2>&1
docker volume create consensus-upgrade >/dev/null

run_one() {
  docker run -d --name "$1" -v consensus-upgrade:/data \
    -e SECRET_KEY_BASE="$SKB" -e DATABASE_PATH=/data/consensus.db \
    -e PHX_HOST="$PHX_HOST" -e PORT=4000 -p "$2":4000 consensus:ci >/dev/null
  for _ in $(seq 1 60); do
    [ "$(curl -fsS "http://127.0.0.1:$2/health" 2>/dev/null)" = "ok" ] && return 0
    sleep 1
  done
  return 1
}

# The volume is empty and root-owned, exactly as Fly presents a fresh one. The image's
# `chown nobody:root /data` only helps when the mount is empty — which it is here.
run_one consensus-upgrade-1 4011 || fail "first boot never became healthy"
echo "PASS  first boot healthy on an empty volume"

[ "$(rpc_int consensus-upgrade-1 'IO.puts(Consensus.Accounts.count_admins())')" = "1" ] \
  || fail "first boot did not seed exactly one admin"
echo "PASS  first boot seeded one admin"

# Rename the bootstrap admin. Two things ride on this: the seeds' gate is "are there zero
# admins?", not "does `aheld` exist", so a rename must NOT look like a first boot on the
# next start; and the rename is what proves the second boot migrated real rows rather than
# a fresh file.
docker exec consensus-upgrade-1 /app/bin/consensus rpc '
  u = Consensus.Repo.get_by!(Consensus.Accounts.User, username: "aheld")
  Ecto.Changeset.change(u, username: "renamed_operator") |> Consensus.Repo.update!()
  IO.puts("renamed")' >/dev/null 2>&1
echo "PASS  bootstrap admin renamed to renamed_operator"

docker stop consensus-upgrade-1 >/dev/null

# Roll the newest migration down so the second boot has real work to do against rows that
# already exist. `eval` runs in a fresh node that never goes through Application.start/2.
# `rollback(repo, version)` reverses everything *after and including* `version`, so the
# argument is the newest migration itself — passing the one before it takes two down.
last=$(ls priv/repo/migrations/*.exs | sort | tail -1 | xargs basename | cut -d_ -f1)
docker run --rm -v consensus-upgrade:/data \
  -e SECRET_KEY_BASE="$SKB" -e DATABASE_PATH=/data/consensus.db -e PHX_HOST="$PHX_HOST" \
  consensus:ci /app/bin/consensus eval "Consensus.Release.rollback(Consensus.Repo, $last)" \
  >/dev/null 2>&1 || fail "rollback of migration $last failed"
echo "PASS  rolled migration $last back down on a populated volume"

# D-058's migration deliberately wipes every group, and the rehearsal below proves it —
# but only while D-058 is `$last`. Once a later migration lands, that one is rolled back
# instead, D-058 stays applied, and a hard-coded "zero groups" would fail. So the
# D-058-specific half is keyed on `$last`; the foreign-key half holds after any migration.
D058=20261024012242

# Put a group and an option on the rolled-back schema, so the second boot's migration
# meets real rows in `activity_groups` and `activities`, not just in `users`. This is
# what proves the wipe runs on the boot path, on the boot-time repo connection, and
# leaves nothing orphaned. Parameters rather than SQL string literals: the eval argument
# is single-quoted here.
if [ "$last" = "$D058" ]; then
  docker run --rm -v consensus-upgrade:/data \
    -e SECRET_KEY_BASE="$SKB" -e DATABASE_PATH=/data/consensus.db -e PHX_HOST="$PHX_HOST" \
    consensus:ci /app/bin/consensus eval '
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(:consensus)
    now = "2026-10-23T12:00:00"
    {:ok, _, _} = Ecto.Migrator.with_repo(Consensus.Repo, fn repo ->
      %{num_rows: 1} = repo.query!(
        "INSERT INTO activity_groups (title, slug, status, organizer_id, inserted_at, updated_at)
         SELECT ?, ?, ?, id, ?, ? FROM users WHERE is_admin = 1 LIMIT 1",
        ["Before the upgrade", "preupgrade", "draft", now, now])
      %{num_rows: 1} = repo.query!(
        "INSERT INTO activities (group_id, position, name, inserted_at, updated_at)
         SELECT id, 0, ?, ?, ? FROM activity_groups WHERE slug = ?",
        ["An option from before the upgrade", now, now, "preupgrade"])
    end)' >/dev/null 2>&1 || fail "could not insert a group and an option on the rolled-back schema"
  echo "PASS  inserted a group and an option on the pre-upgrade schema"
fi

run_one consensus-upgrade-2 4012 || fail "second boot never became healthy"
echo "PASS  second boot healthy on the same volume"

docker logs consensus-upgrade-2 2>&1 | grep -q "== Migrated" \
  || fail "second boot logged no '== Migrated' line — the pending migration did not run"
echo "PASS  second boot ran the pending migration"

[ "$(rpc_int consensus-upgrade-2 'IO.puts(Consensus.Accounts.count_admins())')" = "1" ] \
  || fail "second boot did not leave exactly one admin"
echo "PASS  still exactly one admin after the upgrade"

# `get_by!`, not an `Ecto.Query.from` — inside `bin/consensus rpc` there is no
# `import Ecto.Query`, so `from(u in User, ...)` expands `in` to `Kernel.in/2` and the
# whole expression fails to compile. That looked exactly like lost data the first time.
name=$(docker exec consensus-upgrade-2 /app/bin/consensus rpc \
  'IO.puts("NAME=" <> Consensus.Repo.get_by!(Consensus.Accounts.User, is_admin: true).username)' \
  2>/dev/null | tr -d '\r' | sed -n 's/^NAME=//p' | tail -1)
[ "$name" = "renamed_operator" ] \
  || fail "the admin is now '$name', not 'renamed_operator' — the seeds re-ran or the data was lost"
echo "PASS  the renamed admin survived the upgrade: $name"

# Whatever migration just ran: nothing orphaned, and enforcement still on in the running
# app — a `PRAGMA foreign_keys = OFF` rebuild would fail these two. When that migration is
# D-058's, which wipes every group by cascade inside the DDL transaction, the pre-upgrade
# group and option must also be gone.
wipe=$(docker exec consensus-upgrade-2 /app/bin/consensus rpc '
  rows = fn sql -> Consensus.Repo.query!(sql).rows end
  [[groups]] = rows.("SELECT count(*) FROM activity_groups")
  [[activities]] = rows.("SELECT count(*) FROM activities")
  orphans = length(rows.("PRAGMA foreign_key_check"))
  [[fk]] = rows.("PRAGMA foreign_keys")
  IO.puts("WIPE=#{groups},#{activities},#{orphans},#{fk}")' \
  2>/dev/null | tr -d '\r' | sed -n 's/^WIPE=//p' | tail -1)
[ -n "$wipe" ] && [ "${wipe#*,*,}" = "0,1" ] \
  || fail "after the upgrade groups,activities,foreign_key_check rows,foreign_keys = '$wipe', expected ?,?,0,1"
echo "PASS  nothing orphaned, foreign keys on"

if [ "$last" = "$D058" ]; then
  [ "$wipe" = "0,0,0,1" ] \
    || fail "after the upgrade groups,activities,foreign_key_check rows,foreign_keys = '$wipe', expected 0,0,0,1"
  echo "PASS  the pre-upgrade group and option are gone"
fi

cleanup
docker volume rm consensus-upgrade >/dev/null 2>&1
echo
echo "UPGRADE REHEARSAL PASSED"
