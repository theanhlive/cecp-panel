#!/usr/bin/env bash
# Monitoring + self-healing: cron runs `cecp-panel monitor run` every 5 minutes.
set -euo pipefail

MONITOR_STATE="$VAR_LIB/monitor/state.json"
MONITOR_CRON="/etc/cron.d/cecp-monitor"
MONITOR_SERVICES=(nginx php-fpm mariadb redis fail2ban)

monitor_env() {
  local ssl=14 disk=85 age=36
  if [[ -f "$NOTIFY_ENV" ]]; then
    secure_source "$NOTIFY_ENV"
    ssl="${SSL_WARN_DAYS:-14}"
    disk="${DISK_WARN_PCT:-85}"
    age="${BACKUP_MAX_AGE_HOURS:-36}"
  fi
  export CECP_SITES_DIR="$SITES_DIR" CECP_MONITOR_STATE="$MONITOR_STATE" CECP_BACKUP_STATE="$BACKUP_STATE"
  export CECP_SSL_WARN_DAYS="$ssl" CECP_DISK_WARN_PCT="$disk" CECP_BACKUP_MAX_AGE_HOURS="$age"
}

monitor_run() {
  require_root
  install -d -m 700 "$VAR_LIB/monitor"
  monitor_env
  # Self-heal the PHP-FPM socket ownership problem before probing sites.
  local fixed
  fixed="$(php_fpm_fix_socket_owner)"
  if [[ -n "$fixed" ]]; then
    notify_event socket_fixed warning "PHP-FPM socket ownership repaired (sites were returning 502)" "" \
      "$(python3 -c 'import json,sys; print(json.dumps({"log": sys.argv[1]}))' "$fixed")"
  fi
  local ev sev dom msg det
  while IFS=$'\x1f' read -r ev sev dom msg det; do
    [[ -n "$ev" ]] || continue
    panel_log "monitor: $sev $ev ${dom:+$dom }— $msg"
    notify_event "$ev" "$sev" "$msg" "$dom" "$det"
  done < <(python3 "$PANEL_ROOT/lib/monitor.py" run)
}

monitor_status() {
  monitor_env
  python3 "$PANEL_ROOT/lib/monitor.py" status
  if [[ -f "$MONITOR_CRON" ]]; then echo "Cron: enabled ($MONITOR_CRON)"; else echo "Cron: disabled (cecp-panel monitor enable)"; fi
}

# systemd restarts crashed services on its own; the monitor also starts services that were
# stopped and reports it.
monitor_install_restart_policy() {
  local svc dir
  local -a svcs=("${MONITOR_SERVICES[@]}")
  while read -r svc; do
    [[ -n "$svc" ]] && svcs+=("${svc%.service}")
  done < <(systemctl list-unit-files 'php*-php-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
  for svc in "${svcs[@]}"; do
    systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q . || continue
    dir="/etc/systemd/system/${svc}.service.d"
    mkdir -p "$dir"
    cat >"$dir/cecp-restart.conf" <<'EOF'
# CECP Panel: restart after a crash (max 5 times per 5 minutes)
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Restart=on-failure
RestartSec=5s
EOF
  done
  systemctl daemon-reload
}

monitor_enable() {
  require_root
  monitor_install_restart_policy
  cat >"$MONITOR_CRON" <<'EOF'
# CECP Panel monitor — services, sites, SSL, disk, backup freshness (alerts on change only)
*/5 * * * * root flock -n /run/cecp-monitor.lock /usr/local/bin/cecp-panel monitor run >>/var/log/cecp-panel/monitor.log 2>&1
EOF
  chmod 644 "$MONITOR_CRON"
  panel_log "Monitor enabled: every 5 minutes; services restart automatically on failure"
  monitor_run
}

monitor_disable() {
  require_root
  rm -f "$MONITOR_CRON"
  rm -f /etc/systemd/system/*.service.d/cecp-restart.conf
  systemctl daemon-reload
  panel_log "Monitor disabled (cron + restart policy removed)"
}
