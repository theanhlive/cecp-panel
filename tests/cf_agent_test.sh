#!/usr/bin/env bash
# Offline test for tools/cf-agent.sh against tests/integration/mock_cf.py (no real Cloudflare call).
# Proves: the token never shows in output or in curl's argv, read-only commands make no write
# call, gated actions are refused without their approval flag, and the approved HTML edge cache
# rule is identical to the one "cecp-panel cf edge-cache" writes (lib/cloudflare.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"

PY="$(command -v python3 || command -v python || true)"
[[ -n "$PY" ]] || { echo "python3 required"; exit 2; }

work="$(mktemp -d)"
mock_pid=""
cleanup() {
  [[ -n "$mock_pid" ]] && kill "$mock_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    pass=$(( pass + 1 ))
    echo "ok   $name"
  else
    fail=$(( fail + 1 ))
    echo "FAIL $name"
  fi
}

port=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  p=$(( 20000 + RANDOM % 20000 ))
  if ! curl -s -m 1 -o /dev/null "http://127.0.0.1:${p}/" 2>/dev/null; then
    port="$p"
    break
  fi
done
[[ -n "$port" ]] || { echo "no free port"; exit 2; }

cat >"$work/fixtures.json" <<'EOF'
{
  "/zones/zone123/settings": {"success": true, "result": [
    {"id": "ssl", "value": "flexible"}, {"id": "always_use_https", "value": "off"},
    {"id": "brotli", "value": "off"}, {"id": "cache_level", "value": "basic"}]},
  "/dns_records": {"success": true, "result": [
    {"id": "rec1", "type": "A", "name": "shop.example.com", "content": "192.0.2.10", "proxied": false},
    {"id": "rec2", "type": "MX", "name": "example.com", "content": "mx.example.com"}]}
}
EOF
: >"$work/mock.log"
"$PY" tests/integration/mock_cf.py "$port" "$work/mock.log" 0.05 "$work/fixtures.json" &
mock_pid=$!
for _ in $(seq 1 50); do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:${port}/zones?probe=1" 2>/dev/null && break
  sleep 0.2
done
: >"$work/mock.log"

# curl shim: records every argv curl gets, then runs the real curl.
real_curl="$(command -v curl)"
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/argv.log"
exec "$real_curl" "\$@"
EOF
chmod +x "$work/bin/curl"
: >"$work/argv.log"

TOKEN="cfAgentTestToken_$(date +%s)_${RANDOM}_x9"
export PATH="$work/bin:$PATH"
export CF_API_BASE="http://127.0.0.1:${port}"
export CF_SNAPSHOT_DIR="$work/snaps"
export CF_API_TOKEN="$TOKEN"
D=shop.example.com
TOOL="$ROOT/tools/cf-agent.sh"

out="$work/out.txt"
: >"$out"
run() {  # run EXPECTED_RC_MODE(ok|fail) ARGS...
  local mode="$1" rc=0
  shift
  bash "$TOOL" "$@" >>"$out" 2>&1 || rc=$?
  if [[ "$mode" == ok ]]; then [[ "$rc" == 0 ]]; else [[ "$rc" != 0 ]]; fi
}
no_writes() { ! grep -qvE '^GET ' "$work/mock.log"; }
token_not_in() { ! grep -qF "$TOKEN" "$1"; }

# --- read-only commands ------------------------------------------------------------------
check "verify exits 0" run ok verify
check "zones exits 0" run ok zones
check "audit exits 0" run ok audit "$D"
check "audit --json is valid JSON" bash -c '"$1" "$2" audit "$3" --json | "$4" -c "import json,sys; json.load(sys.stdin)"' _ bash "$TOOL" "$D" "$PY"
check "audit flags SSL flexible as FAIL" grep -q '^FAIL SSL mode is .flexible.' "$out"
check "audit flags the unproxied web record" grep -q '^WARN A shop.example.com is not proxied' "$out"
check "snapshot exits 0" run ok snapshot "$D"
check "snapshot file written" bash -c 'ls "$1"/*.json >/dev/null 2>&1' _ "$CF_SNAPSHOT_DIR"
check "token was sent as a header" grep -qF "auth=Bearer $TOKEN" "$work/mock.log"
check "default mode: no write call" no_writes

# --- gates -------------------------------------------------------------------------------
check "--ssl-strict without --yes-i-approved exits non-zero" run fail apply "$D" --ssl-strict
check "--html-cache without --yes-i-approved exits non-zero" run fail apply "$D" --html-cache
check "--proxy-record without --allow-dns exits non-zero" run fail apply "$D" --proxy-record "$D"
check "--cache-everything is refused" run fail apply "$D" --cache-everything
check "token as an argument is refused" run fail verify --token "$TOKEN"
check "refused actions made no write call" no_writes

# --- token file instead of env -----------------------------------------------------------
printf '%s\n' "$TOKEN" >"$work/token.txt"
token_file_works() { env -u CF_API_TOKEN CF_API_TOKEN_FILE="$work/token.txt" bash "$TOOL" verify >>"$out" 2>&1; }
no_token_fails() { ! env -u CF_API_TOKEN bash "$TOOL" verify >>"$out" 2>&1; }
check "CF_API_TOKEN_FILE works" token_file_works
check "no token at all exits non-zero" no_token_fails

# --- approved HTML edge cache = same rule as cecp-panel cf edge-cache ---------------------
: >"$work/mock.log"
check "approved --html-cache exits 0" run ok apply "$D" --html-cache --yes-i-approved
check "approved --html-cache wrote the ruleset" grep -q '^PUT .*http_request_cache_settings/entrypoint' "$work/mock.log"
( export ETC_DIR="$work" PANEL_ROOT="$ROOT"
  # shellcheck source=/dev/null
  source "$ROOT/lib/cloudflare.sh"
  printf '%s' '{"success":false,"errors":[{"code":10003}]}' | cf_edge_rules_payload "$D" 3600 ) >"$work/panel.json"
same_rule() {
  "$PY" - "$work/mock.log" "$work/panel.json" "$D" <<'PY'
import json, sys
log, panel, domain = sys.argv[1:4]
desc = "cecp-panel: " + domain
put = [l.split(" body=", 1)[1] for l in open(log, encoding="utf-8")
       if l.startswith("PUT ") and "http_request_cache_settings/entrypoint" in l and " body=" in l]
ours = next(r for r in json.loads(put[-1])["rules"] if r.get("description") == desc)
want = next(r for r in json.load(open(panel, encoding="utf-8"))["rules"] if r.get("description") == desc)
keys = ("description", "expression", "action", "action_parameters", "enabled")
sys.exit(0 if all(ours.get(k) == want.get(k) for k in keys) else 1)
PY
}
check "HTML rule identical to cf edge-cache" same_rule
check "approved --proxy-record exits 0" run ok apply "$D" --proxy-record "$D" --allow-dns
check "approved --proxy-record patched only that record" grep -q '^PATCH /zones/zone123/dns_records/rec1 .*"proxied":true' "$work/mock.log"

# --- rollback ----------------------------------------------------------------------------
first_snap="$(ls "$CF_SNAPSHOT_DIR"/*.json | sort | head -n 1)"
check "rollback exits 0" run ok rollback "$first_snap"

# --- secrets -----------------------------------------------------------------------------
check "token absent from all output" token_not_in "$out"
check "token absent from curl argv" token_not_in "$work/argv.log"
check "curl was actually called" test -s "$work/argv.log"
check "snapshots hold no token" bash -c '! grep -rqF "$1" "$2"' _ "$TOKEN" "$CF_SNAPSHOT_DIR"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
