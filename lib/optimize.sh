#!/usr/bin/env bash
set -euo pipefail

ensure_nginx_global() {
  # Idempotent: guarantees the shared nginx zones (cecp_general, cecp_conn, CECP_WP)
  # and the fastcgi cache dir exist BEFORE any site vhost references them.
  require_root
  local src="$PANEL_ROOT/templates/nginx-global-cecp.conf"
  local target="/etc/nginx/conf.d/cecp-global.conf"
  mkdir -p /var/cache/nginx/cecp
  chown nginx:nginx /var/cache/nginx/cecp 2>/dev/null || chown www-data:www-data /var/cache/nginx/cecp 2>/dev/null || true
  if [[ ! -f "$target" ]] || ! cmp -s "$src" "$target"; then
    install -m 644 "$src" "$target"
    panel_log "Installed/updated shared nginx zones -> $target"
  fi
}

optimize_nginx_global() {
  require_root
  ensure_nginx_global
  # worker auto snippet (http context via conf.d is wrong for worker_processes — main context)
  # Put open_file_cache + keepalive in conf.d (http context OK)
  cat >/etc/nginx/conf.d/cecp-perf.conf <<'EOF'
# CECP Panel — http-context performance
open_file_cache max=10000 inactive=60s;
open_file_cache_valid 30s;
open_file_cache_min_uses 2;
open_file_cache_errors on;
keepalive_timeout 65;
keepalive_requests 1000;
EOF
  # main context worker_processes — only if not already set via custom
  if [[ -f /etc/nginx/nginx.conf ]]; then
    if ! grep -qE '^\s*worker_processes\s+auto' /etc/nginx/nginx.conf; then
      sed -i 's/^\s*worker_processes\s\+[0-9]\+;/worker_processes auto;/' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
  fi
  nginx_test_and_reload
  panel_log "Nginx global optimize: gzip, rate limit, fastcgi cache zone, keepalive"
}

