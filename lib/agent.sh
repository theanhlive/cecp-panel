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
[[ -f "$ETC_DIR/agent.env" ]] && source "$ETC_DIR/agent.env"
mkdir -p "$(dirname "$OUT")"
export OUT CECP_API_URL CECP_VPS_ID CECP_AGENT_TOKEN
python3 - <<'PY'
import json, os, socket, time
from pathlib import Path

def read_json(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None

panel = read_json("/etc/cecp-panel/panel.json") or {}
sites_dir = Path("/var/lib/cecp-panel/sites")
sites = []
if sites_dir.is_dir():
    for f in sites_dir.glob("*.json"):
        d = read_json(f) or {}
        dom = d.get("domain") or f.stem
        sites.append({
            "domain": dom,
            "ssl": bool(d.get("ssl")),
            "wordpress": bool(d.get("wordpress")),
        })
mem = {}
try:
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            if line.startswith(("MemTotal:", "MemAvailable:", "SwapTotal:")):
                k, v = line.split(":", 1)
                mem[k.strip()] = int(v.split()[0])
except OSError:
    pass
disk = {}
try:
    st = os.statvfs("/")
    disk["root_total_kb"] = (st.f_blocks * st.f_frsize) // 1024
    disk["root_avail_kb"] = (st.f_bavail * st.f_frsize) // 1024
    if disk["root_total_kb"]:
        disk["root_use_pct"] = int(100 * (1 - disk["root_avail_kb"] / disk["root_total_kb"]))
except OSError:
    pass
data = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "vps_id": os.environ.get("CECP_VPS_ID") or None,
    "hostname": socket.gethostname(),
    "panel_installed": os.path.isfile("/usr/local/bin/cecp-panel"),
    "panel_version": panel.get("version"),
    "sites": sites,
    "domains_hosted": [s["domain"] for s in sites],
    "memory_kb": mem,
    "disk": disk,
    "load": list(os.getloadavg()),
}
with open(os.environ["OUT"], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
api="${CECP_API_URL:-}"
tok="${CECP_AGENT_TOKEN:-}"
vid="${CECP_VPS_ID:-}"
if [[ -n "$api" && -n "$tok" && -n "$vid" ]]; then
  curl -fsS -m 10 -X POST "${api%/}/infra/agent/heartbeat" \
    -H "Authorization: Bearer ${tok}" \
    -H "Content-Type: application/json" \
    -d @"$OUT" >/dev/null 2>>/var/log/cecp-panel/agent.log || true
fi
AGENTEOF
  chmod 755 "$AGENT_BIN"
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
