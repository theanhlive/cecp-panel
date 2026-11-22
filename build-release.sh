#!/usr/bin/env bash
# Build a customer release into dist/<channel>/: cecp-panel-VERSION.tar.gz, cecp-panel-latest.tar.gz,
# SHA256SUMS. Signing is MANUAL and offline (docs/RELEASING.md): the secret key never enters
# this repo or CI. The beta channel is also copied to legacy dist/ for panels older than 1.14.
#   ./build-release.sh [--channel stable|beta]   # default: beta for X.Y.Z-suffix, stable for X.Y.Z
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANNEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 || { echo "ERROR: --channel needs stable|beta" >&2; exit 1; } ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$(basename "$ROOT")" == "cecp-panel" ]] || { echo "ERROR: repo dir must be named cecp-panel" >&2; exit 1; }

SRC_VERSION="$(sed -nE 's/^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-([^}]+)\}"$/\1/p' "$ROOT/lib/common.sh")"
VERSION="${CECP_PANEL_VERSION:-$SRC_VERSION}"
[[ -n "$VERSION" ]] || { echo "ERROR: cannot read version from lib/common.sh" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$ ]] || { echo "ERROR: bad version '$VERSION'" >&2; exit 1; }
if [[ -z "$CHANNEL" ]]; then
  [[ "$VERSION" == *-* ]] && CHANNEL=beta || CHANNEL=stable
fi
[[ "$CHANNEL" =~ ^(stable|beta)$ ]] || { echo "ERROR: --channel must be stable or beta (got '$CHANNEL')" >&2; exit 1; }
if [[ "$CHANNEL" == "stable" && "$VERSION" == *-* ]]; then
  echo "ERROR: $VERSION is a pre-release — it cannot go to the stable channel" >&2
  exit 1
fi
for f in cecp-panel install.sh install-cecp-panel.sh; do
  if grep -qE 'CECP_PANEL_VERSION:-[0-9]' "$ROOT/$f" && ! grep -qF "CECP_PANEL_VERSION:-${VERSION}}" "$ROOT/$f"; then
    echo "ERROR: $f default version differs from $VERSION" >&2
    exit 1
  fi
done

echo "Lint gate..."
bash "$ROOT/tests/lint.sh"

DIST="$ROOT/dist"
CDIR="$DIST/$CHANNEL"
OUT="$CDIR/cecp-panel-${VERSION}.tar.gz"
mkdir -p "$CDIR"
# Never ship local secrets, tests, VCS metadata or previous dist artifacts
tar czf "$OUT" -C "$(dirname "$ROOT")" \
  --exclude='cecp-panel/dist' \
  --exclude='cecp-panel/.git' \
  --exclude='cecp-panel/.gitattributes' \
  --exclude='cecp-panel/.gitignore' \
  --exclude='cecp-panel/tests' \
  --exclude='cecp-panel/etc/credentials.env' \
  --exclude='cecp-panel/keys/*.key' \
  --exclude='cecp-panel/**/*.bak' \
  --exclude='cecp-panel/**/*~' \
  --exclude='__pycache__' \
  cecp-panel
# publish_dir DIR: tarballs of this version only + SHA256SUMS; a stale signature is removed so a
# forgotten signing step fails loudly on panels that enforce signatures instead of passing silently.
publish_dir() {
  local d="$1" old bn
  mkdir -p "$d"
  [[ "$d/cecp-panel-${VERSION}.tar.gz" -ef "$OUT" ]] || cp -f "$OUT" "$d/cecp-panel-${VERSION}.tar.gz"
  # Portable "latest" copy (Windows Git bash may lack ln -sf)
  cp -f "$OUT" "$d/cecp-panel-latest.tar.gz"
  for old in "$d"/cecp-panel-*.tar.gz; do
    [[ -f "$old" ]] || continue
    bn="$(basename "$old")"
    [[ "$bn" == "cecp-panel-latest.tar.gz" || "$bn" == "cecp-panel-${VERSION}.tar.gz" ]] && continue
    rm -f "$old"
  done
  (cd "$d" && sha256sum "cecp-panel-${VERSION}.tar.gz" cecp-panel-latest.tar.gz >SHA256SUMS)
  rm -f "$d/SHA256SUMS.minisig"
}
publish_dir "$CDIR"
# Panels before channels (<= 1.13.x) only read dist/: keep it identical to the beta channel.
[[ "$CHANNEL" == "beta" ]] && publish_dir "$DIST"
echo "Built: $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
echo "Channel: $CHANNEL ($CDIR)"
echo "Checksums: $CDIR/SHA256SUMS"
# Quick integrity (portable grep)
list="$(tar tzf "$OUT")"
echo "$list" | grep -E 'cecp-panel/cecp-panel$' >/dev/null \
  || { echo "ERROR: missing cecp-panel binary in tarball" >&2; exit 1; }
echo "$list" | grep -E 'lib/security\.sh$' >/dev/null \
  || { echo "ERROR: missing lib/security.sh in tarball" >&2; exit 1; }
echo "$list" | grep -E 'cecp-panel/keys/cecp-release\.pub$' >/dev/null \
  || { echo "ERROR: missing keys/cecp-release.pub in tarball" >&2; exit 1; }
if echo "$list" | grep -E 'etc/credentials\.env$|cecp-panel/tests/|\.key$' >/dev/null; then
  echo "ERROR: tarball contains credentials.env, tests/ or a .key file — abort" >&2
  exit 1
fi
echo "Integrity: OK (binary + security.sh + release pubkey present, no credentials.env, no tests, no .key)"

echo ""
if grep -qE '^RW[A-Za-z0-9+/]{54}$' "$ROOT/keys/cecp-release.pub"; then
  echo "=== SIGN NOW (offline machine that holds the secret key — never in CI) ==="
  echo "  minisign -Sm dist/$CHANNEL/SHA256SUMS -s /PATH/OFFLINE/cecp-release.key -t 'cecp-panel $VERSION channel=$CHANNEL'"
  [[ "$CHANNEL" == "beta" ]] && echo "  cp dist/beta/SHA256SUMS.minisig dist/SHA256SUMS.minisig   # legacy dist/ has the same SHA256SUMS"
  echo "  minisign -Vm dist/$CHANNEL/SHA256SUMS -p keys/cecp-release.pub"
  echo "Panels with the release key REFUSE this release until SHA256SUMS.minisig is committed."
else
  echo "NOTE: keys/cecp-release.pub is a placeholder — release not signed (panels only warn)."
  echo "      Create the key once: docs/RELEASING.md, section \"Khoá ký\"."
fi
