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
  local pfx ext
  pfx="$(php_remipkg_prefix "$ver")"
  panel_log "Installing Remi PHP ${ver} (${pfx}) ..."
  dnf -y install "${pfx}-php-fpm" "${pfx}-php-cli" "${pfx}-php-mysqlnd" "${pfx}-php-opcache" \
    || panel_die "Could not install PHP ${ver} from Remi"
  # Extensions WordPress/WooCommerce use; one by one so a missing package (json is built in
  # from PHP 8, redis is pecl-redis5/6 depending on the version) does not abort the rest.
  for ext in gd xml mbstring intl zip bcmath soap sodium pecl-imagick-im7 pecl-redis6 pecl-redis5; do
    dnf -y -q install "${pfx}-php-${ext}" >/dev/null 2>&1 || true
  done
  systemctl enable --now "${pfx}-php-fpm" 2>/dev/null || true
  panel_log "PHP ${ver} installed. Service: ${pfx}-php-fpm"
}

# ---------------------------------------------------------------------------
# Per-site PHP settings (cecp-panel php config). Stored in site meta as php_<key>.
# ---------------------------------------------------------------------------
PHP_CFG_KEYS="memory_limit upload_max_filesize post_max_size max_execution_time max_input_time max_input_vars pm_max_children"

php_cfg_default() {
  case "$1" in
    memory_limit) echo 256M ;;
    upload_max_filesize|post_max_size) echo 64M ;;
    max_execution_time|max_input_time) echo 120 ;;
    max_input_vars) echo 3000 ;;
    pm_max_children) echo auto ;;
  esac
}

php_cfg_get() {
  local v
  v="$(site_json_get_or "$1" "php_$2" "")"
  echo "${v:-$(php_cfg_default "$2")}"
}

# "512M" / "2G" -> megabytes
php_cfg_mb() {
  local v="${1^^}"
  [[ "$v" =~ ^([0-9]{1,5})([MG])$ ]] || { echo 64; return 0; }
  if [[ "${BASH_REMATCH[2]}" == G ]]; then echo $(( BASH_REMATCH[1] * 1024 )); else echo "${BASH_REMATCH[1]}"; fi
}

# Normalize + range-check one value; prints the value to store.
php_cfg_validate() {
  local key="$1" val="$2" mb
  case "$key" in
    memory_limit|upload_max_filesize|post_max_size)
      [[ "${val^^}" =~ ^[0-9]{1,5}[MG]$ ]] || panel_die "$key: use a size like 256M or 1G"
      mb="$(php_cfg_mb "$val")"
      if [[ "$key" == memory_limit ]]; then
        (( mb >= 64 && mb <= 8192 )) || panel_die "memory_limit must be 64M..8G"
      else
        (( mb >= 2 && mb <= 4096 )) || panel_die "$key must be 2M..4G"
      fi
      echo "${mb}M"
      ;;
    max_execution_time|max_input_time)
      [[ "$val" =~ ^[0-9]{1,4}$ ]] && (( val >= 10 && val <= 3600 )) || panel_die "$key must be 10..3600 (seconds)"
      echo "$val"
      ;;
    max_input_vars)
      [[ "$val" =~ ^[0-9]{1,6}$ ]] && (( val >= 1000 && val <= 100000 )) || panel_die "max_input_vars must be 1000..100000"
      echo "$val"
      ;;
    pm_max_children)
      [[ "$val" == auto ]] && { echo auto; return 0; }
      [[ "$val" =~ ^[0-9]{1,3}$ ]] && (( val >= 2 && val <= 256 )) || panel_die "pm_max_children must be 2..256 or auto"
      echo "$val"
      ;;
    *) panel_die "Unknown setting '$key' (allowed: ${PHP_CFG_KEYS// /, })" ;;
  esac
}

# cecp-panel php config DOMAIN [key=value ...] | DOMAIN --reset [key ...]
php_config() {
  local domain="${1:-}"
  shift || true
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local kv key val k
  local -a sets=()
  if [[ $# -eq 0 ]]; then
    echo "=== PHP settings: $domain (PHP $(site_json_get_or "$domain" php_version 80)) ==="
    for k in $PHP_CFG_KEYS; do
      val="$(site_json_get_or "$domain" "php_$k" "")"
      printf '  %-20s %-8s %s\n' "$k" "$(php_cfg_get "$domain" "$k")" "$([[ -n "$val" ]] && echo "(custom)" || echo "(default)")"
    done
    [[ "$(php_cfg_get "$domain" pm_max_children)" == auto ]] && echo "  (pm_max_children auto = $(php_pool_max_children) on this server)"
    return 0
  fi
  if [[ "$1" == "--reset" ]]; then
    shift
    local -a keys=("$@")
    # shellcheck disable=SC2206  # default: every key (space-separated list)
    (( ${#keys[@]} )) || keys=($PHP_CFG_KEYS)
    for k in "${keys[@]}"; do
      [[ " $PHP_CFG_KEYS " == *" $k "* ]] || panel_die "Unknown setting '$k'"
      sets+=("php_$k" "")
    done
  else
    for kv in "$@"; do
      [[ "$kv" == *=* ]] || panel_die "Use key=value (e.g. memory_limit=512M)"
      key="${kv%%=*}"
      val="$(php_cfg_validate "$key" "${kv#*=}")"
      sets+=("php_$key" "$val")
    done
  fi
  site_json_set "$domain" "${sets[@]}"
  # post_max_size must hold the largest upload, or PHP drops the whole request body.
  if (( $(php_cfg_mb "$(php_cfg_get "$domain" post_max_size)") < $(php_cfg_mb "$(php_cfg_get "$domain" upload_max_filesize)") )); then
    site_json_set "$domain" php_post_max_size "$(php_cfg_get "$domain" upload_max_filesize)"
    panel_log "post_max_size raised to $(php_cfg_get "$domain" post_max_size) (must be >= upload_max_filesize)"
  fi
  site_render_pool "$domain"
  site_render_vhost "$domain"
  php_fpm_reload_all
  php_fpm_fix_socket_owner
  nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
  panel_log "PHP settings updated for $domain"
  php_config "$domain"
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
  if [[ "$(site_json_get_or "$domain" php_isolated false)" == "True" ]]; then
    # Own FPM master (site limits): same socket, new binary — restart that service only.
    site_json_set "$domain" php_version "$norm"
    site_render_pool "$domain"
    site_render_vhost "$domain"
    systemctl restart "cecp-php-fpm@$(domain_slug "$domain").service" \
      || panel_die "PHP ${norm} did not start for $domain (journalctl -u cecp-php-fpm@$(domain_slug "$domain"))"
    php_fpm_fix_socket_owner
    nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
    panel_log "Site $domain now uses PHP ${norm} (isolated FPM)"
    return 0
  fi
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
