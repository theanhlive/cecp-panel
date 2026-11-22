#!/usr/bin/env bash
# T1 unit tests (bats-core). No root, no Docker, no network except the first bats-core fetch.
#   bash tests/unit/run.sh                 # all *.bats in tests/unit
#   bash tests/unit/run.sh common.bats     # one file
# BATS_BIN=/path/to/bats overrides the pinned copy (must still be 1.11.1).
# CECP_LIB_DIR=/path/to/lib runs the suite against another lib/ (mutation checks).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_VERSION="1.11.1"
BATS_COMMIT="b640ec3cf2c7c9cfc9e6351479261186f76eeec8"   # tag v1.11.1
BATS_DIR="$HERE/.bats-core"

if [[ -z "${BATS_BIN:-}" ]]; then
  if [[ ! -x "$BATS_DIR/bin/bats" ]] || [[ "$(git -C "$BATS_DIR" rev-parse HEAD 2>/dev/null)" != "$BATS_COMMIT" ]]; then
    rm -rf "$BATS_DIR"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "v${BATS_VERSION}" \
      https://github.com/bats-core/bats-core.git "$BATS_DIR"
    got="$(git -C "$BATS_DIR" rev-parse HEAD)"
    if [[ "$got" != "$BATS_COMMIT" ]]; then
      rm -rf "$BATS_DIR"
      echo "bats-core v${BATS_VERSION}: commit $got != pinned $BATS_COMMIT — refusing to run" >&2
      exit 2
    fi
  fi
  BATS_BIN="$BATS_DIR/bin/bats"
fi

ver="$("$BATS_BIN" --version)"
[[ "$ver" == "Bats ${BATS_VERSION}" ]] || { echo "need Bats ${BATS_VERSION}, got: $ver" >&2; exit 2; }

files=()
if (( $# )); then
  for f in "$@"; do [[ "$f" == /* ]] && files+=("$f") || files+=("$HERE/$f"); done
else
  files=("$HERE"/*.bats)
fi
exec "$BATS_BIN" "${files[@]}"
