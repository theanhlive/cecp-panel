#!/usr/bin/env bash
# Offline tests of the site probe's verdicts and log attribution (lib/probe.sh).
# Pure bash: no root, no Docker, no network. A stub `curl` first in PATH answers from a table and
# every log lives in a temp dir. Prints a final line "RESULT: N passed, M failed".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/nginx" "$TMP/poollogs" "$TMP/conf" "$TMP/panel" "$TMP/site_a"
export CURL_TABLE="$TMP/curl.table"

# Stub curl: the last argument is the URL; the table has lines "PATH|CODE REDIRECT_URL".
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
rest="${url#*://}"
p="/${rest#*/}"
while IFS='|' read -r tp out; do
  if [[ "$tp" == "$p" ]]; then echo -n "$out"; exit 0; fi
done <"$CURL_TABLE"
echo -n "000 "
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

export PROBE_NGINX_LOG_DIR="$TMP/nginx"
export PROBE_POOL_LOG_GLOBS="$TMP/poollogs/*.log"
export PROBE_POOL_CONF_DIR="$TMP/conf"
# shellcheck disable=SC2034  # read by lib/probe.sh
CECP_PANEL_VERSION="test"
# shellcheck disable=SC2034
SITES_DIR="$TMP/panel"
# shellcheck disable=SC2034
LOG_DIR="$TMP/panel-log"
DOM="a.test"
DISABLED_LIST="exec,system,putenv"

# shellcheck source=../lib/probe.sh
source "$ROOT/lib/probe.sh"

# Stubs for the panel helpers probe.sh uses.
site_json_get_or() {
  case "$2" in
    wordpress) echo true ;;
    docroot) echo "$TMP/site_a" ;;
    site_user) echo site_a ;;
    *) echo "${3:-}" ;;
  esac
}
php_cfg_disable_functions() { echo "$DISABLED_LIST"; }
domain_slug() { echo "${1//./_}"; }
rand_alnum() { echo abcdefghijkl; }
panel_die() { echo "die: $*" >&2; return 1; }
probe_domains() { echo "$DOM"; }

PASSED=0
FAILED=0
t_ok() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
t_bad() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }
assert() { # assert DESC COMMAND...
  local d="$1"
  shift
  if "$@"; then t_ok "$d"; else t_bad "$d"; fi
}
has() { grep -qE -- "$1" <<<"$OUT"; }
lacks() { ! grep -qE -- "$1" <<<"$OUT"; }

now_stamp() { date '+%Y/%m/%d %H:%M:%S'; }
old_stamp() { date -d '1 hour ago' '+%Y/%m/%d %H:%M:%S'; }
reset_env() {
  : >"$TMP/nginx/${DOM}-error.log"
  : >"$TMP/poollogs/pool.log"
  DISABLED_LIST="exec,system,putenv"
}
run_probe() { RC=0; OUT="$(probe_site "$DOM" 2>&1)" || RC=$?; }

all_ok_table() {
  printf '%s\n' '/wp-login.php|200 ' '/wp-json/|200 ' '/?cecp_probe=abcdefghijkl|200 ' >"$CURL_TABLE"
}

echo "=== probe verdicts ==="
reset_env
: >"$CURL_TABLE"
run_probe
assert "000 on every URL is never PASS" lacks '^PASS '
assert "000 on every URL is WARN (unverified)" has '^WARN '
assert "unverified-only exit code is 3" test "$RC" = 3

all_ok_table
run_probe
assert "all 200 -> exit 0" test "$RC" = 0
assert "all 200 -> three PASS lines" test "$(grep -c '^PASS ' <<<"$OUT")" = 3

printf '%s\n' '/wp-login.php|302 https://a.test/login/' '/login/|500 ' '/wp-json/|200 ' '/?cecp_probe=abcdefghijkl|200 ' >"$CURL_TABLE"
run_probe
assert "redirect to a 500 is FAIL" has '^FAIL a.test /wp-login.php HTTP 500'
assert "FAIL exit code is 2" test "$RC" = 2

printf '%s\n' '/wp-login.php|302 https://elsewhere.example/x' '/wp-json/|200 ' '/?cecp_probe=abcdefghijkl|200 ' >"$CURL_TABLE"
run_probe
assert "redirect leaving the site is WARN, not PASS" has '^WARN a.test /wp-login.php'
assert "off-site redirect exit code is 3" test "$RC" = 3

printf '%s\n' '/wp-login.php|403 ' '/wp-json/|200 ' '/?cecp_probe=abcdefghijkl|200 ' >"$CURL_TABLE"
run_probe
assert "403 before PHP is WARN" has '^WARN a.test /wp-login.php HTTP 403'

