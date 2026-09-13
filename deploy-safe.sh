#!/usr/bin/env bash
# Safe deploy CECP Panel to a live VPS (code sync only by default).
#
# Does NOT run:
#   security apply-production  (can restart MariaDB / reload sshd)
#   optimize stack             (restart redis/mariadb, sysctl)
#   optimize site DOMAIN       (rewrites live vhosts — opt-in)
#
# Usage:
#   SSH_KEY=~/.ssh/cecp_vultr ./deploy-safe.sh root@IP
#   SSH_KEY=... ./deploy-safe.sh root@IP --with-check
#   SSH_KEY=... ./deploy-safe.sh root@IP --with-nginx-zones   # install shared zones only if missing
#
# Env:
#   CECP_PANEL_VERSION   default: version in lib/common.sh
#   SSH_KEY              optional private key
set -euo pipefail

TARGET="${1:?Usage: $0 root@VPS_IP [--with-check] [--with-nginx-zones]}"
shift || true
WITH_CHECK=0
WITH_ZONES=0
for a in "$@"; do
  case "$a" in
    --with-check) WITH_CHECK=1 ;;
    --with-nginx-zones) WITH_ZONES=1 ;;
    *) echo "Unknown flag: $a" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${CECP_PANEL_VERSION:-$(sed -nE 's/^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-([^}]+)\}"$/\1/p' "$ROOT/lib/common.sh")}"
[[ -n "$VERSION" ]] || { echo "ERROR: cannot read version from lib/common.sh" >&2; exit 1; }
SSH_KEY="${SSH_KEY:-}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
TARBALL="$ROOT/dist/cecp-panel-${VERSION}.tar.gz"

ssh_base() {
  local -a o=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
  [[ -n "$SSH_KEY" ]] && o+=(-i "$SSH_KEY")
  echo "${o[@]}"
}

run_ssh() {
  # shellcheck disable=SC2046
  ssh $(ssh_base) "$TARGET" "$@"
}

run_scp() {
  # shellcheck disable=SC2046
  scp $(ssh_base) "$@"
}

echo "========================================================================="
echo "  CECP Panel SAFE deploy  v${VERSION}"
echo "  Target: $TARGET"
echo "  Mode: code-only (no apply-production / optimize stack)"
echo "========================================================================="

# 0) Build if missing
if [[ ! -f "$TARBALL" ]]; then
  echo "[deploy] Building release..."
  bash "$ROOT/build-release.sh"
fi
[[ -f "$TARBALL" ]] || { echo "ERROR: missing $TARBALL"; exit 1; }
echo "[deploy] Tarball: $TARBALL ($(wc -c <"$TARBALL" | tr -d ' ') bytes)"

# 1) Preflight — services must be up
echo "[deploy] Preflight SSH + services..."
run_ssh 'bash -s' <<'REMOTE'
set -euo pipefail
echo "  hostname=$(hostname) ip=$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "  date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -f /etc/cecp-panel/panel.json ]]; then
  echo "  panel.json:"; sed 's/^/    /' /etc/cecp-panel/panel.json | head -20
else
  echo "  WARN: /etc/cecp-panel/panel.json missing"
fi
if [[ -x /usr/local/bin/cecp-panel ]]; then
  echo -n "  current CLI: "
  grep -oE 'CECP_PANEL_VERSION=\$\{CECP_PANEL_VERSION:-[^}]+\}' /usr/local/bin/cecp-panel 2>/dev/null | head -1 || true
  /usr/local/bin/cecp-panel 2>&1 | head -3 || true
fi
echo "  services:"
for s in nginx mariadb php-fpm fail2ban; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then echo "    [OK] $s"
  elif systemctl list-unit-files "${s}*" 2>/dev/null | grep -q .; then echo "    [--] $s (inactive)"
  else echo "    [??] $s"
  fi
done
echo "  sites meta count: $(ls /var/lib/cecp-panel/sites/*.json 2>/dev/null | wc -l)"
if command -v nginx >/dev/null; then
  if nginx -t 2>/tmp/cecp-nginx-pre.err; then echo "  nginx -t: OK"
  else echo "  nginx -t: FAIL (abort deploy)"; cat /tmp/cecp-nginx-pre.err; exit 10
  fi
fi
REMOTE

# 2) Upload tarball
echo "[deploy] Upload tarball..."
run_ssh "mkdir -p /tmp/cecp-panel-deploy && rm -rf /tmp/cecp-panel-deploy/*"
run_scp "$TARBALL" "$TARGET:/tmp/cecp-panel-deploy/cecp-panel.tar.gz"

# 3) Backup + atomic install of panel files only
echo "[deploy] Backup /opt/cecp-panel + install files..."
run_ssh "STAMP='$STAMP' VERSION='$VERSION' WITH_ZONES='$WITH_ZONES' bash -s" <<'REMOTE'
set -euo pipefail
STAMP="${STAMP}"
VERSION="${VERSION}"
WITH_ZONES="${WITH_ZONES:-0}"
BK="/var/lib/cecp-panel/backups/panel-${STAMP}"
mkdir -p /var/lib/cecp-panel/backups /opt/cecp-panel /etc/cecp-panel /var/log/cecp-panel

if [[ -d /opt/cecp-panel ]] && [[ -f /opt/cecp-panel/cecp-panel ]]; then
  mkdir -p "$BK"
  cp -a /opt/cecp-panel "$BK/opt-cecp-panel"
  [[ -f /usr/local/bin/cecp-panel ]] && cp -a /usr/local/bin/cecp-panel "$BK/cecp-panel.bin"
  echo "  backup -> $BK"
