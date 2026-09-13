#!/usr/bin/env bash
set -euo pipefail

NOTIFY_ENV="${ETC_DIR}/notify.env"
EVENTS_LOG="${LOG_DIR}/events.log"

notify_ensure_env() {
  mkdir -p "$ETC_DIR"
  [[ -f "$NOTIFY_ENV" ]] && return 0
  cat >"$NOTIFY_ENV" <<'EOF'
# CECP Panel notifications
# Telegram: create bot via @BotFather, get chat_id via @userinfobot
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
# Discord: channel → Integrations → Webhooks
DISCORD_WEBHOOK=
# Generic JSON webhook (n8n …), signed with HMAC-SHA256: cecp-panel notify webhook URL
WEBHOOK_URL=
WEBHOOK_SECRET=
# Thresholds
SSL_WARN_DAYS=14
DISK_WARN_PCT=85
EOF
  chmod 600 "$NOTIFY_ENV"
}

notify_load() {
  [[ -f "$NOTIFY_ENV" ]] || return 1
  secure_source "$NOTIFY_ENV"
  return 0
}

notify_is_set() { [[ -n "${1:-}" ]] && echo "set" || echo "missing"; }

notify_status() {
  echo "=== Notify config ($NOTIFY_ENV) ==="
  if [[ ! -f "$NOTIFY_ENV" ]]; then
    echo "  (not configured)"
    echo "  Setup: cecp-panel notify setup"
    return 0
  fi
  secure_source "$NOTIFY_ENV"
  echo "  TELEGRAM_BOT_TOKEN: $(notify_is_set "${TELEGRAM_BOT_TOKEN:-}")"
  echo "  TELEGRAM_CHAT_ID:   ${TELEGRAM_CHAT_ID:-missing}"
  echo "  DISCORD_WEBHOOK:    $(notify_is_set "${DISCORD_WEBHOOK:-}")"
  echo "  WEBHOOK_URL:        ${WEBHOOK_URL:-missing} (secret: $(notify_is_set "${WEBHOOK_SECRET:-}"))"
  echo "  Events log:         $EVENTS_LOG"
  echo "  SSL_WARN_DAYS:      ${SSL_WARN_DAYS:-14}"
  echo "  DISK_WARN_PCT:      ${DISK_WARN_PCT:-85}"
  echo "  Cron: /etc/cron.d/cecp-notify-health"
  [[ -f /etc/cron.d/cecp-notify-health ]] && echo "  cron: present" || echo "  cron: absent"
}

