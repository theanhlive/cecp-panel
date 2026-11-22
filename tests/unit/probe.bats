#!/usr/bin/env bats
# lib/probe.sh: PASS/WARN/FAIL classification, redirect handling and exit codes
# (2 = any FAIL, 3 = only unverified, 0 = all verified). curl is a stub (fixtures/curl).

setup() {
  load helpers
  load_common
  # shellcheck source=../../lib/probe.sh
  source "$CECP_LIB_DIR/probe.sh"
  set +u
  export PATH="$UNIT_DIR/fixtures:$PATH"
  export CURL_TABLE="$T/curl.table" CURL_LOG="$T/curl.log"
  : >"$CURL_TABLE"
  export PROBE_NGINX_LOG_DIR="$T/nginx" PROBE_POOL_LOG_GLOBS="$T/pool/*.log" PROBE_POOL_CONF_DIR="$T/conf"
  mkdir -p "$T/nginx" "$T/pool" "$T/conf"
  # shellcheck disable=SC2034  # read by probe_fetch
  CECP_PANEL_VERSION="test"
  php_cfg_disable_functions() { echo "exec,system"; }
}

table() { printf '%s\n' "$@" >"$CURL_TABLE"; }
site() { # site DOMAIN WORDPRESS(true|false)
  printf '{"domain": "%s", "wordpress": %s, "docroot": "%s/www"}\n' "$1" "$2" "$T" >"$SITES_DIR/$1.json"
}
level() { run probe_level "$@"; [[ "$output" == "$EXPECT" ]] || fail "probe_level $* -> $output, want $EXPECT"; }

# --- probe_level ----------------------------------------------------------
@test "probe_level: 2xx and 3xx are PASS (200 boundary, 399 boundary)" {
  EXPECT=PASS
  local c
  for c in 200 201 204 299 301 302 304 399; do level "$c"; done
}

@test "probe_level: 5xx and above are FAIL (500 boundary)" {
  EXPECT=FAIL
  local c
  for c in 500 502 503 504 599 999; do level "$c"; done
}

@test "probe_level: 4xx (401/403/404/429) is WARN, never PASS" {
  EXPECT=WARN
  local c
  for c in 400 401 403 404 429 499; do level "$c"; done
}

@test "probe_level: 000 (nothing answered) and 1xx/199 are WARN" {
  EXPECT=WARN
  level 000
  level 100
  level 199
}

@test "probe_level: malformed codes are WARN (empty, 2 or 4 digits, text, injection)" {
  EXPECT=WARN
  level ""
  level 20
  level 2000
  level abc
  level '5$(id)'
  level '500;'
  level ' 500'
}

@test "probe_level: a note (offsite/hops) downgrades even a 200 or 500 to WARN" {
  EXPECT=WARN
  level 200 offsite
  level 302 hops
  level 500 offsite
}

@test "probe_level: leading zeros are decimal (010 is not octal 8)" {
  EXPECT=WARN
  level 010
  level 099
}

# --- probe_fetch / probe_request (stub curl) --------------------------------
@test "probe_fetch: HTTPS answer is used, HTTP is not tried" {
  table 'https:/x|200 '
  run probe_fetch a.test /x
  [[ "$output" == "200 " ]] || fail "got '$output'"
  ! grep -q '^http://' "$CURL_LOG"
}

@test "probe_fetch: HTTPS 000 falls back to plain HTTP" {
  table 'http:/x|301 http://a.test/y'
  run probe_fetch a.test /x
  [[ "$output" == "301 http://a.test/y" ]] || fail "got '$output'"
  grep -q '^https://a.test/x' "$CURL_LOG"
  grep -q '^http://a.test/x' "$CURL_LOG"
}

@test "probe_fetch: nothing answering is reported as 000" {
  run probe_fetch a.test /x
  [[ "$output" == "000 " ]] || fail "got '$output'"
}

@test "probe_request: same-host absolute and relative redirects are followed" {
  table '/a|302 https://A.TEST/b' '/b|301 /c' '/c|200 '
  run probe_request a.test /a
  [[ "$output" == "200 /c " ]] || fail "got '$output'"
}

@test "probe_request: a redirect to another host stops with note offsite" {
  table '/a|302 https://evil.example/x'
  run probe_request a.test /a
  [[ "$output" == "302 /a offsite" ]] || fail "got '$output'"
}

@test "probe_request: a look-alike host (a.test.evil) is offsite" {
  table '/a|302 https://a.test.evil/x'
  run probe_request a.test /a
  [[ "$output" == "302 /a offsite" ]] || fail "got '$output'"
}

# (curl's %{redirect_url} is already absolute, so "//host/x" never reaches probe_request.)
@test "probe_request: a non-http(s) Location is offsite" {
  table '/a|302 javascript:alert(1)'
  run probe_request a.test /a
  [[ "$output" == "302 /a offsite" ]] || fail "javascript: got '$output'"
}