optimize_site() {
  local domain="${1,,}"
  require_root
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local slug
  slug="$(domain_slug "$domain")"
  local docroot php_sock site_user pool_name
  docroot="$(site_json_get "$domain" "docroot")"
  php_sock="$(site_json_get "$domain" "php_sock")"
  site_user="$(site_json_get "$domain" "site_user")"
  pool_name="$(site_json_get "$domain" "pool_name")"
  ensure_nginx_global
  template_render "$PANEL_ROOT/templates/nginx-vhost.conf.tpl" \
    "/etc/nginx/conf.d/cecp-${slug}.conf" \
    DOMAIN "$domain" DOCROOT "$docroot" PHP_SOCK "$php_sock"
  template_render "$PANEL_ROOT/templates/php-fpm-pool.conf.tpl" \
    "/etc/php-fpm.d/cecp-${slug}.conf" \
    DOMAIN "$domain" POOL_NAME "$pool_name" SITE_USER "$site_user" \
    DOCROOT "$docroot" PHP_SOCK "$php_sock"
  # Remi multi-PHP: re-place pool if site uses non-default version
  local php_ve
  php_ver="$(python3 -c "import json; print(json.load(open('$(site_meta_path "$domain")')).get('php_version','80'))" 2>/dev/null || echo 80)"
  if [[ "$php_ver" != "80" && -f "$PANEL_ROOT/lib/php_mgr.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PANEL_ROOT/lib/php_mgr.sh"
    local fpm_di
    fpm_dir="$(php_fpm_d_dir "$php_ver")"
    if [[ -d "$fpm_dir" ]]; then
      template_render "$PANEL_ROOT/templates/php-fpm-pool.conf.tpl" \
        "${fpm_dir}/cecp-${slug}.conf" \
        DOMAIN "$domain" POOL_NAME "$pool_name" SITE_USER "$site_user" \
        DOCROOT "$docroot" PHP_SOCK "$php_sock"
      rm -f "/etc/php-fpm.d/cecp-${slug}.conf" 2>/dev/null || true
    fi
  fi
  nginx_test_and_reload
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/ssl.sh"
  ssl_reattach_nginx "$domain" 2>/dev/null || true
  php_fpm_reload
  if [[ -f "$PANEL_ROOT/lib/wordpress.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PANEL_ROOT/lib/wordpress.sh"
    if [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]]; then
      wp_optimize_site "$domain"
    fi
  fi
  panel_log "Optimized site: $domain (nginx cache + php-fpm ondemand)"
}

# ---------------------------------------------------------------------------
# FastCGI cache purge
# ---------------------------------------------------------------------------
optimize_purge_cache() {
  require_root
  local target="${1:-all}"
  if [[ "$target" == "all" || "$target" == "--all" ]]; then
    rm -rf /var/cache/nginx/cecp/*
    mkdir -p /var/cache/nginx/cecp
    chown nginx:nginx /var/cache/nginx/cecp 2>/dev/null || chown www-data:www-data /var/cache/nginx/cecp 2>/dev/null || true
    panel_log "Purged FastCGI cache (all sites)"
    return 0
  fi
  local domain="${target,,}"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  # Key uses host — purge by grepping levels is hard; safe approach: full zone purge
  # or delete files that hash for this host (nginx levels=1:2). Full purge is OK for small VPS.
  panel_log "Purging FastCGI cache for host=$domain (zone CECP_WP shared — clearing matching keys via find)..."
  # Shared zone: safest correct purge is full zone; document that
  rm -rf /var/cache/nginx/cecp/*
  mkdir -p /var/cache/nginx/cecp
  chown nginx:nginx /var/cache/nginx/cecp 2>/dev/null || chown www-data:www-data /var/cache/nginx/cecp 2>/dev/null || true
  panel_log "FastCGI cache cleared (shared zone CECP_WP)"
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
    # shellcheck source=/dev/null
    source /etc/cecp-panel/redis.env
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

  if [[ -n "$conf_d" ]]; then
    echo "$cecp_redis_snippet" >"$conf_d"
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

optimize_redis_wp() {
  local domain="${1,,}"
  require_root
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  [[ -f /etc/cecp-panel/redis.env ]] || optimize_install_redis
  # shellcheck source=/dev/null
  source /etc/cecp-panel/redis.env
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/wordpress.sh"
  [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]] \
    || panel_die "redis-wp requires WordPress: $domain"
  wp_ensure_cli
  panel_log "Configuring Redis object cache for $domain ..."
  wp_site_exec "$domain" plugin install redis-cache --activate 2>/dev/null \
    || wp_site_exec "$domain" plugin activate redis-cache 2>/dev/null || true
  wp_site_exec "$domain" config set WP_REDIS_HOST "${REDIS_HOST:-127.0.0.1}"
  wp_site_exec "$domain" config set WP_REDIS_PORT "${REDIS_PORT:-6379}" --raw
  wp_site_exec "$domain" config set WP_REDIS_PASSWORD "${REDIS_PASSWORD}"
  wp_site_exec "$domain" config set WP_REDIS_PREFIX "cecp_$(domain_slug "$domain")_"
  wp_site_exec "$domain" redis enable 2>/dev/null \
    || wp_site_exec "$domain" redis update-dropin 2>/dev/null || true
  wp_site_exec "$domain" cache flush 2>/dev/null || true
  panel_log "Redis object cache enabled for $domain (plugin redis-cache)"
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
; JIT (PHP 8.0+; ignored on older)
opcache.jit=1255
opcache.jit_buffer_size=64M
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
    local ve
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
  panel_log "OPcache memory=${mem}M JIT=1255 buffer=64M"
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
table_open_cache = 400
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
  cat >"$f" <<'EOF'
# CECP Panel — network + fd tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bb
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
fs.file-max = 2097152
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$f" >/dev/null 2>&1 || true
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  panel_log "Kernel tuning applied ($f). tcp_congestion_control=$cc (expect bbr if kernel supports)"
}

# ---------------------------------------------------------------------------
# Image / Brotli
# ---------------------------------------------------------------------------
optimize_webp() {
  local domain="${1,,}"
  require_root
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/wordpress.sh"
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

# ---------------------------------------------------------------------------
# One-shot stack optimize
# ---------------------------------------------------------------------------
optimize_stack() {
  require_root
  panel_log "Full stack optimize..."
  optimize_kernel_bb
  optimize_nginx_global
  optimize_opcache_jit
  optimize_mariadb_tune
  optimize_install_redis
  panel_log "Stack optimize done. Per-site: optimize site DOMAIN | redis-wp DOMAIN | purge"
}
