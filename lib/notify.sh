#!/usr/bin/env bash
set -euo pipefail

NOTIFY_ENV="${ETC_DIR}/notify.env"
EVENTS_LOG="${LOG_DIR}/events.log"

# ---------------------------------------------------------------------------
# Channels: Telegram bot, Discord webhook, Zalo Bot (bot.zapps.vn), signed JSON webhook (n8n).
# Categories the operator can switch on/off (globally or per channel) + a minimum severity.
# Secrets are pasted at a hidden prompt (or passed in CECP_* env vars by an agent), never on
# the command line: argv lands in shell history and is readable by every local user.
# ---------------------------------------------------------------------------
NOTIFY_CATEGORIES_ALL="security uptime backup ssl resources updates"
NOTIFY_CHANNELS="telegram discord zalo webhook"
ZALO_API_BASE="${ZALO_API_BASE:-https://bot-api.zapps.me}"
TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"

notify_category_label() {
  case "$1" in
    security) echo "Bảo mật: quét phát hiện mã độc, khôi phục bản sạch" ;;
    uptime) echo "Website / dịch vụ (nginx, PHP, MariaDB…) sập và hồi phục" ;;
    backup) echo "Backup / restore lỗi, backup quá cũ, kiểm tra backup" ;;
    ssl) echo "Chứng chỉ SSL sắp hết hạn" ;;
    resources) echo "Ổ đĩa sắp đầy" ;;
    updates) echo "Cập nhật WordPress / hệ thống / staging" ;;
  esac
}

# Event name → category (system = always delivered: tests, configuration changes).
notify_category() {
  case "$1" in
    security_*) echo security ;;
    site_*|service_*|socket_*) echo uptime ;;
    backup_*|restore_*) echo backup ;;
    ssl_*) echo ssl ;;
    disk_*) echo resources ;;
    wp_update_*|update_all_*|staging_*) echo updates ;;
    *) echo system ;;
  esac
}

notify_sev_rank() { case "$1" in critical) echo 2 ;; warning) echo 1 ;; *) echo 0 ;; esac; }

notify_ensure_env() {
  mkdir -p "$ETC_DIR"
  [[ -f "$NOTIFY_ENV" ]] && return 0
  cat >"$NOTIFY_ENV" <<'EOF'
# CECP Panel notifications — configure with: cecp-panel notify setup
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
DISCORD_WEBHOOK=
ZALO_BOT_TOKEN=
ZALO_CHAT_ID=
# Generic JSON webhook (n8n …), signed with HMAC-SHA256: cecp-panel notify webhook URL
WEBHOOK_URL=
WEBHOOK_SECRET=
# What to send: categories (security uptime backup ssl resources updates | all) and minimum
# severity (info | warning | critical). Per channel: TELEGRAM_CATEGORIES, ZALO_MIN_SEVERITY, …
NOTIFY_CATEGORIES=all
NOTIFY_MIN_SEVERITY=info
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

notify_channel_configured() {
  case "$1" in
    telegram) [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] ;;
    discord) [[ -n "${DISCORD_WEBHOOK:-}" ]] ;;
    zalo) [[ -n "${ZALO_BOT_TOKEN:-}" && -n "${ZALO_CHAT_ID:-}" ]] ;;
    webhook) [[ -n "${WEBHOOK_URL:-}" && -n "${WEBHOOK_SECRET:-}" ]] ;;
    *) return 1 ;;
  esac
}

# notify_wants CHANNEL CATEGORY SEVERITY — after notify_load.
notify_wants() {
  local ch="${1^^}" cat="$2" sev="$3" cats min v
  [[ "$cat" == system ]] && return 0
  v="${ch}_CATEGORIES"; cats="${!v:-}"
  # n8n and other machine consumers get everything unless told otherwise.
  [[ -n "$cats" ]] || { [[ "$1" == webhook ]] && cats=all || cats="${NOTIFY_CATEGORIES:-all}"; }
  v="${ch}_MIN_SEVERITY"; min="${!v:-}"
  [[ -n "$min" ]] || { [[ "$1" == webhook ]] && min=info || min="${NOTIFY_MIN_SEVERITY:-info}"; }
  (( $(notify_sev_rank "$sev") >= $(notify_sev_rank "$min") )) || return 1
  [[ "$cats" == all || ",${cats// /,}," == *",$cat,"* ]]
}

