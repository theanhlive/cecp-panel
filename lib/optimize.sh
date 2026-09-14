#!/usr/bin/env bash
set -euo pipefail

ensure_nginx_global() {
  # Idempotent: installs the shared http-context config (zones, cache key, log format), the
  # header/TLS snippets and the Cloudflare real-IP list BEFORE any vhost references them.
  require_root
  local src="$PANEL_ROOT/templates/nginx-global-cecp.conf"
  # "00-": conf.d is read alphabetically and log_format must be defined before a vhost uses it
  # (cecp-a*.conf would otherwise load before cecp-global.conf).
  local target="/etc/nginx/conf.d/00-cecp-global.conf"
  rm -f /etc/nginx/conf.d/cecp-global.conf
  mkdir -p /var/cache/nginx/cecp /etc/nginx/snippets
  chown nginx:nginx /var/cache/nginx/cecp 2>/dev/null || chown www-data:www-data /var/cache/nginx/cecp 2>/dev/null || true
  local rendered
  rendered="$(<"$src")"
  # Ubuntu's nginx.conf already has `gzip on;` — a second one fails nginx -t.
  if grep -qE '^\s*gzip\s+on\s*;' /etc/nginx/nginx.conf 2>/dev/null; then
    rendered="$(grep -vE '^\s*gzip\s+on\s*;' <<<"$rendered")"
  fi
  if [[ ! -f "$target" ]] || [[ "$(<"$target")" != "$rendered" ]]; then
    printf '%s\n' "$rendered" >"$target"
    chmod 644 "$target"
    panel_log "Installed/updated shared nginx config -> $target"
  fi
  install -m 644 "$PANEL_ROOT/templates/nginx-snippet-headers.conf" /etc/nginx/snippets/cecp-headers.conf
  # Staging / preview sites: same headers + never index (vhost picks it via meta noindex).
  { cat "$PANEL_ROOT/templates/nginx-snippet-headers.conf"
    echo 'add_header X-Robots-Tag "noindex, nofollow" always;'
  } | install -m 644 /dev/stdin /etc/nginx/snippets/cecp-headers-noindex.conf
  install -m 644 "$PANEL_ROOT/templates/nginx-snippet-ssl.conf" /etc/nginx/snippets/cecp-ssl-params.conf
  if [[ ! -f /etc/nginx/conf.d/cecp-cloudflare-realip.conf ]]; then
    cf_realip_render "$PANEL_ROOT/templates/cloudflare-ips.txt"
  fi
}

optimize_nginx_global() {
  require_root
  ensure_nginx_global
  # http-context tuning via conf.d. Never repeat directives the distro nginx.conf already sets
  # (keepalive_timeout, sendfile, gzip on Ubuntu) — nginx -t rejects duplicates.
  cat >/etc/nginx/conf.d/cecp-perf.conf <<'EOF'
# CECP Panel — http-context performance
open_file_cache max=10000 inactive=60s;
open_file_cache_valid 30s;
open_file_cache_min_uses 2;
open_file_cache_errors on;
EOF
  # main context worker_processes — only if not already set via custom
  if [[ -f /etc/nginx/nginx.conf ]]; then
    if ! grep -qE '^\s*worker_processes\s+auto' /etc/nginx/nginx.conf; then
      sed -i 's/^\s*worker_processes\s\+[0-9]\+;/worker_processes auto;/' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
  fi
  nginx_test_and_reload
  panel_log "Nginx global optimize: gzip, rate limit, fastcgi cache, real IP, open_file_cache"
}

optimize_site() {
  local domain="${1,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  site_rebuild_vhost "$domain"
  if [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]]; then
    wp_optimize_site "$domain"
  fi
  panel_log "Optimized site: $domain (nginx cache + php-fpm ondemand)"
}

# ---------------------------------------------------------------------------
# FastCGI cache purge
# ---------------------------------------------------------------------------
CECP_CACHE_DIR="/var/cache/nginx/cecp"

