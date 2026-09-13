#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ENV="$ETC_DIR/system.env"
SWAP_FILE="/swapfile"
MAINTAIN_CRON="/etc/cron.d/cecp-system-maintain"

system_load_config() {
  if [[ -f "$SYSTEM_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$SYSTEM_ENV"
  fi
  : "${SWAP_MIN_TOTAL_MB:=512}"
  : "${SWAP_MAX_GB:=4}"
  : "${JOURNAL_RETENTION_DAYS:=7}"
  : "${NGINX_LOG_RETENTION_DAYS:=14}"
  : "${CECP_LOG_RETENTION_DAYS:=30}"
  : "${PHP_FPM_LOG_RETENTION_DAYS:=14}"
  : "${DNF_CLEAN:=true}"
  : "${APT_CLEAN:=true}"
  : "${DISK_CLEAN_MIN_USE_PCT:=70}"
  : "${LOG_TRUNCATE_MB:=50}"
  : "${MAINTAIN_CRON_HOUR:=3}"
  : "${MAINTAIN_CRON_MINUTE:=30}"
}

system_ensure_config() {
  require_root
  mkdir -p "$ETC_DIR"
  if [[ ! -f "$SYSTEM_ENV" ]]; then
    cp "$PANEL_ROOT/templates/system.env.example" "$SYSTEM_ENV" 2>/dev/null || touch "$SYSTEM_ENV"
    chmod 600 "$SYSTEM_ENV"
    panel_log "Created $SYSTEM_ENV"
  fi
}

system_mem_total_mb() {
  awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo
}

system_swap_total_mb() {
  awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo
}

system_disk_use_pct() {
  local mount="${1:-/}"
  df "$mount" 2>/dev/null | awk 'NR==2 {
    gsub(/%/,"",$5); print $5
  }' || echo 0
}

system_swap_recommended_gb() {
  system_load_config
  local ram_mb max_gb
  ram_mb="$(system_mem_total_mb)"
  max_gb="$SWAP_MAX_GB"
  if [[ "$ram_mb" -le 2048 ]]; then
    echo 2
  elif [[ "$ram_mb" -le 4096 ]]; then
    echo $(( (ram_mb + 1023) / 1024 ))
  elif [[ "$ram_mb" -le 8192 ]]; then
    echo 4
  else
    echo "$max_gb"
  fi
}

system_info() {
  system_load_config 2>/dev/null || true
  echo "--- VPS ---"
  panel_host_fqdn
  echo "  IP: $(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || panel_local_ipv4)"
  echo "  OS: $(cat /etc/os-release 2>/dev/null | awk -F= '/^PRETTY_NAME=/{gsub(/"/,"");print $2}')"
  echo "  Uptime: $(uptime -p 2>/dev/null || uptime)"
  echo "--- Disk ---"
  df -h / /var /home 2>/dev/null | sed 's/^/  /'
  local pct
  pct="$(system_disk_use_pct /)"
  echo "  Root use: ${pct}% (auto disk-clean when >= ${DISK_CLEAN_MIN_USE_PCT:-70}%)"
  echo "--- Memory ---"
  free -h | sed 's/^/  /'
  echo "--- Swap ---"
  swapon --show 2>/dev/null | sed 's/^/  /' || echo "  (no swap)"
  local rec
  rec="$(system_swap_recommended_gb 2>/dev/null || echo "?")"
  echo "  Recommended swap file: ${rec}G (cecp-panel system ensure-swap)"
}

system_swap_add() {
  local size_gb="${1:-1}"
  require_root
  [[ -f "$SWAP_FILE" ]] && panel_die "Swap file $SWAP_FILE already exists (use: cecp-panel system info)"
  panel_log "Creating ${size_gb}G swap at $SWAP_FILE ..."
  fallocate -l "${size_gb}G" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((size_gb * 1024)) status=progress
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  grep -qF "$SWAP_FILE" /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >>/etc/fstab
  panel_log "Swap enabled"
  swapon --show
}

system_swap_ensure() {
  require_root
  system_ensure_config
  system_load_config
  local cur_mb rec_gb
  cur_mb="$(system_swap_total_mb)"
  if [[ "$cur_mb" -ge "$SWAP_MIN_TOTAL_MB" ]]; then
    panel_log "Swap OK: ${cur_mb}MB (min ${SWAP_MIN_TOTAL_MB}MB)"
    swapon --show 2>/dev/null || true
    return 0
  fi
  if [[ -f "$SWAP_FILE" ]]; then
    panel_log "Swap file exists but inactive — enabling ..."
    swapon "$SWAP_FILE" 2>/dev/null && return 0
  fi
  rec_gb="$(system_swap_recommended_gb)"
  panel_log "Low swap (${cur_mb}MB) — creating ${rec_gb}G swap file ..."
  system_swap_add "$rec_gb"
}

system_truncate_large_logs() {
  local dir="$1" max_mb="$2"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f -name '*.log' -size +"${max_mb}M" 2>/dev/null | while read -r f; do
    : >"$f"
    panel_log "Truncated large log: $f"
  done
}

