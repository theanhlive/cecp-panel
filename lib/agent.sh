#!/usr/bin/env bash
# CECP agent — heartbeat file + optional push to CECP API
set -euo pipefail

AGENT_DIR="$VAR_LIB/agent"
AGENT_ENV="$ETC_DIR/agent.env"
AGENT_BIN="$PANEL_ROOT/bin/cecp-agent-heartbeat.sh"

agent_install() {
  require_root
  mkdir -p "$AGENT_DIR" "$PANEL_ROOT/bin"
  if [[ ! -f "$AGENT_ENV" ]]; then
    cp "$PANEL_ROOT/templates/agent.env.example" "$AGENT_ENV" 2>/dev/null || cat >"$AGENT_ENV" <<'EOF'
CECP_API_URL=
CECP_VPS_ID=
CECP_AGENT_TOKEN=
EOF
    chmod 600 "$AGENT_ENV"
    panel_log "Created $AGENT_ENV — set CECP_API_URL, CECP_VPS_ID, CECP_AGENT_TOKEN"
  fi
  cat >"$AGENT_BIN" <<'AGENTEOF'
#!/usr/bin/env bash
set -euo pipefail
ETC_DIR="/etc/cecp-panel"
VAR_LIB="/var/lib/cecp-panel"
OUT="$VAR_LIB/agent/heartbeat.json"
ENV_FILE="$ETC_DIR/agent.env"
if [[ -f "$ENV_FILE" ]]; then
  # Root-owned and not group/world-writable only: this file is sourced as root.
  [[ "$(stat -c %u "$ENV_FILE")" == "0" ]] && (( (8#$(stat -c %a "$ENV_FILE") & 8#022) == 0 )) \
    || { echo "refusing insecure $ENV_FILE" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi
mkdir -p "$(dirname "$OUT")"
# Same document as `cecp-panel status --json` (1.9+: per-site disk/DB, cache hit ratio, SSL
# days, backup/uptime/update state); the pre-1.9 heartbeat keys are part of it.
CECP_VPS_ID="${CECP_VPS_ID:-}" /usr/local/bin/cecp-panel status --json >"$OUT.tmp" \
  && mv -f "$OUT.tmp" "$OUT"
chmod 600 "$OUT"
api="${CECP_API_URL:-}"
tok="${CECP_AGENT_TOKEN:-}"
vid="${CECP_VPS_ID:-}"
if [[ -n "$api" && -n "$tok" && -n "$vid" ]]; then
  # Token via a config fd, not argv (site users can read other processes' argv).
  curl -fsS -m 10 -X POST "${api%/}/infra/agent/heartbeat" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$tok") \
    -H "Content-Type: application/json" \
    -d @"$OUT" >/dev/null 2>>/var/log/cecp-panel/agent.log || true
fi
AGENTEOF
  chmod 700 "$AGENT_BIN"
  cat >/etc/cron.d/cecp-agent <<EOF
*/5 * * * * root $AGENT_BIN >>/var/log/cecp-panel/agent.log 2>&1
EOF
  chmod 644 /etc/cron.d/cecp-agent
  "$AGENT_BIN"
  panel_log "CECP agent heartbeat installed (cron every 5 min). State: $AGENT_DIR/heartbeat.json"
  if [[ -f "$AGENT_ENV" ]] && grep -qE '^CECP_API_URL=.+' "$AGENT_ENV" && grep -qE '^CECP_AGENT_TOKEN=.+' "$AGENT_ENV"; then
    panel_log "API push enabled → $(grep '^CECP_API_URL=' "$AGENT_ENV" | cut -d= -f2-)"
  else
    panel_log "API push disabled — set CECP_API_URL + CECP_AGENT_TOKEN in $AGENT_ENV"
  fi
}

agent_status() {
  if [[ -f "$AGENT_DIR/heartbeat.json" ]]; then
    cat "$AGENT_DIR/heartbeat.json"
  else
    echo "Agent not installed. Run: cecp-panel agent install"
  fi
}
