#!/usr/bin/env bash
# PHP multi-version (Remi on Alma/Rocky) + per-site pool
set -euo pipefail

php_version_normalize() {
  local v="${1//./}"
  echo "${v:0:2}"
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
    python3 -c "import json; d=json.load(open('$f')); print(f\"  {d['domain']:35} php {d.get('php_version','80')}\")"
  done
  shopt -u nullglob
  echo ""
  echo "Install: cecp-panel php install 82"
  echo "Per site: cecp-panel php set DOMAIN 82"
}

php_install_version() {
  local ver="$1"
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
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local norm
  norm="$(php_version_normalize "$ver")"
  if [[ "$norm" != "80" ]]; then
    php_install_version "$norm"
  fi
  local meta slug pool_name site_user docroot php_sock old_slug
  meta="$(site_meta_path "$domain")"
  slug="$(domain_slug "$domain")"
  pool_name="$(python3 -c "import json; print(json.load(open('$meta'))['pool_name'])")"
  site_user="$(python3 -c "import json; print(json.load(open('$meta'))['site_user'])")"
  docroot="$(python3 -c "import json; print(json.load(open('$meta'))['docroot'])")"
  php_sock="$(php_fpm_sock_for_version "$norm" "$pool_name")"
  local fpm_dir
  fpm_dir="$(php_fpm_d_dir "$norm")"
  mkdir -p "$fpm_dir"
  rm -f /etc/php-fpm.d/cecp-${slug}.conf 2>/dev/null || true
  rm -f /etc/opt/remi/php*/php-fpm.d/cecp-${slug}.conf 2>/dev/null || true
  template_render "$PANEL_ROOT/templates/php-fpm-pool.conf.tpl" \
    "${fpm_dir}/cecp-${slug}.conf" \
    DOMAIN "$domain" POOL_NAME "$pool_name" SITE_USER "$site_user" \
    DOCROOT "$docroot" PHP_SOCK "$php_sock"
  sed -i "s|^\\[${pool_name}\\]|\\[${pool_name}\\]\\n; PHP ${norm}|" "${fpm_dir}/cecp-${slug}.conf"
  local ngx="/etc/nginx/conf.d/cecp-${slug}.conf"
  [[ -f "$ngx" ]] && sed -i "s|unix:.*\\.sock|unix:${php_sock}|" "$ngx"
  python3 <<PY
import json
p="$meta"
d=json.load(open(p))
d["php_version"]="$norm"
d["php_sock"]="$php_sock"
json.dump(d, open(p,"w"), indent=2)
open(p,"a").write("\n")
PY
  chmod 600 "$meta"
  if [[ "$norm" == "80" ]]; then
    php_fpm_reload
  else
    systemctl reload "$(php_remipkg_prefix "$norm")-php-fpm" 2>/dev/null || \
      systemctl restart "$(php_remipkg_prefix "$norm")-php-fpm"
  fi
  nginx_test_and_reload
  panel_log "Site $domain now uses PHP ${norm}"
}
