# shellcheck shell=bash disable=SC2154  # status/output are set by bats `run`
# Shared setup for tests/unit/*.bats. Loads lib/common.sh with every path pointed at a temp dir.
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
CECP_LIB_DIR="${CECP_LIB_DIR:-$REPO_ROOT/lib}"

load_common() {
  # shellcheck source=../../lib/common.sh
  source "$CECP_LIB_DIR/common.sh"
  set +u   # bats internals are not nounset-clean; the lib functions under test do not rely on -u
  T="$BATS_TEST_TMPDIR"
  ETC_DIR="$T/etc"
  # shellcheck disable=SC2034  # read by lib functions
  VAR_LIB="$T/var"
  SITES_DIR="$T/sites"
  LOG_DIR="$T/log"
  mkdir -p "$ETC_DIR" "$SITES_DIR" "$LOG_DIR"
}

# Fail with a message (bats-assert is not vendored on purpose: one pinned dependency only).
fail() { echo "$*" >&2; return 1; }
assert_status() { [[ "$status" -eq "$1" ]] || fail "expected status $1, got $status; output: $output"; }
assert_output_has() { [[ "$output" == *"$1"* ]] || fail "output lacks '$1': $output"; }