# notify_deliver CHANNEL TEXT — one message to one chat channel. Secrets via the environment.
notify_deliver() {
  local ch="$1" text="$2"
  CECP_TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}" CECP_TG_CHAT="${TELEGRAM_CHAT_ID:-}" \
  CECP_ZL_TOKEN="${ZALO_BOT_TOKEN:-}" CECP_ZL_CHAT="${ZALO_CHAT_ID:-}" \
  CECP_DC_URL="${DISCORD_WEBHOOK:-}" CECP_TEXT="$text" \
  CECP_TG_BASE="$TELEGRAM_API_BASE" CECP_ZL_BASE="$ZALO_API_BASE" \
    python3 - "$ch" <<'PY'
import json, os, sys, urllib.parse, urllib.request
ch, env = sys.argv[1], os.environ
text = env["CECP_TEXT"]
if len(text) > 1900:  # Zalo / Discord limit 2000 characters
    text = text[:1890] + " …"
def post(url, body, ctype):
    req = urllib.request.Request(url, data=body, headers={"Content-Type": ctype, "User-Agent": "cecp-panel"})
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read().decode("utf-8", "replace")
        return r.status, raw
try:
    if ch == "telegram":
        st, raw = post(f'{env["CECP_TG_BASE"]}/bot{env["CECP_TG_TOKEN"]}/sendMessage',
                       urllib.parse.urlencode({"chat_id": env["CECP_TG_CHAT"], "text": text,
                                               "disable_web_page_preview": "true"}).encode(),
                       "application/x-www-form-urlencoded")
        ok = json.loads(raw).get("ok") is True
    elif ch == "zalo":
        st, raw = post(f'{env["CECP_ZL_BASE"]}/bot{env["CECP_ZL_TOKEN"]}/sendMessage',
                       json.dumps({"chat_id": env["CECP_ZL_CHAT"], "text": text}).encode(), "application/json")
        ok = json.loads(raw).get("ok") is True
    elif ch == "discord":
        st, raw = post(env["CECP_DC_URL"], json.dumps({"content": text}).encode(), "application/json")
        ok = 200 <= st < 300
    else:
        ok = False
except Exception as e:  # network, HTTP 4xx/5xx, bad JSON
    print(f"{ch}: {type(e).__name__}: {e}"[:300], file=sys.stderr)
    ok = False
sys.exit(0 if ok else 1)
PY
}

# notify_format SEVERITY MESSAGE [DOMAIN] — the chat text.
notify_format() {
  local icon
  case "$1" in critical) icon="🔴 NGHIÊM TRỌNG" ;; warning) icon="🟠 CẢNH BÁO" ;; *) icon="🟢 THÔNG TIN" ;; esac
  printf '%s · %s\n%s%s\n%s' "$icon" "$(panel_host_fqdn)" "$2" "${3:+$'\n'Site: $3}" "$(date '+%Y-%m-%d %H:%M %Z')"
}

# Manual broadcast (cecp-panel notify send TEXT, module messages): every configured chat channel.
notify_send() {
  local msg="${1:-}" ch
  [[ -n "$msg" ]] || return 0
  notify_load || { panel_log "notify: not configured (skip)"; return 0; }
  for ch in telegram discord zalo; do
    notify_channel_configured "$ch" || continue
    notify_deliver "$ch" "$(notify_format info "$msg")" 2>>"$LOG_DIR/notify.log" || true
  done
}

# --- setup -------------------------------------------------------------------------------

# notify_read_secret PROMPT ENVVAR — value from the CECP_* variable (agents), else a hidden prompt.
notify_read_secret() {
  local prompt="$1" var="$2" v="${!2:-}"
  if [[ -z "$v" ]]; then
    [[ -t 0 ]] || panel_die "No terminal: pass the value in the environment variable $var"
    read -r -s -p "$prompt" v
    echo >&2
  fi
  printf '%s' "$v"
}

