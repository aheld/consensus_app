#!/usr/bin/env bash
# Mirrors the "Boot the release image and smoke test it" step of .github/workflows/ci.yml
# (CLAUDE.md invariant 10). Five assertions, in order.
set -uo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*"; docker logs consensus-smoke 2>&1 | tail -30; exit 1; }

PHX_HOST=$(sed -n "s/^[[:space:]]*PHX_HOST[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" fly.toml)
[ -n "$PHX_HOST" ] || fail "could not read PHX_HOST out of fly.toml"
echo "PHX_HOST from fly.toml: $PHX_HOST"

docker rm -f consensus-smoke >/dev/null 2>&1
docker run -d --name consensus-smoke \
  --tmpfs /data:rw,mode=0750,uid=65534,gid=0 \
  -e SECRET_KEY_BASE="$(head -c 64 /dev/urandom | base64 | tr -d '\n')" \
  -e DATABASE_PATH=/data/consensus.db \
  -e PHX_HOST="$PHX_HOST" \
  -e PORT=4000 \
  -p 4010:4000 \
  consensus:ci >/dev/null || fail "container would not start"

# 1. /health answers 200 ok
for i in $(seq 1 60); do
  body=$(curl -fsS http://127.0.0.1:4010/health 2>/dev/null) && break
  sleep 1
done
[ "$body" = "ok" ] || fail "1/5 /health never answered ok (got: '${body:-nothing}')"
echo "PASS 1/5  /health -> 200 ok"

# 2. /health answers 200 under the deployed hostname. This is the ONLY assertion that
#    proves the force_ssl `paths: ["/health"]` exclusion in config/prod.exs — the poll
#    above used Host: 127.0.0.1, which the sibling `hosts:` exclusion already covers.
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $PHX_HOST" http://127.0.0.1:4010/health)
[ "$code" = "200" ] || fail "2/5 /health under Host: $PHX_HOST returned $code, not 200"
echo "PASS 2/5  /health under Host: $PHX_HOST -> 200"

# 3. A real LiveView websocket handshake returns 101. check_origin defaults to true in
#    prod and validates Origin against PHX_HOST; a mismatch 403s every socket while
#    GET / and /health both keep answering 200. Every page here is a LiveView.
#    The `|| true` is load bearing: a successful upgrade holds the connection open and
#    curl exits 28 on --max-time, having already written the status.
ws=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -H "Host: $PHX_HOST" -H "Origin: https://$PHX_HOST" -H "x-forwarded-proto: https" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://127.0.0.1:4010/live/websocket?vsn=2.0.0" || true)
[ "$ws" = "101" ] || fail "3/5 LiveView websocket handshake returned $ws, not 101"
echo "PASS 3/5  /live/websocket -> 101"

# 4. Seeding ran exactly once.
#    `rpc` on this host prints an "=ESOCK WARNING MSG====" banner ahead of the value —
#    an Erlang/Docker-on-macOS artifact, not the app — so take the last bare-integer line
#    rather than the whole stream. CI runs on Linux and does not emit it.
admins=$(docker exec consensus-smoke /app/bin/consensus rpc 'IO.puts(Consensus.Accounts.count_admins())' 2>/dev/null \
  | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)
[ "$admins" = "1" ] || fail "4/5 count_admins() was '$admins', not 1"
echo "PASS 4/5  count_admins() == 1"

# 5. /health is a real check, not a static 200: break the schema and it must go 503.
docker exec consensus-smoke /app/bin/consensus rpc \
  'Ecto.Adapters.SQL.query!(Consensus.Repo, "ALTER TABLE users RENAME TO users_gone", [])' >/dev/null 2>&1
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4010/health)
[ "$code" = "503" ] || fail "5/5 /health returned $code after the schema was broken, not 503"
echo "PASS 5/5  /health -> 503 with a broken schema"

docker rm -f consensus-smoke >/dev/null 2>&1
echo
echo "SMOKE TEST PASSED — all five assertions"
