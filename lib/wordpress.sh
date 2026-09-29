#!/usr/bin/env bash
set -euo pipefail

wp_domain_lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

WP_CLI_BIN="${WP_CLI_BIN:-/usr/local/bin/wp}"

wp_ensure_cli() {
  if [[ -x "$WP_CLI_BIN" ]]; then
    return 0
  fi
  require_root
  local base="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar" tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$base/wp-cli.phar" -o "$tmp/wp-cli.phar"
  curl -fsSL "$base/wp-cli.phar.sha512" -o "$tmp/wp-cli.phar.sha512"
  if [[ "$(sha512sum "$tmp/wp-cli.phar" | cut -d' ' -f1)" != "$(tr -dc '0-9a-f' <"$tmp/wp-cli.phar.sha512")" ]]; then
    rm -rf "$tmp"
    panel_die "wp-cli.phar checksum mismatch — not installed"
  fi
  install -m 755 "$tmp/wp-cli.phar" "$WP_CLI_BIN"
  rm -rf "$tmp"
}

# cecp-panel update wp-cli — re-download and verify even if already installed (wp_ensure_cli
# only installs when missing). Used by `update all` and standalone.
wp_update_cli() {
  require_root
  local base="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar" tmp old new
  old="$([[ -x "$WP_CLI_BIN" ]] && "$WP_CLI_BIN" --allow-root cli version 2>/dev/null | awk '{print $NF}' || echo "none")"
  tmp="$(mktemp -d)"
  curl -fsSL "$base/wp-cli.phar" -o "$tmp/wp-cli.phar" || { rm -rf "$tmp"; panel_die "Could not download wp-cli.phar"; }
  curl -fsSL "$base/wp-cli.phar.sha512" -o "$tmp/wp-cli.phar.sha512" || { rm -rf "$tmp"; panel_die "Could not download wp-cli.phar.sha512"; }
  if [[ "$(sha512sum "$tmp/wp-cli.phar" | cut -d' ' -f1)" != "$(tr -dc '0-9a-f' <"$tmp/wp-cli.phar.sha512")" ]]; then
    rm -rf "$tmp"
    panel_die "wp-cli.phar checksum mismatch — not updated"
  fi
  install -m 755 "$tmp/wp-cli.phar" "$WP_CLI_BIN"
  rm -rf "$tmp"
  new="$("$WP_CLI_BIN" --allow-root cli version 2>/dev/null | awk '{print $NF}')"
  if [[ "$old" == "$new" ]]; then
    panel_log "wp-cli already at the latest version ($new)"
  else
    panel_log "wp-cli updated: $old -> $new"
  fi
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
  validate_domain "$domain"
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
  # Only with a certificate: on a plain-HTTP site it redirects wp-admin to an https:// that does
  # not exist (admin locked out until `ssl issue`, which turns it on — ssl_wp_sync_scheme).
  if site_cert_dir "$domain" >/dev/null; then
    wp_site_exec "$domain" config set FORCE_SSL_ADMIN true --raw 2>/dev/null || true
  fi
  wp_site_exec "$domain" plugin delete hello akismet 2>/dev/null || true
  wp_site_exec "$domain" rewrite structure '/%postname%/' --hard
  wp_site_exec "$domain" rewrite flush --hard
  wp_site_exec "$domain" cache flush 2>/dev/null || true
  panel_log "WP hardening done for $domain"
}

wp_install_system_cron() {
  local domain
  domain="$(wp_domain_lc "$1")"
  require_root
  validate_domain "$domain"
  if [[ "$(wp_site_is_wordpress "$domain")" != "True" ]]; then
    panel_die "Not a WordPress site: $domain"
  fi
  local site_user docroot slug
  site_user="$(wp_site_meta "$domain" "site_user")"
  docroot="$(wp_site_meta "$domain" "docroot")"
  slug="$(domain_slug "$domain")"
  # Cron runs as the site user, which cannot create files in root-owned $LOG_DIR:
  # pre-create its log, otherwise the redirect fails and wp-cron never runs.
  local cron_log="$LOG_DIR/wp-cron/wp-cron-${slug}.log"
  install -d -m 755 "$LOG_DIR/wp-cron"
  [[ -f "$cron_log" ]] || install -m 640 /dev/null "$cron_log"
  chown "${site_user}:${site_user}" "$cron_log"
  wp_cron_write "$domain"
  wp_site_exec "$domain" config set DISABLE_WP_CRON true --raw
  # wp-cron.php now answers the loopback call only (site_cron_access).
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
  panel_log "System cron for WP $domain (every 5 min, through the site's PHP-FPM pool)"
}

# The cron line itself (also refreshed by `site rebuild-vhost`). WordPress' scheduled tasks run
# through a loopback request to wp-cron.php — i.e. inside the site's own PHP-FPM pool with its
# open_basedir and disable_functions. Before, `wp cron event run` ran plugin code under the PHP
# CLI, where exec()/system() work and open_basedir does not apply: a backdoored plugin got a
# full shell every 15 minutes. -L follows the redirect to HTTPS; --resolve keeps it on this server.
wp_cron_write() {
  local domain="$1" site_user slug minute cron_log
  site_user="$(wp_site_meta "$domain" "site_user")"
  slug="$(domain_slug "$domain")"
  cron_log="$LOG_DIR/wp-cron/wp-cron-${slug}.log"
  # Each site its own minute in the 5-minute cycle: no CPU spike from every site at once.
  minute=$(( $(cksum <<<"$slug" | cut -d' ' -f1) % 5 ))
  cat >"/etc/cron.d/cecp-wp-${slug}" <<EOF
${minute}-59/5 * * * * ${site_user} curl -sSkL -m 600 -o /dev/null -w "\%{http_code} \%{time_total}s\n" --resolve ${domain}:80:127.0.0.1 --resolve ${domain}:443:127.0.0.1 http://${domain}/wp-cron.php >>${cron_log} 2>&1
EOF
  chmod 644 "/etc/cron.d/cecp-wp-${slug}"
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
