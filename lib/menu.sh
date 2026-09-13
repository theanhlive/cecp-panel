#!/usr/bin/env bash
set -euo pipefail

menu_banner() {
  # shellcheck source=/dev/null
  [[ -f "$PANEL_ROOT/lib/colors.sh" ]] && source "$PANEL_ROOT/lib/colors.sh"
  local load up
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
  up="$(uptime -p 2>/dev/null || true)"
  echo "========================================================================="
  echo -e "  ${C_BOLD}${C_CYAN}CECP Panel v${CECP_PANEL_VERSION}${C_RESET} — VPS management"
  echo "-------------------------------------------------------------------------"
  if command -v free &>/dev/null; then
    free -h | awk '/Mem:/ {print "  RAM: "$3" / "$2}'
  fi
  df -h / 2>/dev/null | awk 'NR==2 {print "  Disk: "$3" used / "$2" ("$5")"}'
  echo "  Load: $load  ${up:+| $up}"
  echo "-------------------------------------------------------------------------"
}

menu_domain() {
  while true; do
    echo ""
    echo "== Domain management =="
    echo " 1) List domains"
    echo " 2) Add domain (+ optional WordPress)"
    echo " 3) Remove domain"
    echo " 4) Duplicate domain"
    echo " 5) SFTP info"
    echo " 6) Set SFTP password"
    echo " 7) Protect wp-admin (basic auth / IP allowlist)"
    echo " 8) Rebuild vhost + pool (apply current templates)"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) site_list ;;
      2)
        read -r -p "Domain: " dom
        [[ -z "$dom" ]] && continue
        read -r -p "WordPress? (y/n): " wp
        site_add "$dom" "$wp"
        ;;
      3)
        read -r -p "Domain: " dom
        [[ -z "$dom" ]] && continue
        read -r -p "Confirm delete $dom? (yes): " ok
        [[ "$ok" == "yes" ]] && site_remove "$dom"
        ;;
      4)
        read -r -p "Source domain: " s
        read -r -p "New domain: " d
        [[ -n "$s" && -n "$d" ]] && site_duplicate "$s" "$d"
        ;;
      5)
        read -r -p "Domain: " dom
        [[ -n "$dom" ]] && site_sftp_info "$dom"
        ;;
      6)
        read -r -p "Domain: " dom
        [[ -n "$dom" ]] && site_sftp_password "$dom"
        ;;
      7)
        read -r -p "Domain: " dom
        [[ -z "$dom" ]] && continue
        read -r -p "on / off / status / reset-password [status]: " a
        a="${a:-status}"
        if [[ "$a" == "on" ]]; then
          read -r -p "Allowed IPs/CIDRs (comma, empty = anywhere): " ips
          if [[ -n "$ips" ]]; then site_protect_admin "$dom" on --ip "$ips"; else site_protect_admin "$dom" on; fi
        else
          site_protect_admin "$dom" "$a"
        fi
        ;;
      8)
        read -r -p "Domain (or --all): " dom
        if [[ "$dom" == "--all" ]]; then
          site_rebuild_vhost_all
        elif [[ -n "$dom" ]]; then
          site_rebuild_vhost "$dom"
        fi
        ;;
      0) break ;;
    esac
  done
}

menu_ssl() {
  while true; do
    echo ""
    echo "== SSL (Let's Encrypt) =="
    echo " 1) List  2) Add  3) Remove  4) Renew  5) Status  6) HSTS on/off/subdomains"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) ssl_list ;;
      2) read -r -p "Domain: " dom; [[ -n "$dom" ]] && ssl_issue_for_domain "$dom" ;;
      3) read -r -p "Domain: " dom; [[ -n "$dom" ]] && ssl_remove_for_domain "$dom" ;;
      4) ssl_renew_all ;;
      5) ssl_status ;;
      6)
        read -r -p "Domain: " dom
        read -r -p "on / off / subdomains: " m
        [[ -n "$dom" && -n "$m" ]] && ssl_set_hsts "$dom" "$m"
        ;;
      0) break ;;
    esac
  done
}

