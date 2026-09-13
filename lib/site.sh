#!/usr/bin/env bash
set -euo pipefail

# Per-site temp/session dir: a shared /tmp in open_basedir lets one site read another's
# sessions and upload temp files.
site_ensure_tmp() {
  local u="$1"
  install -d -m 700 -o "$u" -g "$u" "/home/${u}/tmp"
  if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    chcon -R -t httpd_sys_rw_content_t "/home/${u}/tmp" 2>/dev/null || true
  fi
}

# Let's Encrypt directory that serves DOMAIN: its own lineage, else a parent wildcard
# (*.example.com covers shop.example.com — one label only, like the certificate itself).
site_cert_dir() {
  local domain="$1" parent="${1#*.}"
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    echo "/etc/letsencrypt/live/${domain}"
    return 0
  fi
  if [[ "$parent" != "$domain" && "$parent" == *.* && -f "/etc/letsencrypt/live/${parent}/fullchain.pem" ]] \
     && openssl x509 -noout -ext subjectAltName -in "/etc/letsencrypt/live/${parent}/fullchain.pem" 2>/dev/null \
        | grep -qF "DNS:*.${parent}"; then
    echo "/etc/letsencrypt/live/${parent}"
    return 0
  fi
  return 1
}

# Print the HTTP status of the site's home page, fetched locally and bypassing the page cache
# (a cached HIT would hide a broken PHP/DB). Succeeds for 2xx/3xx.
site_http_check() {
  local domain="$1" scheme="http" code
  [[ "$(site_json_get_or "$domain" ssl false)" == "True" ]] && scheme="https"
  code="$(curl -sk -o /dev/null -w '%{http_code}' -m 15 \
    --resolve "${domain}:80:127.0.0.1" --resolve "${domain}:443:127.0.0.1" \
    -H 'Cookie: wordpress_logged_in_cecp_healthcheck=1' -K <(site_auth_curl_config "$domain") \
    "${scheme}://${domain}/" 2>/dev/null || true)"
  code="${code:-000}"
  echo "$code"
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

# After restoring files from a backup: point wp-config.php at the site's current DB credentials
# (and Redis ACL user) — values go through the environment, not argv.
site_wp_config_sync() {
  local domain="$1" cfg
  cfg="$(site_json_get "$domain" docroot)/wp-config.php"
  [[ -f "$cfg" ]] || return 0
  CECP_DB_NAME="$(site_json_get "$domain" db_name)" CECP_DB_USER="$(site_json_get "$domain" db_user)" \
  CECP_DB_PASS="$(site_json_get "$domain" db_pass)" python3 - "$cfg" <<'PY'
import os, re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
for key, env in (("DB_NAME", "CECP_DB_NAME"), ("DB_USER", "CECP_DB_USER"), ("DB_PASSWORD", "CECP_DB_PASS")):
    src = re.sub(r"define\(\s*['\"]%s['\"]\s*,\s*['\"][^'\"]*['\"]\s*\)" % key,
                 lambda m, k=key, v=os.environ[env]: "define( '%s', '%s' )" % (k, v), src)
open(path, "w", encoding="utf-8").write(src)
PY
  if [[ "$(site_json_get_or "$domain" redis false)" == "True" ]]; then
    redis_wp_config_refresh "$domain" || true
  fi
}

# HSTS header value from site meta: "on" (default, 180 days), "subdomains", or "off".
site_hsts_value() {
  case "$(site_json_get_or "$1" hsts on)" in
    off) echo "" ;;
    subdomains) echo "max-age=15552000; includeSubDomains" ;;
    *) echo "max-age=15552000" ;;
  esac
}

# ---------------------------------------------------------------------------
# wp-admin / wp-login protection (cecp-panel site protect-admin)
# Meta: admin_protect_auth (bool), admin_protect_ips ("CIDR,CIDR"), admin_protect_user/pass.
# ---------------------------------------------------------------------------
ADMIN_AUTH_DIR="/etc/nginx/cecp-auth"

