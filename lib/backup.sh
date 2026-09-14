#!/usr/bin/env bash
# Google Drive backup: restic (encrypt) → rclone → Shared Drive
set -euo pipefail

BACKUP_ENV="$ETC_DIR/backup.env"
RCLONE_CONF="$ETC_DIR/rclone.conf"
RESTIC_PASS_FILE="$ETC_DIR/restic-password"
BACKUP_STAGING="$VAR_LIB/backup-staging"
BACKUP_LOG="$LOG_DIR/backup.log"
BACKUP_STATE="$VAR_LIB/backup-state.json"
RESTORE_DIR="$VAR_LIB/restore"

# RESTIC_REPOSITORY may also be a local path or sftp:… (second copy, or no Google Drive at all).
backup_repo_is_rclone() { [[ "${RESTIC_REPOSITORY:-}" == rclone:* ]]; }

# backup_state_set DOMAIN KEY VALUE [KEY VALUE ...] — empty VALUE removes the key.
backup_state_set() {
  python3 - "$BACKUP_STATE" "$@" <<'PY'
import json, os, sys
path, dom, kv = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    data = json.load(open(path))
except (OSError, ValueError):
    data = {}
entry = data.setdefault(dom, {})
for k, v in zip(kv[::2], kv[1::2]):
    if v == "":
        entry.pop(k, None)
    else:
        entry[k] = v
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

backup_state_get() {
  python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], {}).get(sys.argv[3], ""))
except (OSError, ValueError):
    print("")
' "$BACKUP_STATE" "$1" "$2"
}

backup_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

backup_load_config() {
  [[ -f "$BACKUP_ENV" ]] || panel_die "Missing $BACKUP_ENV — run: cecp-panel backup setup"
  secure_source "$BACKUP_ENV"
  : "${RCLONE_REMOTE:=gdrive_cecp}"
  : "${GDRIVE_FOLDER:=CECP-VPS-Backups}"
  : "${RESTIC_REPOSITORY:=}"
  if [[ -z "$RESTIC_REPOSITORY" ]]; then
    local host
    host="$(panel_host_short)"
    RESTIC_REPOSITORY="rclone:${RCLONE_REMOTE}:${GDRIVE_FOLDER}/${host}"
  fi
  export RESTIC_REPOSITORY
  export RCLONE_CONFIG="$RCLONE_CONF"
  export RESTIC_PASSWORD_FILE
  : "${RESTIC_KEEP_DAILY:=7}"
  : "${RESTIC_KEEP_WEEKLY:=6}"
  : "${RESTIC_KEEP_MONTHLY:=12}"
  : "${RESTIC_KEEP_YEARLY:=0}"
  : "${BACKUP_CRON_MINUTE:=15}"
  : "${BACKUP_CRON_HOUR:=2}"
}

backup_ensure_tools() {
  command -v restic &>/dev/null || panel_die "restic not installed — run: cecp-panel backup setup"
  if backup_repo_is_rclone; then
    command -v rclone &>/dev/null || panel_die "rclone not installed — run: cecp-panel backup setup"
  fi
}

backup_auth_mode() {
  [[ -f "$BACKUP_ENV" ]] && secure_source "$BACKUP_ENV"
  echo "${BACKUP_AUTH_MODE:-oauth}"
}

backup_has_oauth_token() {
  [[ -f "$RCLONE_CONF" ]] && grep -q '^token = ' "$RCLONE_CONF" 2>/dev/null
}

backup_write_rclone_oauth() {
  require_root
  secure_source "$BACKUP_ENV"
  local token_file="${GDRIVE_OAUTH_TOKEN_FILE:-$ETC_DIR/gdrive-oauth-token.json}"
  [[ -f "$token_file" ]] || panel_die "Missing OAuth token. From Mac CECP: connect Drive, or: cecp-panel backup oauth-import TOKEN_JSON"
  local token_line
  token_line="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))' "$token_file")"
  cat >"$RCLONE_CONF" <<EOF
[$RCLONE_REMOTE]
type = drive
scope = drive
token = $token_line
EOF
  chmod 600 "$RCLONE_CONF"
  panel_log "Wrote $RCLONE_CONF (OAuth / My Drive)"
}

backup_write_rclone_service_account() {
  require_root
  secure_source "$BACKUP_ENV"
  [[ -f "${GDRIVE_SERVICE_ACCOUNT_FILE:-}" ]] || panel_die "Set GDRIVE_SERVICE_ACCOUNT_FILE in $BACKUP_ENV"
  [[ -n "${GDRIVE_TEAM_DRIVE_ID:-}" ]] || panel_die "Set GDRIVE_TEAM_DRIVE_ID (Shared Drive ID) in $BACKUP_ENV"
  cat >"$RCLONE_CONF" <<EOF
[$RCLONE_REMOTE]
type = drive
scope = drive
service_account_file = $GDRIVE_SERVICE_ACCOUNT_FILE
team_drive = $GDRIVE_TEAM_DRIVE_ID
root_folder_id =
EOF
  chmod 600 "$RCLONE_CONF"
  panel_log "Wrote $RCLONE_CONF (service account)"
}