# notify_bot_api telegram|zalo TOKEN METHOD — prints the JSON reply (token via environment).
notify_bot_api() {
  CECP_TOKEN="$2" CECP_BASE="$([[ "$1" == zalo ]] && echo "$ZALO_API_BASE" || echo "$TELEGRAM_API_BASE")" \
    python3 - "$1" "$3" <<'PY'
import json, os, sys, urllib.request
kind, method = sys.argv[1], sys.argv[2]
url = f'{os.environ["CECP_BASE"]}/bot{os.environ["CECP_TOKEN"]}/{method}'
body = json.dumps({"timeout": 25} if method == "getUpdates" and kind == "zalo" else {}).encode()
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "cecp-panel"})
try:
    with urllib.request.urlopen(req, timeout=40) as r:
        print(r.read().decode("utf-8", "replace"))
except urllib.error.HTTPError as e:
    print(e.read().decode("utf-8", "replace") or json.dumps({"ok": False, "description": str(e)}))
except Exception as e:
    print(json.dumps({"ok": False, "description": f"{type(e).__name__}: {e}"}))
PY
}

# Chats that wrote to the bot, from a getUpdates reply (Telegram: list, Zalo: one update):
# "ID<TAB>NAME" lines.
notify_chats_from_updates() {
  python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
seen = {}
def walk(o):
    if isinstance(o, dict):
        chat = o.get("chat")
        if isinstance(chat, dict) and chat.get("id") is not None:
            name = chat.get("title") or chat.get("display_name") or chat.get("first_name") or chat.get("username") or ""
            if not name and isinstance(o.get("from"), dict):
                f = o["from"]
                name = f.get("display_name") or f.get("first_name") or f.get("username") or ""
            seen[str(chat["id"])] = name
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(data.get("result"))
for k, v in seen.items():
    print(k + "\t" + v)
'
}

# cecp-panel notify telegram|zalo — bot token (hidden) + chat found automatically.
notify_setup_bot() {
  local kind="$1" label token_var chat_var env_token env_chat token reply name chat chats n
  require_root
  notify_ensure_env
  if [[ "$kind" == telegram ]]; then
    label="Telegram"; token_var=TELEGRAM_BOT_TOKEN; chat_var=TELEGRAM_CHAT_ID
    env_token=CECP_TELEGRAM_TOKEN; env_chat=CECP_TELEGRAM_CHAT
    echo "Tạo bot: mở Telegram → @BotFather → /newbot → copy token (dạng 123456789:ABC…)."
  else
    label="Zalo"; token_var=ZALO_BOT_TOKEN; chat_var=ZALO_CHAT_ID
    env_token=CECP_ZALO_TOKEN; env_chat=CECP_ZALO_CHAT
    echo "Tạo bot: mở Zalo → tìm \"Zalo Bot Manager\" (hoặc https://bot.zapps.vn) → Tạo bot → copy Bot Token."
  fi
  token="$(notify_read_secret "Dán ${label} Bot Token (không hiện khi gõ): " "$env_token")"
  [[ "$token" =~ ^[A-Za-z0-9:_-]{20,200}$ ]] || panel_die "${label} token không đúng định dạng"
  reply="$(notify_bot_api "$kind" "$token" getMe)"
  name="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); r=d.get("result") or {}; print((r.get("username") or r.get("account_name") or r.get("display_name") or r.get("first_name") or "") if d.get("ok") else "")' <<<"$reply" 2>/dev/null || true)"
  [[ -n "$name" ]] || panel_die "${label} từ chối token: $(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("description","?"))' <<<"$reply" 2>/dev/null || echo "?")"
  panel_log "${label} bot OK: ${name}"
  chat="${!env_chat:-}"
  if [[ -z "$chat" ]]; then
    [[ -t 0 ]] || panel_die "No terminal: pass the chat id in $env_chat"
    echo "Bây giờ mở ${label}, nhắn một tin bất kỳ cho bot \"${name}\" (hoặc thêm bot vào nhóm rồi nhắn trong nhóm)."
    read -r -p "Nhắn xong thì nhấn Enter… " _
    chats="$(notify_bot_api "$kind" "$token" getUpdates | notify_chats_from_updates)"
    n="$(grep -c . <<<"$chats" || true)"
    if (( n == 1 )); then
      chat="$(cut -f1 <<<"$chats")"
      echo "Tìm thấy: $(cut -f2 <<<"$chats") (chat id $chat)"
    elif (( n > 1 )); then
      echo "Nhiều cuộc trò chuyện đã nhắn cho bot:"
      nl -w2 -s') ' <<<"$chats"
      read -r -p "Chọn số: " n
      chat="$(sed -n "${n}p" <<<"$chats" | cut -f1)"
    else
      echo "Chưa thấy tin nhắn nào (bot đang dùng webhook ở nơi khác thì không đọc được)."
      read -r -p "Nhập chat id thủ công: " chat
    fi
  fi
  [[ "$chat" =~ ^-?[A-Za-z0-9_.-]{1,64}$ ]] || panel_die "Chat id không hợp lệ"
  env_set "$NOTIFY_ENV" "$token_var" "$token"
  env_set "$NOTIFY_ENV" "$chat_var" "$chat"
  notify_load
  if notify_deliver "$kind" "$(notify_format info "Đã kết nối thông báo ${label} cho VPS này. Loại thông báo: cecp-panel notify events")" 2>>"$LOG_DIR/notify.log"; then
    panel_log "${label}: đã gửi tin thử — kiểm tra ${label} của bạn"
  else
    panel_log "WARN: ${label} đã lưu nhưng gửi thử thất bại (xem $LOG_DIR/notify.log)"
  fi
}