printf '%s\n' '/wp-login.php|302 /a/' '/a/|302 /b/' '/b/|302 /c/' '/c/|302 /d/' '/d/|200 ' '/wp-json/|200 ' '/?cecp_probe=abcdefghijkl|200 ' >"$CURL_TABLE"
run_probe
assert "more than 3 redirects is WARN" has '^WARN a.test /wp-login.php'

echo "=== log attribution ==="
printf '%s\n' '/wp-login.php|500 ' '/wp-json/|500 ' '/?cecp_probe=abcdefghijkl|200 ' >"$CURL_TABLE"
THEME="$TMP/site_a/theme-functions.php"
echo '<?php' >"$THEME"

reset_env
echo "$(now_stamp) [error] 1#1: *1 FastCGI sent in stderr: \"PHP message: PHP Warning:  require($THEME): Failed to open stream: Permission denied in $TMP/site_a/index.php on line 3\" while reading response header, host: a.test" >"$TMP/nginx/${DOM}-error.log"
run_probe
assert "permission-denied log prints the unreadable path" has "$THEME"
assert "permission-denied log gives the chown remedy" has 'chown site_a:site_a .*theme-functions.php'
assert "permission-denied log mentions harden-docroot" has 'cecp-panel security harden-docroot a.test'
assert "permission-denied log never suggests allow_putenv" lacks 'allow_putenv'
assert "permission-denied log shows the pool user" has 'pool user site_a'

reset_env
echo "$(now_stamp) [error] 1#1: PHP Fatal error:  Uncaught Error: Failed opening required '$THEME' (include_path='.') in $TMP/site_a/index.php" >"$TMP/nginx/${DOM}-error.log"
run_probe
assert "'Failed opening required' is recognised" has 'chown site_a:site_a .*theme-functions.php'

reset_env
echo "[$(date '+%d-%b-%Y %H:%M:%S')] WARNING: [pool b_test] child 9 said into stderr: \"PHP message: putenv() has been disabled for security reasons in /home/site_b/public_html/wp-content/plugins/woocommerce/x.php\"" >"$TMP/poollogs/pool.log"
run_probe
assert "another site's putenv line in a shared log is not attributed" lacks 'putenv'
assert "no cause -> says so instead of guessing" has "cause not found in this site's log: cecp-panel log nginx a.test"

reset_env
echo "$(now_stamp) [error] 1#1: *1 FastCGI sent in stderr: \"PHP message: PHP Warning:  putenv() has been disabled for security reasons in $TMP/site_a/x.php\" host: a.test" >"$TMP/nginx/${DOM}-error.log"
run_probe
assert "putenv log + pool disables putenv -> allow_putenv remedy" has 'cecp-panel php config a.test allow_putenv=on'

DISABLED_LIST="exec,system"
run_probe
assert "putenv log but the pool allows it -> no allow_putenv remedy" lacks 'allow_putenv=on'
DISABLED_LIST="exec,system,putenv"

reset_env
echo "$(old_stamp) [error] 1#1: *1 FastCGI sent in stderr: \"PHP message: PHP Warning:  putenv() has been disabled for security reasons\" host: a.test" >"$TMP/nginx/${DOM}-error.log"
run_probe
assert "a putenv line from an hour ago is not attributed" lacks 'allow_putenv'

reset_env
echo "$(now_stamp) [error] 1#1: PHP Fatal error:  Allowed memory size of 134217728 bytes exhausted in $TMP/site_a/x.php host: a.test" >"$TMP/nginx/${DOM}-error.log"
run_probe
assert "memory exhaustion -> memory_limit remedy" has 'cecp-panel php config a.test memory_limit=512M'

reset_env
echo "$(now_stamp) [error] 1#1: PHP message: PHP Warning:  file_get_contents(): open_basedir restriction in effect. File(/etc/passwd) is not within the allowed path(s): (/home/site_a/:/tmp) host: a.test" >"$TMP/nginx/${DOM}-error.log"
run_probe
assert "open_basedir -> shows the path" has 'File\(/etc/passwd\)'
assert "open_basedir -> shows the allowed paths" has '/home/site_a/'

echo "=== summary wording ==="
: >"$CURL_TABLE"
reset_env
OUT="$(site_probe --all --summary 2>&1)" || true
assert "summary of an unverified site never says OK" lacks 'OK'
assert "summary counts verified/unverified/failed" has 'Probe: 0 verified, 1 unverified, 0 FAILED'
OUT="$(probe_post_summary 2>&1)"
RC=$?
assert "post-upgrade wrapper never fails" test "$RC" = 0
all_ok_table
OUT="$(site_probe --all --summary 2>&1)" || true
assert "summary of a verified site" has 'Probe: 1 verified, 0 unverified, 0 FAILED'

