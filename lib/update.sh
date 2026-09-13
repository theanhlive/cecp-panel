#!/usr/bin/env bash
# OS components + CECP Panel self-update
set -euo pipefail

PANEL_ENV="$ETC_DIR/panel.env"

update_save_mirror() {
  local base="${1:-}"
  [[ -n "$base" ]] || return 0
  mkdir -p "$ETC_DIR"
  if [[ -f "$PANEL_ENV" ]]; then
    grep -v '^CECP_PANEL_RAW_BASE=' "$PANEL_ENV" >"$PANEL_ENV.tmp" || true
    mv "$PANEL_ENV.tmp" "$PANEL_ENV"
  fi
  echo "CECP_PANEL_RAW_BASE=$base" >>"$PANEL_ENV"
  chmod 600 "$PANEL_ENV"
}

update_load_mirror() {
  CECP_PANEL_RAW_BASE=""
  [[ -f "$PANEL_ENV" ]] && source "$PANEL_ENV"
  CECP_PANEL_RAW_BASE="${CECP_PANEL_RAW_BASE:-${CECP_PANEL_BUNDLE_URL:-}}"
}

update_check() {
  echo "--- CECP Panel ---"
  [[ -f "$ETC_DIR/panel.json" ]] && cat "$ETC_DIR/panel.json" || echo "  (not installed)"
  echo "  CLI version: $CECP_PANEL_VERSION"
  echo ""
  echo "--- System packages ---"
  for p in nginx mariadb-server php-fpm restic rclone certbot; do
    rpm -q "$p" 2>/dev/null | sed 's/^/  /' || dpkg -l "$p" 2>/dev/null | awk '/^ii/{print "  "$2" "$3}' || echo "  $p: (not from pkg mgr)"
  done
  command -v php &>/dev/null && echo "  $(php -v | head -1)"
  update_load_mirror
  [[ -n "${CECP_PANEL_RAW_BASE:-}" ]] && echo "" && echo "  Update mirror: $CECP_PANEL_RAW_BASE"
}

update_component() {
  local comp="${1:-all}"
  require_root
  panel_log "Updating component: $comp ..."
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release ]]; then
    case "$comp" in
      nginx) dnf -y update nginx ;;
      mariadb|mysql) dnf -y update mariadb-server mariadb ;;
      php) dnf -y update php\* php-fpm ;;
      certbot) dnf -y update certbot python3-certbot-nginx ;;
      restic) dnf -y update restic ;;
      rclone) dnf -y update rclone ;;
      fail2ban) dnf -y update fail2ban ;;
      os|all)
        [[ "$comp" == "all" ]] && dnf -y update
        ;;
      *) panel_die "Unknown component: $comp (nginx|mariadb|php|certbot|restic|rclone|fail2ban|os|all)" ;;
    esac
  else
    apt-get update -y
    case "$comp" in
      nginx) apt-get install -y --only-upgrade nginx ;;
      mariadb) apt-get install -y --only-upgrade mariadb-server ;;
      php) apt-get install -y --only-upgrade 'php*' ;;
      certbot) apt-get install -y --only-upgrade certbot ;;
      restic) apt-get install -y --only-upgrade restic ;;
      rclone) apt-get install -y --only-upgrade rclone ;;
      os|all) apt-get upgrade -y ;;
      *) panel_die "Unknown component: $comp" ;;
    esac
  fi
  panel_log "Update done: $comp"
}

update_panel() {
  local url_ver="${1:-}"
  require_root
  update_load_mirror
  local base="${CECP_PANEL_RAW_BASE:-}"
  [[ -n "$base" ]] || panel_die "Set update mirror: cecp-panel update mirror https://raw.githubusercontent.com/ORG/REPO/main/scripts/cecp-panel"
  local ver="${url_ver:-$CECP_PANEL_VERSION}"
  local url="${base%/}/dist/cecp-panel-${ver}.tar.gz"
  local tmp bak
  tmp="$(mktemp -d)"
  bak="/opt/cecp-panel.bak-$(date +%Y%m%d_%H%M%S)"
  panel_log "Downloading panel $ver ..."
  curl -fsSL "$url" -o "$tmp/bundle.tar.gz" || {
    url="${base%/}/dist/cecp-panel-latest.tar.gz"
    curl -fsSL "$url" -o "$tmp/bundle.tar.gz"
  }
  tar xzf "$tmp/bundle.tar.gz" -C "$tmp"
  [[ -d "$INSTALL_ROOT" ]] && cp -a "$INSTALL_ROOT" "$bak"
  panel_log "Backup previous panel at $bak"
  cp -a "$tmp/cecp-panel/." "$INSTALL_ROOT/"
  chmod +x "$INSTALL_ROOT/cecp-panel" "$INSTALL_ROOT"/lib/*.sh
  install -m 0755 "$INSTALL_ROOT/cecp-panel" "$BIN_PATH"
  cat >"$ETC_DIR/panel.json" <<EOF
{
  "version": "$ver",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "previous_backup": "$bak",
  "standalone": true
}
EOF
  chmod 600 "$ETC_DIR/panel.json"
  rm -rf "$tmp"
  panel_log "Panel updated to $ver. Config in $ETC_DIR preserved."
}

update_mirror_set() {
  require_root
  [[ -n "${1:-}" ]] || panel_die "Usage: cecp-panel update mirror URL"
  update_save_mirror "$1"
  panel_log "Update mirror saved. Use: cecp-panel update panel"
}