# http-context part (outside server {}): IP allowlist as a geo variable.
site_admin_guard_http() {
  local domain="$1" slug="$2" ips cidr
  ips="$(site_json_get_or "$domain" admin_protect_ips "")"
  [[ -n "$ips" ]] || return 0
  echo "geo \$cecp_admin_ip_${slug} {"
  echo "    default 0;"
  for cidr in ${ips//,/ }; do
    echo "    ${cidr} 1;"
  done
  echo "}"
}

# server-context part: 403 for non-allowlisted IPs and/or basic auth, admin area only — or
# basic auth on the whole site (staging sites: meta site_auth).
site_admin_guard() {
  local domain="$1" slug="$2" ips auth
  ips="$(site_json_get_or "$domain" admin_protect_ips "")"
  auth="$(site_json_get_or "$domain" admin_protect_auth false)"
  if [[ "$(site_json_get_or "$domain" site_auth false)" == "True" ]]; then
    echo "    # Whole site behind basic auth (cecp-panel site auth)"
    echo "    auth_basic \"Restricted\";"
    echo "    auth_basic_user_file ${ADMIN_AUTH_DIR}/${slug}-site.htpasswd;"
    auth=False  # one auth_basic per server: the site-wide one already covers wp-admin
  fi
  [[ -n "$ips" || "$auth" == "True" ]] || return 0
  echo "    # wp-admin / wp-login protection (cecp-panel site protect-admin)"
  if [[ -n "$ips" ]]; then
    echo "    set \$cecp_admin_block \"\${cecp_admin_area}\${cecp_admin_ip_${slug}}\";"
    echo "    if (\$cecp_admin_block = \"10\") { return 403; }"
  fi
  if [[ "$auth" == "True" ]]; then
    echo "    set \$cecp_auth off;"
    echo "    if (\$cecp_admin_area) { set \$cecp_auth \"Restricted\"; }"
    echo "    auth_basic \$cecp_auth;"
    echo "    auth_basic_user_file ${ADMIN_AUTH_DIR}/${slug}.htpasswd;"
  fi
}

site_admin_write_htpasswd() {
  local domain="$1" user="$2" slug pass hash
  slug="$(domain_slug "$domain")"
  pass="$(rand_alnum 20)"
  hash="$(printf '%s' "$pass" | openssl passwd -6 -stdin)"
  install -d -m 750 -o root -g nginx "$ADMIN_AUTH_DIR" 2>/dev/null || install -d -m 750 "$ADMIN_AUTH_DIR"
  printf '%s:%s\n' "$user" "$hash" >"${ADMIN_AUTH_DIR}/${slug}.htpasswd"
  chown root:nginx "${ADMIN_AUTH_DIR}/${slug}.htpasswd" 2>/dev/null || true
  chmod 640 "${ADMIN_AUTH_DIR}/${slug}.htpasswd"
  site_json_set "$domain" admin_protect_user "$user" admin_protect_pass "$pass"
  panel_secret "wp-admin protection for $domain — user: $user  password: $pass"
}

# cecp-panel site protect-admin DOMAIN on [--ip CIDR[,CIDR]] [--no-auth] [--user NAME] | off | status | reset-password
site_protect_admin() {
  local domain="${1:-}" action="${2:-status}"
  shift 2 || true
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local slug htfile
  slug="$(domain_slug "$domain")"
  htfile="${ADMIN_AUTH_DIR}/${slug}.htpasswd"
  case "$action" in
    on)
      local ips="" auth=1 user="" old_user
      old_user="$(site_json_get_or "$domain" admin_protect_user "")"
      user="${old_user:-cecp}"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --ip) ips="${2:-}"; shift 2 || true ;;
          --no-auth) auth=0; shift ;;
          --user) user="${2:-}"; shift 2 || true ;;
          *) panel_die "Unknown option: $1" ;;
        esac
      done
      [[ "$user" =~ ^[a-z][a-z0-9_-]{2,31}$ ]] || panel_die "User must be 3-32 chars [a-z0-9_-]"
      if [[ -n "$ips" ]]; then
        ips="$(python3 -c '
import ipaddress, sys
nets = [str(ipaddress.ip_network(x.strip(), strict=False)) for x in sys.argv[1].split(",") if x.strip()]
print(",".join(nets))
' "$ips" 2>/dev/null)" || panel_die "Invalid --ip list (use CIDRs, e.g. 203.0.113.7/32,198.51.100.0/24)"
      fi
      (( auth == 1 )) || [[ -n "$ips" ]] || panel_die "Nothing to enable: use basic auth and/or --ip"
      if (( auth == 1 )); then
        if [[ ! -f "$htfile" || "$user" != "$old_user" ]]; then
          site_admin_write_htpasswd "$domain" "$user"
        fi
        site_json_set "$domain" admin_protect_auth true admin_protect_ips "$ips"
      else
        rm -f "$htfile"
        site_json_set "$domain" admin_protect_auth false admin_protect_ips "$ips" admin_protect_user "" admin_protect_pass ""
      fi
      ;;
    off)
      rm -f "$htfile"
      site_json_set "$domain" admin_protect_auth false admin_protect_ips "" admin_protect_user "" admin_protect_pass ""
      ;;
    reset-password)
      [[ "$(site_json_get_or "$domain" admin_protect_auth false)" == "True" ]] || panel_die "Basic auth is not enabled for $domain"
      site_admin_write_htpasswd "$domain" "$(site_json_get_or "$domain" admin_protect_user cecp)"
      ;;
    status)
      echo "wp-admin protection for $domain:"
      echo "  basic auth: $(site_json_get_or "$domain" admin_protect_auth false) (user: $(site_json_get_or "$domain" admin_protect_user -))"
      echo "  IP allowlist: $(site_json_get_or "$domain" admin_protect_ips none)"
      return 0
      ;;
    *) panel_die "Usage: cecp-panel site protect-admin DOMAIN on [--ip CIDR,...] [--no-auth] [--user NAME] | off | status | reset-password" ;;
  esac
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_die "nginx rejected the protected vhost for $domain (config rolled back)"
  panel_log "wp-admin protection for $domain: $action"
}

