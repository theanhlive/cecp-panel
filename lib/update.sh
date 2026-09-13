#!/usr/bin/env bash
# OS components + CECP Panel self-update
set -euo pipefail

PANEL_ENV="$ETC_DIR/panel.env"

update_validate_mirror() {
  [[ "${1:-}" =~ ^(https://|http://|file:///)[A-Za-z0-9._~%/:@+-]+$ ]] \
    || panel_die "Invalid mirror URL: '${1:-}' (https://… or file:///…)"
}

update_save_mirror() {
  local base="${1:-}"
  [[ -n "$base" ]] || return 0
  update_validate_mirror "$base"
  mkdir -p "$ETC_DIR"
  env_set "$PANEL_ENV" CECP_PANEL_RAW_BASE "$base"
}

update_load_mirror() {
  CECP_PANEL_RAW_BASE=""
  if [[ -f "$PANEL_ENV" ]]; then
    secure_source "$PANEL_ENV"
  fi
  CECP_PANEL_RAW_BASE="${CECP_PANEL_RAW_BASE:-${CECP_PANEL_BUNDLE_URL:-}}"
}

update_check() {
  echo "--- CECP Panel ---"
  [[ -f "$ETC_DIR/panel.json" ]] && cat "$ETC_DIR/panel.json" || echo "  (not installed)"
  echo "  CLI version: $CECP_PANEL_VERSION"
  echo ""
  echo "--- System packages ---"
  for p in nginx mariadb-server php-fpm restic rclone certbot; do
    rpm -q "$p" 2>/dev/null | sed 's/^/  /' || dpkg -l "$p" 2>/dev/null | awk '/^ii/{print "  "$2" "$3}' || echo "  $p: (not from pkg mgr)"
  done
  command -v php &>/dev/null && echo "  $(php -v | head -1)"
  update_load_mirror
  if [[ -n "${CECP_PANEL_RAW_BASE:-}" ]]; then
    echo ""
    echo "  Update mirror: $CECP_PANEL_RAW_BASE"
  fi
}

update_component() {
  local comp="${1:-all}"
  require_root
  panel_log "Updating component: $comp ..."
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release ]]; then
    case "$comp" in
      nginx) dnf -y update nginx ;;
      mariadb|mysql) dnf -y update mariadb-server mariadb ;;
      php) dnf -y update php\* php-fpm ;;
      certbot) dnf -y update certbot python3-certbot-nginx ;;
      restic) dnf -y update restic ;;
      rclone) dnf -y update rclone ;;
      fail2ban) dnf -y update fail2ban ;;
      os|all)
        [[ "$comp" == "all" ]] && dnf -y update
        ;;
      *) panel_die "Unknown component: $comp (nginx|mariadb|php|certbot|restic|rclone|fail2ban|os|all)" ;;
    esac
  else
    apt-get update -y
    case "$comp" in
      nginx) apt-get install -y --only-upgrade nginx ;;
      mariadb) apt-get install -y --only-upgrade mariadb-server ;;
      php) apt-get install -y --only-upgrade 'php*' ;;
      certbot) apt-get install -y --only-upgrade certbot ;;
      restic) apt-get install -y --only-upgrade restic ;;
      rclone) apt-get install -y --only-upgrade rclone ;;
      os|all) apt-get upgrade -y ;;
      *) panel_die "Unknown component: $comp" ;;
    esac
  fi
  panel_log "Update done: $comp"
}

