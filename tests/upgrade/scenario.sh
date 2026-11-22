#!/usr/bin/env bash
# Runs INSIDE the test container after the BASELINE install.sh (see tests/upgrade/run.sh).
#   1. baseline: production profile + one WordPress site + seeded data
#   2. upgrade to /root/cecp-panel (this checkout) following CHANGELOG "Nâng cấp từ …"
#   3. after: site answers 200, security check 0 FAIL, status OK, site data unchanged
# Env: FROM (baseline version), TO (checkout version). Exit code = number of failures.
set -uo pipefail

PASS=0
FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() {
  local desc="$1"
  shift
  if "$@" >/tmp/up-last.log 2>&1; then
    ok "$desc"
  else
    bad "$desc"
    tail -25 /tmp/up-last.log | sed 's/^/        /'
  fi
}
# A baseline step that must work, or nothing after it means anything.
gate() { [[ "$FAIL" == 0 ]] || { echo "  ABORT baseline not usable — upgrade not attempted"; finish; }; }
finish() {
  echo ""
  echo "RESULT ($FROM -> $TO): $PASS passed, $FAIL failed"
  exit "$FAIL"
}

: "${FROM:?FROM not set}" "${TO:?TO not set}"
D="upgrade.test"
META="/var/lib/cecp-panel/sites/$D.json"
SNAP=/root/upgrade-snapshot
grep -q " $D\$" /etc/hosts || echo "127.0.0.1 $D" >>/etc/hosts

meta_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$META" "$1"; }
status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# nginx/php-fpm reloads are asynchronous: allow a few seconds for new workers.
serves_wp() {
  for _ in 1 2 3 4 5; do
    [[ "$(status_of "http://$D/")" == 200 ]] && curl -s "http://$D/" | grep -q 'wp-content' && return 0
    sleep 1
  done
  return 1
}
panel_json_version() { python3 -c 'import json; print(json.load(open("/etc/cecp-panel/panel.json"))["version"])'; }

# --- CHANGELOG "Nâng cấp từ …" as commands, per baseline -------------------------------------
# Every path ends on `update panel latest` (one jump to the newest bundle) followed by the
# post-upgrade commands the CHANGELOG sections between FROM and TO ask for.
# The update source is the test mirror below instead of GitHub raw (CHANGELOG 1.12.1+:
# GitHub is the default source; `update mirror` overrides it) — the code under test is local.
upgrade_steps() {
  case "$1" in
    1.12.1-beta)  # 1.13.0 "Nâng cấp từ 1.12.1" + 1.13.1 "Nâng cấp từ 1.13.0-beta"
      echo "update panel latest"
      echo "site probe --all"
      echo "security check"
      ;;
    1.13.0-beta)  # 1.13.1 "Nâng cấp từ 1.13.0-beta"
      echo "update panel latest"
      echo "site probe --all"
      echo "security check"
      ;;
    *) return 1 ;;
  esac
}

echo "=== Baseline $FROM ==="
check "baseline CLI reports $FROM" bash -c "cecp-panel help | head -1 | grep -qF '$FROM'"
check "baseline panel.json records $FROM" test "$(panel_json_version)" = "$FROM"
check "upgrade path $FROM -> $TO is described in this test (CHANGELOG)" upgrade_steps "$FROM"
check "baseline apply-production" cecp-panel security apply-production
check "baseline site add --wp $D" cecp-panel site add "$D" --wp
SU="$(meta_of site_user)"
DOCROOT="/home/$SU/public_html"
wp_d() { runuser -u "$SU" -- php /usr/local/bin/wp --path="$DOCROOT" "$@"; }
check "baseline site serves WordPress" serves_wp
gate
# A failing baseline security check is not this test's subject; print it for the record.
echo "  INFO  baseline security check: $(cecp-panel security check 2>&1 | grep -E '^RESULT:' || echo 'no RESULT line')"

echo "=== Seed site data ==="
mkdir -p "$SNAP"
MARK="cecp-upgrade-$(date +%s)-$RANDOM"
seed() {
  local pid
  pid="$(wp_d post create --post_type=post --post_status=publish --post_title="Upgrade $MARK" \
    --post_content="Body $MARK" --porcelain)" || return 1
  echo "$pid" >"$SNAP/post_id"
  wp_d option add cecp_upgrade_marker "$MARK" || return 1
  runuser -u "$SU" -- mkdir -p "$DOCROOT/wp-content/uploads/cecp-upgrade" || return 1
  runuser -u "$SU" -- bash -c "head -c 65536 /dev/urandom >'$DOCROOT/wp-content/uploads/cecp-upgrade/blob.bin'" || return 1
  echo "$MARK" >"$SNAP/mark"
}
check "seed: post, option, uploaded file" seed
gate
snapshot() {
  # Content that must survive the upgrade byte for byte: site files (minus caches), the site's
  # rows, its vhost/pool/meta, panel secrets. Mutable WordPress state (cron, transients) is left out.
  (cd "$DOCROOT" && find . -type f ! -path './wp-content/cache/*' -print0 | sort -z | xargs -0 sha256sum) >"$1.files"
  find "$DOCROOT" -printf '%P %u:%g %m\n' | grep -v '^wp-content/cache' | sort >"$1.perms"
  wp_d post get "$(cat "$SNAP/post_id")" --fields=ID,post_title,post_content,post_status --format=json >"$1.post"
  wp_d option get cecp_upgrade_marker >"$1.option"
  wp_d db query "SELECT COUNT(*) FROM $(wp_d db prefix)posts WHERE post_status='publish'" --skip-column-names >"$1.posts"
  wp_d user list --fields=ID,user_login,user_email --format=csv >"$1.users"
  python3 - "$META" >"$1.meta" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# Identity of the site: must not change. New keys added by the new version are allowed.
for k in sorted(d):
    if k in ("site_user", "db_name", "db_user", "db_pass", "wp_admin_user", "wp_admin_pass", "php_version", "domain"):
        print(k, d[k])
PY
  # Panel settings: panel.env minus the mirror line this test sets; every other env file whole.
  { grep -v '^CECP_PANEL_RAW_BASE=' /etc/cecp-panel/panel.env | sha256sum
    find /etc/cecp-panel -maxdepth 1 -name '*.env' ! -name panel.env -print0 | sort -z | xargs -0r sha256sum
  } >"$1.etc"
}
check "snapshot before upgrade" snapshot "$SNAP/before"