menu_dns() {
  while true; do
    echo ""
    echo "== Cloudflare DNS =="
    echo " 1) List A records (default zone)"
    echo " 2) Add/update A record (subdomain → this VPS)"
    echo " 3) Point site domain to this VPS"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) dns_list_a ;;
      2)
        read -r -p "Name (test2 or fqdn): " n
        read -r -p "Proxied? (y/n): " px
        local ip
        ip="$(curl -4 -s ifconfig.me 2>/dev/null || panel_local_ipv4)"
        [[ "$px" =~ ^[nN] ]] && dns_add_a "$n" "$ip" false || dns_add_a "$n" "$ip" true
        ;;
      3)
        read -r -p "Domain: " dom
        [[ -n "$dom" ]] && dns_point_site "$dom"
        ;;
      0) break ;;
    esac
  done
}

menu_security() {
  while true; do
    echo ""
    echo "== Security =="
    echo " 1) fail2ban status"
    echo " 2) Firewall status"
    echo " 3) SSH settings"
    echo " 4) SSH harden (prohibit-password root)"
    echo " 5) Disable SSH password login (keys only)"
    echo " 6) Change SSH port"
    echo " 7) Fail2Ban full jails"
    echo " 8) MariaDB bind localhost"
    echo " 9) Apply production profile (all-in-one)"
    echo "10) Security self-check"
    echo "11) Auto security updates (dnf-automatic / unattended)"
    echo "12) Repair SFTP sshd drop-ins"
    echo "13) Fix permissions + redact old secrets in logs"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) security_fail2ban_status ;;
      2) security_firewall_status ;;
      3) security_ssh_show ;;
      4) security_ssh_harden ;;
      5)
        read -r -p "Disable password SSH? Ensure key works! (yes): " ok
        [[ "$ok" == "yes" ]] && security_apply_ssh_key_only
        ;;
      6)
        read -r -p "New SSH port [2222]: " p
        security_ssh_set_port "${p:-2222}"
        ;;
      7) security_fail2ban_full ;;
      8) security_mariadb_bind_local ;;
      9) security_apply_production ;;
      10) security_self_check ;;
      11) security_unattended_updates ;;
      12) security_ssh_repair ;;
      13) security_fix_permissions ;;
      0) break ;;
    esac
  done
}

menu_wordpress() {
  while true; do
    echo ""
    echo "== WordPress =="
    echo " 1) Harden site"
    echo " 2) Optimize (harden+cron+db)"
    echo " 3) System cron (disable wp-cron web)"
    echo " 4) Status"
    echo " 0) Back"
    read -r -p "Domain: " d
    [[ -z "$d" || "$d" == "0" ]] && { [[ "$d" == "0" ]] && break; continue; }
    read -r -p "Action (1-4): " c
    case "$c" in
      1) wp_harden_site "$d" ;;
      2) wp_optimize_site "$d" ;;
      3) wp_install_system_cron "$d" ;;
      4) wp_status_site "$d" ;;
    esac
  done
}