@test "probe_request: exactly 3 hops is followed, a 4th is note hops" {
  table '/a|302 /b' '/b|302 /c' '/c|302 /d' '/d|200 '
  run probe_request a.test /a
  [[ "$output" == "200 /d " ]] || fail "3 hops: got '$output'"
  table '/a|302 /b' '/b|302 /c' '/c|302 /d' '/d|302 /e' '/e|200 '
  run probe_request a.test /a
  [[ "$output" == "302 /d hops" ]] || fail "4 hops: got '$output'"
}

@test "probe_request: a redirect loop ends after PROBE_MAX_HOPS" {
  table '/a|302 /a'
  run timeout 10 bash -c 'source "$1/common.sh"; source "$1/probe.sh"; probe_request a.test /a' _ "$CECP_LIB_DIR"
  [[ "$output" == "302 /a hops" ]] || fail "got '$output'"
  [[ "$(wc -l <"$CURL_LOG")" -le 8 ]]
}

@test "probe_request: a 3xx without Location is the final answer" {
  table '/a|304 '
  run probe_request a.test /a
  [[ "$output" == "304 /a " ]] || fail "got '$output'"
}

# --- probe_site exit codes ---------------------------------------------------
@test "probe_site: WordPress site, every URL 200 -> 3 PASS lines, exit 0" {
  site a.test true
  table '/wp-login.php|200 ' '/wp-json/|200 ' '/?cecp_probe=*|200 '
  run probe_site a.test
  assert_status 0
  [[ "$(grep -c '^PASS a.test ' <<<"$output")" -eq 3 ]] || fail "$output"
  assert_output_has "/?cecp_probe=<random>"
}

@test "probe_site: a non-WordPress site probes only the random URL" {
  site b.test false
  table '/?cecp_probe=*|200 '
  run probe_site b.test
  assert_status 0
  [[ "$(grep -c '^PASS' <<<"$output")" -eq 1 ]] || fail "$output"
  [[ "$output" != *wp-login* ]]
}

@test "probe_site: one 500 among PASS -> FAIL line, diagnosis, exit 2" {
  site a.test true
  table '/wp-login.php|200 ' '/wp-json/|500 ' '/?cecp_probe=*|200 '
  run probe_site a.test
  assert_status 2
  assert_output_has "FAIL a.test /wp-json/ HTTP 500"
  assert_output_has "cause not found in this site's log"
}

@test "probe_site: FAIL wins over WARN (403 + 503) -> exit 2" {
  site a.test true
  table '/wp-login.php|403 ' '/wp-json/|503 ' '/?cecp_probe=*|200 '
  run probe_site a.test
  assert_status 2
  assert_output_has "WARN a.test /wp-login.php HTTP 403"
}

@test "probe_site: a WARN after a FAIL does not lower the exit code (500 then 403) -> 2" {
  site a.test true
  table '/wp-login.php|500 ' '/wp-json/|403 ' '/?cecp_probe=*|000 '
  run probe_site a.test
  assert_status 2
  assert_output_has "FAIL a.test /wp-login.php HTTP 500"
  assert_output_has "WARN a.test /wp-json/ HTTP 403"
}

@test "probe_site: only unverified (000 everywhere) -> WARN, exit 3, no PASS" {
  site a.test true
  run probe_site a.test
  assert_status 3
  [[ "$output" != *PASS* ]] || fail "$output"
}

@test "probe_site: an off-site redirect is WARN with the reason, exit 3" {
  site a.test false
  table '/?cecp_probe=*|302 https://elsewhere.example/'
  run probe_site a.test
  assert_status 3
  assert_output_has "redirect leaves the site: unverified"
}

@test "probe_site: a redirect to a 500 is reported as FAIL after redirect" {
  site a.test false
  table '/?cecp_probe=*|302 /broken' '/broken|500 '
  run probe_site a.test
  assert_status 2
  assert_output_has "(after redirect to /broken)"
}

# --- site_probe aggregate ----------------------------------------------------
@test "site_probe --all --summary: counts and worst exit code over sites" {
  site ok.test false
  site bad.test false
  site unv.test false
  probe_fetch() {
    case "$1" in ok.test) echo "200 " ;; bad.test) echo "500 " ;; *) echo "000 " ;; esac
  }
  run site_probe --all --summary
  assert_status 2
  assert_output_has "Probe: 1 verified, 1 unverified, 1 FAILED"
  rm "$SITES_DIR/bad.test.json"
  run site_probe --all --summary
  assert_status 3
  rm "$SITES_DIR/unv.test.json"
  run site_probe --all --summary
  assert_status 0
  assert_output_has "Probe: 1 verified, 0 unverified, 0 FAILED"
}

@test "site_probe: hostile or unknown domain is rejected before any request" {
  run site_probe 'a.test;id'
  assert_status 1
  assert_output_has "Invalid domain"
  run site_probe '../../etc/passwd'
  assert_status 1
  assert_output_has "Invalid domain"
  run site_probe missing.test
  assert_status 1
  assert_output_has "is not a panel site"
  [[ ! -s "$CURL_LOG" ]] || fail "curl was called: $(cat "$CURL_LOG")"
}