backup_write_rclone_conf() {
  local mode
  mode="$(backup_auth_mode)"
  if [[ "$mode" == "oauth" ]]; then
    if backup_has_oauth_token; then
      panel_log "Using existing OAuth rclone config: $RCLONE_CONF"
      return 0
    fi
    backup_write_rclone_oauth
  else
    backup_write_rclone_service_account
  fi
}

backup_oauth_import() {
  local raw="${1:-}"
  require_root
  mkdir -p "$ETC_DIR"
  chmod 700 "$ETC_DIR"
  if [[ -z "$raw" ]]; then
    panel_log "Paste token JSON from: rclone authorize drive (on Mac), then Ctrl-D:"
    raw="$(cat)"
  fi
  (umask 077; printf '%s' "$raw" >"$ETC_DIR/.oauth-import-tmp.json")
  python3 - "$ETC_DIR/.oauth-import-tmp.json" "$ETC_DIR/gdrive-oauth-token.json" <<'PY' || { rm -f "$ETC_DIR/.oauth-import-tmp.json"; panel_die "Invalid JSON token"; }
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, separators=(",", ":"))
PY
  rm -f "$ETC_DIR/.oauth-import-tmp.json"
  chmod 600 "$ETC_DIR/gdrive-oauth-token.json"
  if [[ ! -f "$BACKUP_ENV" ]]; then
    install -m 600 "$PANEL_ROOT/templates/backup.env.example" "$BACKUP_ENV"
  fi
  env_set "$BACKUP_ENV" BACKUP_AUTH_MODE oauth
  backup_write_rclone_oauth
  panel_log "OAuth token imported. Run: cecp-panel backup setup"
}

backup_oauth_status() {
  echo "--- Google Drive backup auth ---"
  echo "  Mode: $(backup_auth_mode)"
  if backup_has_oauth_token; then
    echo "  OAuth: configured ($RCLONE_CONF)"
  else
    echo "  OAuth: not configured"
  fi
  if [[ -f "${GDRIVE_SERVICE_ACCOUNT_FILE:-/etc/cecp-panel/gdrive-service-account.json}" ]]; then
    echo "  Service account file: present (legacy)"
  fi
  echo ""
  echo "Easy setup (recommended): from CECP WebUI → Backup Drive → nhập Client ID/Secret → Xác thực"
  echo "Or on Mac: rclone authorize drive CLIENT_ID CLIENT_SECRET"
  echo "Then paste token: cecp-panel backup oauth-import '<json>'"
}

backup_setup() {
  require_root
  mkdir -p "$ETC_DIR" "$VAR_LIB" "$LOG_DIR" "$BACKUP_STAGING"
  chmod 700 "$ETC_DIR"

  if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
    dnf -y install restic rclone 2>/dev/null || {
      dnf -y install epel-release
      dnf -y install restic rclone
    }
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y restic rclone
  fi

  if [[ ! -f "$BACKUP_ENV" ]]; then
    cp "$PANEL_ROOT/templates/backup.env.example" "$BACKUP_ENV"
    chmod 600 "$BACKUP_ENV"
    panel_log "Created $BACKUP_ENV — edit Google Drive settings, then re-run: cecp-panel backup setup"
    return 0
  fi

  backup_load_config
  if backup_repo_is_rclone; then
    backup_write_rclone_conf
  fi

  if [[ ! -f "$RESTIC_PASS_FILE" ]]; then
    (umask 077; rand_alnum 32 >"$RESTIC_PASS_FILE")
    panel_log "Created restic encryption password: $RESTIC_PASS_FILE (back up offline!)"
  fi
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"

  if backup_repo_is_rclone; then
    rclone lsd "${RCLONE_REMOTE}:" --config "$RCLONE_CONF" >/dev/null \
      || panel_die "rclone cannot access Google Drive — re-run OAuth connect or check credentials"
  fi

  if ! restic snapshots &>/dev/null; then
    restic init
    panel_log "Initialized restic repo: $RESTIC_REPOSITORY"
  fi
  panel_log "Backup setup OK. Schedule: cecp-panel backup enable-cron"
}