# cecp-panel site auth DOMAIN on [--user NAME] | off | status | reset-password
# Basic auth on the whole site (staging, previews for clients). ACME challenges stay open.
site_auth() {
  local domain="${1:-}" action="${2:-status}"
  shift $(( $# < 2 ? $# : 2 ))
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local slug htfile user pass hash
  slug="$(domain_slug "$domain")"
  htfile="${ADMIN_AUTH_DIR}/${slug}-site.htpasswd"
  case "$action" in
    on|reset-password)
      user="$(site_json_get_or "$domain" site_auth_user "")"
      user="${user:-preview}"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --user) user="${2:-}"; shift 2 || true ;;
          *) panel_die "Unknown option: $1" ;;
        esac
      done
      [[ "$user" =~ ^[a-z][a-z0-9_-]{2,31}$ ]] || panel_die "User must be 3-32 chars [a-z0-9_-]"
      pass="$(site_json_get_or "$domain" site_auth_pass "")"
      if [[ "$action" == "reset-password" || -z "$pass" || ! -f "$htfile" ]]; then
        pass="$(rand_alnum 20)"
      fi
      hash="$(printf '%s' "$pass" | openssl passwd -6 -stdin)"
      install -d -m 750 -o root -g nginx "$ADMIN_AUTH_DIR" 2>/dev/null || install -d -m 750 "$ADMIN_AUTH_DIR"
      printf '%s:%s\n' "$user" "$hash" >"$htfile"
      chown root:nginx "$htfile" 2>/dev/null || true
      chmod 640 "$htfile"
      site_json_set "$domain" site_auth true site_auth_user "$user" site_auth_pass "$pass"
      panel_secret "Basic auth for $domain — user: $user  password: $pass"
      ;;
    off)
      rm -f "$htfile"
      site_json_set "$domain" site_auth false site_auth_user "" site_auth_pass ""
      ;;
    status)
      echo "Site-wide basic auth for $domain: $(site_json_get_or "$domain" site_auth false) (user: $(site_json_get_or "$domain" site_auth_user -))"
      return 0
      ;;
    *) panel_die "Usage: cecp-panel site auth DOMAIN on [--user NAME] | off | status | reset-password" ;;
  esac
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
  panel_log "Site-wide basic auth for $domain: $action"
}

# curl config lines (for -K) that let panel health checks through site-wide basic auth;
# credentials stay off argv.
site_auth_curl_config() {
  [[ "$(site_json_get_or "$1" site_auth false)" == "True" ]] || return 0
  printf 'user = "%s:%s"\n' "$(site_json_get_or "$1" site_auth_user "")" "$(site_json_get_or "$1" site_auth_pass "")"
}

