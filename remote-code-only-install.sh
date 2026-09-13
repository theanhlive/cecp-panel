#!/usr/bin/env bash
# Runs ON the VPS after tarball is at /tmp/cecp-panel-deploy/cecp-panel.tar.gz
# Code-only install: no apply-production, no optimize stack, no nginx reload.
set -euo pipefail
VERSION="${1:-1.5.1-beta}"
STAMP="${2:-$(date -u +%Y%m%d_%H%M%S)}"
BK="/var/lib/cecp-panel/backups/panel-${STAMP}"
TARBALL="/tmp/cecp-panel-deploy/cecp-panel.tar.gz"

[[ -f "$TARBALL" ]] || { echo "ERROR: missing $TARBALL"; exit 1; }
mkdir -p /var/lib/cecp-panel/backups /opt/cecp-panel /etc/cecp-panel /var/log/cecp-panel

if [[ -f /opt/cecp-panel/cecp-panel ]]; then
  mkdir -p "$BK"
  cp -a /opt/cecp-panel "$BK/opt-cecp-panel"
  [[ -f /usr/local/bin/cecp-panel ]] && cp -a /usr/local/bin/cecp-panel "$BK/cecp-panel.bin"
  echo "backup -> $BK"
fi

tmpdir="$(mktemp -d)"
tar xzf "$TARBALL" -C "$tmpdir"
src="$tmpdir/cecp-panel"
[[ -f "$src/cecp-panel" ]] || { echo "ERROR: bad tarball"; ls -la "$tmpdir"; exit 1; }

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude 'dist/' --exclude '.git/' --exclude 'etc/' "$src/" /opt/cecp-panel/
else
  (cd "$src" && tar cf - .) | (cd /opt/cecp-panel && tar xf -)
fi

chmod +x /opt/cecp-panel/cecp-panel /opt/cecp-panel/lib/*.sh 2>/dev/null || true
install -m 0755 /opt/cecp-panel/cecp-panel /usr/local/bin/cecp-panel

# Update panel.json without fragile argv/heredoc edge cases
python3 -c "
import json, os
from datetime import datetime, timezone
p='/etc/cecp-panel/panel.json'
data={}
if os.path.isfile(p):
    try: data=json.load(open(p))
    except Exception: data={}
data['version']='${VERSION}'
data['updated_at']=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
data['standalone']=True
open(p,'w').write(json.dumps(data, indent=2)+chr(10))
os.chmod(p, 0o600)
print('panel.json version=', data.get('version'), 'updated_at=', data.get('updated_at'))
"

if ! nginx -t; then
  echo "ERROR: nginx -t failed — restoring panel from backup"
  if [[ -d "$BK/opt-cecp-panel" ]]; then
    rm -rf /opt/cecp-panel
    cp -a "$BK/opt-cecp-panel" /opt/cecp-panel
    [[ -f "$BK/cecp-panel.bin" ]] && install -m 0755 "$BK/cecp-panel.bin" /usr/local/bin/cecp-panel
  fi
  exit 11
fi

echo "nginx -t: OK (NOT reloaded — live vhosts unchanged)"
systemctl is-active nginx && echo "nginx: active"
systemctl is-active mariadb && echo "mariadb: active"
echo "CLI:"; cecp-panel help 2>&1 | head -2
cecp-panel site list 2>/dev/null || true

shopt -s nullglob
for f in /var/lib/cecp-panel/sites/*.json; do
  d="$(python3 -c "import json; print(json.load(open('$f'))['domain'])" 2>/dev/null || true)"
  [[ -n "$d" ]] || continue
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -k "https://${d}/" 2>/dev/null || echo err)"
  echo "HTTP https://${d}/ -> ${code}"
done
shopt -u nullglob

rm -rf "$tmpdir" /tmp/cecp-panel-deploy
echo "CODE_ONLY_OK version=${VERSION} stamp=${STAMP}"
