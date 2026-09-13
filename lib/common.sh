#!/usr/bin/env bash
# Shared helpers for CECP Panel (sourced, not executed directly)
set -euo pipefail

CECP_PANEL_VERSION="${CECP_PANEL_VERSION:-1.5.0-beta}"
PANEL_ROOT="${PANEL_ROOT:-/opt/cecp-panel}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/cecp-panel}"
ETC_DIR="/etc/cecp-panel"
VAR_LIB="/var/lib/cecp-panel"
SITES_DIR="$VAR_LIB/sites"
LOG_DIR="/var/log/cecp-panel"
BIN_PATH="/usr/local/bin/cecp-panel"

panel_log() {
  echo "[cecp-panel] $*"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$LOG_DIR/panel.log" 2>/dev/null || true
}
panel_die() { echo "[cecp-panel] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || panel_die "Run as root: sudo cecp-panel $*"
}

domain_slug() {
  local d="${1,,}"
  d="${d//./_}"
  d="${d//-/_}"
  echo "${d:0:28}"
}

site_user_for_domain() {
  echo "site_$(domain_slug "$1")"
}

rand_alnum() {
  local n="${1:-16}"
  python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(int('${n}'))))"
}

site_meta_path() {
  echo "$SITES_DIR/$(echo "$1" | tr '[:upper:]' '[:lower:]').json"
}

load_site_meta() {
  local domain="$1"
  local f
  f="$(site_meta_path "$domain")"
  [[ -f "$f" ]] || return 1
  cat "$f"
}

site_json_get() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$(site_meta_path "$(echo "$1" | tr '[:upper:]' '[:lower:]')")" "$2"
}

save_site_meta() {
  local domain="$1" json="$2"
  mkdir -p "$SITES_DIR"
  echo "$json" >"$(site_meta_path "$domain")"
  chmod 600 "$(site_meta_path "$domain")"
}

site_set_ssl_flag() {
  local domain="$1" enabled="$2"
  python3 - "$domain" "$enabled" <<'PY'
import json, sys
domain, enabled = sys.argv[1], sys.argv[2].lower() in ("1", "true", "yes", "on")
path = f"/var/lib/cecp-panel/sites/{domain.lower()}.json"
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["ssl"] = enabled
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

detect_php_fpm_sock_dir() {
  if [[ -d /run/php-fpm ]]; then
    echo /run/php-fpm
  elif [[ -d /var/run/php-fpm ]]; then
    echo /var/run/php-fpm
  else
    echo /run/php-fpm
  fi
}

NGINX_LKG_DIR="${NGINX_LKG_DIR:-/var/lib/cecp-panel/nginx-lkg}"

# Save the current (known-good) nginx conf.d as the rollback point.
nginx_save_known_good() {
  mkdir -p "$NGINX_LKG_DIR"
  rm -rf "$NGINX_LKG_DIR/conf.d"
  cp -a /etc/nginx/conf.d "$NGINX_LKG_DIR/conf.d" 2>/dev/null || true
}

# Test nginx config; reload on success. On failure, automatically roll back
# conf.d to the last known-good snapshot so a single bad vhost can never take
# the whole nginx (and therefore every site on the box) down.
nginx_test_and_reload() {
  local errlog
  errlog="$(mktemp)"
  if nginx -t 2>"$errlog"; then
    systemctl reload nginx
    nginx_save_known_good
    rm -f "$errlog"
    return 0
  fi

  # nginx -t failed — the running nginx is still up (reload did not happen),
  # but on-disk config is broken and would fail on the next restart/reboot.
  panel_log "ERROR: nginx config test failed:"
  sed 's/^/    /' "$errlog" >&2

  if [[ -d "$NGINX_LKG_DIR/conf.d" ]]; then
    panel_log "Rolling back /etc/nginx/conf.d to last known-good snapshot ..."
    local quarantine="/var/lib/cecp-panel/nginx-broken-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$quarantine"
    cp -a /etc/nginx/conf.d "$quarantine/conf.d" 2>/dev/null || true
    rm -rf /etc/nginx/conf.d
    cp -a "$NGINX_LKG_DIR/conf.d" /etc/nginx/conf.d
    if nginx -t 2>/dev/null; then
      systemctl reload nginx 2>/dev/null || true
      panel_log "Rollback OK. Broken config saved at $quarantine for inspection."
    else
      panel_log "Rollback restored snapshot but nginx -t still fails — manual check needed. Broken config at $quarantine."
    fi
  else
    panel_log "No known-good snapshot yet; left config as-is (running nginx untouched). Fix the error above and retry."
  fi
  rm -f "$errlog"
  return 1
}

php_fpm_reload() {
  if systemctl is-active --quiet php-fpm 2>/dev/null; then
    systemctl reload php-fpm 2>/dev/null || systemctl restart php-fpm
  elif systemctl is-active --quiet php8.2-fpm 2>/dev/null; then
    systemctl reload php8.2-fpm 2>/dev/null || systemctl restart php8.2-fpm
  else
    systemctl restart php-fpm 2>/dev/null || true
  fi
}

template_render() {
  local tpl="$1" out="$2"
  shift 2
  local content
  content="$(<"$tpl")"
  while [[ $# -ge 2 ]]; do
    local key="$1" val="$2"
    content="${content//\{\{$key\}\}/$val}"
    shift 2
  done
  echo "$content" >"$out"
}

selinux_fixup_path() {
  command -v restorecon &>/dev/null || return 0
  restorecon -RF "$1" 2>/dev/null || true
}