menu_perf() {
  while true; do
    echo ""
    echo "== Performance =="
    echo " 1) Global nginx (gzip, cache zone, rate limit)"
    echo " 2) Optimize one site (vhost + pool + WP)"
    echo " 3) Install/secure Redis"
    echo " 4) Redis object cache for WordPress site"
    echo " 5) Tune MariaDB (by RAM)"
    echo " 6) OPcache + JIT"
    echo " 7) Kernel BBR + sysctl"
    echo " 8) Purge FastCGI cache (all)"
    echo " 9) Full stack optimize (1-7)"
    echo "10) Bench TTFB (domain)"
    echo "11) Brotli (origin)"
    echo "12) WebP (WordPress plugin)"
    echo "13) Media optimize (per-site on/off)"
    echo "14) Purge cache of one site"
    echo "15) Purge one URL (origin cache)"
    echo "16) Cache report (hit ratio, p50/p95)"
    echo "17) Redis: per-site ACL for all sites + rotate shared password"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) optimize_nginx_global ;;
      2)
        read -r -p "Domain: " d
        [[ -n "$d" ]] && optimize_site "$d"
        ;;
      3) optimize_install_redis ;;
      4)
        read -r -p "Domain: " d
        [[ -n "$d" ]] && optimize_redis_wp "$d"
        ;;
      5) optimize_mariadb_tune ;;
      6) optimize_opcache_jit ;;
      7) optimize_kernel_bbr ;;
      8) optimize_purge_cache all ;;
      9) optimize_stack ;;
      10)
        read -r -p "Domain: " d
        optimize_bench "${d:-}"
        ;;
      11) optimize_brotli ;;
      12)
        read -r -p "Domain: " d
        [[ -n "$d" ]] && optimize_webp "$d"
        ;;
      13) menu_media ;;
      14) read -r -p "Domain: " d; [[ -n "$d" ]] && optimize_purge_cache "$d" ;;
      15) read -r -p "URL: " u; [[ -n "$u" ]] && optimize_purge_url "$u" ;;
      16) read -r -p "Domain: " d; [[ -n "$d" ]] && optimize_report "$d" 5000 ;;
      17) optimize_redis_acl --all ;;
      0) break ;;
    esac
  done
}

menu_media() {
  while true; do
    echo ""
    echo "== Media optimize (per-site opt-in) =="
    echo " 1) Status (all sites)"
    echo " 2) Enable for domain (on-upload + cron)"
    echo " 3) Disable for domain"
    echo " 4) Run once (backlog batch)"
    echo " 5) Dry-run"
    echo " 6) Enable global daily cron"
    echo " 7) Disable global daily cron"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) media_status ;;
      2)
        read -r -p "Domain: " d
        [[ -z "$d" ]] && continue
        read -r -p "Max width [1920]: " mw
        mw="${mw:-1920}"
        read -r -p "Quality [80]: " q
        q="${q:-80}"
        media_enable "$d" --max-width "$mw" --quality "$q"
        ;;
      3)
        read -r -p "Domain: " d
        [[ -n "$d" ]] && media_disable "$d"
        ;;
      4)
        read -r -p "Domain: " d
        [[ -n "$d" ]] && media_run "$d"
        ;;
      5)
        read -r -p "Domain: " d
        [[ -n "$d" ]] && media_run "$d" --dry-run
        ;;
      6) media_enable_cron ;;
      7) media_disable_cron ;;
      0) break ;;
    esac
  done
}

menu_system() {
  while true; do
    echo ""
    echo "== System (RAM / disk) =="
    echo " 1) VPS info"
    echo " 2) Auto swap (theo RAM VPS)"
    echo " 3) Add swap file (manual GB)"
    echo " 4) Disk + log cleanup"
    echo " 5) Full tune (swap + clean + weekly cron)"
    echo " 6) Enable weekly maintain cron"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) system_info ;;
      2) system_swap_ensure ;;
      3)
        read -r -p "Size GB [2]: " gb
        system_swap_add "${gb:-2}"
        ;;
      4) system_disk_clean ;;
      5) system_tune ;;
      6) system_enable_maintain_cron ;;
      0) break ;;
    esac
  done
}

menu_php() {
  while true; do
    echo ""
    echo "== PHP =="
    echo " 1) List versions / per-site"
    echo " 2) Install PHP (81/82/83 via Remi)"
    echo " 3) Set site PHP version"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) php_list_versions ;;
      2)
        read -r -p "Version (81/82/83): " v
        [[ -n "$v" ]] && php_install_version "$v"
        ;;
      3)
        read -r -p "Domain: " d
        read -r -p "PHP version: " v
        [[ -n "$d" && -n "$v" ]] && php_set_site_version "$d" "$v"
        ;;
      0) break ;;
    esac
  done
}