# Render the site's nginx vhost: HTTPS variant (HTTP/2, HSTS, 80→301) when a Let's Encrypt
# certificate exists, plain HTTP otherwise. Caller reloads nginx (nginx_test_and_reload).
site_render_vhost() {
  local domain="${1,,}"
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local slug docroot php_sock body out
  slug="$(domain_slug "$domain")"
  docroot="$(site_json_get "$domain" docroot)"
  php_sock="$(site_json_get "$domain" php_sock)"
  out="/etc/nginx/conf.d/cecp-${slug}.conf"
  local ttl avif cert_dir
  ttl="$(site_json_get_or "$domain" cache_ttl 5m)"
  [[ "$ttl" =~ ^[0-9]{1,4}[smhd]$ ]] || ttl=5m
  if [[ "$(site_json_get_or "$domain" img_avif false)" == "True" ]]; then
    avif='$cecp_avif_ext'
  else
    avif='".no-avif"'
  fi
  local headers=/etc/nginx/snippets/cecp-headers.conf post_mb exec_s
  # Staging copies must never be indexed: X-Robots-Tag on every response.
  [[ "$(site_json_get_or "$domain" noindex false)" == "True" ]] && headers=/etc/nginx/snippets/cecp-headers-noindex.conf
  post_mb="$(php_cfg_mb "$(php_cfg_get "$domain" post_max_size)")"
  exec_s="$(php_cfg_get "$domain" max_execution_time)"
  ensure_nginx_global
  body="$(mktemp)"
  template_render "$PANEL_ROOT/templates/nginx-site-body.tpl" "$body" \
    DOMAIN "$domain" DOCROOT "$docroot" PHP_SOCK "$php_sock" CACHE_TTL "$ttl" IMG_AVIF "$avif" \
    ADMIN_GUARD "$(site_admin_guard "$domain" "$slug")" HEADERS "$headers" \
    BODY_SIZE "$(( post_mb + 1 ))m" FCGI_TIMEOUT "$(( exec_s + 30 ))s"
  if cert_dir="$(site_cert_dir "$domain")"; then
    template_render "$PANEL_ROOT/templates/nginx-vhost-ssl.conf.tpl" "$out" \
      DOMAIN "$domain" DOCROOT "$docroot" LISTEN_SSL "$(nginx_listen_ssl_lines)" CERT_DIR "$cert_dir" \
      HSTS "$(site_hsts_value "$domain")" SITE_BODY "$(<"$body")" \
      ADMIN_GUARD_HTTP "$(site_admin_guard_http "$domain" "$slug")"
    site_set_ssl_flag "$domain" true
  else
    template_render "$PANEL_ROOT/templates/nginx-vhost.conf.tpl" "$out" \
      DOMAIN "$domain" SITE_BODY "$(<"$body")" \
      ADMIN_GUARD_HTTP "$(site_admin_guard_http "$domain" "$slug")"
    site_set_ssl_flag "$domain" false
  fi
  rm -f "$body"
  chmod 644 "$out"
}

# Render the site's PHP-FPM pool into the directory of its PHP version (default or Remi).
site_render_pool() {
  local domain="${1,,}"
  local slug site_user docroot php_sock pool_name php_ver fpm_dir
  slug="$(domain_slug "$domain")"
  site_user="$(site_json_get "$domain" site_user)"
  docroot="$(site_json_get "$domain" docroot)"
  php_sock="$(site_json_get "$domain" php_sock)"
  pool_name="$(site_json_get "$domain" pool_name)"
  php_ver="$(php_version_normalize "$(site_json_get_or "$domain" php_version 80)")"
  fpm_dir="$(php_fpm_d_dir "$php_ver")"
  site_ensure_tmp "$site_user"
  rm -f "/etc/php-fpm.d/cecp-${slug}.conf" /etc/opt/remi/php*/php-fpm.d/cecp-"${slug}".conf
  local pool_file="${fpm_dir}/cecp-${slug}.conf" children
  # Sites with resource limits run their pool under their own FPM master (cecp-php-fpm@SLUG).
  if [[ "$(site_json_get_or "$domain" php_isolated false)" == "True" ]]; then
    pool_file="$FPM_ISOLATED_DIR/${slug}.pool.conf"
    limits_write_master "$domain"
  else
    rm -f "$FPM_ISOLATED_DIR/${slug}.conf" "$FPM_ISOLATED_DIR/${slug}.pool.conf"
  fi
  mkdir -p "$(dirname "$pool_file")"
  children="$(php_cfg_get "$domain" pm_max_children)"
  [[ "$children" == auto ]] && children="$(php_pool_max_children)"
  template_render "$PANEL_ROOT/templates/php-fpm-pool.conf.tpl" "$pool_file" \
    DOMAIN "$domain" POOL_NAME "$pool_name" SITE_USER "$site_user" DOCROOT "$docroot" \
    SITE_HOME "/home/${site_user}" PHP_SOCK "$php_sock" PHP_VERSION "$php_ver" \
    PM_MAX_CHILDREN "$children" \
    MEMORY_LIMIT "$(php_cfg_get "$domain" memory_limit)" \
    POST_MAX_SIZE "$(php_cfg_get "$domain" post_max_size)" \
    UPLOAD_MAX_FILESIZE "$(php_cfg_get "$domain" upload_max_filesize)" \
    MAX_EXECUTION_TIME "$(php_cfg_get "$domain" max_execution_time)" \
    MAX_INPUT_TIME "$(php_cfg_get "$domain" max_input_time)" \
    MAX_INPUT_VARS "$(php_cfg_get "$domain" max_input_vars)"
}