optimize_purge_cache() {
  require_root
  local target="${1:-all}"
  if [[ "$target" == "all" || "$target" == "--all" ]]; then
    find "$CECP_CACHE_DIR" -mindepth 1 -delete 2>/dev/null || true
    panel_log "Purged FastCGI cache (all sites)"
    return 0
  fi
  local domain="${target,,}"
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  # Every cache file carries a "KEY: <scheme><method><host><uri>" header line.
  local f n=0
  while IFS= read -r -d '' f; do
    rm -f "$f" && n=$((n + 1))
  done < <(grep -rlaZF \
             -e "KEY: httpsGET${domain}/" -e "KEY: httpGET${domain}/" \
             -e "KEY: httpsHEAD${domain}/" -e "KEY: httpHEAD${domain}/" \
             "$CECP_CACHE_DIR" 2>/dev/null || true)
  panel_log "Purged FastCGI cache for $domain (${n} entries)"
}

# Purge one URL from the origin cache: md5 of the cache key → levels=1:2 file path.
optimize_purge_url() {
  require_root
  local url="${1:-}"
  validate_url "$url"
  local f n=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    rm -f "$f" && n=$((n + 1))
  done < <(python3 - "$url" "$CECP_CACHE_DIR" <<'PY'
import hashlib, re, sys
from urllib.parse import urlsplit
u, root = urlsplit(sys.argv[1]), sys.argv[2]
track = re.compile(r"^(?:(?:utm_[a-z_]+|fbclid|gclid|gbraid|wbraid|dclid|msclkid|ttclid|twclid|igshid|mc_cid|mc_eid|_ga|_gl)=[^&]*&?)+$")
pct = re.compile(r"%[0-9a-fA-F]{2}")
path = u.path or "/"
uri = path if (u.query and track.match(u.query)) else path + ("?" + u.query if u.query else "")
host = (u.hostname or "").lower()
# The key is the raw request URI: purge both %xx spellings (WordPress lowercase, browsers uppercase).
uris = dict.fromkeys([uri, pct.sub(lambda m: m.group(0).upper(), uri), pct.sub(lambda m: m.group(0).lower(), uri)])
for scheme in ("http", "https"):  # the page may be cached under either scheme (proxy, redirects)
    for method in ("GET", "HEAD"):
        for x in uris:
            h = hashlib.md5(f"{scheme}{method}{host}{x}".encode()).hexdigest()
            print(f"{root}/{h[-1]}/{h[-3:-1]}/{h}")
PY
)
  panel_log "Purged origin cache for $url (${n} entries)"
}

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------
optimize_redis_mem_mb() {
  local ram_mb
  ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
  # 10% RAM, min 64, max 512
  local m=$(( ram_mb / 10 ))
  (( m < 64 )) && m=64
  (( m > 512 )) && m=512
  echo "$m"
}

