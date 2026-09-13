#!/usr/bin/env bash
# Per-site resource limits (cecp-panel site limits). The site's PHP pool moves out of the
# shared PHP-FPM master into its own master, cecp-php-fpm@SLUG.service, which systemd caps
# (CPUQuota / MemoryMax / TasksMax) inside cecp-sites.slice — a hacked site or a runaway
# plugin then exhausts its own budget instead of the whole VPS.
# The socket lives in the unit's RuntimeDirectory: php-fpm.service deletes /run/php-fpm
# (its RuntimeDirectory) on every restart, which would cut an isolated site off.
set -euo pipefail

FPM_ISOLATED_DIR="$ETC_DIR/fpm"
FPM_ISOLATED_RUN="/run/cecp-php-fpm"

limits_unit() { echo "cecp-php-fpm@$(domain_slug "$1").service"; }
limits_dropin_dir() { echo "/etc/systemd/system/cecp-php-fpm@$(domain_slug "$1").service.d"; }
limits_sock() { echo "$FPM_ISOLATED_RUN/$(domain_slug "$1")/php.sock"; }

limits_fpm_bin() {
  local v
  v="$(php_version_normalize "$(site_json_get_or "$1" php_version 80)")"
  if [[ "$v" == 80 ]]; then echo /usr/sbin/php-fpm; else echo "/opt/remi/php${v}/root/usr/sbin/php-fpm"; fi
}

limits_install_template() {
  cat >/etc/systemd/system/cecp-sites.slice <<'EOF'
[Unit]
Description=CECP Panel sites with resource limits
Before=slices.target
EOF
  cat >/etc/systemd/system/cecp-php-fpm@.service <<'EOF'
[Unit]
Description=PHP-FPM with resource limits for site_%i (cecp-panel site limits)
After=network.target

[Service]
Type=notify
Slice=cecp-sites.slice
RuntimeDirectory=cecp-php-fpm/%i
RuntimeDirectoryMode=0755
# SELinux: nginx may only connect to sockets with the php-fpm run type.
ExecStartPre=-/usr/bin/chcon -t httpd_var_run_t /run/cecp-php-fpm/%i
ExecStart=/usr/sbin/php-fpm --nodaemonize --fpm-config /etc/cecp-panel/fpm/%i.conf
ExecReload=/bin/kill -USR2 $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# FPM master config + unit drop-in (binary for the site's PHP version, limits) for DOMAIN.
# Called by site_render_pool for isolated sites.
limits_write_master() {
  local domain="$1" slug bin dropin cpu mem tasks new
  slug="$(domain_slug "$domain")"
  bin="$(limits_fpm_bin "$domain")"
  [[ -x "$bin" ]] || panel_die "PHP-FPM binary $bin missing (cecp-panel php install $(site_json_get_or "$domain" php_version 80))"
  # Rebuilt on a fresh server (restore): the template unit is not part of the site backup.
  [[ -f /etc/systemd/system/cecp-php-fpm@.service ]] || { limits_install_template; systemctl daemon-reload; }
  install -d -m 700 "$FPM_ISOLATED_DIR"
  cat >"$FPM_ISOLATED_DIR/${slug}.conf" <<EOF
; Managed by cecp-panel (site limits $domain) — rewritten on every render.
[global]
pid = $FPM_ISOLATED_RUN/$slug/php-fpm.pid
error_log = syslog
syslog.ident = cecp-php-fpm-$slug
daemonize = no
include = $FPM_ISOLATED_DIR/${slug}.pool.conf
EOF
  chmod 600 "$FPM_ISOLATED_DIR/${slug}.conf"
  cpu="$(site_json_get_or "$domain" limit_cpu 100)"
  mem="$(site_json_get_or "$domain" limit_mem_mb 1024)"
  tasks="$(site_json_get_or "$domain" limit_tasks 256)"
  dropin="$(limits_dropin_dir "$domain")"
  new="$(cat <<EOF
# Managed by cecp-panel site limits $domain
[Service]
ExecStart=
ExecStart=$bin --nodaemonize --fpm-config $FPM_ISOLATED_DIR/${slug}.conf
CPUQuota=${cpu}%
MemoryHigh=$(( mem * 9 / 10 ))M
MemoryMax=${mem}M
TasksMax=${tasks}
EOF
)"
  mkdir -p "$dropin"
  if [[ ! -f "$dropin/cecp.conf" || "$(<"$dropin/cecp.conf")" != "$new" ]]; then
    printf '%s\n' "$new" >"$dropin/cecp.conf"
    systemctl daemon-reload
  fi
}

limits_wait_socket() {
  local sock="$1"
  for _ in $(seq 30); do
    [[ -S "$sock" ]] && return 0
    sleep 0.3
  done
  return 1
}

