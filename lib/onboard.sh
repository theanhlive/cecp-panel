#!/usr/bin/env bash
# First-run wizard: Cloudflare DNS + Google Drive backup
set -euo pipefail

onboard_write_cf() {
  local token="$1" zone="${2:-theanhlive.com}"
  mkdir -p "$ETC_DIR"
  if [[ -f "$ETC_DIR/credentials.env" ]]; then
    grep -v '^CF_API_TOKEN=' "$ETC_DIR/credentials.env" 2>/dev/null | grep -v '^CF_DEFAULT_ZONE=' >"$ETC_DIR/credentials.env.tmp" || true
    mv "$ETC_DIR/credentials.env.tmp" "$ETC_DIR/credentials.env"
  else
    cp "$PANEL_ROOT/templates/credentials.env.example" "$ETC_DIR/credentials.env" 2>/dev/null || touch "$ETC_DIR/credentials.env"
  fi
  {
    echo "CF_API_TOKEN=$token"
    echo "CF_DEFAULT_ZONE=$zone"
  } >>"$ETC_DIR/credentials.env"
  chmod 600 "$ETC_DIR/credentials.env"
}

onboard_write_backup() {
  local sa_path="$1" team_id="$2"
  if [[ ! -f "$BACKUP_ENV" ]]; then
    cp "$PANEL_ROOT/templates/backup.env.example" "$BACKUP_ENV"
  fi
  local tmp="$BACKUP_ENV.new"
  grep -v '^GDRIVE_SERVICE_ACCOUNT_FILE=' "$BACKUP_ENV" 2>/dev/null | grep -v '^GDRIVE_TEAM_DRIVE_ID=' >"$tmp" || cp "$BACKUP_ENV" "$tmp"
  {
    echo "GDRIVE_SERVICE_ACCOUNT_FILE=$sa_path"
    echo "GDRIVE_TEAM_DRIVE_ID=$team_id"
  } >>"$tmp"
  mv "$tmp" "$BACKUP_ENV"
  chmod 600 "$BACKUP_ENV"
  if [[ "$sa_path" != /etc/cecp-panel/* ]]; then
    install -m 600 "$sa_path" /etc/cecp-panel/gdrive-service-account.json
    onboard_write_backup "/etc/cecp-panel/gdrive-service-account.json" "$team_id"
  fi
}

onboard_interactive() {
  require_root
  echo "========================================================================="
  echo "  CECP Panel — first-time setup (DNS + backup)"
  echo "========================================================================="
  echo ""
  echo "--- Cloudflare DNS (optional) ---"
  read -r -p "Cloudflare API token (Enter=skip): " cf_tok
  if [[ -n "$cf_tok" ]]; then
    read -r -p "Default zone [theanhlive.com]: " cf_zone
    cf_zone="${cf_zone:-theanhlive.com}"
    onboard_write_cf "$cf_tok" "$cf_zone"
    if dns_list_a 2>/dev/null; then
      panel_log "Cloudflare DNS OK"
    else
      panel_log "WARN: Cloudflare test failed — check token (Zone.DNS Edit)"
    fi
  fi
  echo ""
  echo "--- Google Drive backup (optional) ---"
  read -r -p "Path to service-account JSON (Enter=skip): " sa_path
  if [[ -n "$sa_path" && -f "$sa_path" ]]; then
    read -r -p "Shared Drive ID (team_drive_id): " team_id
    [[ -n "$team_id" ]] || panel_die "Team Drive ID required for backup"
    onboard_write_backup "$sa_path" "$team_id"
    backup_setup
    read -r -p "Enable daily backup cron? (y/n): " en
    [[ "$en" =~ ^[yY] ]] && backup_enable_cron
  else
    panel_log "Backup skipped — add later: cecp-panel backup setup"
  fi
  echo ""
  echo "--- Done ---"
  echo "  cecp-panel site add subdomain.${CF_DEFAULT_ZONE:-yourdomain.com}"
  echo "  cecp-panel dns point subdomain.${CF_DEFAULT_ZONE:-yourdomain.com}"
  echo "  cecp-panel ssl issue subdomain.${CF_DEFAULT_ZONE:-yourdomain.com}"
  echo "  cecp-panel"
}

onboard_from_env() {
  # Non-interactive: CECP_CF_TOKEN, CECP_CF_ZONE, CECP_GDRIVE_SA_JSON, CECP_GDRIVE_TEAM_ID
  require_root
  [[ -n "${CECP_CF_TOKEN:-}" ]] && onboard_write_cf "$CECP_CF_TOKEN" "${CECP_CF_ZONE:-theanhlive.com}"
  if [[ -n "${CECP_GDRIVE_SA_JSON:-}" && -n "${CECP_GDRIVE_TEAM_ID:-}" ]]; then
    onboard_write_backup "$CECP_GDRIVE_SA_JSON" "$CECP_GDRIVE_TEAM_ID"
    backup_setup
    backup_enable_cron
  fi
}

onboard_main() {
  if [[ -n "${CECP_CF_TOKEN:-}" || -n "${CECP_GDRIVE_SA_JSON:-}" ]]; then
    onboard_from_env
  else
    onboard_interactive
  fi
}