optimize_install_redis() {
  require_root
  if command -v security_audit_log &>/dev/null; then
    security_audit_log "optimize redis-install"
  fi
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
    dnf -y install redis 2>/dev/null || true
    dnf -y install php-pecl-redis php-redis 2>/dev/null || true
  else
    apt-get install -y redis-server 2>/dev/null || true
    apt-get install -y php-redis 2>/dev/null || true
  fi

  local conf=""
  for conf in /etc/redis/redis.conf /etc/redis.conf; do
    [[ -f "$conf" ]] && break
  done
  [[ -f "$conf" ]] || panel_die "Redis config not found after install"

  local mem pass conf_d
  mem="$(optimize_redis_mem_mb)"
  mkdir -p /etc/cecp-panel
  if [[ -f /etc/cecp-panel/redis.env ]]; then
    secure_source /etc/cecp-panel/redis.env
    pass="${REDIS_PASSWORD:-}"
  fi
  if [[ -z "${pass:-}" ]]; then
    pass="$(rand_alnum 24)"
    cat >/etc/cecp-panel/redis.env <<EOF
REDIS_PASSWORD=${pass}
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_MAXMEMORY_MB=${mem}
EOF
    chmod 600 /etc/cecp-panel/redis.env
  fi

  # Prefer drop-in conf.d if supported
  conf_d=""
  if [[ -d /etc/redis/redis.conf.d ]] || mkdir -p /etc/redis 2>/dev/null; then
    if grep -q 'include' "$conf" 2>/dev/null || [[ -d /etc/redis ]]; then
      conf_d=/etc/redis/cecp.conf
    fi
  fi

  local cecp_redis_snippet
  cecp_redis_snippet="$(cat <<EOF
# CECP Panel Redis hardening
bind 127.0.0.1 -::1
protected-mode yes
requirepass ${pass}
maxmemory ${mem}mb
maxmemory-policy allkeys-lru
save ""
appendonly no
EOF
)"
  if redis_supports_acl; then
    cecp_redis_snippet+=$'\n'"include ${REDIS_ACL_CONF}"
  fi

  if [[ -n "$conf_d" ]]; then
    echo "$cecp_redis_snippet" >"$conf_d"
    # Contains requirepass: readable by root and the redis group only.
    chown root:redis "$conf_d" 2>/dev/null || true
    chmod 640 "$conf_d"
    redis_acl_write_conf
    if ! grep -qF "cecp.conf" "$conf" 2>/dev/null; then
      echo "include $conf_d" >>"$conf"
    fi
  else
    # inline sed on main conf
    sed -i 's/^#\?bind .*/bind 127.0.0.1 -::1/' "$conf" 2>/dev/null || true
    if grep -qE '^\s*requirepass' "$conf"; then
      sed -i "s/^\s*requirepass.*/requirepass ${pass}/" "$conf"
    else
      echo "requirepass ${pass}" >>"$conf"
    fi
    if grep -qE '^\s*maxmemory\s' "$conf"; then
      sed -i "s/^\s*maxmemory\s.*/maxmemory ${mem}mb/" "$conf"
    else
      echo "maxmemory ${mem}mb" >>"$conf"
    fi
    if grep -qE '^\s*maxmemory-policy' "$conf"; then
      sed -i 's/^\s*maxmemory-policy.*/maxmemory-policy allkeys-lru/' "$conf"
    else
      echo "maxmemory-policy allkeys-lru" >>"$conf"
    fi
  fi

  systemctl enable --now redis 2>/dev/null || systemctl enable --now redis-server 2>/dev/null || true
  systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null || true
  panel_log "Redis secured: bind=127.0.0.1 maxmemory=${mem}mb policy=allkeys-lru"
  panel_log "Password stored in /etc/cecp-panel/redis.env (chmod 600)"
  panel_log "WP object cache: cecp-panel optimize redis-wp DOMAIN"
}

REDIS_ACL_CONF="/etc/redis/cecp-acl.conf"

redis_supports_acl() {
  local v
  v="$(redis-server --version 2>/dev/null | grep -oE 'v=[0-9]+' | cut -d= -f2)"
  [[ -n "$v" ]] && (( v >= 6 ))
}

# Admin redis-cli: commands on stdin and the password in REDISCLI_AUTH, so no secret in argv.
redis_admin() {
  secure_source /etc/cecp-panel/redis.env
  REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}"
}

# Persist per-site ACL users (from site meta) so they survive a Redis restart.
redis_acl_write_conf() {
  local tmp
  tmp="$(mktemp)"
  python3 - "$SITES_DIR" >"$tmp" <<'PY'
import glob, json, re, sys
for p in sorted(glob.glob(sys.argv[1] + "/*.json")):
    d = json.load(open(p))
    u, pw = d.get("redis_user", ""), d.get("redis_pass", "")
    if re.fullmatch(r"cecp_[a-z0-9_]+", u) and re.fullmatch(r"[A-Za-z0-9]+", pw):
        print(f"user {u} on >{pw} ~{u}_* +@all -@admin -@dangerous +info +ping +select")
PY
  install -m 640 -o root -g redis "$tmp" "$REDIS_ACL_CONF" 2>/dev/null || install -m 640 "$tmp" "$REDIS_ACL_CONF"
  rm -f "$tmp"
}

