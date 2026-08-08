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

cleanup
docker volume rm consensus-upgrade >/dev/null 2>&1
echo
echo "UPGRADE REHEARSAL PASSED"