# Re-apply current templates (vhost + pool) to an existing site, with nginx rollback on error.
site_rebuild_vhost() {
  local domain="${1,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    ssl_renewal_use_webroot "$domain"
  fi
  site_render_pool "$domain"
  site_render_vhost "$domain"
  php_fpm_reload_all
  if [[ "$(site_json_get_or "$domain" php_isolated false)" == "True" ]]; then
    systemctl enable --now "cecp-php-fpm@$(domain_slug "$domain").service" >/dev/null 2>&1 \
      || panel_log "WARN: cecp-php-fpm@$(domain_slug "$domain") did not start (journalctl -u cecp-php-fpm@$(domain_slug "$domain"))"
    php_fpm_fix_socket_owner
  fi
  nginx_test_and_reload || panel_die "nginx rejected the rebuilt vhost for $domain (config rolled back)"
  panel_log "Rebuilt vhost + pool: $domain"
}

site_rebuild_vhost_all() {
  require_root
  local f domain
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    site_rebuild_vhost "$domain"
  done
  shopt -u nullglob
}

site_list_json() {
  shopt -s nullglob
  local f
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({'domain':d['domain'],'ssl':bool(d.get('ssl')),'wordpress':bool(d.get('wordpress'))}))" "$f"
  done
  shopt -u nullglob
}