# Each site gets a Redis ACL user limited to its own key prefix. Before, all sites shared one
# password, so any site's PHP could read (or flush) every other site's object cache.
redis_site_acl() {
  local domain="$1" slug user pass
  slug="$(domain_slug "$domain")"
  user="cecp_${slug}"
  pass="$(site_json_get_or "$domain" redis_pass "")"
  if [[ -z "$pass" ]]; then
    pass="$(rand_alnum 32)"
    site_json_set "$domain" redis_user "$user" redis_pass "$pass"
  fi
  printf 'ACL SETUSER %s reset on >%s ~%s_* +@all -@admin -@dangerous +info +ping +select\n' \
    "$user" "$pass" "$user" | redis_admin >/dev/null
  redis_acl_write_conf
}

# Write the Redis constants straight into wp-config.php (as root, keeping ownership): passing
# the password to `wp config set` would expose it in the process list.
redis_wp_config_write() {
  local docroot="$1" user="$2" pass="$3" prefix="$4" host="$5" port="$6"
  python3 - "$docroot/wp-config.php" "$user" "$pass" "$prefix" "$host" "$port" <<'PY'
import re, sys
path, user, pw, prefix, host, port = sys.argv[1:7]
src = open(path, encoding="utf-8").read()
src = re.sub(r"^\s*define\(\s*['\"]WP_REDIS_(HOST|PORT|PASSWORD|PREFIX|SELECTIVE_FLUSH)['\"].*\n", "", src, flags=re.M)
auth = f"['{user}', '{pw}']" if user else f"'{pw}'"
block = (
    "/* CECP Panel: Redis object cache (managed) */\n"
    f"define( 'WP_REDIS_HOST', '{host}' );\n"
    f"define( 'WP_REDIS_PORT', {int(port)} );\n"
    f"define( 'WP_REDIS_PASSWORD', {auth} );\n"
    f"define( 'WP_REDIS_PREFIX', '{prefix}' );\n"
    "define( 'WP_REDIS_SELECTIVE_FLUSH', true );\n"
)
src = src.replace("/* CECP Panel: Redis object cache (managed) */\n", "")
marker = "/* That's all, stop editing!"
src = src.replace(marker, block + marker, 1) if marker in src else src.replace("<?php", "<?php\n" + block, 1)
open(path, "w", encoding="utf-8").write(src)
PY
}

# Re-write the Redis constants of a site from its meta (e.g. after restoring an old wp-config).
redis_wp_config_refresh() {
  local domain="$1" slug user="" pass
  [[ -f /etc/cecp-panel/redis.env ]] || return 0
  secure_source /etc/cecp-panel/redis.env
  slug="$(domain_slug "$domain")"
  pass="$(site_json_get_or "$domain" redis_pass "")"
  if [[ -n "$pass" ]]; then
    user="cecp_${slug}"
  else
    pass="$REDIS_PASSWORD"
  fi
  redis_wp_config_write "$(site_json_get "$domain" docroot)" "$user" "$pass" \
    "cecp_${slug}_" "${REDIS_HOST:-127.0.0.1}" "${REDIS_PORT:-6379}"
}

optimize_redis_wp() {
  local domain="${1,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  [[ -f /etc/cecp-panel/redis.env ]] || optimize_install_redis
  secure_source /etc/cecp-panel/redis.env
  [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]] \
    || panel_die "redis-wp requires WordPress: $domain"
  wp_ensure_cli
  panel_log "Configuring Redis object cache for $domain ..."
  wp_site_exec "$domain" plugin install redis-cache --activate 2>/dev/null \
    || wp_site_exec "$domain" plugin activate redis-cache 2>/dev/null || true
  local slug user="" pass="$REDIS_PASSWORD"
  slug="$(domain_slug "$domain")"
  if redis_supports_acl; then
    redis_site_acl "$domain"
    user="cecp_${slug}"
    pass="$(site_json_get "$domain" redis_pass)"
  else
    panel_log "WARN: Redis < 6 has no ACLs — $domain shares the server-wide Redis password"
  fi
  redis_wp_config_write "$(site_json_get "$domain" docroot)" "$user" "$pass" \
    "cecp_${slug}_" "${REDIS_HOST:-127.0.0.1}" "${REDIS_PORT:-6379}"
  site_json_set "$domain" redis true
  wp_site_exec "$domain" redis enable 2>/dev/null \
    || wp_site_exec "$domain" redis update-dropin 2>/dev/null || true
  wp_site_exec "$domain" cache flush 2>/dev/null || true
  panel_log "Redis object cache enabled for $domain (ACL user: ${user:-default})"
}