# ---------------------------------------------------------------------------------------------------------------
# optimize loadtest monitor (lib/loadtest.sh). Each scenario runs the real monitor in a subshell; the scenarios run
# in parallel (each takes 12-20 s of wall clock). Test-only hooks, none of them set in production:
#   CECP_LOADTEST_SWAP_FIXTURE=FILE  cumulative "pswpin pswpout" lines (one per sample) instead of /proc/vmstat
#   CECP_LOADTEST_JOURNALCTL=FILE    shell script run via bash instead of journalctl; it sees journalctl's arguments
#   CECP_LOADTEST_ACCESS_LOG=FILE    access log read instead of /var/log/nginx/DOMAIN-access.log
# ---------------------------------------------------------------------------------------------------------------
echo "=== loadtest monitor ==="
MON="$TMP/mon"
mkdir -p "$MON/iso"
wpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Journal stubs: arguments arrive as "$@" (-k for the kernel query, _SYSTEMD_UNIT=cecp-php-fpm@... for isolated pools).
printf '#!/bin/bash\nexit 0\n' >"$MON/j-clean.sh"
printf '#!/bin/bash\nexit 1\n' >"$MON/j-empty.sh"
printf '#!/bin/bash\necho "-- No entries --" >&2\nexit 1\n' >"$MON/j-noentries.sh"
printf '#!/bin/bash\necho "Failed to open journal: Input/output error" >&2\nexit 1\n' >"$MON/j-ioerr.sh"
cat >"$MON/j-sat.sh" <<'EOF'
#!/bin/bash
# Only the isolated-pool query (SYSLOG_IDENTIFIER=cecp-php-fpm-a_test) carries the saturation warning.
if [[ "$*" == *SYSLOG_IDENTIFIER=cecp-php-fpm-a_test* && "$*" != *--after-cursor* ]]; then
  echo "WARNING: [pool a_test] server reached pm.max_children setting (5), consider raising it"
  echo "-- cursor: s=1;i=1"
  exit 0
fi
exit 0
EOF
cat >"$MON/j-isobroken.sh" <<'EOF'
#!/bin/bash
[[ "$*" == *cecp-php-fpm@* ]] && exit 2
exit 0
EOF

# Isolated pool of the test domain, as lib/limits.sh writes it.
printf '; CECP Panel pool — %s (isolated)\n[a_test]\npm.max_children = 5\n' "$DOM" >"$MON/iso/a_test.pool.conf"

access_line() { printf '1.2.3.4 - - [10/Oct/2026:00:00:00 +0000] "GET / HTTP/1.1" %s 100 "-" "k6"\n' "$1"; }
# write_log FILE CODE COUNT
write_log() { local i; for ((i = 0; i < $3; i++)); do access_line "$2"; done >>"$1"; }

# mon NAME DURATION INTERVAL — env for the run comes from the caller's MON_* variables.
mon() {
  local name="$1" dur="$2" itv="$3"
  (
    # shellcheck source=../lib/loadtest.sh
    source "$ROOT/lib/loadtest.sh"
    set +e
    # shellcheck disable=SC2034  # read by loadtest_monitor
    LOADTEST_DIR="$MON/$name.d"
    # shellcheck disable=SC2034
    FPM_ISOLATED_DIR="$(wpath "$MON/${MON_ISO:-none}")"
    loadtest_require_site() { :; }
    validate_int_range() { :; }
    panel_local_ipv4() { echo 127.0.0.1; }
    CECP_LOADTEST_JOURNALCTL="$(wpath "$MON/${MON_JOURNAL:-j-clean.sh}")"
    CECP_LOADTEST_ACCESS_LOG="$(wpath "$MON/$name.access.log")"
    export CECP_LOADTEST_JOURNALCTL CECP_LOADTEST_ACCESS_LOG
    if [[ -n "${MON_SWAP:-}" ]]; then
      CECP_LOADTEST_SWAP_FIXTURE="$(wpath "$MON/$MON_SWAP")"
      export CECP_LOADTEST_SWAP_FIXTURE
    fi
    loadtest_monitor "$DOM" --duration "$dur" --interval "$itv"
  ) >"$MON/$name.out" 2>&1
  echo $? >"$MON/$name.rc"
}
mon_has() { grep -qE -- "$2" "$MON/$1.out"; }
mon_lacks() { ! grep -qE -- "$2" "$MON/$1.out"; }
mon_rc() { [[ "$(cat "$MON/$1.rc" 2>/dev/null)" == "$2" ]]; }

