#!/usr/bin/env bash
set -euo pipefail

NOTIFY_ENV="${ETC_DIR}/notify.env"

notify_load() {
  [[ -f "$NOTIFY_ENV" ]] || return 1
  # shellcheck source=/dev/null
  source "$NOTIFY_ENV"
  return 0
}

notify_status() {
  echo "=== Notify config ($NOTIFY_ENV) ==="
  if [[ ! -f "$NOTIFY_ENV" ]]; then
    echo "  (not configured)"
    echo "  Setup: cecp-panel notify setup"
    return 0
  fi
  # shellcheck source=/dev/null
  source "$NOTIFY_ENV"
  echo "  TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:+set}${TELEGRAM_BOT_TOKEN:-missing}"
  echo "  TELEGRAM_CHAT_ID:   ${TELEGRAM_CHAT_ID:-missing}"
  echo "  DISCORD_WEBHOOK:    ${DISCORD_WEBHOOK:+set}${DISCORD_WEBHOOK:-missing}"
  echo "  SSL_WARN_DAYS:      ${SSL_WARN_DAYS:-14}"
  echo "  DISK_WARN_PCT:      ${DISK_WARN_PCT:-85}"
  echo "  Cron: /etc/cron.d/cecp-notify-health"
  [[ -f /etc/cron.d/cecp-notify-health ]] && echo "  cron: present" || echo "  cron: absent"
}

notify_setup() {
  require_root
  mkdir -p "$ETC_DIR"
  if [[ ! -f "$NOTIFY_ENV" ]]; then
    cat >"$NOTIFY_ENV" <<'EOF'
# CECP Panel notifications
# Telegram: create bot via @BotFather, get chat_id via @userinfobot
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
# Discord: channel → Integrations → Webhooks
DISCORD_WEBHOOK=
# Thresholds
SSL_WARN_DAYS=14
DISK_WARN_PCT=85
EOF
    chmod 600 "$NOTIFY_ENV"
  fi
  panel_log "Edit $NOTIFY_ENV then: cecp-panel notify test && cecp-panel notify enable-cron"
  if [[ -t 0 ]]; then
    read -r -p "Telegram bot token (empty skip): " t
    read -r -p "Telegram chat id (empty skip): " c
    read -r -p "Discord webhook URL (empty skip): " d
    [[ -n "$t" ]] && sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${t}|" "$NOTIFY_ENV"
    [[ -n "$c" ]] && sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=${c}|" "$NOTIFY_ENV"
    [[ -n "$d" ]] && sed -i "s|^DISCORD_WEBHOOK=.*|DISCORD_WEBHOOK=${d}|" "$NOTIFY_ENV"
  fi
  chmod 600 "$NOTIFY_ENV"
  notify_status
}

notify_send() {
  local msg="${1:-}"
  [[ -n "$msg" ]] || return 0
  notify_load || { panel_log "notify: not configured (skip)"; return 0; }
  local host
  host="$(hostname -f 2>/dev/null || hostname)"
  local full="[CECP ${host}] ${msg}"

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${full}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
    python3 -c "
import json,urllib.request
url='${DISCORD_WEBHOOK}'
data=json.dumps({'content':'''${full}'''}).encode()
req=urllib.request.Request(url, data=data, headers={'Content-Type':'application/json'})
try: urllib.request.urlopen(req, timeout=10)
except Exception: pass
" 2>/dev/null || true
  fi
}

notify_test() {
  require_root
  notify_load || panel_die "Run: cecp-panel notify setup"
  notify_send "Test notification $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  panel_log "Test message sent (check Telegram/Discord)"
}

notify_check_ssl() {
  notify_load || return 0
  local warn_days="${SSL_WARN_DAYS:-14}"
  local now end days d dir alerts=()
  now=$(date +%s)
  shopt -s nullglob
  for dir in /etc/letsencrypt/live/*/; do
    d="$(basename "$dir")"
    [[ "$d" == "README" ]] && continue
    [[ -f "$dir/fullchain.pem" ]] || continue
    end="$(openssl x509 -enddate -noout -in "$dir/fullchain.pem" 2>/dev/null | cut -d= -f2-)" || continue
    local end_epoch
    end_epoch=$(date -d "$end" +%s 2>/dev/null) || continue
    days=$(( (end_epoch - now) / 86400 ))
    if (( days <= warn_days )); then
      alerts+=("SSL ${d}: ${days}d left")
    fi
  done
  shopt -u nullglob
  if (( ${#alerts[@]} > 0 )); then
    local msg
    msg="$(IFS='; '; echo "${alerts[*]}")"
    notify_send "SSL WARN: $msg"
    echo "$msg"
  else
    echo "SSL: all certs > ${warn_days}d"
  fi
}

notify_check_disk() {
  notify_load || return 0
  local thr="${DISK_WARN_PCT:-85}"
  local pct
  pct="$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  [[ -n "$pct" ]] || return 0
  if (( pct >= thr )); then
    notify_send "DISK WARN: / at ${pct}% (threshold ${thr}%)"
    echo "DISK: ${pct}% WARN"
  else
    echo "DISK: ${pct}% OK"
  fi
}

notify_health() {
  # Called by cron — quiet unless issues
  notify_check_ssl
  notify_check_disk
  # fail2ban banned count spike (informational)
  if command -v fail2ban-client &>/dev/null; then
    echo "fail2ban jails configured: check status for bans"
  fi
}

notify_enable_cron() {
  require_root
  cat >/etc/cron.d/cecp-notify-health <<'EOF'
# CECP Panel — SSL expiry + disk alerts (daily 06:15 UTC)
15 6 * * * root /usr/local/bin/cecp-panel notify health >>/var/log/cecp-panel/notify.log 2>&1
EOF
  chmod 644 /etc/cron.d/cecp-notify-health
  panel_log "Enabled daily notify health cron"
}

notify_disable_cron() {
  require_root
  rm -f /etc/cron.d/cecp-notify-health
  panel_log "Disabled notify health cron"
}