# cecp-panel site limits DOMAIN [on] [--cpu PCT] [--mem SIZE] [--tasks N] | off | show
site_limits() {
  local domain="${1:-}"
  shift || true
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local action=on
  case "${1:-show}" in
    off|show|status) action="${1}"; shift ;;
    on) shift ;;
    --*) ;;
    *) panel_die "Usage: cecp-panel site limits DOMAIN [--cpu 100] [--mem 1G] [--tasks 256] | off | show" ;;
  esac
  case "$action" in
    show|status) limits_show "$domain"; return 0 ;;
    off) limits_off "$domain"; return 0 ;;
  esac
  local cpu mem tasks ram_mb
  cpu="$(site_json_get_or "$domain" limit_cpu 100)"
  mem="$(site_json_get_or "$domain" limit_mem_mb 1024)"
  tasks="$(site_json_get_or "$domain" limit_tasks 256)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpu) cpu="${2:-}"; cpu="${cpu%\%}"; shift 2 || panel_die "--cpu needs a value" ;;
      --mem)
        [[ "${2:-}" =~ ^[0-9]{1,5}[MmGg]$ ]] || panel_die "--mem: use a size like 512M or 2G"
        mem="$(php_cfg_mb "$2")"; shift 2
        ;;
      --tasks) tasks="${2:-}"; shift 2 || panel_die "--tasks needs a value" ;;
      *) panel_die "Unknown option: $1" ;;
    esac
  done
  ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  [[ "$cpu" =~ ^[0-9]{1,4}$ ]] && (( cpu >= 10 && cpu <= 6400 )) || panel_die "--cpu is percent of one core: 10..6400 (100 = 1 core)"
  (( mem >= 128 && mem <= ram_mb )) || panel_die "--mem must be 128M..${ram_mb}M (RAM of this server)"
  [[ "$tasks" =~ ^[0-9]{1,5}$ ]] && (( tasks >= 16 && tasks <= 32768 )) || panel_die "--tasks must be 16..32768"
  local children
  children="$(php_cfg_get "$domain" pm_max_children)"
  [[ "$children" == auto ]] && children="$(php_pool_max_children)"
  if (( children * 48 > mem )); then
    panel_log "WARN: pm.max_children=$children needs ~$(( children * 48 ))M at full load; with --mem ${mem}M busy workers will be OOM-killed. Consider: cecp-panel php config $domain pm_max_children=$(( mem / 64 > 2 ? mem / 64 : 2 ))"
  fi
  local was unit sock code
  was="$(site_json_get_or "$domain" php_isolated false)"
  unit="$(limits_unit "$domain")"
  sock="$(limits_sock "$domain")"
  limits_install_template
  site_json_set "$domain" php_isolated true limit_cpu "$cpu" limit_mem_mb "$mem" limit_tasks "$tasks" php_sock "$sock"
  site_render_pool "$domain"
  systemctl daemon-reload
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if ! systemctl restart "$unit" || ! limits_wait_socket "$sock"; then
    panel_log "ERROR: $unit did not start (journalctl -u $unit) — reverting"
    limits_off "$domain"
    panel_die "Resource limits NOT applied to $domain"
  fi
  php_fpm_fix_socket_owner
  site_render_vhost "$domain"
  nginx_test_and_reload || { limits_off "$domain"; panel_die "nginx rejected the vhost for $domain (limits reverted)"; }
  # The shared master still holds the old pool: a reload drops it.
  [[ "$was" == "True" ]] || { php_fpm_reload_all; php_fpm_fix_socket_owner; }
  sleep 1
  if ! code="$(site_http_check "$domain")"; then
    panel_log "ERROR: $domain answers HTTP $code with its own PHP-FPM — reverting"
    limits_off "$domain"
    panel_die "Resource limits NOT applied to $domain"
  fi
  panel_log "Limits for $domain: CPU ${cpu}% (of one core), RAM ${mem}M, ${tasks} tasks — PHP runs in $unit"
}

limits_off() {
  local domain="$1" unit slug ver
  unit="$(limits_unit "$domain")"
  slug="$(domain_slug "$domain")"
  ver="$(php_version_normalize "$(site_json_get_or "$domain" php_version 80)")"
  site_json_set "$domain" php_isolated false \
    php_sock "$(php_fpm_sock_for_version "$ver" "$(site_json_get "$domain" pool_name)")"
  site_render_pool "$domain"
  # Pool added back to a shared master: restart (a reload re-owns sockets as root → 502).
  if [[ "$ver" == 80 ]]; then php_fpm_restart_for_new_pool php-fpm
  else php_fpm_restart_for_new_pool "$(php_remipkg_prefix "$ver")-php-fpm"; fi
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_log "WARN: nginx rejected the vhost for $domain"
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  rm -rf "$(limits_dropin_dir "$domain")"
  rm -f "$FPM_ISOLATED_DIR/${slug}.conf" "$FPM_ISOLATED_DIR/${slug}.pool.conf"
  systemctl daemon-reload
  panel_log "Resource limits removed for $domain (back on the shared PHP-FPM)"
}

limits_show() {
  local domain="$1" unit
  unit="$(limits_unit "$domain")"
  echo "=== Resource limits: $domain ==="
  if [[ "$(site_json_get_or "$domain" php_isolated false)" != "True" ]]; then
    echo "  none (PHP runs in the shared PHP-FPM). Enable: cecp-panel site limits $domain --cpu 100 --mem 1G"
    return 0
  fi
  echo "  unit:   $unit ($(systemctl is-active "$unit" 2>/dev/null || true))"
  echo "  limits: CPU $(site_json_get "$domain" limit_cpu)% of one core, RAM $(site_json_get "$domain" limit_mem_mb)M, $(site_json_get "$domain" limit_tasks) tasks"
  systemctl show -p MemoryCurrent -p TasksCurrent -p CPUUsageNSec "$unit" 2>/dev/null | python3 -c '
import sys
d = dict(l.strip().split("=", 1) for l in sys.stdin if "=" in l)
def num(k):
    try:
        return int(d.get(k, ""))
    except ValueError:
        return None
m, t, c = num("MemoryCurrent"), num("TasksCurrent"), num("CPUUsageNSec")
print("  usage:  RAM %s, tasks %s, CPU time %s" % (
    "%d M" % (m // 1048576) if m is not None else "n/a",
    t if t is not None else "n/a",
    "%d s" % (c // 10**9) if c is not None else "n/a"))
'
}
