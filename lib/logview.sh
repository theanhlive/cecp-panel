#!/usr/bin/env bash
set -euo pipefail

log_view() {
  local kind="${1:-panel}"
  local domain="${2:-}"
  local lines="${3:-80}"
  case "$kind" in
    panel)
      echo "=== $LOG_DIR/panel.log (last $lines) ==="
      tail -n "$lines" "$LOG_DIR/panel.log" 2>/dev/null || echo "(empty)"
      ;;
    audit)
      echo "=== $LOG_DIR/audit.log (last $lines) ==="
      tail -n "$lines" "$LOG_DIR/audit.log" 2>/dev/null || echo "(empty)"
      ;;
    nginx)
      if [[ -n "$domain" ]]; then
        echo "=== nginx access $domain ==="
        tail -n "$lines" "/var/log/nginx/${domain}-access.log" 2>/dev/null || echo "(no access log)"
        echo "=== nginx error $domain ==="
        tail -n "$lines" "/var/log/nginx/${domain}-error.log" 2>/dev/null || echo "(no error log)"
      else
        echo "=== nginx error.log ==="
        tail -n "$lines" /var/log/nginx/error.log 2>/dev/null || echo "(empty)"
      fi
      ;;
    php|php-fpm)
      echo "=== php-fpm ==="
      journalctl -u php-fpm -n "$lines" --no-pager 2>/dev/null \
        || journalctl -u 'php*-fpm' -n "$lines" --no-pager 2>/dev/null \
        || tail -n "$lines" /var/log/php-fpm/error.log 2>/dev/null \
        || echo "(no php logs found)"
      ;;
    mysql|mariadb)
      echo "=== mariadb/mysql ==="
      journalctl -u mariadb -n "$lines" --no-pager 2>/dev/null \
        || journalctl -u mysql -n "$lines" --no-pager 2>/dev/null \
        || tail -n "$lines" /var/log/mariadb/mariadb.log 2>/dev/null \
        || echo "(no mysql logs)"
      ;;
    fail2ban)
      fail2ban-client status 2>/dev/null | head -40 || true
      journalctl -u fail2ban -n "$lines" --no-pager 2>/dev/null || true
      ;;
    notify)
      tail -n "$lines" "$LOG_DIR/notify.log" 2>/dev/null || echo "(empty)"
      ;;
    *)
      panel_die "Usage: cecp-panel log panel|audit|nginx|php|mysql|fail2ban|notify [DOMAIN] [LINES]"
      ;;
  esac
}