# Site configuration for disaster recovery on a new VPS (vhost, pool, cron, SFTP, htpasswd,
# Let's Encrypt lineage). `site rebuild-vhost` can also regenerate vhost/pool from site.json.
backup_stage_config() {
  local domain="$1" out="$2" slug site_user f
  slug="$(domain_slug "$domain")"
  site_user="$(site_json_get "$domain" site_user)"
  local -a files=()
  for f in "/etc/nginx/conf.d/cecp-${slug}.conf" "/etc/php-fpm.d/cecp-${slug}.conf" \
           /etc/opt/remi/php*/php-fpm.d/cecp-"${slug}".conf "/etc/cron.d/cecp-wp-${slug}" \
           "/etc/ssh/sshd_config.d/cecp-${site_user}.conf" "/etc/nginx/cecp-auth/${slug}.htpasswd" \
           "/etc/letsencrypt/renewal/${domain}.conf" "/etc/letsencrypt/live/${domain}" \
           "/etc/letsencrypt/archive/${domain}" "/etc/nginx/cecp-auth/${slug}-site.htpasswd" \
           "/etc/cecp-panel/fpm/${slug}.conf" "/etc/cecp-panel/fpm/${slug}.pool.conf" \
           "/etc/systemd/system/cecp-php-fpm@${slug}.service.d"; do
    [[ -e "$f" ]] && files+=("${f#/}")
  done
  (( ${#files[@]} )) || return 0
  tar -C / -czf "$out/config.tar.gz" "${files[@]}"
}

# Prints the stage directory. Quiet on stdout otherwise (the caller captures it); errors go
# to $BACKUP_LOG and make it return non-zero.
backup_stage_site() {
  local domain="$1"
  local docroot db_name stage cnf
  docroot="$(site_json_get "$domain" docroot)" || return 1
  db_name="$(site_json_get "$domain" db_name)" || return 1

  stage="$BACKUP_STAGING/$(domain_slug "$domain")-$(date +%Y%m%d_%H%M%S)"
  (umask 077; mkdir -p "$stage/files" "$stage/config") || return 1
  cp "$(site_meta_path "$domain")" "$stage/site.json" || { rm -rf "$stage"; return 1; }
  cnf="$(mysql_client_cnf "$(site_json_get "$domain" db_user)" "$(site_json_get "$domain" db_pass)")"
  if ! mysqldump --defaults-extra-file="$cnf" --single-transaction --quick --routines --triggers \
       "$db_name" >"$stage/database.sql" 2>>"$BACKUP_LOG"; then
    rm -f "$cnf"
    rm -rf "$stage"
    echo "$(backup_now) $domain: mysqldump failed" >>"$BACKUP_LOG"
    return 1
  fi
  rm -f "$cnf"
  if ! tar -C "$(dirname "$docroot")" -czf "$stage/files/public_html.tar.gz" "$(basename "$docroot")" 2>>"$BACKUP_LOG"; then
    rm -rf "$stage"
    echo "$(backup_now) $domain: tar of $docroot failed" >>"$BACKUP_LOG"
    return 1
  fi
  backup_stage_config "$domain" "$stage/config" 2>>"$BACKUP_LOG" || true
  echo "$stage"
}

backup_fail() {
  local domain="$1" msg="$2"
  panel_log "ERROR: backup $domain: $msg"
  backup_state_set "$domain" last_error "$msg" last_error_at "$(backup_now)"
  notify_event backup_failed critical "Backup FAILED: $domain — $msg" "$domain"
}

backup_ok() {
  local domain="$1" snap="$2" prev_err
  prev_err="$(backup_state_get "$domain" last_error)"
  backup_state_set "$domain" last_ok "$(backup_now)" last_snapshot "$snap" last_error "" last_error_at ""
  panel_log "Backup done: $domain (snapshot ${snap:0:8})"
  if [[ -n "$prev_err" ]]; then
    notify_event backup_recovered info "Backup OK again: $domain" "$domain"
  fi
}

# Returns non-zero (and notifies) when any step fails — a failed backup used to be
# reported as "done" because restic's exit code was discarded.
backup_run_one() {
  local domain="${1,,}"
  local skip_retention="${2:-0}"
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Unknown site: $domain"
  backup_load_config
  backup_ensure_tools
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"

  local stage summary snap rc=0
  if ! stage="$(backup_stage_site "$domain")" || [[ -z "$stage" ]]; then
    backup_fail "$domain" "could not dump database / archive files (see $BACKUP_LOG)"
    return 1
  fi
  panel_log "Backing up $domain → $RESTIC_REPOSITORY ..."
  summary="$(restic backup "$stage" --tag "$domain" --host "$(panel_host_short)" --json 2>>"$BACKUP_LOG" | tail -1)" || rc=$?
  rm -rf "$stage"
  if (( rc != 0 )); then
    backup_fail "$domain" "restic backup exited with code $rc (see $BACKUP_LOG)"
    return 1
  fi
  snap="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("snapshot_id",""))' <<<"$summary" 2>/dev/null || true)"
  backup_ok "$domain" "$snap"
  if [[ "$skip_retention" != "1" ]]; then
    backup_apply_retention || true
  fi
  return 0
}

backup_run_all() {
  local f domain
  local -a failed=()
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    backup_run_one "$domain" 1 || failed+=("$domain")
  done
  shopt -u nullglob
  backup_apply_retention || failed+=("(retention)")
  if (( ${#failed[@]} )); then
    panel_log "Backup run finished with failures: ${failed[*]}"
    return 1
  fi
  panel_log "Backup run OK (all sites)"
}

backup_policy_show() {
  backup_load_config 2>/dev/null || {
    echo "Retention defaults (edit $BACKUP_ENV):"
    echo "  daily=7  weekly=6  monthly=12"
    return 0
  }
  cat <<EOF
--- CECP backup retention (restic forget --prune) ---
  keep-daily   $RESTIC_KEEP_DAILY   → tối đa ~$RESTIC_KEEP_DAILY bản (1/ngày trong $RESTIC_KEEP_DAILY ngày gần nhất)
  keep-weekly  $RESTIC_KEEP_WEEKLY  → thêm ~$RESTIC_KEEP_WEEKLY bản theo tuần (~$RESTIC_KEEP_WEEKLY tuần)
  keep-monthly $RESTIC_KEEP_MONTHLY → thêm $RESTIC_KEEP_MONTHLY bản theo tháng (~1 năm)
$(
  if [[ "${RESTIC_KEEP_YEARLY:-0}" -gt 0 ]]; then
    echo "  keep-yearly  $RESTIC_KEEP_YEARLY  → thêm snapshot theo năm"
  fi
)
Các bản cũ hơn quy tắc trên bị xóa khi prune.

Cần backup chạy HÀNG NGÀY (cecp-panel backup enable-cron) để đủ 7 bản/tuần.
Sau mỗi lần backup: tự chạy forget + prune.
EOF
}

backup_apply_retention() {
  local dry=0
  [[ "${1:-}" == "--dry-run" ]] && dry=1
  backup_load_config
  backup_ensure_tools
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
  local -a forget_args=(
    --keep-daily "$RESTIC_KEEP_DAILY"
    --keep-weekly "$RESTIC_KEEP_WEEKLY"
    --keep-monthly "$RESTIC_KEEP_MONTHLY"
  )
  if [[ "${RESTIC_KEEP_YEARLY:-0}" -gt 0 ]]; then
    forget_args+=(--keep-yearly "$RESTIC_KEEP_YEARLY")
  fi
  panel_log "Retention: daily=$RESTIC_KEEP_DAILY weekly=$RESTIC_KEEP_WEEKLY monthly=$RESTIC_KEEP_MONTHLY prune=on"
  local rc=0
  if [[ "$dry" -eq 1 ]]; then
    restic forget "${forget_args[@]}" --dry-run 2>>"$BACKUP_LOG" || rc=$?
  else
    restic forget "${forget_args[@]}" --prune 2>>"$BACKUP_LOG" || rc=$?
  fi
  if (( rc != 0 )); then
    panel_log "WARN: retention (restic forget) exited with code $rc"
    notify_event backup_retention_failed warning "Backup retention/prune failed (exit $rc) on $RESTIC_REPOSITORY"
    return 1
  fi
}

backup_list() {
  backup_load_config
  backup_ensure_tools
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
  restic snapshots "$@"
}

backup_list_json() {
  local tag="${1:-}"
  backup_load_config
  backup_ensure_tools
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
  if [[ -n "$tag" ]]; then
    restic snapshots --tag "$tag" --json
  else
    restic snapshots --json
  fi
}

backup_config_get() {
  local host repo cron_enabled
  host="$(panel_host_short)"
  if [[ -f "$BACKUP_ENV" ]]; then
    secure_source "$BACKUP_ENV"
  fi
  : "${RCLONE_REMOTE:=gdrive_cecp}"
  : "${GDRIVE_FOLDER:=CECP-VPS-Backups}"
  repo="${RESTIC_REPOSITORY:-}"
  if [[ -z "$repo" ]]; then
    repo="rclone:${RCLONE_REMOTE}:${GDRIVE_FOLDER}/${host}"
  fi
  cron_enabled="false"
  [[ -f /etc/cron.d/cecp-panel-backup ]] && cron_enabled="true"
  export CECP_CFG_HOST="$host" CECP_CFG_REPO="$repo" CECP_CFG_CRON="$cron_enabled"
  export CECP_CFG_H="${BACKUP_CRON_HOUR:-2}" CECP_CFG_M="${BACKUP_CRON_MINUTE:-15}"
  export CECP_CFG_DOW="${BACKUP_CRON_DOW:-*}"
  export CECP_CFG_KD="${RESTIC_KEEP_DAILY:-7}" CECP_CFG_KW="${RESTIC_KEEP_WEEKLY:-6}"
  export CECP_CFG_KM="${RESTIC_KEEP_MONTHLY:-12}" CECP_CFG_KY="${RESTIC_KEEP_YEARLY:-0}"
  python3 -c "import json, os; print(json.dumps({
    'hostname': os.environ['CECP_CFG_HOST'],
    'restic_repository': os.environ['CECP_CFG_REPO'],
    'cron_enabled': os.environ['CECP_CFG_CRON'] == 'true',
    'cron_hour': int(os.environ['CECP_CFG_H']),
    'cron_minute': int(os.environ['CECP_CFG_M']),
    'cron_dow': os.environ['CECP_CFG_DOW'],
    'keep_daily': int(os.environ['CECP_CFG_KD']),
    'keep_weekly': int(os.environ['CECP_CFG_KW']),
    'keep_monthly': int(os.environ['CECP_CFG_KM']),
    'keep_yearly': int(os.environ['CECP_CFG_KY']),
  }))"
}

# Usage: backup configure HOUR MINUTE DOW KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY [KEEP_YEARLY]
backup_configure() {
  local h="${1:-2}" m="${2:-15}" dow="${3:-*}"
  local kd="${4:-7}" kw="${5:-6}" km="${6:-12}" ky="${7:-0}"
  require_root
  # These land in root's crontab line and in a root-sourced env file: strict formats only.
  validate_int_range "$h" 0 23 "hour"
  validate_int_range "$m" 0 59 "minute"
  [[ "$dow" =~ ^(\*|[0-7](-[0-7])?(,[0-7](-[0-7])?)*)$ ]] || panel_die "Invalid day-of-week: '$dow'"
  validate_int_range "$kd" 0 3650 "keep-daily"
  validate_int_range "$kw" 0 520 "keep-weekly"
  validate_int_range "$km" 0 240 "keep-monthly"
  validate_int_range "$ky" 0 100 "keep-yearly"
  [[ -f "$BACKUP_ENV" ]] || install -m 600 "$PANEL_ROOT/templates/backup.env.example" "$BACKUP_ENV"
  env_set "$BACKUP_ENV" BACKUP_CRON_HOUR "$h"
  env_set "$BACKUP_ENV" BACKUP_CRON_MINUTE "$m"
  env_set "$BACKUP_ENV" BACKUP_CRON_DOW "$dow"
  env_set "$BACKUP_ENV" RESTIC_KEEP_DAILY "$kd"
  env_set "$BACKUP_ENV" RESTIC_KEEP_WEEKLY "$kw"
  env_set "$BACKUP_ENV" RESTIC_KEEP_MONTHLY "$km"
  env_set "$BACKUP_ENV" RESTIC_KEEP_YEARLY "$ky"
  backup_enable_cron
  panel_log "Backup schedule: ${h}:${m} dow=${dow} retention daily=${kd} weekly=${kw} monthly=${km} yearly=${ky}"
}

# The stage directory (site.json + database.sql + files/) inside a restored snapshot tree.
backup_find_stage() {
  find "$1" -type f -name site.json -path '*backup-staging*' -printf '%h\n' 2>/dev/null | head -1
}

# cecp-panel backup restore DOMAIN SNAPSHOT_ID|latest [--live [--dry-run] [--yes]] [--target DIR] [--repo REPO]
# Legacy positional form still works: backup restore DOMAIN SNAPSHOT_ID [TARGET_DIR] [RESTIC_REPO]
backup_restore() {
  local domain="${1:-}" snapshot_id="${2:-}"
  shift 2 || true
  local target="" repo_override="" live=0 dry=0 yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=1; shift ;;
      --dry-run) dry=1; shift ;;
      --yes|-y) yes=1; shift ;;
      --target) target="${2:-}"; shift 2 || true ;;
      --repo) repo_override="${2:-}"; shift 2 || true ;;
      --*) panel_die "Unknown option: $1" ;;
      *)
        if [[ -z "$target" ]]; then target="$1"
        elif [[ -z "$repo_override" ]]; then repo_override="$1"
        else panel_die "Too many arguments"
        fi
        shift ;;
    esac
  done
  require_root
  [[ -n "$domain" && -n "$snapshot_id" ]] \
    || panel_die "Usage: cecp-panel backup restore DOMAIN SNAPSHOT_ID|latest [--live [--dry-run] [--yes]] [--target DIR] [--repo REPO]"
  domain="${domain,,}"
  validate_domain "$domain"
  [[ "$snapshot_id" =~ ^([0-9a-f]{8,64}|latest)$ ]] || panel_die "Invalid snapshot id: '$snapshot_id'"
  backup_load_config
  if [[ -n "$repo_override" ]]; then
    export RESTIC_REPOSITORY="$repo_override"
    panel_log "Using repository override: $RESTIC_REPOSITORY"
  fi
  backup_ensure_tools
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
  if (( live )); then
    backup_restore_live "$domain" "$snapshot_id" "$dry" "$yes"
    return
  fi
  target="${target:-$RESTORE_DIR/${domain}}"
  mkdir -p "$target"
  panel_log "Restoring $snapshot_id (tag $domain) → $target"
  restic restore "$snapshot_id" --tag "$domain" --target "$target"
  panel_log "Restore extracted to $target. To replace the live site: cecp-panel backup restore $domain $snapshot_id --live"
}