site_list() {
  echo "--- Sites ---"
  if [[ ! -d "$SITES_DIR" ]] || [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    echo "  (no sites)"
    return 0
  fi
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(f\"  {d['domain']:40} user={d['site_user']} ssl={d.get('ssl', False)}\")" "$f" 2>/dev/null \
      || grep -o '"domain": *"[^"]*"' "$f" | head -1
  done
}

site_add() {
  local domain="${1,,}"
  local install_wp="${2:-n}"
  require_root
  validate_domain "$domain"

  local meta
  meta="$(site_meta_path "$domain")"
  [[ ! -f "$meta" ]] || panel_die "Site already exists: $domain"

  local slug site_user docroot pool_name sock_dir php_sock other
  slug="$(domain_slug "$domain")"
  site_user="$(site_user_for_domain "$domain")"
  # domain_slug maps "." and "-" to "_" and truncates, so two domains can share a slug —
  # and with it the unix user, PHP pool and database. Refuse rather than merge sites.
  for other in "$SITES_DIR"/*.json; do
    [[ -f "$other" ]] || continue
    if [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["site_user"])' "$other")" == "$site_user" ]]; then
      panel_die "$domain maps to system user $site_user, already used by $(basename "$other" .json)"
    fi
  done
  id "$site_user" &>/dev/null && panel_die "System user $site_user already exists (leftover of a removed site?) — refusing to reuse it"
  docroot="/home/${site_user}/public_html"
  pool_name="$slug"
  sock_dir="$(detect_php_fpm_sock_dir)"
  php_sock="${sock_dir}/${pool_name}.sock"

  local db_name="db_${slug}"
  local db_user="u_${slug}"
  local db_pass
  db_pass="$(rand_alnum 20)"

  panel_log "Creating UNIX user $site_user ..."
  useradd -r -m -d "/home/${site_user}" -s /sbin/nologin "$site_user"
  mkdir -p "$docroot"
  # SFTP chroot: home root-owned, only public_html writable by site user
  chown root:root "/home/${site_user}"
  chmod 755 "/home/${site_user}"
  chown -R "${site_user}:${site_user}" "$docroot"
  chmod 755 "$docroot"
  if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P httpd_enable_homedirs 1 2>/dev/null || true
    setsebool -P httpd_read_user_content 1 2>/dev/null || true
    chcon -R -t httpd_sys_content_t "$docroot" 2>/dev/null || true
  fi
  site_ensure_tmp "$site_user"
  selinux_fixup_path "$docroot"
  mkdir -p "$sock_dir"
  chown nginx:nginx "$sock_dir" 2>/dev/null || true

  panel_log "MariaDB database $db_name ..."
  mysql_create_site_db "$domain" "$db_name" "$db_user" "$db_pass"

  local installed_at
  installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_site_meta "$domain" "$(cat <<EOF
{
  "domain": "$domain",
  "site_user": "$site_user",
  "docroot": "$docroot",
  "pool_name": "$pool_name",
  "php_version": "80",
  "php_sock": "$php_sock",
  "db_name": "$db_name",
  "db_user": "$db_user",
  "db_pass": "$db_pass",
  "wordpress": $( [[ "$install_wp" =~ ^[yY] ]] && echo true || echo false ),
  "ssl": false,
  "hsts": "on",
  "installed_at": "$installed_at"
}
EOF
)"

  panel_log "PHP-FPM pool + nginx vhost ..."
  site_render_pool "$domain"
  site_render_vhost "$domain"

  if [[ "$install_wp" =~ ^[yY] ]]; then
    site_install_wordpress "$domain" "$docroot" "$site_user" "$db_name" "$db_user" "$db_pass"
    wp_harden_site "$domain"
    wp_install_system_cron "$domain"
  else
    cat >"$docroot/index.html" <<EOF
<!DOCTYPE html><html><head><title>${domain}</title></head>
<body><h1>CECP Panel</h1><p>Site <strong>${domain}</strong> is ready.</p></body></html>
EOF
    chown "${site_user}:${site_user}" "$docroot/index.html"
  fi

  php_fpm_restart_for_new_pool php-fpm
  nginx_test_and_reload || panel_die "nginx rejected the new vhost for $domain (config rolled back)"

  panel_log "Site added: http://$domain"
  panel_log "DB: $db_name | user: $db_user | pass: (in $(site_meta_path "$domain"))"

  # Default: bật backup tự động (cron daily + retention) và backup lần đầu cho site mới.
  # An toàn — bỏ qua nếu Drive chưa kết nối, không làm hỏng việc tạo site.
  if [[ "${CECP_NO_AUTOBACKUP:-0}" != 1 ]] && declare -F backup_autoenable_for_new_site >/dev/null 2>&1; then
    backup_autoenable_for_new_site "$domain" || true
  fi
}

site_install_wordpress() {
  local domain="$1" docroot="$2" site_user="$3" db_name="$4" db_user="$5" db_pass="$6"
  wp_ensure_cli
  panel_log "Installing WordPress for $domain ..."
  local wp_run=(sudo -u "$site_user" php -d memory_limit=512M "$WP_CLI_BIN")
  "${wp_run[@]}" core download --path="$docroot" --quiet
  # Passwords via --prompt (stdin), not argv: site users can read argv of other processes.
  "${wp_run[@]}" config create \
    --path="$docroot" \
    --dbname="$db_name" --dbuser="$db_user" --prompt=dbpass \
    --dbhost=localhost --dbprefix=wp_ --skip-check <<<"$db_pass"
  local admin_user admin_pass
  # Not "admin": the first name every wp-login brute-force list tries.
  admin_user="admin_$(rand_alnum 6 | tr '[:upper:]' '[:lower:]')"
  admin_pass="$(rand_alnum 20)"
  "${wp_run[@]}" core install \
    --path="$docroot" \
    --url="http://${domain}" \
    --title="${domain}" \
    --admin_user="$admin_user" \
    --prompt=admin_password \
    --admin_email="admin@${domain}" \
    --skip-email <<<"$admin_pass"
  chown -R "${site_user}:${site_user}" "$docroot"
  site_json_set "$domain" wp_admin_user "$admin_user" wp_admin_pass "$admin_pass"
  panel_log "WordPress admin user: $admin_user (password stored in $(site_meta_path "$domain"))"
  panel_secret "WordPress admin password: $admin_pass (save now)"
}

site_remove() {
  local domain="${1,,}"
  require_root
  validate_domain "$domain"
  local meta
  meta="$(site_meta_path "$domain")"
  [[ -f "$meta" ]] || panel_die "Site not found: $domain"

  local site_user slug db_name db_user
  site_user="$(site_json_get "$domain" site_user)"
  slug="$(domain_slug "$domain")"
  db_name="$(site_json_get "$domain" db_name)"
  db_user="$(site_json_get "$domain" db_user)"

  ssl_remove_for_domain "$domain"

  rm -f "/etc/nginx/conf.d/cecp-${slug}.conf"
  rm -f "/etc/php-fpm.d/cecp-${slug}.conf"
  # Remi pools: an orphan pool pointing at a deleted user stops that PHP version from starting.
  local remi_pool svc
  for remi_pool in /etc/opt/remi/php*/php-fpm.d/cecp-"${slug}".conf; do
    [[ -f "$remi_pool" ]] || continue
    rm -f "$remi_pool"
    svc="$(echo "$remi_pool" | sed -E 's#^/etc/opt/remi/(php[0-9]+)/.*#\1#')-php-fpm"
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
  done
  systemctl disable --now "cecp-purge@${slug}.path" >/dev/null 2>&1 || true
  if [[ "$(site_json_get_or "$domain" php_isolated false)" == "True" ]]; then
    systemctl disable --now "cecp-php-fpm@${slug}.service" >/dev/null 2>&1 || true
    rm -rf "/etc/systemd/system/cecp-php-fpm@${slug}.service.d"
    rm -f "$FPM_ISOLATED_DIR/${slug}.conf" "$FPM_ISOLATED_DIR/${slug}.pool.conf"
    systemctl daemon-reload
  fi
  # A staging copy points at its parent (and the parent at it): keep both metas consistent.
  local parent
  parent="$(site_json_get_or "$domain" staging_of "")"
  [[ -n "$parent" && -f "$(site_meta_path "$parent")" ]] && site_json_set "$parent" staging_site ""
  rm -f "/etc/cron.d/cecp-wp-${slug}" "${ADMIN_AUTH_DIR}/${slug}.htpasswd" "${ADMIN_AUTH_DIR}/${slug}-site.htpasswd"
  if [[ -f "/etc/ssh/sshd_config.d/cecp-${site_user}.conf" ]]; then
    rm -f "/etc/ssh/sshd_config.d/cecp-${site_user}.conf"
    sshd_test_and_reload || panel_log "WARN: sshd -t failed after removing SFTP drop-in — check manually"
  fi
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/mysql.sh"
  mysql_drop_site_db "$db_name" "$db_user"

  if id "$site_user" &>/dev/null; then
    userdel -r "$site_user" 2>/dev/null || userdel "$site_user" 2>/dev/null || true
  fi
  # userdel -r skips the root-owned SFTP chroot home, leaving the site files (and the
  # wp-config.php DB credentials) behind; remove it explicitly.
  if [[ "$site_user" =~ ^site_[a-z0-9_]+$ && -d "/home/${site_user}" ]]; then
    rm -rf --one-file-system "/home/${site_user:?}"
  fi
  local redis_user
  redis_user="$(site_json_get_or "$domain" redis_user "")"
  rm -f "$meta"
  if [[ -n "$redis_user" && -f /etc/cecp-panel/redis.env ]]; then
    printf 'ACL DELUSER %s\n' "$redis_user" | redis_admin >/dev/null 2>&1 || true
    redis_acl_write_conf
  fi

  php_fpm_reload
  nginx_test_and_reload
  panel_log "Removed site: $domain"
}

site_duplicate() {
  local src="${1,,}" dst="${2,,}"
  require_root
  [[ -n "$src" && -n "$dst" ]] || panel_die "Usage: cecp-panel site duplicate SRC_DOMAIN NEW_DOMAIN"
  validate_domain "$src"
  validate_domain "$dst"
  [[ -f "$(site_meta_path "$src")" ]] || panel_die "Source not found: $src"
  [[ ! -f "$(site_meta_path "$dst")" ]] || panel_die "Target exists: $dst"
  local src_doc src_wp
  src_doc="$(site_json_get "$src" docroot)"
  src_wp="$(wp_site_is_wordpress "$src" 2>/dev/null || echo False)"
  # No first backup of the still-empty copy (site_add would take one).
  CECP_NO_AUTOBACKUP=1 site_add "$dst" n
  local dst_doc dst_cnf
  dst_doc="$(site_json_get "$dst" docroot)"
  panel_log "Copying files $src → $dst ..."
  rsync -a --delete "$src_doc/" "$dst_doc/" 2>/dev/null || cp -a "$src_doc/." "$dst_doc/"
  chown -R "$(site_json_get "$dst" site_user):" "$dst_doc"
  # The auto-purge config names the source site's queue; enable it on the copy separately.
  rm -f "$dst_doc/wp-content/mu-plugins/cecp-cache-purge.php" "$dst_doc/wp-content/mu-plugins/cecp-cache-purge.json"
  if [[ "$src_wp" == "True" ]]; then
    # The copied wp-config.php still holds the SOURCE database credentials: without this the
    # copy (and the search-replace below) would write to the source site's database.
    site_json_set "$dst" wordpress true
    site_wp_config_sync "$dst"
  fi
  panel_log "Copying database $(site_json_get "$src" db_name) → $(site_json_get "$dst" db_name) ..."
  # Dump as root (routines/triggers of any definer), import as the copy's own DB user so the
  # dump can only land in its database; DEFINER clauses would need SUPER.
  dst_cnf="$(mysql_client_cnf "$(site_json_get "$dst" db_user)" "$(site_json_get "$dst" db_pass)")"
  mysqldump --single-transaction --quick --routines --triggers "$(site_json_get "$src" db_name)" \
    | sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' \
    | mysql --defaults-extra-file="$dst_cnf" "$(site_json_get "$dst" db_name)"
  rm -f "$dst_cnf"
  selinux_fixup_path "$dst_doc"
  if [[ "$src_wp" == "True" ]]; then
    # Same for Redis: the copy must get its own ACL user and key prefix, not the source's.
    if [[ "$(site_json_get_or "$src" redis false)" == "True" ]] || grep -q "WP_REDIS_" "$dst_doc/wp-config.php" 2>/dev/null; then
      optimize_redis_wp "$dst" || panel_log "WARN: Redis object cache for $dst could not be configured"
    fi
    site_wordpress_clone_fixup "$src" "$dst" "${3:-}"
    [[ "${CECP_DUPLICATE_NO_CRON:-0}" == 1 ]] || wp_install_system_cron "$dst"
  fi
  panel_log "Duplicated $src → $dst"
}

# Set siteurl/home and verify them (WP-CLI calls it an error when the value is unchanged).
site_wp_set_urls() {
  local domain="$1" url="$2" k
  for k in siteurl home; do
    [[ "$(wp_site_exec "$domain" option get "$k" 2>/dev/null)" == "$url" ]] && continue
    wp_site_exec "$domain" option update "$k" "$url" >/dev/null 2>&1 || true
    wp_site_exec "$domain" cache flush >/dev/null 2>&1 || true
    [[ "$(wp_site_exec "$domain" option get "$k" 2>/dev/null)" == "$url" ]] \
      || panel_die "Could not set WordPress $k of $domain to $url"
  done
}

# Rewrite URLs of SRC to DST inside DST's database. The scheme follows DST's certificate
# (a copy without HTTPS must not point at https://), JSON-escaped URLs (page builders) too.
site_wordpress_clone_fixup() {
  local src="${1,,}" dst="${2,,}" repl_file="${3:-}" scheme=http
  [[ "$(wp_site_is_wordpress "$dst" 2>/dev/null || echo False)" == "True" ]] || return 0
  site_cert_dir "$dst" >/dev/null && scheme=https
  panel_log "WordPress URL/search-replace for $dst ($scheme) ..."
  wp_site_exec "$dst" search-replace "//${src}" "//${dst}" --all-tables --skip-columns=guid --quiet
  wp_site_exec "$dst" search-replace "\\/\\/${src}" "\\/\\/${dst}" --all-tables --skip-columns=guid --quiet 2>/dev/null || true
  if [[ "$scheme" == https ]]; then
    wp_site_exec "$dst" search-replace "http://${dst}" "https://${dst}" --all-tables --skip-columns=guid --quiet 2>/dev/null || true
  else
    wp_site_exec "$dst" search-replace "https://${dst}" "http://${dst}" --all-tables --skip-columns=guid --quiet 2>/dev/null || true
  fi
  # search-replace writes SQL directly: a persistent object cache (Redis) still holds the old
  # options, and update_option against it "fails" (0 rows changed). Flush first.
  wp_site_exec "$dst" cache flush >/dev/null 2>&1 || true
  site_wp_set_urls "$dst" "${scheme}://${dst}"
  if [[ -n "$repl_file" && -f "$repl_file" ]]; then
    local line old new
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS=$'\t' read -r old new <<<"$line"
      [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || continue
      wp_site_exec "$dst" search-replace "$old" "$new" --all-tables 2>/dev/null || true
    done < <(python3 - "$repl_file" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1])):
    o = (p.get("from") or p.get("old") or "").strip()
    n = (p.get("to") or p.get("new") or "").strip()
    if o and n and o != n and "\t" not in o + n and "\n" not in o + n:
        print(o + "\t" + n)
PY
)
  fi
}