# cecp-panel update panel [VERSION|latest] [--sha256 HASH]
# The bundle must match dist/SHA256SUMS on the mirror (or the pinned hash): the panel runs
# as root, so an unverified download is remote code execution for whoever controls the mirror.
update_panel() {
  local ver="" pin=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha256) pin="${2:-}"; shift 2 || true ;;
      *) ver="$1"; shift ;;
    esac
  done
  require_root
  update_load_mirror
  local base="${CECP_PANEL_RAW_BASE:-}"
  [[ -n "$base" ]] || panel_die "Set update mirror: cecp-panel update mirror https://HOST/path/cecp-panel"
  update_validate_mirror "$base"
  ver="${ver:-$CECP_PANEL_VERSION}"
  [[ "$ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?|latest)$ ]] || panel_die "Invalid version: '$ver'"
  [[ -z "$pin" || "$pin" =~ ^[0-9a-f]{64}$ ]] || panel_die "--sha256 expects 64 hex chars"

  local tmp bak name expected actual
  tmp="$(mktemp -d)"
  name="cecp-panel-${ver}.tar.gz"
  panel_log "Downloading panel $ver ..."
  if ! curl -fsSL "${base%/}/dist/${name}" -o "$tmp/bundle.tar.gz"; then
    name="cecp-panel-latest.tar.gz"
    curl -fsSL "${base%/}/dist/${name}" -o "$tmp/bundle.tar.gz" || { rm -rf "$tmp"; panel_die "Download failed"; }
  fi
  if [[ -n "$pin" ]]; then
    expected="$pin"
  else
    curl -fsSL "${base%/}/dist/SHA256SUMS" -o "$tmp/SHA256SUMS" \
      || { rm -rf "$tmp"; panel_die "Mirror has no dist/SHA256SUMS — refusing an unverified update (or pass --sha256 HASH)"; }
    expected="$(awk -v f="$name" '{n=$2; sub(/^\*/, "", n); if (n == f) print $1}' "$tmp/SHA256SUMS" | head -1)"
  fi
  actual="$(sha256sum "$tmp/bundle.tar.gz" | cut -d' ' -f1)"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    rm -rf "$tmp"
    panel_die "Checksum mismatch for $name (expected ${expected:-none}, got $actual) — update aborted"
  fi
  panel_log "Checksum OK ($actual)"

  tar xzf "$tmp/bundle.tar.gz" -C "$tmp"
  local f
  [[ -f "$tmp/cecp-panel/cecp-panel" && -f "$tmp/cecp-panel/lib/common.sh" ]] || { rm -rf "$tmp"; panel_die "Bad bundle layout"; }
  for f in "$tmp/cecp-panel/cecp-panel" "$tmp/cecp-panel"/lib/*.sh; do
    bash -n "$f" || { rm -rf "$tmp"; panel_die "Bundle has a syntax error in $(basename "$f") — update aborted"; }
  done

  mkdir -p "$VAR_LIB/backups"
  bak="$(mktemp -d "$VAR_LIB/backups/panel-$(date +%Y%m%d_%H%M%S)-XXXX")"
  [[ -d "$INSTALL_ROOT" ]] && cp -a "$INSTALL_ROOT" "$bak/opt-cecp-panel"
  cp -a "$BIN_PATH" "$bak/cecp-panel.bin" 2>/dev/null || true
  panel_log "Backup previous panel at $bak"
  if ! { if command -v rsync &>/dev/null; then
           # bin/ holds the agent heartbeat script generated on the VPS (cron calls it)
           rsync -a --delete --exclude 'etc/' --exclude 'bin/' "$tmp/cecp-panel/" "$INSTALL_ROOT/"
         else
           cp -a "$tmp/cecp-panel/." "$INSTALL_ROOT/"
         fi \
         && chmod +x "$INSTALL_ROOT/cecp-panel" "$INSTALL_ROOT"/lib/*.sh \
         && install -m 0755 "$INSTALL_ROOT/cecp-panel" "$BIN_PATH"; }; then
    rm -rf "$INSTALL_ROOT"
    cp -a "$bak/opt-cecp-panel" "$INSTALL_ROOT"
    [[ -f "$bak/cecp-panel.bin" ]] && install -m 0755 "$bak/cecp-panel.bin" "$BIN_PATH"
    rm -rf "$tmp"
    panel_die "Install failed — previous panel restored from $bak"
  fi
  python3 - "$ETC_DIR/panel.json" "$ver" "$bak" "$actual" <<'PY'
import json, os, sys
from datetime import datetime, timezone
p, ver, bak, sha = sys.argv[1:5]
d = {}
if os.path.isfile(p):
    try:
        d = json.load(open(p))
    except ValueError:
        d = {}
d.update(version=ver, updated_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
         previous_backup=bak, bundle_sha256=sha, standalone=True)
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.chmod(p, 0o600)
PY
  rm -rf "$tmp"
  panel_log "Panel updated to $ver. Config in $ETC_DIR preserved."
}

update_mirror_set() {
  require_root
  [[ -n "${1:-}" ]] || panel_die "Usage: cecp-panel update mirror URL"
  update_save_mirror "$1"
  panel_log "Update mirror saved. Use: cecp-panel update panel"
}
