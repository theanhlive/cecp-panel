#!/usr/bin/env bash
set -euo pipefail

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
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || panel_die "Invalid domain: $domain"

  local meta
  meta="$(site_meta_path "$domain")"
  [[ ! -f "$meta" ]] || panel_die "Site already exists: $domain"

  local slug site_user docroot pool_name sock_dir php_sock
  slug="$(domain_slug "$domain")"
  site_user="$(site_user_for_domain "$domain")"
  docroot="/home/${site_user}/public_html"
  pool_name="$slug"
  sock_dir="$(detect_php_fpm_sock_dir)"
  php_sock="${sock_dir}/${pool_name}.sock"

  local db_name="db_${slug}"
  local db_user="u_${slug}"
  local db_pass
  db_pass="$(rand_alnum 20)"

  panel_log "Creating UNIX user $site_user ..."
  if ! id "$site_user" &>/dev/null; then
    useradd -r -m -d "/home/${site_user}" -s /sbin/nologin "$site_user"
  fi
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

  panel_log "Nginx vhost ..."
  # Guarantee shared zones (cecp_general/cecp_conn/CECP_WP) exist before the vhost
  # that references them is loaded — otherwise `nginx -t` fails with [emerg].
  ensure_nginx_global
  template_render "$PANEL_ROOT/templates/nginx-vhost.conf.tpl" \
    "/etc/nginx/conf.d/cecp-${slug}.conf" \
    DOMAIN "$domain" DOCROOT "$docroot" PHP_SOCK "$php_sock"
  selinux_fixup_path "$docroot"

  panel_log "PHP-FPM pool ..."
  template_render "$PANEL_ROOT/templates/php-fpm-pool.conf.tpl" \
    "/etc/php-fpm.d/cecp-${slug}.conf" \
    DOMAIN "$domain" POOL_NAME "$pool_name" SITE_USER "$site_user" \
    DOCROOT "$docroot" PHP_SOCK "$php_sock"
  mkdir -p "$sock_dir"
  chown nginx:nginx "$sock_dir" 2>/dev/null || true

  panel_log "MariaDB database $db_name ..."
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/mysql.sh"
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
  "installed_at": "$installed_at"
}
EOF
)"

  if [[ "$install_wp" =~ ^[yY] ]]; then
    site_install_wordpress "$domain" "$docroot" "$site_user" "$db_name" "$db_user" "$db_pass"
    # shellcheck source=/dev/null
    source "$PANEL_ROOT/lib/wordpress.sh"
    wp_harden_site "$domain"
    wp_install_system_cron "$domain"
  else
    cat >"$docroot/index.html" <<EOF
<!DOCTYPE html><html><head><title>${domain}</title></head>
<body><h1>CECP Panel</h1><p>Site <strong>${domain}</strong> is ready.</p></body></html>
EOF
    chown "${site_user}:${site_user}" "$docroot/index.html"
  fi

  php_fpm_reload
  nginx_test_and_reload

  panel_log "Site added: http://$domain"
  panel_log "DB: $db_name | user: $db_user | pass: (in $(site_meta_path "$domain"))"

  # Default: bật backup tự động (cron daily + retention) và backup lần đầu cho site mới.
  # An toàn — bỏ qua nếu Drive chưa kết nối, không làm hỏng việc tạo site.
  if declare -F backup_autoenable_for_new_site >/dev/null 2>&1; then
    backup_autoenable_for_new_site "$domain" || true
  fi
}

site_install_wordpress() {
  local domain="$1" docroot="$2" site_user="$3" db_name="$4" db_user="$5" db_pass="$6"
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/wordpress.sh"
  wp_ensure_cli
  panel_log "Installing WordPress for $domain ..."
  local wp_run=(sudo -u "$site_user" php -d memory_limit=512M "$WP_CLI_BIN")
  "${wp_run[@]}" core download --path="$docroot" --quiet
  "${wp_run[@]}" config create \
    --path="$docroot" \
    --dbname="$db_name" --dbuser="$db_user" --dbpass="$db_pass" \
    --dbhost=localhost --dbprefix=wp_ --skip-check
  local admin_pass
  admin_pass="$(rand_alnum 16)"
  "${wp_run[@]}" core install \
    --path="$docroot" \
    --url="http://${domain}" \
    --title="${domain}" \
    --admin_user=admin \
    --admin_password="$admin_pass" \
    --admin_email="admin@${domain}" \
    --skip-email
  chown -R "${site_user}:${site_user}" "$docroot"
  panel_log "WordPress admin user: admin | pass: $admin_pass (save now)"
}

