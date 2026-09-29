#!/usr/bin/env bash
# Incident tools: cecp-panel security scan | rotate-secrets
# Runbook: docs/INCIDENT_RESPONSE.md
set -euo pipefail

# ---------------------------------------------------------------------------
# cecp-panel security scan [DOMAIN|--all] [--days N]
# Read-only. Looks for web shells / injected code, cross-site writes, persistence (crontabs,
# odd processes, recently changed system cron/systemd/SSH keys) and root-level indicators.
# WordPress checks run with --skip-plugins --skip-themes so infected plugins never execute.
# Exit 1 when something needs a human look.
# ---------------------------------------------------------------------------
SCAN_BAD=0
SCAN_SECTION=""          # "server" or the domain being scanned
SCAN_FAILED=()           # sections with at least one FAIL (used by scan-cron)

_scan() {  # _scan LEVEL MESSAGE [DETAIL_LINES]
  printf '  [%s] %s\n' "$1" "$2"
  [[ -z "${3:-}" ]] || sed 's/^/        /' <<<"$3"
  [[ "$1" == OK || "$1" == INFO ]] || SCAN_BAD=1
  if [[ "$1" == FAIL && -n "$SCAN_SECTION" && " ${SCAN_FAILED[*]} " != *" $SCAN_SECTION "* ]]; then
    SCAN_FAILED+=("$SCAN_SECTION")
  fi
}

security_scan() {
  local target="--all" days=7 f d
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="${2:-}"; shift 2 || true ;;
      --all) target="--all"; shift ;;
      -*) panel_die "Usage: cecp-panel security scan [DOMAIN|--all] [--days N]" ;;
      *) target="${1,,}"; shift ;;
    esac
  done
  validate_int_range "$days" 1 365 "days"
  require_root
  SCAN_BAD=0
  SCAN_FAILED=()
  echo "=== CECP infection scan — $(date -u +%Y-%m-%dT%H:%M:%SZ), changes of the last ${days} day(s) ==="
  security_scan_server "$days"
  if [[ "$target" == "--all" ]]; then
    shopt -s nullglob
    for f in "$SITES_DIR"/*.json; do
      d="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
      security_scan_site "$d" "$days"
    done
    shopt -u nullglob
  else
    validate_domain "$target"
    [[ -f "$(site_meta_path "$target")" ]] || panel_die "Site not found: $target"
    security_scan_site "$target" "$days"
  fi
  echo ""
  if (( SCAN_BAD )); then
    echo "RESULT: indicators found — review the lines above, then follow docs/INCIDENT_RESPONSE.md"
    return 1
  fi
  echo "RESULT: no indicator found (a clean scan is not a proof: keep backups and updates current)"
}

security_scan_server() {
  local days="$1" out u
  SCAN_SECTION="server"
  echo ""
  echo "--- Server ---"
  out="$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd)"
  if [[ -n "$out" ]]; then _scan FAIL "extra accounts with UID 0 (root equivalents)" "$out"; else _scan OK "only root has UID 0"; fi
  if [[ -s /etc/ld.so.preload ]]; then _scan FAIL "/etc/ld.so.preload is set (common rootkit hook)" "$(cat /etc/ld.so.preload)"
  else _scan OK "no /etc/ld.so.preload"; fi
  local -a site_users=()
  mapfile -t site_users < <(awk -F: '$1 ~ /^site_[a-z0-9_]+$/ {print $1}' /etc/passwd)
  # Site users must have no crontab/at job of their own (the panel's jobs live in /etc/cron.d).
  out=""
  for u in "${site_users[@]}"; do
    out+="$(find /var/spool/cron /var/spool/at /var/spool/cron/atjobs -xdev -type f \( -name "$u" -o -user "$u" \) 2>/dev/null || true)"
  done
  if [[ -n "$out" ]]; then _scan FAIL "crontab/at jobs of site users (persistence: re-infects after cleaning)" "$out"; else _scan OK "no site-user crontab/at jobs"; fi
  # Long-running processes of site users that are not PHP-FPM workers (miners, reverse shells).
  out="$(ps -eo user:32,pid,etimes,args --no-headers 2>/dev/null \
    | awk '$1 ~ /^site_/ && $3 > 120 && $4 !~ /^php-fpm/ && $0 !~ /wp-cron\.php/' | head -20)"
  if [[ -n "$out" ]]; then _scan FAIL "processes running as site users outside PHP-FPM" "$out"; else _scan OK "no stray site-user processes"; fi
  out="$(for u in "${site_users[@]}"; do find /tmp /var/tmp /dev/shm -xdev -user "$u" 2>/dev/null; done | head -20 || true)"
  if [[ -n "$out" ]]; then _scan WARN "files of site users in shared temp dirs (droppers are often parked here)" "$out"; else _scan OK "nothing of site users in /tmp, /var/tmp, /dev/shm"; fi
  out="$(find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/crontab /etc/systemd/system \
           /etc/rc.local /etc/profile.d /etc/sudoers.d /root/.ssh /root/.bashrc -xdev -type f -mtime "-${days}" \
           ! -name 'cecp-*' ! -path '*/cecp-php-fpm@*' ! -path '*/cecp-purge@*' 2>/dev/null | head -30 || true)"
  if [[ -n "$out" ]]; then _scan WARN "system startup/cron/SSH files changed in the last ${days}d (not by the panel) — check each" "$out"
  else _scan OK "no recent changes to cron, systemd, sudoers, root SSH keys"; fi
  u="$( { awk '$1 !~ /^#/ && NF' /root/.ssh/authorized_keys 2>/dev/null || true; } | wc -l)"
  _scan INFO "root authorized_keys: ${u} key(s) — make sure you recognise every one (cat /root/.ssh/authorized_keys)"
}

