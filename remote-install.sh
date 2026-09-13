#!/usr/bin/env bash
# One command from Mac: ship full panel tree + run install.sh on VPS
# Usage: ./remote-install.sh root@207.148.65.70
#        SSH_KEY=~/.ssh/cecp_vultr ./remote-install.sh root@207.148.65.70
set -euo pipefail

TARGET="${1:?Usage: $0 root@VPS_IP}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPTS="$(cd "$SCRIPT_ROOT/.." && pwd)"

SSH_OPTS=()
if [[ -n "${SSH_KEY:-}" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

echo "[remote-install] Uploading full cecp-panel bundle to $TARGET ..."
tar czf - -C "$REPO_SCRIPTS" cecp-panel | ssh "${SSH_OPTS[@]}" "$TARGET" \
  'set -euo pipefail
   rm -rf /tmp/cecp-panel-install
   mkdir -p /tmp/cecp-panel-install
   tar xzf - -C /tmp/cecp-panel-install
   exec bash /tmp/cecp-panel-install/cecp-panel/install.sh'

echo "[remote-install] Complete. SSH in and run: cecp-panel"
