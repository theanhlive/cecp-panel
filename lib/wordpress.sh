#!/usr/bin/env bash
set -euo pipefail

wp_domain_lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

WP_CLI_BIN="${WP_CLI_BIN:-/usr/local/bin/wp}"

wp_ensure_cli() {
  if [[ -x "$WP_CLI_BIN" ]]; then
    return 0
  fi
  require_root
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$WP_CLI_BIN"
  chmod +x "$WP_CLI_BIN"
}

wp_site_meta() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$(site_meta_path "$(wp_domain_lc "$1")")" "$2"
}

wp_site_is_wordpress() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("wordpress",False))' \
    "$(site_meta_path "$(wp_domain_lc "$1")")"
}

wp_site_exec() {
  local domain
  domain="$(wp_domain_lc "$1")"
  shift
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  [[ "$(wp_site_is_wordpress "$domain")" == "True" ]] || panel_die "Not a WordPress site: $domain"
  local docroot site_user
  docroot="$(wp_site_meta "$domain" "docroot")"
  site_user="$(wp_site_meta "$domain" "site_user")"
  sudo -u "$site_user" php -d memory_limit=512M "$WP_CLI_BIN" --path="$docroot" "$@"
}

wp_harden_site() {
  local domain
  domain="$(wp_domain_lc "$1")"
  require_root
  wp_ensure_cli
  panel_log "Hardening WordPress: $domain"
  wp_site_exec "$domain" config set DISALLOW_FILE_EDIT true --raw
  wp_site_exec "$domain" config set WP_AUTO_UPDATE_CORE "'minor'"
  wp_site_exec "$domain" config set FORCE_SSL_ADMIN true --raw 2>/dev/null || true
  wp_site_exec "$domain" plugin delete hello akismet 2>/dev/null || true
  wp_site_exec "$domain" rewrite structure --hard
  wp_site_exec "$domain" rewrite flush --hard
  wp_site_exec "$domain" cache flush 2>/dev/null || true
  panel_log "WP hardening done for $domain"
}

wp_install_system_cron() {
  local domain
  domain="$(wp_domain_lc "$1")"
  require_root
  if [[ "$(wp_site_is_wordpress "$domain")" != "True" ]]; then
    panel_die "Not a WordPress site: $domain"
  fi
  local site_user docroot slug
  site_user="$(wp_site_meta "$domain" "site_user")"
  docroot="$(wp_site_meta "$domain" "docroot")"
  slug="$(domain_slug "$domain")"
  cat >/etc/cron.d/cecp-wp-${slug} <<EOF
*/15 * * * * ${site_user} cd ${docroot} && /usr/local/bin/wp cron event run --due-now >>/var/log/cecp-panel/wp-cron-${slug}.log 2>&1
EOF
  chmod 644 /etc/cron.d/cecp-wp-${slug}
  wp_site_exec "$domain" config set DISABLE_WP_CRON true --raw
  panel_log "System cron for WP $domain (every 15 min)"
}

wp_optimize_site() {
  local domain
  domain="$(wp_domain_lc "$1")"
  wp_harden_site "$domain"
  wp_install_system_cron "$domain"
  wp_site_exec "$domain" db optimize 2>/dev/null || true
  wp_site_exec "$domain" transient delete --expired 2>/dev/null || true
  panel_log "WP optimize done: $domain"
}

wp_status_site() {
  local domain
  domain="$(wp_domain_lc "$1")"
  wp_ensure_cli
  wp_site_exec "$domain" core version
  wp_site_exec "$domain" plugin list --status=active 2>/dev/null | head -15
}
