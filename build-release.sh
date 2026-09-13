#!/usr/bin/env bash
# Build customer release tarball: dist/cecp-panel-VERSION.tar.gz
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${CECP_PANEL_VERSION:-1.5.0-beta}"
DIST="$ROOT/dist"
OUT="$DIST/cecp-panel-${VERSION}.tar.gz"
mkdir -p "$DIST"
# Never ship local secrets or previous dist artifacts
tar czf "$OUT" -C "$(dirname "$ROOT")" \
  --exclude='cecp-panel/dist' \
  --exclude='cecp-panel/.git' \
  --exclude='cecp-panel/etc/credentials.env' \
  --exclude='cecp-panel/**/*.bak' \
  --exclude='cecp-panel/**/*~' \
  cecp-panel
# Portable "latest" copy (Windows Git bash may lack ln -sf)
cp -f "$OUT" "$DIST/cecp-panel-latest.tar.gz"
echo "Built: $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
echo "Latest: $DIST/cecp-panel-latest.tar.gz"
# Quick integrity (portable grep)
list="$(tar tzf "$OUT")"
echo "$list" | grep -E 'cecp-panel/cecp-panel$' >/dev/null \
  || { echo "ERROR: missing cecp-panel binary in tarball" >&2; exit 1; }
echo "$list" | grep -E 'lib/security\.sh$' >/dev/null \
  || { echo "ERROR: missing lib/security.sh in tarball" >&2; exit 1; }
if echo "$list" | grep -E 'etc/credentials\.env$' >/dev/null; then
  echo "ERROR: tarball contains etc/credentials.env — abort" >&2
  exit 1
fi
echo "Integrity: OK (binary + security.sh present, no credentials.env)"