echo "=== Upgrade $FROM -> $TO (CHANGELOG) ==="
# Customer bundle from the checkout, laid out like dist/ on GitHub (build-release.sh excludes tests/).
MIRROR=/root/upgrade-mirror
rm -rf "$MIRROR" && mkdir -p "$MIRROR/dist"
tar -C /root --exclude=cecp-panel/tests --exclude=cecp-panel/dist --exclude=cecp-panel/.git \
  --exclude='cecp-panel/etc/credentials.env' -czf "$MIRROR/dist/cecp-panel-${TO}.tar.gz" cecp-panel
cp "$MIRROR/dist/cecp-panel-${TO}.tar.gz" "$MIRROR/dist/cecp-panel-latest.tar.gz"
(cd "$MIRROR/dist" && sha256sum "cecp-panel-${TO}.tar.gz" cecp-panel-latest.tar.gz >SHA256SUMS)
PREV_UPDATE_SH=/root/upgrade-snapshot/update.sh.before
cp /opt/cecp-panel/lib/update.sh "$PREV_UPDATE_SH"
check "point the panel at the test mirror" cecp-panel update mirror "file://$MIRROR"
while IFS= read -r step; do
  [[ -n "$step" ]] || continue
  read -r -a argv <<<"$step"
  check "cecp-panel $step" cecp-panel "${argv[@]}"
done < <(upgrade_steps "$FROM" || true)

echo "=== After upgrade ==="
check "CLI reports $TO" bash -c "cecp-panel help | head -1 | grep -qF '$TO'"
check "installed lib/common.sh is $TO" grep -qF "CECP_PANEL_VERSION:-${TO}}" /opt/cecp-panel/lib/common.sh
# The OLD code runs `update panel`: before 1.13.1 it wrote "latest" into panel.json (CHANGELOG
# 1.13.1: fixed on the next update). Accept that only for such baselines.
panel_json_ok() {
  local v
  v="$(panel_json_version)"
  [[ "$v" == "$TO" ]] && return 0
  [[ "$v" == latest ]] && ! grep -q 'installed_ver=' "$PREV_UPDATE_SH" && { echo "  NOTE  panel.json says 'latest' (baseline updater predates 1.13.1)"; return 0; }
  echo "panel.json version: $v"; return 1
}
check "panel.json records $TO (or 'latest' from a pre-1.13.1 updater)" panel_json_ok
echo "  INFO  panel.json version after upgrade: $(panel_json_version)"
prev_backup_ok() {
  local b
  b="$(python3 -c 'import json; print(json.load(open("/etc/cecp-panel/panel.json")).get("previous_backup",""))')"
  [[ -n "$b" ]] && grep -qF "CECP_PANEL_VERSION:-${FROM}}" "$b/opt-cecp-panel/lib/common.sh"
}
check "previous panel ($FROM) kept as a backup" prev_backup_ok
check "installed panel has no tests/" test ! -e /opt/cecp-panel/tests
check "site answers 200 with WordPress" serves_wp
check "wp-login.php answers 200" test "$(status_of "http://$D/wp-login.php")" = 200
# ?p=ID 301s to the permalink: follow it (same host), the query string keeps it off the cache.
check "uncached page answers 200" test "$(status_of -L --max-redirs 3 "http://$D/?p=$(cat "$SNAP/post_id")&cecp_up=$RANDOM")" = 200
check "seeded post is served" bash -c "curl -sL --max-redirs 3 'http://$D/?p=$(cat "$SNAP/post_id")&cecp_up=$RANDOM' | grep -qF '$(cat "$SNAP/mark")'"
check "site probe --all: every site verified (exit 0)" cecp-panel site probe --all
check "security check: 0 FAIL" bash -c "cecp-panel security check >/tmp/up-sec.log 2>&1; rc=\$?; cat /tmp/up-sec.log; [ \$rc = 0 ] && ! grep -q '^  \[FAIL\]' /tmp/up-sec.log && grep -qE '^RESULT: .*, 0 fail' /tmp/up-sec.log"
check "status runs" cecp-panel status
status_json_ok() {
  cecp-panel status --json >/tmp/up-status.json || return 1
  python3 - "$D" /tmp/up-status.json <<'PY'
import json, sys
dom, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
assert dom in d["domains_hosted"], d["domains_hosted"]
svc = d["services"]
need = ["nginx", "mariadb", "php-fpm"] + [k for k in svc if "php-fpm" in k]
assert all(svc.get(k) == "active" for k in need), svc
s = next(x for x in d["sites"] if x["domain"] == dom)
assert s["disk_mb"] and s["db_mb"] is not None, s
PY
}
check "status --json: nginx/mariadb/PHP-FPM units active, site listed" status_json_ok
check "nginx -t" nginx -t

echo "=== Site data unchanged ==="
check "snapshot after upgrade" snapshot "$SNAP/after"
for part in files perms post option posts users meta etc; do
  check "unchanged: $part" diff -u "$SNAP/before.$part" "$SNAP/after.$part"
done
check "WordPress DB tables check clean" wp_d db check

finish