# cecp-panel notify discord — webhook URL (hidden).
notify_setup_discord() {
  local url
  require_root
  notify_ensure_env
  echo "Discord: kênh → Chỉnh sửa kênh → Tích hợp → Webhook → Webhook mới → Sao chép URL."
  url="$(notify_read_secret "Dán Discord Webhook URL (không hiện khi gõ): " CECP_DISCORD_WEBHOOK)"
  [[ "$url" =~ ^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] \
    || panel_die "Discord webhook phải có dạng https://discord.com/api/webhooks/ID/TOKEN"
  env_set "$NOTIFY_ENV" DISCORD_WEBHOOK "$url"
  notify_load
  if notify_deliver discord "$(notify_format info "Đã kết nối thông báo Discord cho VPS này.")" 2>>"$LOG_DIR/notify.log"; then
    panel_log "Discord: đã gửi tin thử"
  else
    panel_log "WARN: Discord đã lưu nhưng gửi thử thất bại (xem $LOG_DIR/notify.log)"
  fi
}

# cecp-panel notify off telegram|discord|zalo|webhook
notify_channel_off() {
  require_root
  notify_ensure_env
  local k
  case "${1:-}" in
    telegram) for k in TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do env_unset "$NOTIFY_ENV" "$k"; done ;;
    discord) env_unset "$NOTIFY_ENV" DISCORD_WEBHOOK ;;
    zalo) for k in ZALO_BOT_TOKEN ZALO_CHAT_ID; do env_unset "$NOTIFY_ENV" "$k"; done ;;
    webhook) notify_webhook_set off; return 0 ;;
    *) panel_die "Usage: cecp-panel notify off telegram|discord|zalo|webhook" ;;
  esac
  panel_log "Notifications via $1: off"
}