menu_update() {
  while true; do
    echo ""
    echo "== Updates =="
    echo " 1) Check versions"
    echo " 2) Update panel (from mirror)"
    echo " 3) Set update mirror URL"
    echo " 4) Update nginx"
    echo " 5) Update mariadb"
    echo " 6) Update php (system)"
    echo " 7) Update all OS packages"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) update_check ;;
      2) update_panel ;;
      3)
        read -r -p "Mirror base URL: " u
        [[ -n "$u" ]] && update_mirror_set "$u"
        ;;
      4) update_component nginx ;;
      5) update_component mariadb ;;
      6) update_component php ;;
      7) update_component all ;;
      0) break ;;
    esac
  done
}

menu_backup() {
  while true; do
    echo ""
    echo "== Backup =="
    echo " 1) Setup  2) Status  3) Run all  4) List snapshots"
    echo " 5) Policy  6) Daily cron  7) Prune now  8) Verify (test restore)"
    echo " 9) Restore to a folder  10) Restore LIVE (with automatic rollback)"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) backup_setup ;;
      2) backup_status ;;
      3) backup_run_all ;;
      4) backup_list ;;
      5) backup_policy_show ;;
      6) backup_enable_cron ;;
      7) backup_apply_retention ;;
      8) read -r -p "Domain [--all]: " d; backup_verify "${d:---all}" ;;
      9)
        read -r -p "Domain: " d
        read -r -p "Snapshot id [latest]: " s
        [[ -n "$d" ]] && backup_restore "$d" "${s:-latest}"
        ;;
      10)
        read -r -p "Domain: " d
        read -r -p "Snapshot id [latest]: " s
        [[ -n "$d" ]] && backup_restore "$d" "${s:-latest}" --live
        ;;
      0) break ;;
    esac
  done
}

menu_notify() {
  while true; do
    echo ""
    echo "== Notify (Telegram / Discord) =="
    echo " 1) Status  2) Setup  3) Test  4) Health check now"
    echo " 5) Enable daily cron  6) Disable cron  7) Webhook (n8n) URL"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) notify_status ;;
      2) notify_setup ;;
      3) notify_test ;;
      4) notify_health ;;
      5) notify_enable_cron ;;
      6) notify_disable_cron ;;
      7) read -r -p "Webhook URL (or off): " u; [[ -n "$u" ]] && notify_webhook_set "$u" ;;
      0) break ;;
    esac
  done
}

menu_cf() {
  while true; do
    echo ""
    echo "== Cloudflare edge =="
    echo " 1) Status (zone settings)"
    echo " 2) Purge cache (zone)"
    echo " 3) Enable Brotli"
    echo " 4) Cache level aggressive"
    echo " 5) Recommendations"
    echo " 6) Refresh Cloudflare real-IP ranges"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) read -r -p "Zone [default]: " z; cf_status "${z:-}" ;;
      2) read -r -p "Zone/domain [default]: " z; cf_purge "${z:-all}" ;;
      3) cf_set_brotli on ;;
      4) cf_set_cache_level aggressive ;;
      5) cf_recommend ;;
      6) cf_realip_update ;;
      0) break ;;
    esac
  done
}

menu_modsec() {
  while true; do
    echo ""
    echo "== ModSecurity (optional / advanced) =="
    echo " 1) Status  2) Install  3) Enable  4) Disable  5) Blocking mode"
    echo " 0) Back"
    read -r -p "Choice: " c
    case "$c" in
      1) modsec_status ;;
      2) modsec_install ;;
      3) modsec_enable ;;
      4) modsec_disable ;;
      5)
        read -r -p "Enable real blocking? WP may break (yes): " ok
        [[ "$ok" == "yes" ]] && modsec_blocking
        ;;
      0) break ;;
    esac
  done
}