# Copy the site's current database + files aside so a failed live restore can be undone.
backup_restore_safety_copy() {
  local domain="$1" dir="$2" docroot db_name
  docroot="$(site_json_get "$domain" docroot)"
  db_name="$(site_json_get "$domain" db_name)"
  (umask 077; mkdir -p "$dir")
  mysqldump --single-transaction --quick --routines --triggers "$db_name" >"$dir/database.sql" 2>>"$BACKUP_LOG" || return 1
  tar -C "$(dirname "$docroot")" -czf "$dir/public_html.tar.gz" "$(basename "$docroot")" 2>>"$BACKUP_LOG" || return 1
}

# Replace the site's files and database with those from STAGE_DIR (a backup stage or a
# safety copy with database.sql + public_html.tar.gz).
backup_restore_apply() {
  local domain="$1" sql="$2" archive="$3" stamp="$4"
  local docroot site_user db_name new old
  docroot="$(site_json_get "$domain" docroot)"
  site_user="$(site_json_get "$domain" site_user)"
  db_name="$(site_json_get "$domain" db_name)"
  new="${docroot}.restore-${stamp}"
  old="${docroot}.pre-restore-${stamp}"
  rm -rf "$new.tmp" "$new"
  mkdir -p "$new.tmp"
  tar -C "$new.tmp" -xzf "$archive" || { rm -rf "$new.tmp"; return 1; }
  mv "$new.tmp/$(basename "$docroot")" "$new" && rmdir "$new.tmp" || return 1
  # Files: swap directories (same filesystem → near-atomic)
  mv "$docroot" "$old" && mv "$new" "$docroot" || return 1
  chown -R "${site_user}:${site_user}" "$docroot"
  # The extracted tar carries whatever mode bits it had at backup time — may predate the
  # nginx-ACL hardening (e.g. a snapshot from before this version), so reapply rather than
  # trust it's already non-world-readable.
  site_harden_docroot_perms "$domain"
  selinux_fixup_path "$docroot"
  if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    chcon -R -t httpd_sys_content_t "$docroot" 2>/dev/null || true
  fi
  site_wp_config_sync "$domain"
  # Database: recreate empty, then import (grants live in mysql.db and survive the drop)
  mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`; CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  mysql "$db_name" <"$sql" 2>>"$BACKUP_LOG" || return 1
  rm -rf "$old"
  # OPcache would keep serving the previous code for up to revalidate_freq (60 s) and make
  # the health check lie; a graceful reload resets it.
  php_fpm_reload_all >/dev/null 2>&1 || true
  optimize_purge_cache "$domain" >/dev/null 2>&1 || true
  if [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]]; then
    wp_site_exec "$domain" cache flush >/dev/null 2>&1 || true
  fi
}

# Live restore: safety copy → swap files → re-import DB → fix wp-config → purge cache → health
# check. If the site does not answer 2xx/3xx afterwards, the safety copy is put back.
backup_restore_live() {
  local domain="$1" snapshot_id="$2" dry="$3" yes="$4"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site $domain does not exist here — create it first: cecp-panel site add $domain"
  local stamp work stage tables snap_time code
  stamp="$(date +%Y%m%d_%H%M%S)"
  work="$RESTORE_DIR/$(domain_slug "$domain")-${stamp}"
  (umask 077; mkdir -p "$work")
  panel_log "Fetching snapshot $snapshot_id of $domain ..."
  restic restore "$snapshot_id" --tag "$domain" --host "$(panel_host_short)" --target "$work/snap" >>"$BACKUP_LOG" 2>&1 \
    || restic restore "$snapshot_id" --tag "$domain" --target "$work/snap" >>"$BACKUP_LOG" 2>&1 \
    || { rm -rf "$work"; panel_die "Snapshot $snapshot_id (tag $domain) could not be restored (see $BACKUP_LOG)"; }
  stage="$(backup_find_stage "$work/snap")"
  [[ -n "$stage" && -s "$stage/database.sql" ]] || { rm -rf "$work"; panel_die "Snapshot has no CECP site backup (database.sql missing)"; }
  tar -tzf "$stage/files/public_html.tar.gz" >/dev/null 2>&1 || { rm -rf "$work"; panel_die "File archive in snapshot is unreadable"; }
  tables="$(grep -c '^CREATE TABLE' "$stage/database.sql" || true)"
  snap_time="$(restic snapshots "$snapshot_id" --tag "$domain" --json 2>/dev/null \
    | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["time"][:19] if s else "?")' 2>/dev/null || echo "?")"
  echo "=== Live restore plan: $domain ==="
  echo "  snapshot:  $snapshot_id (taken $snap_time UTC)"
  echo "  database:  $(site_json_get "$domain" db_name) ← ${tables} tables"
  echo "  files:     $(site_json_get "$domain" docroot) ← $(du -h "$stage/files/public_html.tar.gz" | cut -f1) archive"
  echo "  safety:    current files + DB saved to $work/pre (automatic rollback on failure)"
  if (( dry )); then
    rm -rf "$work"
    panel_log "Dry run only — nothing changed"
    return 0
  fi
  if (( ! yes )); then
    [[ -t 0 ]] || { rm -rf "$work"; panel_die "Live restore replaces the site; pass --yes when not running interactively"; }
    local answer
    read -r -p "Type the domain to replace the LIVE site with this snapshot: " answer
    [[ "$answer" == "$domain" ]] || { rm -rf "$work"; panel_die "Aborted"; }
  fi
  site_lock "$domain"
  panel_log "Saving current state of $domain ..."
  backup_restore_safety_copy "$domain" "$work/pre" || { rm -rf "$work"; panel_die "Could not save the current site — live restore aborted, nothing changed"; }
  panel_log "Restoring $domain from $snapshot_id ..."
  if backup_restore_apply "$domain" "$stage/database.sql" "$stage/files/public_html.tar.gz" "$stamp"; then
    sleep 1
    if code="$(site_http_check "$domain")"; then
      rm -rf "$work/snap"
      panel_log "Live restore OK: $domain (HTTP $code). Pre-restore copy kept in $work/pre"
      notify_event restore_done info "Restored $domain from snapshot ${snapshot_id:0:8} ($snap_time UTC)" "$domain"
      return 0
    fi
    panel_log "ERROR: $domain answers HTTP $code after restore — rolling back"
  else
    panel_log "ERROR: restore step failed — rolling back"
  fi
  if backup_restore_apply "$domain" "$work/pre/database.sql" "$work/pre/public_html.tar.gz" "${stamp}-rb" \
     && code="$(site_http_check "$domain")"; then
    rm -rf "$(site_json_get "$domain" docroot).pre-restore-${stamp}"
    notify_event restore_rolled_back critical "Restore of $domain from ${snapshot_id:0:8} failed; previous site restored (HTTP $code)" "$domain"
    panel_die "Restore failed; the previous site was put back (HTTP $code). Snapshot left in $work/snap for inspection"
  fi
  notify_event restore_failed critical "Restore of $domain FAILED and rollback did not bring the site back — manual action needed ($work)" "$domain"
  panel_die "Restore and rollback failed — manual action needed. Safety copy: $work/pre"
}

# cecp-panel backup verify DOMAIN|--all — repository check + test import of the latest dump.
backup_verify() {
  local target="${1:---all}" rc=0 f d
  require_root
  backup_load_config
  backup_ensure_tools
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
  panel_log "Checking repository $RESTIC_REPOSITORY (structure + 5% data sample) ..."
  if ! restic check --read-data-subset=5% >>"$BACKUP_LOG" 2>&1; then
    notify_event backup_verify_failed critical "Backup repository check FAILED ($RESTIC_REPOSITORY)"
    panel_log "ERROR: restic check failed (see $BACKUP_LOG)"
    rc=1
  fi
  if [[ "$target" == "--all" ]]; then
    shopt -s nullglob
    for f in "$SITES_DIR"/*.json; do
      d="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
      backup_verify_site "$d" || rc=1
    done
    shopt -u nullglob
  else
    backup_verify_site "${target,,}" || rc=1
  fi
  return "$rc"
}

backup_verify_site() {
  local domain="$1" tmp stage vdb n=0 err=""
  validate_domain "$domain"
  tmp="$(mktemp -d "$VAR_LIB/verify.XXXXXX")"
  if ! restic restore latest --tag "$domain" --host "$(panel_host_short)" --target "$tmp" >>"$BACKUP_LOG" 2>&1; then
    err="no restorable snapshot"
  else
    stage="$(backup_find_stage "$tmp")"
    if [[ -z "$stage" || ! -s "$stage/database.sql" ]]; then
      err="snapshot has no database dump"
    elif ! tar -tzf "$stage/files/public_html.tar.gz" >/dev/null 2>&1; then
      err="file archive is unreadable"
    else
      vdb="cecp_verify_$(rand_alnum 8 | tr '[:upper:]' '[:lower:]')"
      if mysql -e "CREATE DATABASE \`${vdb}\`" && mysql "$vdb" <"$stage/database.sql" 2>>"$BACKUP_LOG"; then
        n="$(mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${vdb}'")"
        (( n > 0 )) || err="database dump contains no tables"
      else
        err="database dump does not import"
      fi
      mysql -e "DROP DATABASE IF EXISTS \`${vdb}\`" || true
    fi
  fi
  rm -rf "$tmp"
  if [[ -n "$err" ]]; then
    backup_state_set "$domain" last_verify_error "$err" last_verify_error_at "$(backup_now)"
    notify_event backup_verify_failed critical "Backup verify FAILED: $domain — $err" "$domain"
    panel_log "ERROR: verify $domain: $err"
    return 1
  fi
  backup_state_set "$domain" last_verify_ok "$(backup_now)" last_verify_error "" last_verify_error_at ""
  panel_log "Verify OK: $domain (latest snapshot restores; $n tables import cleanly)"
}

backup_enable_cron() {
  require_root
  backup_load_config 2>/dev/null || true
  local m="${BACKUP_CRON_MINUTE:-15}"
  local h="${BACKUP_CRON_HOUR:-2}"
  local dow="${BACKUP_CRON_DOW:-*}"
  cat >/etc/cron.d/cecp-panel-backup <<EOF
# CECP backup + tiered retention (cecp-panel backup policy)
${m} ${h} * * ${dow} root /usr/local/bin/cecp-panel backup run --all >>/var/log/cecp-panel/backup.log 2>&1
# Weekly proof that backups restore: repository check + test-import of every site's latest dump
30 5 * * 0 root /usr/local/bin/cecp-panel backup verify --all >>/var/log/cecp-panel/backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/cecp-panel-backup
  if [[ "$dow" == "*" ]]; then
    panel_log "Enabled backup cron daily at ${h}:${m} (UTC)"
  else
    panel_log "Enabled backup cron weekly (dow=${dow}) at ${h}:${m} (UTC)"
  fi
}

backup_is_configured() {
  # True only when Drive auth + restic password are present (setup completed).
  [[ -f "$BACKUP_ENV" ]] || return 1
  [[ -f "$RESTIC_PASS_FILE" ]] || return 1
  secure_source "$BACKUP_ENV"
  if [[ -n "${RESTIC_REPOSITORY:-}" ]] && ! backup_repo_is_rclone; then
    return 0
  fi
  local mode
  mode="$(backup_auth_mode)"
  if [[ "$mode" == "oauth" ]]; then
    backup_has_oauth_token || return 1
  else
    [[ -f "$RCLONE_CONF" ]] || return 1
  fi
  return 0
}

# Auto-enable scheduled backup for a freshly added site.
# Default policy (CECP): cron daily 02:15 UTC, retention daily=7/weekly=6/monthly=12.
# Safe to call from site_add: never aborts site creation if Drive isn't connected.
backup_autoenable_for_new_site() {
  local domain="${1:-}"
  if ! backup_is_configured; then
    panel_log "Backup auto-enable bỏ qua cho ${domain:-site mới}: Drive chưa kết nối (chạy: cecp-panel backup setup / kết nối Google Drive trên CECP WebUI)."
    return 0
  fi
  backup_load_config 2>/dev/null || true
  # Ensure tiered retention + daily cron are in place (idempotent).
  if [[ ! -f /etc/cron.d/cecp-panel-backup ]]; then
    backup_configure "${BACKUP_CRON_HOUR:-2}" "${BACKUP_CRON_MINUTE:-15}" "${BACKUP_CRON_DOW:-*}" \
      "${RESTIC_KEEP_DAILY:-7}" "${RESTIC_KEEP_WEEKLY:-6}" "${RESTIC_KEEP_MONTHLY:-12}" "${RESTIC_KEEP_YEARLY:-0}" \
      || panel_log "Cảnh báo: không bật được cron backup tự động."
  fi
  # Take an immediate first backup so the new site has a restore point.
  if [[ -n "$domain" ]]; then
    panel_log "Auto backup (lần đầu) cho site mới: $domain ..."
    backup_run_one "$domain" || panel_log "Cảnh báo: backup đầu tiên cho $domain lỗi — sẽ tự thử lại theo cron."
  fi
}

backup_status() {
  if [[ ! -f "$BACKUP_ENV" ]]; then
    echo "Backup not configured. Run: cecp-panel backup setup"
    backup_oauth_status
    return 0
  fi
  backup_oauth_status
  backup_load_config
  echo "--- Backup config ---"
  echo "  Repository: $RESTIC_REPOSITORY"
  echo "  Rclone:     $RCLONE_CONF"
  [[ -f /etc/cron.d/cecp-panel-backup ]] && echo "  Cron:       enabled (/etc/cron.d/cecp-panel-backup)" || echo "  Cron:       not enabled (run: backup enable-cron)"
  echo "  Retention:  daily=$RESTIC_KEEP_DAILY weekly=$RESTIC_KEEP_WEEKLY monthly=$RESTIC_KEEP_MONTHLY"
  backup_policy_show
  echo ""
  echo "--- Per-site status ($BACKUP_STATE) ---"
  python3 - "$BACKUP_STATE" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    data = {}
if not data:
    print("  (no backup has run yet)")
for dom, e in sorted(data.items()):
    line = f"  {dom:35} last_ok={e.get('last_ok', 'never')}"
    if e.get("last_verify_ok"):
        line += f" verified={e['last_verify_ok']}"
    if e.get("last_error"):
        line += f"  ERROR({e.get('last_error_at', '?')}): {e['last_error']}"
    print(line)
PY
  echo ""
  if [[ -f "$RESTIC_PASS_FILE" ]] && backup_ensure_tools 2>/dev/null; then
    export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
    restic snapshots 2>/dev/null | tail -15 || echo "  (no snapshots yet)"
  fi
}