site_remove() {
  local domain="${1,,}"
  require_root
  local meta
  meta="$(site_meta_path "$domain")"
  [[ -f "$meta" ]] || panel_die "Site not found: $domain"

  local site_user slug db_name db_user
  site_user="$(site_json_get "$domain" site_user)"
  slug="$(domain_slug "$domain")"
  db_name="$(site_json_get "$domain" db_name)"
  db_user="$(site_json_get "$domain" db_user)"

  ssl_remove_for_domain "$domain" 2>/dev/null || true

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
  rm -f "/etc/cron.d/cecp-wp-${slug}"
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
  rm -f "$meta"

  php_fpm_reload
  nginx_test_and_reload
  panel_log "Removed site: $domain"
}

site_duplicate() {
  local src="${1,,}" dst="${2,,}"
  require_root
  [[ -n "$src" && -n "$dst" ]] || panel_die "Usage: cecp-panel site duplicate SRC_DOMAIN NEW_DOMAIN"
  [[ -f "$(site_meta_path "$src")" ]] || panel_die "Source not found: $src"
  [[ ! -f "$(site_meta_path "$dst")" ]] || panel_die "Target exists: $dst"
  local src_doc
  src_doc="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$src")'))['docroot'])")"
  site_add "$dst" n
  local dst_doc db_name db_user db_pass src_db src_user src_pass
  dst_doc="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$dst")'))['docroot'])")"
  db_name="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$dst")'))['db_name'])")"
  db_user="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$dst")'))['db_user'])")"
  db_pass="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$dst")'))['db_pass'])")"
  src_db="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$src")'))['db_name'])")"
  src_user="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$src")'))['db_user'])")"
  src_pass="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$src")'))['db_pass'])")"
  panel_log "Copying files $src → $dst ..."
  rsync -a "$src_doc/" "$dst_doc/" 2>/dev/null || cp -a "$src_doc/." "$dst_doc/"
  chown -R "$(python3 -c "import json; print(json.load(open('$(site_meta_path "$dst")'))['site_user'])"):" "$dst_doc"
  panel_log "Copying database $src_db → $db_name ..."
  mysqldump -u"$src_user" -p"$src_pass" "$src_db" | mysql -u"$db_user" -p"$db_pass" "$db_name"
  selinux_fixup_path "$dst_doc"
  if [[ -n "${3:-}" && -f "${3:-}" ]]; then
    site_wordpress_clone_fixup "$src" "$dst" "$3"
  elif [[ "$(wp_site_is_wordpress "$dst" 2>/dev/null || echo False)" == "True" ]]; then
    site_wordpress_clone_fixup "$src" "$dst" ""
  fi
  panel_log "Duplicated $src → $dst"
}

site_wordpress_clone_fixup() {
  local src="${1,,}" dst="${2,,}" repl_file="${3:-}"
  [[ "$(wp_site_is_wordpress "$dst" 2>/dev/null || echo False)" == "True" ]] || return 0
  panel_log "WordPress URL/search-replace for $dst ..."
  wp_site_exec "$dst" search-replace "https://${src}" "https://${dst}" --all-tables --skip-columns-guid 2>/dev/null || true
  wp_site_exec "$dst" search-replace "http://${src}" "https://${dst}" --all-tables 2>/dev/null || true
  wp_site_exec "$dst" option update siteurl "https://${dst}" 2>/dev/null || true
  wp_site_exec "$dst" option update home "https://${dst}" 2>/dev/null || true
  if [[ -n "$repl_file" && -f "$repl_file" ]]; then
    local line old new
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS=$'\t' read -r old new <<<"$line"
      [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || continue
      wp_site_exec "$dst" search-replace "$old" "$new" --all-tables 2>/dev/null || true
    done < <(python3 -c "
import json
for p in json.load(open('$repl_file')):
    o=(p.get('from') or p.get('old') or '').strip()
    n=(p.get('to') or p.get('new') or '').strip()
    if o and n and o!=n:
        print(o+'\t'+n)
")
  fi
}

site_sftp_info() {
  local domain="${1,,}"
  local meta
  meta="$(site_meta_path "$domain")"
  [[ -f "$meta" ]] || panel_die "Site not found: $domain"
  local site_user docroot
  site_user="$(python3 -c "import json; print(json.load(open('$meta'))['site_user'])")"
  docroot="$(python3 -c "import json; print(json.load(open('$meta'))['docroot'])")"
  site_sftp_enable "$site_user"
  local ip
  ip="$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
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
  local meta site_user
  meta="$(site_meta_path "$domain")"
  [[ -f "$meta" ]] || panel_die "Site not found: $domain"
  site_user="$(python3 -c "import json; print(json.load(open('$meta'))['site_user'])")"
  if [[ -z "$pass" ]]; then
    pass="$(rand_alnum 16)"
  fi
  site_sftp_enable "$site_user"
  echo "${site_user}:${pass}" | chpasswd
  usermod -s /usr/sbin/nologin "$site_user" 2>/dev/null || true
  panel_log "SFTP password set for $site_user (domain $domain)"
  panel_log "Password: $pass"
}