# cecp-panel optimize redis-acl DOMAIN|--all
# --all moves every site already using Redis to its own ACL user, then rotates the shared
# password so copies of it left in old wp-config.php files stop working.
optimize_redis_acl() {
  local target="${1:-}"
  require_root
  redis_supports_acl || panel_die "Redis >= 6 required for per-site ACLs"
  [[ -f /etc/cecp-panel/redis.env ]] || panel_die "Redis not installed by the panel (cecp-panel optimize redis)"
  if [[ "$target" != "--all" ]]; then
    optimize_redis_wp "$target"
    return 0
  fi
  local f domain docroot
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    docroot="$(site_json_get "$domain" docroot)"
    if [[ "$(site_json_get_or "$domain" redis false)" == "True" ]] || grep -q "WP_REDIS_" "$docroot/wp-config.php" 2>/dev/null; then
      optimize_redis_wp "$domain"
    fi
  done
  shopt -u nullglob
  local newpass
  newpass="$(rand_alnum 32)"
  printf 'CONFIG SET requirepass %s\n' "$newpass" | redis_admin >/dev/null
  env_set /etc/cecp-panel/redis.env REDIS_PASSWORD "$newpass"
  local conf
  for conf in /etc/redis/cecp.conf /etc/redis/redis.conf /etc/redis.conf; do
    [[ -f "$conf" ]] && sed -i -E "s/^\s*requirepass\s.*/requirepass ${newpass}/" "$conf"
  done
  panel_log "Redis: per-site ACL users applied; shared default password rotated"
}

