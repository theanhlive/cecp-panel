#!/usr/bin/env bash
# Finish lab VPS: DNS (Cloudflare) + backup config from Mac CECP credentials
# Usage: SSH_KEY=~/.ssh/cecp_vultr ./finish-lab.sh root@207.148.65.70
set -euo pipefail

TARGET="${1:?Usage: $0 root@VPS_IP}"
CECP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRED="$CECP_ROOT/config/infrastructure_credentials.yaml"
SSH_KEY="${SSH_KEY:-}"

ssh_cmd() {
  local -a o=()
  [[ -n "$SSH_KEY" ]] && o=(-i "$SSH_KEY")
  ssh "${o[@]}" -o StrictHostKeyChecking=accept-new "$TARGET" "$@"
}

extract_cf_token() {
  [[ -f "$CRED" ]] || return 1
  awk '/^cloudflare_accounts:/{f=1} f && /api_token:/{gsub(/.*api_token: */,""); gsub(/"/,""); print; exit}' "$CRED"
}

echo "[finish-lab] Sync panel + configure lab on $TARGET ..."

tar czf - -C "$CECP_ROOT/scripts" cecp-panel | ssh_cmd 'tar xzf - -C /tmp && cp -a /tmp/cecp-panel/* /opt/cecp-panel/ && chmod +x /opt/cecp-panel/cecp-panel /opt/cecp-panel/lib/*.sh && install -m 0755 /opt/cecp-panel/cecp-panel /usr/local/bin/cecp-panel'

CF_TOKEN="$(extract_cf_token || true)"
if [[ -n "$CF_TOKEN" ]]; then
  ssh_cmd "mkdir -p /etc/cecp-panel && chmod 700 /etc/cecp-panel && cat > /etc/cecp-panel/credentials.env <<EOF
CF_API_TOKEN=${CF_TOKEN}
CF_DEFAULT_ZONE=theanhlive.com
EOF
chmod 600 /etc/cecp-panel/credentials.env"
  echo "[finish-lab] Cloudflare credentials installed"
  ssh_cmd "cecp-panel dns list 2>&1 | head -15" || echo "[finish-lab] WARN: dns list failed (token permissions?)"
else
  echo "[finish-lab] No CF token in $CRED — skip DNS"
fi

SA_JSON="${CECP_GDRIVE_SA_JSON:-}"
TEAM_ID="${CECP_GDRIVE_TEAM_ID:-}"
if [[ -n "$SA_JSON" && -f "$SA_JSON" && -n "$TEAM_ID" ]]; then
  scp ${SSH_KEY:+-i "$SSH_KEY"} "$SA_JSON" "$TARGET:/etc/cecp-panel/gdrive-service-account.json"
  ssh_cmd "chmod 600 /etc/cecp-panel/gdrive-service-account.json
cat >>/etc/cecp-panel/backup.env <<EOF
GDRIVE_SERVICE_ACCOUNT_FILE=/etc/cecp-panel/gdrive-service-account.json
GDRIVE_TEAM_DRIVE_ID=${TEAM_ID}
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=6
RESTIC_KEEP_MONTHLY=12
EOF
chmod 600 /etc/cecp-panel/backup.env
cecp-panel backup setup
cecp-panel backup run test2.theanhlive.com
cecp-panel backup enable-cron"
  echo "[finish-lab] Backup configured"
else
  echo "[finish-lab] Backup: set CECP_GDRIVE_SA_JSON and CECP_GDRIVE_TEAM_ID then re-run"
  ssh_cmd "test -f /etc/cecp-panel/backup.env || cp /opt/cecp-panel/templates/backup.env.example /etc/cecp-panel/backup.env; chmod 600 /etc/cecp-panel/backup.env"
fi

echo "[finish-lab] Done. SSH: cecp-panel status"