security_scan_site() {
  local domain="$1" days="$2" su docroot out db_name cfg_db x l t n
  su="$(site_json_get "$domain" site_user)"
  docroot="$(site_json_get "$domain" docroot)"
  SCAN_SECTION="$domain"
  echo ""
  echo "--- $domain ($docroot) ---"
  [[ -d "$docroot" ]] || { _scan WARN "docroot missing"; return 0; }

  out="$(find "$docroot/wp-content/uploads" -type f -iregex '.*\.\(php[0-9]*\|phtml\|phar\|pht\|shtml\)\(\.[^/]*\)?$' 2>/dev/null | head -20 || true)"
  if [[ -n "$out" ]]; then _scan FAIL "PHP files inside uploads/ (WordPress never puts code there)" "$out"; else _scan OK "no PHP in uploads/"; fi

  # Written by another account = the infection came from outside this site (or root did it).
  out="$(find "$docroot" \! -user "$su" -printf '%u  %p\n' 2>/dev/null \
    | grep -vE '^root  .*/mu-plugins/cecp-(cache-purge|staging)\.(php|json)$' | head -20 || true)"
  if [[ -n "$out" ]]; then _scan FAIL "files not owned by $su (cross-site / root writes)" "$out"; else _scan OK "every file owned by $su"; fi

  out=""
  while IFS= read -r l; do
    t="$(readlink -f -- "$l" 2>/dev/null || true)"
    [[ "$t" == "$docroot"/* ]] || out+="$l -> ${t:-?}"$'\n'
  done < <(find "$docroot" -type l 2>/dev/null)
  out="${out%$'\n'}"
  if [[ -n "$out" ]]; then _scan FAIL "symlinks leaving the docroot (reading/writing other sites or the system)" "$out"; else _scan OK "no symlink leaves the docroot"; fi

  out="$(grep -rlIE --include='*.php' --include='*.phtml' --include='*.inc' \
    -e 'eval[[:space:]]*\([[:space:]]*(base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|rawurldecode|hex2bin)[[:space:]]*\(' \
    -e 'assert[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)' \
    -e '\$_(POST|GET|REQUEST|COOKIE)\[[^]]*\][[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)' \
    -e "(include|require)(_once)?[[:space:]]*\(?[[:space:]]*['\"][^'\"]*\.(ico|png|jpe?g|gif|txt|log)['\"]" \
    -e '(base64_decode|gzinflate|str_rot13)[[:space:]]*\([[:space:]]*['"'"'"][A-Za-z0-9+/=]{800,}' \
    -e 'FilesMan|b374k|c99shell|r57shell|IndoXploit|0byt3m1n1|AlfaShell|WSO [0-9]\.[0-9]' \
    "$docroot" 2>/dev/null | head -30 || true)"
  if [[ -n "$out" ]]; then _scan FAIL "code patterns typical of web shells / injected loaders — open each file" "$out"
  else _scan OK "no known web-shell / obfuscated-loader patterns"; fi

  out="$(find "$docroot/wp-content/mu-plugins" -maxdepth 1 -type f ! -name 'cecp-*' 2>/dev/null | head -20 || true)"
  if [[ -n "$out" ]]; then _scan WARN "mu-plugins not installed by the panel (always run, invisible in the plugin list) — confirm you added them" "$out"
  else _scan OK "no foreign mu-plugins"; fi

  n="$(find "$docroot" -type f -iname '*.php' -mtime "-${days}" 2>/dev/null | wc -l)"
  if (( n > 0 )); then
    _scan INFO "${n} PHP file(s) changed in the last ${days}d (updates do this too; newest first):" \
      "$(find "$docroot" -type f -iname '*.php' -mtime "-${days}" -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -r | head -15)"
  fi

  if [[ -f "$docroot/wp-config.php" ]]; then
    db_name="$(site_json_get_or "$domain" db_name "")"
    cfg_db="$(sed -nE "s/.*define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/p" "$docroot/wp-config.php" | head -1)"
    if [[ -n "$db_name" && "$cfg_db" != "$db_name" ]]; then
      _scan FAIL "wp-config.php uses database '${cfg_db}', the panel created '${db_name}' (repointed to another site's DB?)"
    else
      _scan OK "wp-config.php points at its own database"
    fi
    x="$(grep -nE "^[[:space:]]*(@?include|@?require)(_once)?[[:space:]]*\(?[[:space:]]*['\"]/" "$docroot/wp-config.php" 2>/dev/null | grep -v 'wp-settings.php' || true)"
    [[ -z "$x" ]] || _scan FAIL "wp-config.php includes files by absolute path" "$x"
  fi

  [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]] || return 0
  # Core, plugins and users, loading neither plugins nor themes (infected code must not run).
  out="$(wp_site_exec "$domain" core verify-checksums --skip-plugins --skip-themes 2>&1 || true)"
  if grep -q '^Success' <<<"$out"; then _scan OK "WordPress core files match wordpress.org checksums"
  elif grep -qiE "doesn't verify|should not exist" <<<"$out"; then _scan FAIL "WordPress core files modified/added" "$(grep -iE "doesn't verify|should not exist" <<<"$out" | head -20)"
  else _scan WARN "could not verify core checksums" "$(tail -2 <<<"$out")"; fi
  out="$(wp_site_exec "$domain" plugin verify-checksums --all --skip-plugins --skip-themes 2>&1 || true)"
  x="$(grep -iE "checksum does not match|File was added|File is missing" <<<"$out" | head -20 || true)"
  if [[ -n "$x" ]]; then _scan FAIL "plugin files differ from wordpress.org (modified or added)" "$x"
  elif grep -qiE '^Error|Failed to get url' <<<"$out"; then _scan WARN "could not verify plugin checksums" "$(tail -2 <<<"$out")"
  else _scan OK "wordpress.org plugins match their checksums (premium/custom plugins cannot be checked)"; fi
  out="$(wp_site_exec "$domain" user list --role=administrator --fields=ID,user_login,user_email,user_registered \
    --format=csv --skip-plugins --skip-themes 2>/dev/null | tail -n +2 || true)"
  x="$(CECP_ADMINS="$out" python3 - "$days" <<'PY'
import datetime, os, sys
days = int(sys.argv[1])
cut = datetime.datetime.utcnow() - datetime.timedelta(days=days)
for line in os.environ["CECP_ADMINS"].splitlines():
    parts = line.rstrip("\n").split(",")
    if len(parts) >= 4:
        try:
            if datetime.datetime.strptime(parts[-1].strip('" ')[:19], "%Y-%m-%d %H:%M:%S") >= cut:
                print(line.rstrip("\n"))
        except ValueError:
            pass
PY
)"
  if [[ -n "$x" ]]; then _scan FAIL "administrator accounts created in the last ${days}d" "$x"; fi
  _scan INFO "administrators: $(wc -l <<<"$out" | tr -d ' ') — every one must be known (cecp-panel wp status $domain)" "$out"
}

# ---------------------------------------------------------------------------
# cecp-panel security rotate-secrets DOMAIN|--all [--admins]
# After a compromise every secret a site could read is burnt: its DB password (in wp-config.php),
# WordPress salts (live login cookies), its Redis ACL password, its SFTP password. --admins also
# gives every WordPress administrator a new password (printed once, never logged).
# ---------------------------------------------------------------------------
security_rotate_secrets() {
  local target="${1:-}" admins=0 f d
  shift || true
  [[ "${1:-}" == "--admins" ]] && admins=1
  [[ -n "$target" ]] || panel_die "Usage: cecp-panel security rotate-secrets DOMAIN|--all [--admins]"
  require_root
  security_audit_log "security rotate-secrets $target"
  if [[ "$target" == "--all" ]]; then
    shopt -s nullglob
    for f in "$SITES_DIR"/*.json; do
      d="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
      security_rotate_site "$d" "$admins"
    done
    shopt -u nullglob
  else
    target="${target,,}"
    validate_domain "$target"
    [[ -f "$(site_meta_path "$target")" ]] || panel_die "Site not found: $target"
    security_rotate_site "$target" "$admins"
  fi
  panel_log "Secrets rotated. Also change: Cloudflare API token, SSH keys/root password, any API keys stored in plugins."
}

security_rotate_site() {
  local domain="$1" admins="$2" su docroot db_user pass id login
  su="$(site_json_get "$domain" site_user)"
  docroot="$(site_json_get "$domain" docroot)"
  panel_log "Rotating secrets of $domain ..."
  if [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" && -f "$docroot/wp-config.php" ]]; then
    db_user="$(site_json_get "$domain" db_user)"
    pass="$(rand_alnum 24)"
    [[ "$db_user" =~ ^[a-z0-9_]+$ ]] || panel_die "unexpected DB user name for $domain"
    mysql <<SQL
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${pass}';
FLUSH PRIVILEGES;
SQL
    site_json_set "$domain" db_pass "$pass"
    site_wp_config_sync "$domain"
    panel_log "  DB password: new (wp-config.php updated)"
    wp_site_exec "$domain" config shuffle-salts --skip-plugins --skip-themes >/dev/null \
      && panel_log "  WordPress salts: new (every login session ended)" \
      || panel_log "  WARN: could not shuffle the WordPress salts of $domain"
  else
    panel_log "  DB password: skipped (not WordPress — change it together with the application's config)"
  fi
  if [[ -n "$(site_json_get_or "$domain" redis_user "")" && -f /etc/cecp-panel/redis.env ]] && redis_supports_acl; then
    site_json_set "$domain" redis_pass ""
    redis_site_acl "$domain"
    redis_wp_config_refresh "$domain"
    panel_log "  Redis ACL password: new"
  fi
  # SFTP: password disabled until the owner sets a new one.
  passwd -l "$su" >/dev/null 2>&1 && panel_log "  SFTP password: disabled — set a new one with: cecp-panel site sftp-password $domain"
  if (( admins )) && [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]]; then
    while read -r id; do
      [[ "$id" =~ ^[0-9]+$ ]] || continue
      pass="$(rand_alnum 20)"
      login="$(wp_site_exec "$domain" user get "$id" --field=user_login --skip-plugins --skip-themes 2>/dev/null)"
      # Password through the environment: argv is visible to every local user.
      CECP_NEWPASS="$pass" site_run_as "$su" php -d memory_limit=512M "$WP_CLI_BIN" --path="$docroot" \
        --skip-plugins --skip-themes eval "wp_set_password(getenv('CECP_NEWPASS'), ${id});" >/dev/null
      [[ "$login" == "$(site_json_get_or "$domain" wp_admin_user "")" ]] && site_json_set "$domain" wp_admin_pass "$pass"
      panel_secret "  $domain administrator ${login}: new password ${pass}"
    done < <(wp_site_exec "$domain" user list --role=administrator --field=ID --skip-plugins --skip-themes 2>/dev/null)
  fi
  optimize_purge_cache "$domain" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Periodic scan: cecp-panel security scan-schedule on [--every 14|30] [--hour H] | off | status
# A daily cron at the quietest hour of this server (from nginx access logs) runs `scan-cron`,
# which only scans when the interval is due and the box is idle (otherwise: tomorrow night).
#   clean     → the latest backup of every site is tagged "scan-clean" (kept by retention: a
#               known-good restore point, the last two per site).
#   infected  → retention is frozen (older = cleaner snapshots are never pruned), an evidence
#               snapshot of the affected sites is taken (tag "scan-suspect"), alert sent.
#   review    → warnings only: alert, nothing frozen.
# Report files: /var/log/cecp-panel/security-scan/. Unfreeze after handling: security scan-ack
# ---------------------------------------------------------------------------
SCAN_STATE="$VAR_LIB/scan-state.json"
SCAN_CRON="/etc/cron.d/cecp-security-scan"
SCAN_REPORT_DIR="$LOG_DIR/security-scan"

scan_state_get() {  # scan_state_get KEY DEFAULT
  python3 - "$SCAN_STATE" "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], sys.argv[3]))
except (OSError, ValueError):
    print(sys.argv[3])
PY
}

scan_state_set() {  # scan_state_set KEY VALUE [KEY VALUE ...]
  python3 - "$SCAN_STATE" "$@" <<'PY'
import json, os, sys
path, kv = sys.argv[1], sys.argv[2:]
try:
    data = json.load(open(path))
except (OSError, ValueError):
    data = {}
data.update(zip(kv[::2], kv[1::2]))
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

# Quietest hour of the day from the last ~2 weeks of nginx access logs (all sites), skipping the
# hours of the panel's own heavy jobs (backup and the hour after it, 03:xx maintenance/media).
# Prints: HOUR REQUESTS_IN_THAT_HOUR DAYS_OF_DATA
security_quiet_hour() {
  local backup_h=2
  if [[ -f "$BACKUP_ENV" ]]; then
    backup_h="$( (secure_source "$BACKUP_ENV" >/dev/null 2>&1; echo "${BACKUP_CRON_HOUR:-2}") )"
  fi
  [[ "$backup_h" =~ ^[0-9]{1,2}$ ]] || backup_h=2
  python3 - "$backup_h,$(( (backup_h + 1) % 24 )),3" <<'PY'
import collections, glob, gzip, os, re, sys, time
avoid = {int(x) for x in sys.argv[1].split(",") if x}
rx = re.compile(r"\[(\d{2}/\w{3}/\d{4}):(\d{2}):")
hours, days = collections.Counter(), set()
for p in glob.glob("/var/log/nginx/*access.log*"):
    try:
        if time.time() - os.path.getmtime(p) > 15 * 86400:
            continue
        opener = gzip.open if p.endswith(".gz") else open
        with opener(p, "rt", errors="replace") as f:
            for n, line in enumerate(f):
                if n > 3_000_000:
                    break
                m = rx.search(line, 0, 200)
                if m:
                    hours[int(m.group(2))] += 1
                    days.add(m.group(1))
    except (OSError, EOFError):
        pass
cands = [h for h in range(24) if h not in avoid]
# Ties (or no logs at all): prefer the small hours after the nightly jobs.
best = min(cands, key=lambda h: (hours[h], (h - 5) % 24))
print(best, hours[best], len(days))
PY
}

security_scan_schedule() {
  local action="${1:-status}" every="" hour="" quiet n days minute=40 nice_cmd
  shift || true
  require_root
  case "$action" in
    on)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --every) every="${2:-}"; shift 2 || true ;;
          --hour) hour="${2:-}"; shift 2 || true ;;
          *) panel_die "Usage: cecp-panel security scan-schedule on [--every 14|30] [--hour 0-23]" ;;
        esac
      done
      every="${every:-$(scan_state_get every 14)}"
      case "${every,,}" in 2w) every=14 ;; 1m) every=30 ;; *d) every="${every%d}" ;; esac
      validate_int_range "$every" 1 90 "--every (days)"
      if [[ -n "$hour" ]]; then
        validate_int_range "$hour" 0 23 "--hour"
        quiet="manual"
      else
        read -r hour n days <<<"$(security_quiet_hour)"
        quiet="auto: ${n} request(s) in that hour over ${days} day(s) of nginx logs"
      fi
      nice_cmd="nice -n 19"
      command -v ionice &>/dev/null && nice_cmd+=" ionice -c3"
      install -d -m 750 "$SCAN_REPORT_DIR"
      cat >"$SCAN_CRON" <<EOF
# CECP Panel — periodic security scan (cecp-panel security scan-schedule). Checked daily at the
# quietest hour; scans only when ${every} days have passed and the server is idle.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${minute} ${hour} * * * root ${nice_cmd} /usr/local/bin/cecp-panel security scan-cron >>${LOG_DIR}/security-scan.log 2>&1
EOF
      chmod 644 "$SCAN_CRON"
      scan_state_set every "$every" hour "$hour"
      panel_log "Periodic security scan ON: every ${every} days, at $(printf '%02d:%02d' "$hour" "$minute") ($quiet)"
      panel_log "  Infection found → evidence backup + retention frozen + alert (cecp-panel notify setup). Run now: cecp-panel security scan-cron --force"
      ;;
    off)
      rm -f "$SCAN_CRON"
      panel_log "Periodic security scan OFF"
      ;;
    status)
      local last next
      if [[ -f "$SCAN_CRON" ]]; then
        every="$(scan_state_get every 14)"
        last="$(scan_state_get last_run_epoch 0)"
        next=$(( last + every * 86400 ))
        (( next < $(date +%s) )) && next="$(date +%s)"
        echo "Periodic security scan: ON — every ${every} day(s), checked daily at $(printf '%02d:40' "$(scan_state_get hour 5)")"
        echo "  next due:    $(date -d "@$next" '+%Y-%m-%d') (runs that night if the server is idle)"
      else
        echo "Periodic security scan: OFF (cecp-panel security scan-schedule on)"
      fi
      echo "  last run:    $(scan_state_get last_run never) → $(scan_state_get last_result -)"
      echo "  last report: $(scan_state_get last_report -)"
      [[ -z "$(scan_state_get last_postponed "")" ]] || echo "  postponed:   $(scan_state_get last_postponed "")"
      if [[ -f "$SCAN_FREEZE_FLAG" ]]; then
        echo "  BACKUP RETENTION FROZEN since: $(<"$SCAN_FREEZE_FLAG")"
        echo "  → handle it (docs/INCIDENT_RESPONSE.md), then: cecp-panel security scan-ack"
      fi
      ;;
    *) panel_die "Usage: cecp-panel security scan-schedule on [--every 14|30] [--hour 0-23] | off | status" ;;
  esac
}

# restic snapshot helpers (only when backups are configured).
scan_restic_ready() {
  declare -F backup_is_configured >/dev/null && backup_is_configured || return 1
  backup_load_config
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
  command -v restic &>/dev/null
}

# Tag the newest snapshot of DOMAIN; keep the tag on the newest KEEP snapshots only.
scan_tag_latest() {  # scan_tag_latest DOMAIN TAG KEEP (>= 1)
  local domain="$1" tag="$2" keep="$3" ids
  ids="$(restic snapshots --json --tag "$domain" 2>/dev/null | python3 -c '
import json, sys
s = sorted(json.load(sys.stdin) or [], key=lambda x: x["time"])
print(s[-1]["id"] if s else "")')" || return 1
  [[ -n "$ids" ]] || return 1
  restic tag --add "$tag" "$ids" >/dev/null 2>>"$BACKUP_LOG" || return 1
  restic snapshots --json --tag "${tag},${domain}" 2>/dev/null | python3 -c '
import json, sys
s = sorted(json.load(sys.stdin) or [], key=lambda x: x["time"])
keep = int(sys.argv[1])
for x in s[:-keep]:
    print(x["id"])' "$keep" | while read -r id; do
    restic tag --remove "$tag" "$id" >/dev/null 2>>"$BACKUP_LOG" || true
  done
}

# cecp-panel security scan-cron [--force]  (run by the schedule; --force: now, whatever the load)
security_scan_cron() {
  local force=0 every last now load cores report rc=0 result failed d f fd
  [[ "${1:-}" == "--force" ]] && force=1
  require_root
  (( force )) || [[ -f "$SCAN_CRON" ]] || return 0
  every="$(scan_state_get every 14)"
  last="$(scan_state_get last_run_epoch 0)"
  now="$(date +%s)"
  if (( ! force )); then
    # 1 h of slack: a scan that started at 03:40 must be due again at 03:40 N days later.
    (( now - last >= every * 86400 - 3600 )) || return 0
    read -r load _ </proc/loadavg
    cores="$(nproc 2>/dev/null || echo 1)"
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0.7 * int(sys.argv[2]) else 1)' "$load" "$cores"; then
      scan_state_set last_postponed "$(date -u +%Y-%m-%dT%H:%M:%SZ) load ${load} on ${cores} core(s) — retry tomorrow"
      panel_log "security scan postponed: load ${load} on ${cores} core(s)"
      return 0
    fi
    if pgrep -x restic >/dev/null 2>&1; then
      scan_state_set last_postponed "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup running — retry tomorrow"
      panel_log "security scan postponed: a backup is running"
      return 0
    fi
  fi
  mkdir -p "$VAR_LIB/locks"
  exec {fd}>"$VAR_LIB/locks/security-scan.lock"
  flock -n "$fd" || { panel_log "security scan already running"; return 0; }
  install -d -m 750 "$SCAN_REPORT_DIR"
  report="$SCAN_REPORT_DIR/scan-$(date +%Y%m%d-%H%M%S).txt"
  panel_log "Periodic security scan started (report: $report)"
  if security_scan --all --days "$every" >"$report" 2>&1; then rc=0; else rc=1; fi
  chmod 640 "$report"
  failed="${SCAN_FAILED[*]}"

  if (( rc == 0 )); then
    result="clean"
    if scan_restic_ready; then
      shopt -s nullglob
      for f in "$SITES_DIR"/*.json; do
        d="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
        scan_tag_latest "$d" scan-clean 2 || panel_log "WARN: no snapshot of $d to mark as scan-clean"
      done
      shopt -u nullglob
      result="clean (latest backups tagged scan-clean)"
    fi
    notify_event security_scan_clean info "Security scan: no indicator found ($(panel_host_short))" "" \
      "{\"report\": \"$report\"}" || true
  elif [[ -z "$failed" ]]; then
    result="review: warnings only"
    notify_event security_scan_warning warning "Security scan: warnings to review — $report" "" "{\"report\": \"$report\"}" || true
  else
    result="INFECTED: $failed"
    printf '%s — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$failed" >"$SCAN_FREEZE_FLAG"
    if scan_restic_ready; then
      local -a targets=()
      if [[ " $failed " == *" server "* ]]; then
        shopt -s nullglob
        for f in "$SITES_DIR"/*.json; do targets+=("$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"); done
        shopt -u nullglob
      else
        read -r -a targets <<<"$failed"
      fi
      for d in "${targets[@]}"; do
        # Evidence copy of the state at detection time; the older (clean) ones stay: retention frozen.
        if ( backup_run_one "$d" 1 ) >/dev/null 2>&1; then
          scan_tag_latest "$d" scan-suspect 10 >/dev/null 2>&1 || panel_log "WARN: could not tag the evidence snapshot of $d"
        else
          panel_log "WARN: evidence backup of $d failed"
        fi
      done
    fi
    notify_event security_scan_infected critical \
      "SECURITY SCAN: indicators of compromise on ${failed}. Backup retention frozen (clean snapshots kept), evidence snapshot taken. Report: $report — follow docs/INCIDENT_RESPONSE.md" \
      "" "{\"report\": \"$report\", \"sections\": \"$failed\"}" || true
  fi
  scan_state_set last_run_epoch "$now" last_run "$(date -u +%Y-%m-%dT%H:%M:%SZ)" last_result "$result" \
    last_report "$report" last_postponed ""
  find "$SCAN_REPORT_DIR" -name 'scan-*.txt' -mtime +365 -delete 2>/dev/null || true
  panel_log "Periodic security scan: $result"
}

# cecp-panel security scan-ack — after handling an infection: resume retention; evidence
# snapshots lose their tag and age out with the normal retention.
security_scan_ack() {
  require_root
  [[ -f "$SCAN_FREEZE_FLAG" ]] || { panel_log "No frozen scan alert"; return 0; }
  security_audit_log "security scan-ack ($(<"$SCAN_FREEZE_FLAG"))"
  rm -f "$SCAN_FREEZE_FLAG"
  if scan_restic_ready; then
    restic snapshots --json --tag scan-suspect 2>/dev/null \
      | python3 -c 'import json,sys; [print(x["id"]) for x in (json.load(sys.stdin) or [])]' \
      | while read -r id; do restic tag --remove scan-suspect "$id" >/dev/null 2>>"$BACKUP_LOG" || true; done
  fi
  scan_state_set last_result "acknowledged $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  panel_log "Scan alert acknowledged: backup retention resumes at the next backup"
}