notify_setup() {
  require_root
  notify_ensure_env
  panel_log "Edit $NOTIFY_ENV then: cecp-panel notify test && cecp-panel notify enable-cron"
  if [[ -t 0 ]]; then
    read -r -p "Telegram bot token (empty skip): " t
    read -r -p "Telegram chat id (empty skip): " c
    read -r -p "Discord webhook URL (empty skip): " d
    if [[ -n "$t" ]]; then
      [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || panel_die "Telegram token format: 123456:ABC..."
      env_set "$NOTIFY_ENV" TELEGRAM_BOT_TOKEN "$t"
    fi
    if [[ -n "$c" ]]; then
      [[ "$c" =~ ^-?[0-9]+$ ]] || panel_die "Telegram chat id must be numeric"
      env_set "$NOTIFY_ENV" TELEGRAM_CHAT_ID "$c"
    fi
    if [[ -n "$d" ]]; then
      [[ "$d" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] \
        || panel_die "Discord webhook must be https://discord.com/api/webhooks/ID/TOKEN"
      env_set "$NOTIFY_ENV" DISCORD_WEBHOOK "$d"
    fi
  fi
  chmod 600 "$NOTIFY_ENV"
  notify_status
}

notify_send() {
  local msg="${1:-}"
  [[ -n "$msg" ]] || return 0
  notify_load || { panel_log "notify: not configured (skip)"; return 0; }
  local host
  host="$(panel_host_fqdn)"
  local full="[CECP ${host}] ${msg}"

  # Secrets (bot token, webhook URL) go through a curl config fd / the environment,
  # never argv: site users can read other processes' argv via /proc.
  if [[ "${TELEGRAM_BOT_TOKEN:-}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -sS -m 10 -X POST \
      -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN") \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${full}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
    CECP_WEBHOOK="$DISCORD_WEBHOOK" CECP_TEXT="$full" python3 -c '
import json, os, urllib.request
req = urllib.request.Request(os.environ["CECP_WEBHOOK"],
                             data=json.dumps({"content": os.environ["CECP_TEXT"]}).encode(),
                             headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
' 2>/dev/null || true
  fi
}

# notify_event EVENT SEVERITY MESSAGE [DOMAIN] [DETAILS_JSON]
# Every event is appended to events.log (JSON lines, read by CECP Core) and, when configured,
# sent as text to Telegram/Discord and as signed JSON to WEBHOOK_URL (n8n etc.).
notify_event() {
  local event="$1" severity="$2" msg="$3" domain="${4:-}" details="${5:-}"
  [[ -n "$details" ]] || details='{}'
  local payload
  payload="$(CECP_EV="$event" CECP_SEV="$severity" CECP_MSG="$msg" CECP_DOM="$domain" \
    CECP_DET="$details" CECP_VER="$CECP_PANEL_VERSION" python3 -c '
import json, os, socket, time
try:
    det = json.loads(os.environ["CECP_DET"])
except ValueError:
    det = {"raw": os.environ["CECP_DET"]}
print(json.dumps({
    "event": os.environ["CECP_EV"], "severity": os.environ["CECP_SEV"],
    "message": os.environ["CECP_MSG"], "domain": os.environ["CECP_DOM"] or None,
    "host": socket.getfqdn(), "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "panel_version": os.environ["CECP_VER"], "details": det,
}, separators=(",", ":"), ensure_ascii=False))
')"
  if [[ -d "$LOG_DIR" ]]; then
    [[ -f "$EVENTS_LOG" ]] || install -m 640 /dev/null "$EVENTS_LOG" 2>/dev/null || true
    printf '%s\n' "$payload" >>"$EVENTS_LOG" 2>/dev/null || true
  fi
  notify_load || return 0
  local tag
  case "$severity" in
    critical) tag="[CRITICAL]" ;;
    warning) tag="[WARN]" ;;
    *) tag="[OK]" ;;
  esac
  notify_send "$tag $msg"
  if [[ -n "${WEBHOOK_URL:-}" && -n "${WEBHOOK_SECRET:-}" ]]; then
    notify_webhook_post "$event" "$payload" || panel_log "WARN: webhook delivery failed for event $event"
  fi
}

# POST the JSON payload with X-CECP-Signature: sha256=HMAC(secret, "<timestamp>.<body>").
# URL and secret travel in the environment, never argv. 3 attempts with backoff.
notify_webhook_post() {
  CECP_URL="$WEBHOOK_URL" CECP_SECRET="$WEBHOOK_SECRET" CECP_EV="$1" CECP_BODY="$2" \
    CECP_VER="$CECP_PANEL_VERSION" python3 -c '
import hashlib, hmac, os, sys, time, urllib.request
body = os.environ["CECP_BODY"].encode()
ts = str(int(time.time()))
sig = hmac.new(os.environ["CECP_SECRET"].encode(), ts.encode() + b"." + body, hashlib.sha256).hexdigest()
headers = {"Content-Type": "application/json", "User-Agent": "cecp-panel/" + os.environ["CECP_VER"],
           "X-CECP-Event": os.environ["CECP_EV"], "X-CECP-Timestamp": ts,
           "X-CECP-Signature": "sha256=" + sig}
for attempt in range(3):
    try:
        req = urllib.request.Request(os.environ["CECP_URL"], data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            if 200 <= r.status < 300:
                sys.exit(0)
    except Exception:
        pass
    time.sleep(1 + 2 * attempt)
sys.exit(1)
'
}

# cecp-panel notify webhook URL | off
notify_webhook_set() {
  require_root
  local url="${1:-}"
  notify_ensure_env
  if [[ "$url" == "off" ]]; then
    env_unset "$NOTIFY_ENV" WEBHOOK_URL
    env_unset "$NOTIFY_ENV" WEBHOOK_SECRET
    panel_log "Webhook disabled"
    return 0
  fi
  local re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/:@!$&()*+,;=?-]*)?$'
  [[ "$url" =~ $re ]] || panel_die "Usage: cecp-panel notify webhook https://n8n.example.com/webhook/ID | off"
  if [[ "$url" == http://* && ! "$url" =~ ^http://(127\.|10\.|192\.168\.|localhost) ]]; then
    panel_log "WARN: plain http webhook — events (and their signatures) travel unencrypted"
  fi
  local secret
  secret="$(rand_alnum 40)"
  env_set "$NOTIFY_ENV" WEBHOOK_URL "$url"
  env_set "$NOTIFY_ENV" WEBHOOK_SECRET "$secret"
  panel_log "Webhook set: $url"
  panel_secret "Webhook HMAC secret (verify X-CECP-Signature in n8n): $secret"
  notify_event webhook_configured info "Webhook configured on $(panel_host_fqdn)"
}

notify_test() {
  require_root
  notify_load || panel_die "Run: cecp-panel notify setup"
  notify_event test info "Test notification $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  panel_log "Test event sent (Telegram/Discord/webhook as configured)"
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
    notify_event ssl_expiring warning "SSL expiring: $msg"
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
    notify_event disk_high warning "Disk / at ${pct}% (threshold ${thr}%)" "" "{\"use_pct\": ${pct}}"
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