# cecp-panel notify events [set CATEGORIES|all] [--channel CH] [--min info|warning|critical]
notify_events() {
  local action="${1:-show}" cats="" ch="" min="" c prefix=NOTIFY
  shift || true
  if [[ "$action" == set ]]; then
    require_root
    notify_ensure_env
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --channel) ch="${2:-}"; shift 2 || true ;;
        --min|--min-severity) min="${2:-}"; shift 2 || true ;;
        *) cats="$1"; shift ;;
      esac
    done
    if [[ -n "$ch" ]]; then
      [[ " $NOTIFY_CHANNELS " == *" $ch "* ]] || panel_die "Channel: telegram|discord|zalo|webhook"
      prefix="${ch^^}"
    fi
    if [[ -n "$cats" ]]; then
      if [[ "$cats" == default ]]; then
        env_unset "$NOTIFY_ENV" "${prefix}_CATEGORIES"
      else
        [[ "$cats" == all || "$cats" == none ]] || for c in ${cats//,/ }; do
          [[ " $NOTIFY_CATEGORIES_ALL " == *" $c "* ]] || panel_die "Unknown category '$c' (security uptime backup ssl resources updates | all | none)"
        done
        env_set "$NOTIFY_ENV" "${prefix}_CATEGORIES" "${cats// /,}"
      fi
    fi
    if [[ -n "$min" ]]; then
      [[ "$min" =~ ^(info|warning|critical)$ ]] || panel_die "--min: info | warning | critical"
      env_set "$NOTIFY_ENV" "${prefix}_MIN_SEVERITY" "$min"
    fi
    panel_log "Notification filter updated (${ch:-all channels})"
  elif [[ "$action" == edit ]]; then
    notify_events_edit
    return 0
  elif [[ "$action" != show ]]; then
    panel_die "Usage: cecp-panel notify events [edit | set CATEGORIES|all|none|default [--channel CH] [--min info|warning|critical]]"
  fi
  notify_load || { echo "(notifications not configured: cecp-panel notify setup)"; return 0; }
  echo "=== Loại thông báo ==="
  for c in $NOTIFY_CATEGORIES_ALL; do
    printf '  %-10s %s\n' "$c" "$(notify_category_label "$c")"
  done
  echo "  (thử kết nối / thay đổi cấu hình luôn được gửi)"
  echo ""
  printf '  %-9s %-10s %-9s %s\n' "kênh" "trạng thái" "mức ≥" "nhóm được gửi"
  for c in $NOTIFY_CHANNELS; do
    local v s m
    v="${c^^}_CATEGORIES"; s="${!v:-}"
    [[ -n "$s" ]] || { [[ "$c" == webhook ]] && s="all" || s="${NOTIFY_CATEGORIES:-all}"; }
    v="${c^^}_MIN_SEVERITY"; m="${!v:-}"
    [[ -n "$m" ]] || { [[ "$c" == webhook ]] && m=info || m="${NOTIFY_MIN_SEVERITY:-info}"; }
    printf '  %-9s %-10s %-9s %s\n' "$c" "$(notify_channel_configured "$c" && echo "bật" || echo "chưa cài")" "$m" "$s"
  done
}

# Interactive on/off per category (global) and minimum severity.
notify_events_edit() {
  require_root
  notify_ensure_env
  notify_load
  [[ -t 0 ]] || panel_die "Interactive: use cecp-panel notify events set … instead"
  local cur="${NOTIFY_CATEGORIES:-all}" c a out="" min
  [[ "$cur" == all ]] && cur="${NOTIFY_CATEGORIES_ALL// /,}"
  echo "Bật/tắt từng loại thông báo (Enter = giữ nguyên):"
  for c in $NOTIFY_CATEGORIES_ALL; do
    local on=n
    [[ ",$cur," == *",$c,"* ]] && on=y
    read -r -p "  $(notify_category_label "$c") [$([[ $on == y ]] && echo "Y/n" || echo "y/N")]: " a
    a="${a:-$on}"
    [[ "$a" =~ ^[yY] ]] && out+="${out:+,}$c"
  done
  read -r -p "Chỉ gửi từ mức: 1) mọi thông báo  2) cảnh báo trở lên  3) chỉ nghiêm trọng [1]: " a
  case "${a:-1}" in 2) min=warning ;; 3) min=critical ;; *) min=info ;; esac
  env_set "$NOTIFY_ENV" NOTIFY_CATEGORIES "${out:-none}"
  env_set "$NOTIFY_ENV" NOTIFY_MIN_SEVERITY "$min"
  panel_log "Notification filter: ${out:-none}, severity >= $min"
}