site_sftp_info() {
  local domain="${1,,}"
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local site_user docroot
  site_user="$(site_json_get "$domain" site_user)"
  docroot="$(site_json_get "$domain" docroot)"
  site_sftp_enable "$site_user"
  local ip
  ip="$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || panel_local_ipv4)"
  cat <<EOF
SFTP (site-isolated user):
  Host: $ip
  User: $site_user
  Path: $docroot (chroot: /home/$site_user)
  Set password: cecp-panel site sftp-password $domain
EOF
}

site_sftp_enable() {
  local site_user="${1:-}"
  require_root
  [[ "$site_user" =~ ^site_[a-z0-9_]+$ ]] || panel_die "Refusing SFTP drop-in for invalid site user: '${site_user}'"
  sshd_apply_dropin "/etc/ssh/sshd_config.d/cecp-${site_user}.conf" "Match User ${site_user}
    ChrootDirectory /home/${site_user}
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no" || panel_die "SFTP not enabled for ${site_user} (sshd config test failed)"
}

site_sftp_password() {
  local domain="${1,,}" pass="${2:-}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local site_user
  site_user="$(site_json_get "$domain" site_user)"
  if [[ -z "$pass" ]]; then
    pass="$(rand_alnum 20)"
  fi
  # chpasswd reads "user:password" lines: a ":" or newline in the password could set
  # the password of another account (e.g. root).
  [[ "$pass" =~ ^[A-Za-z0-9!@#%^_+=.,-]{12,128}$ ]] \
    || panel_die "Password must be 12-128 chars of [A-Za-z0-9!@#%^_+=.,-]"
  site_sftp_enable "$site_user"
  printf '%s:%s\n' "$site_user" "$pass" | chpasswd
  usermod -s /usr/sbin/nologin "$site_user" 2>/dev/null || true
  panel_log "SFTP password set for $site_user (domain $domain)"
  panel_secret "SFTP password: $pass"
}
