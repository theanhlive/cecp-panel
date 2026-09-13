#!/usr/bin/env bash
# Build customer release tarball: dist/cecp-panel-VERSION.tar.gz (+ dist/SHA256SUMS)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(basename "$ROOT")" == "cecp-panel" ]] || { echo "ERROR: repo dir must be named cecp-panel" >&2; exit 1; }

SRC_VERSION="$(sed -nE 's/^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-([^}]+)\}"$/\1/p' "$ROOT/lib/common.sh")"
VERSION="${CECP_PANEL_VERSION:-$SRC_VERSION}"
[[ -n "$VERSION" ]] || { echo "ERROR: cannot read version from lib/common.sh" >&2; exit 1; }
for f in cecp-panel install.sh install-cecp-panel.sh; do
  if grep -qE 'CECP_PANEL_VERSION:-[0-9]' "$ROOT/$f" && ! grep -qF "CECP_PANEL_VERSION:-${VERSION}}" "$ROOT/$f"; then
    echo "ERROR: $f default version differs from $VERSION" >&2
    exit 1
  fi
done

echo "Lint gate..."
bash "$ROOT/tests/lint.sh"

DIST="$ROOT/dist"
OUT="$DIST/cecp-panel-${VERSION}.tar.gz"
mkdir -p "$DIST"
# Never ship local secrets, tests, VCS metadata or previous dist artifacts
tar czf "$OUT" -C "$(dirname "$ROOT")" \
  --exclude='cecp-panel/dist' \
  --exclude='cecp-panel/.git' \
  --exclude='cecp-panel/.gitattributes' \
  --exclude='cecp-panel/.gitignore' \
  --exclude='cecp-panel/tests' \
  --exclude='cecp-panel/etc/credentials.env' \
  --exclude='cecp-panel/**/*.bak' \
  --exclude='cecp-panel/**/*~' \
  cecp-panel
# Portable "latest" copy (Windows Git bash may lack ln -sf)
cp -f "$OUT" "$DIST/cecp-panel-latest.tar.gz"
(cd "$DIST" && sha256sum cecp-panel-*.tar.gz >SHA256SUMS)
echo "Built: $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
echo "Latest: $DIST/cecp-panel-latest.tar.gz"
echo "Checksums: $DIST/SHA256SUMS"
# Quick integrity (portable grep)
list="$(tar tzf "$OUT")"
echo "$list" | grep -E 'cecp-panel/cecp-panel$' >/dev/null \
  || { echo "ERROR: missing cecp-panel binary in tarball" >&2; exit 1; }
echo "$list" | grep -E 'lib/security\.sh$' >/dev/null \
  || { echo "ERROR: missing lib/security.sh in tarball" >&2; exit 1; }
if echo "$list" | grep -E 'etc/credentials\.env$|cecp-panel/tests/' >/dev/null; then
  echo "ERROR: tarball contains credentials.env or tests/ — abort" >&2
  exit 1
fi
echo "Integrity: OK (binary + security.sh present, no credentials.env, no tests)"
