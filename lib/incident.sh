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

_scan() {  # _scan LEVEL MESSAGE [DETAIL_LINES]
  printf '  [%s] %s\n' "$1" "$2"
  [[ -z "${3:-}" ]] || sed 's/^/        /' <<<"$3"
  [[ "$1" == OK || "$1" == INFO ]] || SCAN_BAD=1
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