notify_status() {
  echo "=== Notify config ($NOTIFY_ENV) ==="
  if [[ ! -f "$NOTIFY_ENV" ]]; then
    echo "  (not configured) — setup: cecp-panel notify setup"
    return 0
  fi
  secure_source "$NOTIFY_ENV"
  echo "  Telegram:  $(notify_channel_configured telegram && echo "on (chat ${TELEGRAM_CHAT_ID})" || echo off)"
  echo "  Discord:   $(notify_channel_configured discord && echo on || echo off)"
  echo "  Zalo:      $(notify_channel_configured zalo && echo "on (chat ${ZALO_CHAT_ID})" || echo off)"
  echo "  Webhook:   ${WEBHOOK_URL:-off}"
  echo "  Events log: $EVENTS_LOG"
  echo "  SSL_WARN_DAYS=${SSL_WARN_DAYS:-14}  DISK_WARN_PCT=${DISK_WARN_PCT:-85}"
  [[ -f /etc/cron.d/cecp-notify-health ]] && echo "  Daily SSL/disk check: on" || echo "  Daily SSL/disk check: off (cecp-panel notify enable-cron)"
  echo ""
  notify_events show
}

# cecp-panel notify setup — wizard.
notify_setup() {
  require_root
  notify_ensure_env
  if [[ ! -t 0 ]]; then
    notify_status
    echo "Non-interactive: cecp-panel notify telegram|zalo|discord with CECP_TELEGRAM_TOKEN/CECP_TELEGRAM_CHAT, CECP_ZALO_TOKEN/CECP_ZALO_CHAT, CECP_DISCORD_WEBHOOK"
    return 0
  fi
  local c
  while true; do
    echo ""
    echo "== Thông báo VPS =="
    echo " 1) Telegram      2) Zalo Bot      3) Discord      4) Webhook (n8n)"
    echo " 5) Chọn loại thông báo            6) Gửi thử      7) Xem cấu hình"
    echo " 8) Tắt một kênh                   0) Xong"
    read -r -p "Chọn: " c
    case "$c" in
      1) ( notify_setup_bot telegram ) || true ;;
      2) ( notify_setup_bot zalo ) || true ;;
      3) ( notify_setup_discord ) || true ;;
      4) read -r -p "Webhook URL (n8n): " c; ( notify_webhook_set "$c" ) || true ;;
      5) ( notify_events_edit ) || true ;;
      6) ( notify_test ) || true ;;
      7) notify_status ;;
      8) read -r -p "Kênh (telegram/zalo/discord/webhook): " c; ( notify_channel_off "$c" ) || true ;;
      0|"") break ;;
    esac
  done
  [[ -f /etc/cron.d/cecp-notify-health ]] || notify_enable_cron
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
  local cat ch text
  cat="$(notify_category "$event")"
  text="$(notify_format "$severity" "$msg" "$domain")"
  for ch in telegram discord zalo; do
    notify_channel_configured "$ch" && notify_wants "$ch" "$cat" "$severity" || continue
    notify_deliver "$ch" "$text" 2>>"$LOG_DIR/notify.log" || panel_log "WARN: $ch delivery failed for event $event"
  done
  if notify_channel_configured webhook && notify_wants webhook "$cat" "$severity"; then
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

# cecp-panel notify test [CHANNEL] — one test message per configured channel, with the result.
# shellcheck disable=SC2120  # CHANNEL is optional; the menu calls it without one
notify_test() {
  require_root
  notify_load || panel_die "Run: cecp-panel notify setup"
  local ch any=0
  for ch in telegram discord zalo; do
    [[ -z "${1:-}" || "$1" == "$ch" ]] || continue
    notify_channel_configured "$ch" || continue
    any=1
    if notify_deliver "$ch" "$(notify_format info "Tin nhắn thử từ CECP Panel ($(date '+%H:%M'))")" 2>>"$LOG_DIR/notify.log"; then
      panel_log "  $ch: OK"
    else
      panel_log "  $ch: FAILED (see $LOG_DIR/notify.log)"
    fi
  done
  if [[ -z "${1:-}" || "${1:-}" == webhook ]] && notify_channel_configured webhook; then
    any=1
    notify_event test info "Test notification $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
    panel_log "  webhook: test event posted"
  fi
  (( any )) || panel_die "No channel configured: cecp-panel notify setup"
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
