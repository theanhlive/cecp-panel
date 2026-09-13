#!/usr/bin/env bash
# PHP multi-version (Remi on Alma/Rocky) + per-site pool
set -euo pipefail

php_version_normalize() {
  local v="${1//./}"
  v="${v:0:2}"
  [[ "$v" =~ ^(74|8[0-4])$ ]] || panel_die "Unsupported PHP version: '${1:-}' (use 74, 80-84)"
  echo "$v"
}

php_remipkg_prefix() {
  local v
  v="$(php_version_normalize "$1")"
  echo "php${v}"
}

php_is_remirepo_available() {
  [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]
}

php_ensure_remi() {
  require_root
  php_is_remirepo_available || panel_die "PHP switching via Remi requires Alma/Rocky/CentOS"
  if ! rpm -q remi-release &>/dev/null; then
    panel_log "Installing Remi repository..."
    local el
    el="$(rpm -E '%{rhel}' 2>/dev/null || echo 9)"
    dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-${el}.rpm"
  fi
}

php_list_versions() {
  echo "--- PHP versions ---"
  command -v php &>/dev/null && echo "  default php: $(php -v | head -1)"
  rpm -qa 2>/dev/null | grep -E '^php[0-9]*-php-fpm|^php-fpm' | sort | sed 's/^/  /' || true
  systemctl list-units 'php*fpm*' --type=service --all 2>/dev/null | grep -E 'php.*fpm' | sed 's/^/  /' || true
  echo ""
  echo "Installed for panel:"
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("  %-35s php %s" % (d["domain"], d.get("php_version", "80")))' "$f"
  done
  shopt -u nullglob
  echo ""
  echo "Install: cecp-panel php install 82"
  echo "Per site: cecp-panel php set DOMAIN 82"
}

php_install_version() {
  local ver
  ver="$(php_version_normalize "${1:-}")"
  require_root
  php_ensure_remi
  local pfx
  pfx="$(php_remipkg_prefix "$ver")"
  panel_log "Installing Remi PHP ${ver} (${pfx}) ..."
  dnf -y install "${pfx}-php-fpm" "${pfx}-php-cli" "${pfx}-php-mysqlnd" \
    "${pfx}-php-gd" "${pfx}-php-xml" "${pfx}-php-mbstring" "${pfx}-php-json" \
    "${pfx}-php-opcache" 2>/dev/null || dnf -y install "${pfx}-php-fpm" "${pfx}-php-cli" "${pfx}-php-mysqlnd"
  systemctl enable --now "${pfx}-php-fpm" 2>/dev/null || true
  panel_log "PHP ${ver} installed. Service: ${pfx}-php-fpm"
}

php_fpm_d_dir() {
  local ver="$1"
  local norm
  norm="$(php_version_normalize "$ver")"
  if [[ "$norm" == "80" ]] && [[ -d /etc/php-fpm.d ]]; then
    echo /etc/php-fpm.d
  else
    echo "/etc/opt/remi/php${norm}/php-fpm.d"
  fi
}

php_fpm_sock_for_version() {
  local ver="$1" pool="$2"
  local norm
  norm="$(php_version_normalize "$ver")"
  if [[ "$norm" == "80" ]]; then
    echo "$(detect_php_fpm_sock_dir)/${pool}.sock"
  else
    echo "/var/opt/remi/php${norm}/run/php-fpm/${pool}.sock"
  fi
}

php_set_site_version() {
  local domain="${1,,}" ver="$2"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local norm
  norm="$(php_version_normalize "$ver")"
  if [[ "$norm" != "80" ]]; then
    php_install_version "$norm"
  fi
  local php_sock
  php_sock="$(php_fpm_sock_for_version "$norm" "$(site_json_get "$domain" pool_name)")"
  site_json_set "$domain" php_version "$norm" php_sock "$php_sock"
  site_render_pool "$domain"
  site_render_vhost "$domain"
  # The pool left one FPM service (reload is fine for removals) and joined another (restart).
  php_fpm_reload_all
  if [[ "$norm" == "80" ]]; then
    php_fpm_restart_for_new_pool php-fpm
  else
    php_fpm_restart_for_new_pool "$(php_remipkg_prefix "$norm")-php-fpm"
  fi
  nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
  panel_log "Site $domain now uses PHP ${norm}"
}
