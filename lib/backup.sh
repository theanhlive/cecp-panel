#!/usr/bin/env bash
# Google Drive backup: restic (encrypt) → rclone → Shared Drive
set -euo pipefail

BACKUP_ENV="$ETC_DIR/backup.env"
RCLONE_CONF="$ETC_DIR/rclone.conf"
RESTIC_PASS_FILE="$ETC_DIR/restic-password"
BACKUP_STAGING="$VAR_LIB/backup-staging"
BACKUP_LOG="$LOG_DIR/backup.log"

backup_load_config() {
  [[ -f "$BACKUP_ENV" ]] || panel_die "Missing $BACKUP_ENV — run: cecp-panel backup setup"
  secure_source "$BACKUP_ENV"
  : "${RCLONE_REMOTE:=gdrive_cecp}"
  : "${GDRIVE_FOLDER:=CECP-VPS-Backups}"
  : "${RESTIC_REPOSITORY:=}"
  if [[ -z "$RESTIC_REPOSITORY" ]]; then
    local host
    host="$(hostname -s)"
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
  command -v rclone &>/dev/null || panel_die "rclone not installed — run: cecp-panel backup setup"
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
  backup_write_rclone_conf

  if [[ ! -f "$RESTIC_PASS_FILE" ]]; then
    rand_alnum 32 >"$RESTIC_PASS_FILE"
    chmod 600 "$RESTIC_PASS_FILE"
    panel_log "Created restic encryption password: $RESTIC_PASS_FILE (back up offline!)"
  fi
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"

  rclone lsd "${RCLONE_REMOTE}:" --config "$RCLONE_CONF" >/dev/null \
    || panel_die "rclone cannot access Google Drive — re-run OAuth connect or check credentials"

  if ! restic snapshots &>/dev/null; then
    restic init
    panel_log "Initialized restic repo: $RESTIC_REPOSITORY"
  fi
  panel_log "Backup setup OK. Schedule: cecp-panel backup enable-cron"
}

backup_stage_site() {
  local domain="$1"
  local docroot db_name stage cnf
  docroot="$(site_json_get "$domain" docroot)"
  db_name="$(site_json_get "$domain" db_name)"

  stage="$BACKUP_STAGING/$(domain_slug "$domain")-$(date +%Y%m%d_%H%M%S)"
  (umask 077; mkdir -p "$stage/files")
  cp "$(site_meta_path "$domain")" "$stage/site.json"
  cnf="$(mysql_client_cnf "$(site_json_get "$domain" db_user)" "$(site_json_get "$domain" db_pass)")"
  mysqldump --defaults-extra-file="$cnf" "$db_name" >"$stage/database.sql"
  rm -f "$cnf"
  tar -C "$(dirname "$docroot")" -czf "$stage/files/public_html.tar.gz" "$(basename "$docroot")"
  echo "$stage"
}

backup_run_one() {
  local domain="${1,,}"
  local skip_retention="${2:-0}"
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Unknown site: $domain"
  backup_load_config
  backup_ensure_tools
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"

  local stage
  stage="$(backup_stage_site "$domain")"
  panel_log "Backing up $domain → $RESTIC_REPOSITORY ..."
  restic backup "$stage" \
    --tag "$domain" \
    --host "$(hostname -s)" \
    --json 2>>"$BACKUP_LOG" | tail -1 || true
  rm -rf "$stage"
  [[ "$skip_retention" == "1" ]] || backup_apply_retention
  panel_log "Backup done: $domain"
}

backup_run_all() {
  shopt -s nullglob
  local f
  for f in "$SITES_DIR"/*.json; do
    local domain
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    backup_run_one "$domain" 1
  done
  shopt -u nullglob
  backup_apply_retention
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
  if [[ "$dry" -eq 1 ]]; then
    restic forget "${forget_args[@]}" --dry-run 2>>"$BACKUP_LOG" || true
  else
    restic forget "${forget_args[@]}" --prune 2>>"$BACKUP_LOG" || true
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
  host="$(hostname -s)"
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

backup_restore() {
  local domain="$1" snapshot_id="$2" target="${3:-}" repo_override="${4:-}"
  require_root
  [[ -n "$domain" && -n "$snapshot_id" ]] || panel_die "Usage: cecp-panel backup restore DOMAIN SNAPSHOT_ID [TARGET_DIR] [RESTIC_REPO]"
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
  target="${target:-/var/lib/cecp-panel/restore/${domain}}"
  mkdir -p "$target"
  panel_log "Restoring $snapshot_id (tag $domain) → $target"
  restic restore "$snapshot_id" --tag "$domain" --target "$target"
  panel_log "Restore extracted. Review files before swapping live site."
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
  if [[ -f "$RESTIC_PASS_FILE" ]] && backup_ensure_tools 2>/dev/null; then
    export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"
    restic snapshots 2>/dev/null | tail -15 || echo "  (no snapshots yet)"
  fi
}