menu_main() {
  while true; do
    menu_banner
    echo " 1) Domains (add/remove/duplicate/SFTP)"
    echo " 2) SSL (Let's Encrypt)"
    echo " 3) Cloudflare DNS"
    echo " 4) Backup (Google Drive)"
    echo " 5) Security (fail2ban/SSH/production)"
    echo " 6) WordPress (harden/optimize)"
    echo " 7) Performance (cache/gzip/redis/media)"
    echo " 8) System (info/swap/logs)"
    echo " 9) MariaDB hardening"
    echo "10) PHP versions"
    echo "11) Updates (OS / panel)"
    echo "12) CECP agent"
    echo "13) Quick status"
    echo "14) Notify (Telegram/Discord)"
    echo "15) Cloudflare edge (purge/brotli)"
    echo "16) ModSecurity (optional)"
    echo "17) View logs"
    echo "18) Monitoring (status / run / enable / disable)"
    echo " 0) Exit"
    echo "========================================================================="
    read -r -p "Choice [0]: " choice
    choice="${choice:-0}"
    case "$choice" in
      1) menu_domain ;;
      2) menu_ssl ;;
      3) menu_dns ;;
      4) menu_backup ;;
      5) menu_security ;;
      6) menu_wordpress ;;
      7) menu_perf ;;
      8) menu_system ;;
      9) mysql_secure_basics ;;
      10) menu_php ;;
      11) menu_update ;;
      12) agent_install; agent_status ;;
      13) show_status ;;
      14) menu_notify ;;
      15) menu_cf ;;
      16) menu_modsec ;;
      17)
        read -r -p "log kind [panel|nginx|php|mysql|fail2ban]: " k
        read -r -p "domain (nginx only, empty=global): " d
        log_view "${k:-panel}" "$d" 80
        ;;
      18)
        read -r -p "status / run / enable / disable [status]: " a
        case "${a:-status}" in
          run) monitor_run ;;
          enable) monitor_enable ;;
          disable) monitor_disable ;;
          *) monitor_status ;;
        esac
        ;;
      0) exit 0 ;;
      *) echo "Unknown option" ;;
    esac
  done
}

show_status() {
  # shellcheck source=/dev/null
  [[ -f "$PANEL_ROOT/lib/colors.sh" ]] && source "$PANEL_ROOT/lib/colors.sh"
  system_info
  echo ""
  echo "--- Versions ---"
  command -v nginx >/dev/null && echo "  nginx: $(nginx -v 2>&1 | head -1)"
  command -v php >/dev/null && echo "  php:   $(php -v 2>/dev/null | head -1)"
  command -v mysql >/dev/null && echo "  mysql: $(mysql --version 2>/dev/null | head -1)"
  echo "  panel: $CECP_PANEL_VERSION"
  echo ""
  echo "--- Services ---"
  for s in nginx mariadb fail2ban php-fpm redis redis-server; do
    systemctl list-unit-files "${s}*" --type=service --no-legend 2>/dev/null | head -1 | grep -q . || continue
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      echo -e "  ${C_GREEN}[OK]${C_RESET} $s"
    else
      # skip missing units quietly
      systemctl status "$s" &>/dev/null || continue
      echo -e "  ${C_RED}[--]${C_RESET} $s"
    fi
  done
  # PHP-FPM remi
  systemctl list-units 'php*-php-fpm*' --type=service --state=running --no-legend 2>/dev/null \
    | awk '{print "  [OK] "$1}' || true
  echo ""
  echo "--- SSL days left ---"
  local now d dir end end_epoch days
  now=$(date +%s)
  shopt -s nullglob
  for dir in /etc/letsencrypt/live/*/; do
    d="$(basename "$dir")"
    [[ "$d" == "README" ]] && continue
    [[ -f "$dir/fullchain.pem" ]] || continue
    end="$(openssl x509 -enddate -noout -in "$dir/fullchain.pem" 2>/dev/null | cut -d= -f2-)" || continue
    end_epoch=$(date -d "$end" +%s 2>/dev/null) || continue
    days=$(( (end_epoch - now) / 86400 ))
    if (( days <= 14 )); then
      echo -e "  ${C_YELLOW}${d}: ${days}d${C_RESET}"
    else
      echo "  ${d}: ${days}d"
    fi
  done
  shopt -u nullglob
  echo ""
  site_list
  echo ""
  if [[ "$(id -u)" -eq 0 && -f "$MONITOR_STATE" ]]; then
    monitor_status 2>/dev/null | grep -E "FAIL|last run|failing" || true
    echo ""
  fi
  echo "Cache: X-CECP-Cache header on PHP pages | purge: cecp-panel optimize purge DOMAIN"
}