# Swap fixtures: cumulative pswpin per sample (the first line is the baseline read before sample 1).
{ echo "0 0"; echo "3000 0"; echo "3001 0"; for _ in $(seq 1 12); do echo "3002 0"; done; } >"$MON/swap-burst.txt"
for n in $(seq 0 12); do echo "$((n * 300)) 0"; done >"$MON/swap-sustained.txt"

# Scenarios that need traffic get their access log written once the monitor has opened it: the monitor opens the
# access log before it creates its CSV, so wait (up to 30 s) for the CSV, then 0.5 s more. A fixed delay raced the
# start-up of nine monitors in parallel and the lines landed before the log was opened (seeked past, never counted).
for n in j-ioerr j-empty j-noentries throttled burst sustained rotate iso-sat iso-broken; do : >"$MON/$n.access.log"; done
wait_monitor() {
  local i
  for ((i = 0; i < 300; i++)); do
    compgen -G "$MON/$1.d/*.csv" >/dev/null && break
    sleep 0.1
  done
  sleep 0.5
}
write_later() { wait_monitor "$1"; write_log "$MON/$1.access.log" "$2" "$3"; }

MON_JOURNAL=j-ioerr.sh mon j-ioerr 12 2 &
MON_JOURNAL=j-empty.sh mon j-empty 12 2 &
MON_JOURNAL=j-noentries.sh mon j-noentries 12 2 &
write_later throttled 429 100 &
mon throttled 12 2 &
write_later burst 200 50 &
MON_SWAP=swap-burst.txt mon burst 20 2 &
write_later sustained 200 50 &
MON_SWAP=swap-sustained.txt mon sustained 20 2 &
write_later iso-sat 200 50 &
MON_ISO=iso MON_JOURNAL=j-sat.sh mon iso-sat 12 2 &
write_later iso-broken 200 50 &
MON_ISO=iso MON_JOURNAL=j-isobroken.sh mon iso-broken 12 2 &
# Rotation (Linux only: an open file cannot be renamed on Windows). 5 old lines exist at start; 0.5 s later 2 more
# lines land in the OLD file (once the monitor has it open), it is renamed and a NEW file with 7 lines appears: all 9 must be counted. A monitor
# that seeks the new file to the old offset (5 lines) would lose its first 5 lines.
if [[ "$(uname -s)" == Linux ]]; then
  write_log "$MON/rotate.access.log" 200 5
  (
    wait_monitor rotate
    write_log "$MON/rotate.access.log" 200 2
    mv "$MON/rotate.access.log" "$MON/rotate.access.log.1"
    write_log "$MON/rotate.access.log" 200 7
  ) &
  mon rotate 12 2 &
fi
wait

assert "journal exit 1 + stderr error -> OOM check unavailable" mon_has j-ioerr 'OOM check unavailable'
assert "journal exit 1 + stderr error -> INCONCLUSIVE exit 3" mon_rc j-ioerr 3
assert "journal exit 1, empty stderr -> no entries, OOM check available" mon_lacks j-empty 'OOM check unavailable'
assert "journal exit 1, 'No entries' on stderr -> no entries, OOM check available" mon_lacks j-noentries 'OOM check unavailable'
assert "all requests 429 -> INCONCLUSIVE exit 3" mon_rc throttled 3
assert "all requests 429 -> says throttled, capacity not measured" mon_has throttled 'throttled by limit_req/Cloudflare: capacity not measured'
assert "all requests 429 -> never PASS" mon_lacks throttled '^PASS loadtest'
assert "swap [3000,1,1] burst is not FAIL" mon_lacks burst 'FAIL loadtest'
assert "swap burst prints the burst note" mon_has burst 'burst'
assert "sustained swap (300 pages per 2 s sample) -> FAIL exit 2" mon_rc sustained 2
assert "sustained swap -> swap-in message" mon_has sustained 'FAIL loadtest — swap-in kéo dài'
assert "isolated pool warning via syslog identifier -> FAIL pm.max_children" mon_has iso-sat 'FAIL loadtest — PHP-FPM pool của site chạm pm.max_children'
assert "isolated pool journal unreadable -> saturation telemetry unavailable" mon_has iso-broken 'Saturation telemetry unavailable'
assert "isolated pool journal unreadable -> INCONCLUSIVE exit 3, not PASS" mon_rc iso-broken 3
if [[ "$(uname -s)" == Linux ]]; then
  ROT_SUM="$(awk -F, 'NR > 1 { s += $10 } END { print s + 0 }' "$MON"/rotate.d/*.csv)"
  assert "rotation: old-handle tail + whole new file counted (9 requests)" test "$ROT_SUM" = 9
else
  echo "  SKIP  rotation scenario (needs Linux: a renamed open file)"
fi

echo
echo "RESULT: ${PASSED} passed, ${FAILED} failed"
[[ "$FAILED" == 0 ]]