else
  echo "  no previous panel tree to backup"
fi

tmpdir="$(mktemp -d)"
tar xzf /tmp/cecp-panel-deploy/cecp-panel.tar.gz -C "$tmpdir"
# tarball contains top-level cecp-panel/
src="$tmpdir/cecp-panel"
[[ -f "$src/cecp-panel" ]] || { echo "ERROR: bad tarball layout"; ls -la "$tmpdir"; exit 1; }

# Copy panel tree without wiping VPS-only paths; prefer rsync, fallback to tar pipe
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude 'dist/' \
    --exclude '.git/' \
    --exclude 'etc/' \
    "$src/" /opt/cecp-panel/
else
  # Fallback: overwrite files from new tree (keep unknown local files)
  (cd "$src" && tar cf - .) | (cd /opt/cecp-panel && tar xf -)
fi

chmod +x /opt/cecp-panel/cecp-panel /opt/cecp-panel/lib/*.sh /opt/cecp-panel/deploy-safe.sh /opt/cecp-panel/build-release.sh 2>/dev/null || true
install -m 0755 /opt/cecp-panel/cecp-panel /usr/local/bin/cecp-panel

# Update panel.json version stamp (keep installed_at)
export VERSION
python3 - <<'PY'
import json, os
from datetime import datetime, timezone
p="/etc/cecp-panel/panel.json"
data={}
if os.path.isfile(p):
    try:
        data=json.load(open(p))
    except Exception:
        data={}
data["version"]=os.environ.get("VERSION","unknown")
data["updated_at"]=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data["standalone"]=True
open(p,"w").write(json.dumps(data, indent=2)+"\n")
os.chmod(p, 0o600)
print("  panel.json version=", data.get("version"))
PY

# Optional: ensure shared nginx zones exist WITHOUT rewriting site vhosts
if [[ "$WITH_ZONES" == "1" ]]; then
  if [[ -f /opt/cecp-panel/templates/nginx-global-cecp.conf ]]; then
    mkdir -p /var/cache/nginx/cecp
    chown nginx:nginx /var/cache/nginx/cecp 2>/dev/null || chown www-data:www-data /var/cache/nginx/cecp 2>/dev/null || true
    install -m 644 /opt/cecp-panel/templates/nginx-global-cecp.conf /etc/nginx/conf.d/cecp-global.conf
    echo "  installed/updated cecp-global.conf (zones only)"
  fi
fi

# NEVER rewrite existing site vhosts here.
# Post-check nginx
if ! nginx -t 2>/tmp/cecp-nginx-post.err; then
  echo "ERROR: nginx -t failed after panel file sync — restoring /opt/cecp-panel from backup"
  cat /tmp/cecp-nginx-post.err
  if [[ -d "$BK/opt-cecp-panel" ]]; then
    rm -rf /opt/cecp-panel
    cp -a "$BK/opt-cecp-panel" /opt/cecp-panel
    [[ -f "$BK/cecp-panel.bin" ]] && install -m 0755 "$BK/cecp-panel.bin" /usr/local/bin/cecp-panel
    echo "  restored panel from $BK"
  fi
  nginx -t
  exit 11
fi

# Do NOT reload nginx unless zones flag set (reload is usually safe but still optional)
if [[ "$WITH_ZONES" == "1" ]]; then
  systemctl reload nginx
  echo "  nginx reloaded (zones update)"
else
  echo "  nginx NOT reloaded (code-only; running config unchanged)"
fi

rm -rf "$tmpdir" /tmp/cecp-panel-deploy
echo "  install OK"
REMOTE

# 4) Post verify
echo "[deploy] Post-verify..."
run_ssh 'bash -s' <<'REMOTE'
set -euo pipefail
echo -n "  CLI help version line: "
/usr/local/bin/cecp-panel help 2>&1 | head -1
echo "  optimize subcommands:"
/usr/local/bin/cecp-panel optimize 2>&1 | head -3 || true
echo "  security subcommands:"
/usr/local/bin/cecp-panel security 2>&1 | head -3 || true
for s in nginx mariadb; do
  systemctl is-active --quiet "$s" 2>/dev/null && echo "  [OK] $s still active" || echo "  [!!] $s not active"
done
# HTTP smoke on localhost if any site
if curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1/ 2>/dev/null | grep -qE '^[0-9]+$'; then
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1/ || echo err)
  echo "  localhost HTTP: $code"
fi
# list sites
if [[ -x /usr/local/bin/cecp-panel ]]; then
  cecp-panel site list 2>/dev/null | head -20 || true
fi
REMOTE

if [[ "$WITH_CHECK" == "1" ]]; then
  echo "[deploy] security check (read-only)..."
  run_ssh "cecp-panel security check 2>&1 | tail -40" || true
fi

echo "========================================================================="
echo "  SAFE deploy done on $TARGET"
echo "  Rollback if needed:"
echo "    ssh $TARGET 'ls /var/lib/cecp-panel/backups/'"
echo "    # restore: cp -a /var/lib/cecp-panel/backups/panel-STAMP/opt-cecp-panel /opt/cecp-panel"
echo ""
echo "  Manual next steps (when you choose, NOT auto):"
echo "    cecp-panel security check"
echo "    # later, off-peak: cecp-panel security apply-production"
echo "    # later, off-peak: cecp-panel optimize stack"
echo "    # per site (rewrites vhost): cecp-panel optimize site DOMAIN"
echo "========================================================================="