# ---------------------------------------------------------------------------
# OPcache + JIT
# ---------------------------------------------------------------------------
optimize_opcache_jit() {
  require_root
  local ram_mb mem
  ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
  mem=128
  (( ram_mb >= 2048 )) && mem=192
  (( ram_mb >= 4096 )) && mem=256

  local conf_body
  conf_body="$(cat <<EOF
; CECP Panel OPcache + JIT
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=${mem}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.save_comments=1
; JIT off by default: PHP 8.0's JIT is experimental and crashes (SIGSEGV) under real
; WordPress traffic (hook-heavy, highly dynamic code is exactly what triggers its bugs) —
; confirmed live on a production VPS. It also buys little for an I/O-bound web workload;
; the real win here is opcache.enable=1 above. Turn on deliberately, per PHP version, only
; after load-testing: opcache.jit=1255 / opcache.jit_buffer_size=64M.
opcache.jit=disable
opcache.jit_buffer_size=0
EOF
)"

  local written=0
  local d f
  # Alma system + Remi
  for d in /etc/php.d /etc/opt/remi/php*/php.d; do
    [[ -d $d ]] || continue
    f="${d}/99-cecp-opcache.ini"
    echo "$conf_body" >"$f"
    written=1
    panel_log "OPcache/JIT -> $f"
  done
  # Ubuntu
  for d in /etc/php/*/mods-available; do
    [[ -d $d ]] || continue
    f="${d}/cecp-opcache.ini"
    echo "$conf_body" >"$f"
    local ver
    ver="$(echo "$d" | grep -oE '[0-9]+\.[0-9]+' || true)"
    if [[ -n "$ver" ]] && command -v phpenmod &>/dev/null; then
      phpenmod -v "$ver" cecp-opcache 2>/dev/null || true
    fi
    written=1
    panel_log "OPcache/JIT -> $f"
  done
  [[ "$written" == "1" ]] || panel_log "WARN: no php.d found; pool-level opcache values still apply"
  php_fpm_reload || true
  # reload remi fpm services
  systemctl list-units 'php*-php-fpm*' --type=service --state=running --no-legend 2>/dev/null \
    | awk '{print $1}' | while read -r svc; do
      systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
    done
  panel_log "OPcache memory=${mem}M, JIT off by default (unstable under PHP 8.0; enable manually per version after testing)"
}

# ---------------------------------------------------------------------------
# MariaDB tune by RAM
# ---------------------------------------------------------------------------
optimize_mariadb_tune() {
  require_root
  local ram_mb pool max_conn
  ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
  # ~50% RAM for buffer pool on dedicated DB; on shared LEMP use ~25-40%
  pool=$(( ram_mb * 30 / 100 ))
  (( pool < 128 )) && pool=128
  (( pool > 4096 )) && pool=4096
  max_conn=50
  (( ram_mb >= 2048 )) && max_conn=80
  (( ram_mb >= 4096 )) && max_conn=150
  (( ram_mb >= 8192 )) && max_conn=200
  # ~12 WordPress tables per site plus plugins; 400 caused constant table re-opens on multi-site hosts.
  local table_cache sites
  sites="$(find "$SITES_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
  table_cache=$(( sites * 100 ))
  (( table_cache < 2000 )) && table_cache=2000

  local f
  if [[ -d /etc/my.cnf.d ]]; then
    f=/etc/my.cnf.d/cecp-tune.cnf
  elif [[ -d /etc/mysql/mariadb.conf.d ]]; then
    f=/etc/mysql/mariadb.conf.d/99-cecp-tune.cnf
  else
    f=/etc/mysql/conf.d/cecp-tune.cnf
    mkdir -p "$(dirname "$f")"
  fi
  cat >"$f" <<EOF
[mysqld]
# CECP auto-tune RAM=${ram_mb}MB
innodb_buffer_pool_size = ${pool}M
innodb_log_file_size = 128M
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
max_connections = ${max_conn}
tmp_table_size = 64M
max_heap_table_size = 64M
table_open_cache = ${table_cache}
table_definition_cache = 1400
query_cache_type = 0
skip_name_resolve = 1
EOF
  systemctl restart mariadb 2>/dev/null || systemctl restart mysql
  panel_log "MariaDB tuned: innodb_buffer_pool=${pool}M max_connections=${max_conn} (RAM ${ram_mb}MB) -> $f"
}

# ---------------------------------------------------------------------------
# Kernel BBR
# ---------------------------------------------------------------------------
optimize_kernel_bbr() {
  require_root
  local f=/etc/sysctl.d/99-cecp-bbr.conf
  mkdir -p /etc/sysctl.d
  cat >"$f" <<'EOF'
# CECP Panel — network + fd tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
fs.file-max = 2097152
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
  # BBR is a module: load it now and at boot, otherwise sysctl rejects "bbr" (early at boot too).
  mkdir -p /etc/modules-load.d
  printf 'tcp_bbr\n' >/etc/modules-load.d/cecp-bbr.conf
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || sysctl -p "$f" >/dev/null 2>&1 || true
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  if [[ "$cc" == "bbr" ]]; then
    panel_log "Kernel tuning applied ($f). tcp_congestion_control=bbr"
  else
    panel_log "WARN: tcp_congestion_control=$cc — kernel lacks BBR or sysctl is read-only (container)"
  fi
}

# ---------------------------------------------------------------------------
# Image / Brotli
# ---------------------------------------------------------------------------
optimize_webp() {
  local domain="${1,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]] \
    || panel_die "WebP enable requires WordPress: $domain"
  wp_ensure_cli
  panel_log "Enabling WebP (webp-express) on $domain ..."
  wp_site_exec "$domain" plugin install webp-express --activate 2>/dev/null \
    || wp_site_exec "$domain" plugin activate webp-express
  wp_site_exec "$domain" cache flush 2>/dev/null || true
  panel_log "WebP enabled on $domain (webp-express active; converts images on delivery)"
}

optimize_brotli() {
  require_root
  local installed=0
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
    dnf -y install nginx-mod-http-brotli >/dev/null 2>&1 && installed=1 || true
  else
    apt-get install -y libnginx-mod-brotli >/dev/null 2>&1 && installed=1 || true
  fi
  if [[ "$installed" != "1" ]]; then
    panel_log "Brotli origin module NOT available via package manager on this host."
    echo "RESULT: brotli=unavailable_origin"
    echo "RECOMMENDATION: Enable Brotli at Cloudflare edge (Speed > Optimization > Brotli)."
    return 0
  fi
  local f=/etc/nginx/conf.d/cecp-brotli.conf
  cat >"$f" <<'EOF'
brotli on;
brotli_comp_level 5;
brotli_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
EOF
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    panel_log "Brotli enabled at origin (nginx) — $f"
    echo "RESULT: brotli=enabled_origin"
  else
    rm -f "$f"
    panel_log "Brotli config test failed; reverted. Recommend Cloudflare edge Brotli."
    echo "RESULT: brotli=test_failed_reverted"
  fi
}

# ---------------------------------------------------------------------------
# Benchmark (light)
# ---------------------------------------------------------------------------
optimize_bench() {
  local domain="${1:-}"
  local url="http://127.0.0.1/"
  if [[ -n "$domain" ]]; then
    domain="${domain,,}"
    domain="${domain#https://}"
    domain="${domain#http://}"
    domain="${domain%%/*}"
    validate_domain "$domain"
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      url="https://${domain}/"
    else
      url="http://${domain}/"
    fi
  fi
  echo "=== TTFB bench: $url ==="
  if command -v curl &>/dev/null; then
    curl -o /dev/null -s -w "  DNS: %{time_namelookup}s\n  Connect: %{time_connect}s\n  TTFB: %{time_starttransfer}s\n  Total: %{time_total}s\n  HTTP: %{http_code}\n  Size: %{size_download}\n" \
      -A "CECP-Bench/1.4" --max-time 30 -k "$url" || panel_log "curl failed"
  else
    panel_die "curl required"
  fi
}

# cecp-panel optimize report DOMAIN [LINES] — cache hit ratio and latency from the `cecp` log format.
optimize_report() {
  local domain="${1,,}" n="${2:-5000}"
  validate_domain "$domain"
  validate_int_range "$n" 1 1000000 "line count"
  local log="/var/log/nginx/${domain}-access.log"
  [[ -f "$log" ]] || panel_die "No access log: $log"
  tail -n "$n" "$log" | python3 -c '
import re, sys
rows = []
for line in sys.stdin:
    m = re.search(r" rt=([0-9.]+) cs=(\S+)$", line.rstrip())
    if m:
        rows.append((float(m.group(1)), m.group(2)))
if not rows:
    sys.exit("No requests in the cecp log format yet (run: cecp-panel site rebuild-vhost DOMAIN)")
def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(round(p / 100 * (len(vals) - 1))))] * 1000
dyn = [r for r in rows if r[1] != "-"]
print(f"=== {sys.argv[1]}: last {len(rows)} logged requests ({len(dyn)} dynamic) ===")
counts = {}
for _, s in dyn:
    counts[s] = counts.get(s, 0) + 1
for s, c in sorted(counts.items(), key=lambda kv: -kv[1]):
    print(f"  {s:12} {c:7}  {100 * c / len(dyn):5.1f}%")
hits = [t for t, s in dyn if s in ("HIT", "STALE", "UPDATING", "REVALIDATED")]
miss = [t for t, s in dyn if s not in ("HIT", "STALE", "UPDATING", "REVALIDATED")]
for name, vals in (("all", [t for t, _ in rows]), ("cached", hits), ("uncached", miss)):
    if vals:
        print(f"  {name:9} p50={pct(vals, 50):7.1f} ms  p95={pct(vals, 95):7.1f} ms")
' "$domain"
}

# ---------------------------------------------------------------------------
# One-shot stack optimize
# ---------------------------------------------------------------------------
optimize_stack() {
  require_root
  panel_log "Full stack optimize..."
  optimize_kernel_bbr
  optimize_nginx_global
  optimize_opcache_jit
  optimize_mariadb_tune
  optimize_install_redis
  panel_log "Stack optimize done. Per-site: optimize site DOMAIN | redis-wp DOMAIN | purge"
}