system_clean_logs() {
  require_root
  system_load_config
  journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}d" 2>/dev/null || true
  find /var/log/nginx -type f \( -name '*.log' -o -name '*.log.*' \) -mtime +"${NGINX_LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
  find "$LOG_DIR" -type f -name '*.log' -mtime +"${CECP_LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
  find /var/log/php-fpm -type f -name '*.log' -mtime +"${PHP_FPM_LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
  system_truncate_large_logs /var/log/nginx "$LOG_TRUNCATE_MB"
  system_truncate_large_logs "$LOG_DIR" "$LOG_TRUNCATE_MB"
  panel_log "Log cleanup (journal ${JOURNAL_RETENTION_DAYS}d, nginx>${NGINX_LOG_RETENTION_DAYS}d)"
}

system_clean_package_cache() {
  system_load_config
  if [[ -f /etc/redhat-release ]]; then
    [[ "$DNF_CLEAN" == "true" ]] && dnf clean all -y &>/dev/null || yum clean all -y &>/dev/null || true
  elif [[ -f /etc/debian_version ]]; then
    [[ "$APT_CLEAN" == "true" ]] && apt-get clean -y &>/dev/null && apt-get autoclean -y &>/dev/null || true
  fi
}

system_clean_temp_and_cache() {
  find /tmp -mindepth 1 -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
  find /var/tmp -mindepth 1 -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
  rm -rf /var/cache/nginx/cecp/* 2>/dev/null || true
  rm -rf /root/.cache/restic 2>/dev/null || true
  if command -v certbot &>/dev/null; then
    find /var/log/letsencrypt -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true
  fi
}

system_clean_wp_transients() {
  command -v wp &>/dev/null || return 0
  local f domain docroot site_user
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("wordpress") else 1)' "$f" 2>/dev/null || continue
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    docroot="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["docroot"])' "$f")"
    site_user="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["site_user"])' "$f")"
    [[ -d "$docroot" ]] || continue
    sudo -u "$site_user" wp transient delete --expired --path="$docroot" --quiet 2>/dev/null && \
      panel_log "WP transients: $domain" || true
  done
  shopt -u nullglob
}

system_disk_clean() {
  require_root
  system_load_config
  local pct before after
  pct="$(system_disk_use_pct /)"
  if [[ "$pct" -lt "$DISK_CLEAN_MIN_USE_PCT" ]]; then
    panel_log "Disk use ${pct}% < ${DISK_CLEAN_MIN_USE_PCT}% — light cleanup only"
  else
    panel_log "Disk use ${pct}% >= ${DISK_CLEAN_MIN_USE_PCT}% — full cleanup"
  fi
  before="$(df / | awk 'NR==2 {print $3}')"
  system_clean_logs
  system_clean_package_cache
  system_clean_temp_and_cache
  if [[ "$pct" -ge "$DISK_CLEAN_MIN_USE_PCT" ]]; then
    system_clean_wp_transients
  fi
  after="$(df / | awk 'NR==2 {print $3}')"
  panel_log "Disk cleanup done (used blocks before=$before after=$after)"
  df -h / | sed 's/^/  /'
}

system_enable_maintain_cron() {
  require_root
  system_ensure_config
  system_load_config
  cat >"$MAINTAIN_CRON" <<EOF
# CECP Panel — weekly swap check + disk maintenance
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${MAINTAIN_CRON_MINUTE} ${MAINTAIN_CRON_HOUR} * * 0 root /usr/local/bin/cecp-panel system maintain >>${LOG_DIR}/maintain.log 2>&1
EOF
  chmod 644 "$MAINTAIN_CRON"
  panel_log "Weekly maintenance cron: Sun ${MAINTAIN_CRON_HOUR}:${MAINTAIN_CRON_MINUTE} UTC ($MAINTAIN_CRON)"
}

system_maintain() {
  require_root
  system_load_config
  panel_log "=== CECP system maintain $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  system_swap_ensure
  system_disk_clean
  # Pre-restore safety copies and interrupted verify/staging leftovers older than a week.
  find "$VAR_LIB/restore" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
  find "$VAR_LIB" -maxdepth 1 -name 'verify.*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
  find "$VAR_LIB/backup-staging" -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
  # Safety copies of staging pushes / WP updates and DB exports: kept 14 days for manual undo.
  find "$VAR_LIB/staging-push" "$VAR_LIB/wp-update" -mindepth 1 -maxdepth 1 -mtime +14 -exec rm -rf {} + 2>/dev/null || true
  find "$VAR_LIB/db-exports" -mindepth 1 -maxdepth 1 -name '*.sql.gz' -mtime +14 -delete 2>/dev/null || true
}

# Rotate the panel's own logs (per-site nginx logs are covered by the distro's nginx rule).
system_logrotate_install() {
  require_root
  cat >/etc/logrotate.d/cecp-panel <<'EOF'
# CECP Panel logs (managed by cecp-panel)
/var/log/cecp-panel/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
# wp-cron logs are written by each site's user: truncate in place to keep ownership.
/var/log/cecp-panel/wp-cron/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  chmod 644 /etc/logrotate.d/cecp-panel
  if [[ ! -f /etc/logrotate.d/nginx ]] || ! grep -qE '/var/log/nginx/\*\.?log' /etc/logrotate.d/nginx; then
    panel_log "WARN: no logrotate rule for /var/log/nginx/*.log — per-site nginx logs will grow unbounded"
  fi
  panel_log "Logrotate: /etc/logrotate.d/cecp-panel"
}

system_tune_install() {
  require_root
  system_ensure_config
  system_swap_ensure
  system_disk_clean
  system_enable_maintain_cron
  system_logrotate_install
  panel_log "System tune: swap + disk policy + weekly cron + logrotate"
}

system_tune() {
  system_tune_install
}
