#!/usr/bin/env bash
# CECP Panel — ONE command install for customers (VPS root)
#
#   curl -fsSL https://YOUR-CDN/install-cecp-panel.sh | sudo bash
#
# Or with your GitHub raw base:
#   curl -fsSL https://raw.githubusercontent.com/ORG/REPO/main/scripts/cecp-panel/install-cecp-panel.sh | sudo bash -s -- --raw-base https://raw.githubusercontent.com/ORG/REPO/main/scripts/cecp-panel
#
set -euo pipefail

CECP_PANEL_VERSION="${CECP_PANEL_VERSION:-1.5.1-beta}"
# Public mirror — one-command install for end users
CECP_PANEL_RAW_BASE="${CECP_PANEL_RAW_BASE:-https://isharevn.net/downloads/cecp-panel}"

log() { echo "[install-cecp-panel] $*"; }
die() { echo "[install-cecp-panel] ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: curl ... | sudo bash"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-base) CECP_PANEL_RAW_BASE="$2"; shift 2 ;;
    --version) CECP_PANEL_VERSION="$2"; shift 2 ;;
    --no-onboard) NO_ONBOARD=1; shift ;;
    -h|--help)
      echo "Usage: install-cecp-panel.sh [--raw-base URL] [--version VER] [--no-onboard]"
      exit 0
      ;;
    *) die "Unknown arg: $1" ;;
  esac
done

INSTALLER_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" ]]; then
  INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

run_local_install() {
  local dir="$1"
  [[ -f "$dir/install.sh" ]] || return 1
  export CECP_PANEL_VERSION
  bash "$dir/install.sh"
  return 0
}

download_and_install() {
  local base="${CECP_PANEL_RAW_BASE%/}"
  [[ -n "$base" ]] || die "Set CECP_PANEL_RAW_BASE or pass --raw-base (GitHub raw path to scripts/cecp-panel)"
  local url="${base}/dist/cecp-panel-${CECP_PANEL_VERSION}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading $url ..."
  if ! curl -fsSL "$url" -o "$tmp/bundle.tar.gz"; then
    url="${base}/dist/cecp-panel-latest.tar.gz"
    log "Retry: $url ..."
    curl -fsSL "$url" -o "$tmp/bundle.tar.gz"
  fi
  tar xzf "$tmp/bundle.tar.gz" -C "$tmp"
  run_local_install "$tmp/cecp-panel"
  rm -rf "$tmp"
}

main() {
  echo "========================================================================="
  echo "  CECP Panel — one-command install $CECP_PANEL_VERSION"
  echo "========================================================================="
  if [[ -n "$INSTALLER_DIR" ]] && run_local_install "$INSTALLER_DIR"; then
    :
  elif [[ -n "$INSTALLER_DIR" ]] && [[ -d "$INSTALLER_DIR/dist" ]]; then
    tmp="$(mktemp -d)"
    tar xzf "$INSTALLER_DIR/dist/cecp-panel-latest.tar.gz" -C "$tmp" 2>/dev/null \
      || tar xzf "$INSTALLER_DIR/dist/cecp-panel-${CECP_PANEL_VERSION}.tar.gz" -C "$tmp"
    run_local_install "$tmp/cecp-panel"
    rm -rf "$tmp"
  else
    download_and_install
  fi
  log "Install complete."
  if [[ -z "${NO_ONBOARD:-}" ]] && [[ -t 0 ]] && command -v cecp-panel &>/dev/null; then
    log "Starting setup wizard (DNS + backup)..."
    cecp-panel onboard || true
  else
    log "Next: cecp-panel onboard   # DNS + Google Drive backup"
    log "Then:  cecp-panel site add your.domain.com"
  fi
}

main "$@"
