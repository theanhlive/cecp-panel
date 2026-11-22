#!/usr/bin/env bash
# Offline test of system_swap_ensure / system_swap_add / system_tune_install with a failing swapon.
# No root, no real swap: stub commands first in PATH, temp SWAP_FILE. Prints "RESULT: N passed, M failed".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/etc" "$TMP/log"
export CALLS="$TMP/calls"
: >"$CALLS"

# Stubs: swapon always fails (except --show), mkswap and fallocate succeed; every call is recorded.
for c in swapon mkswap fallocate; do
  cat >"$TMP/bin/$c" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
echo "$name $*" >>"$CALLS"
if [[ "$name" == "swapon" && "${1:-}" != "--show" ]]; then
  echo "swapon: $1: swapon failed: Operation not permitted" >&2
  exit 1
fi
if [[ "$name" == "fallocate" ]]; then : >"${*: -1}"; fi
exit 0
STUB
  chmod +x "$TMP/bin/$c"
done
export PATH="$TMP/bin:$PATH"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/system.sh
source "$ROOT/lib/system.sh"

# Redirect every path the libs write to (after sourcing, so the defaults are overridden).
ETC_DIR="$TMP/etc"
LOG_DIR="$TMP/log"
SWAP_FILE="$TMP/swapfile"
PROC_SWAPS="$TMP/proc_swaps"
: >"$PROC_SWAPS"
: >"$SWAP_FILE"
require_root() { :; }
system_ensure_config() { :; }
system_load_config() { SWAP_MIN_TOTAL_MB=512; }
system_swap_total_mb() { echo 0; }
system_swap_recommended_gb() { echo 1; }
set +e

PASSED=0
FAILED=0
t_ok() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
t_bad() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

# 1. Existing inactive file, swapon keeps failing: WARN + rc 0, no system_swap_add.
OUT="$(system_swap_ensure 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then t_ok "ensure returns 0 when swapon keeps failing"; else t_bad "ensure returned $RC"; fi
if grep -q 'WARN' <<<"$OUT"; then t_ok "prints WARN"; else t_bad "no WARN in output"; fi
if grep -q 'Operation not permitted' <<<"$OUT"; then t_ok "WARN includes swapon stderr"; else t_bad "swapon stderr missing"; fi
if grep -q 'already exists' <<<"$OUT"; then t_bad "printed 'already exists'"; else t_ok "no 'already exists'"; fi
if grep -q '^mkswap' "$CALLS"; then t_ok "mkswap re-init attempted"; else t_bad "mkswap not called"; fi
if grep -q '^fallocate' "$CALLS"; then t_bad "system_swap_add was called"; else t_ok "system_swap_add not called"; fi

# 2. File already active (listed in /proc/swaps) but below minimum: leave it, never mkswap.
: >"$CALLS"
echo "$SWAP_FILE file 262140 0 -2" >"$PROC_SWAPS"
OUT="$(system_swap_ensure 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then t_ok "active file: ensure returns 0"; else t_bad "active file: rc=$RC"; fi
if grep -q '^mkswap' "$CALLS"; then t_bad "active file: mkswap was called"; else t_ok "active file: mkswap NOT called"; fi
if grep -q 'active but below minimum' <<<"$OUT"; then t_ok "active file: logged"; else t_bad "active file: no log line"; fi

# 2b. Exact match only: /swapfile2 is listed, /swapfile is not -> NOT active (swapfile2 must not match).
: >"$CALLS"
SWAP_FILE_SAVED="$SWAP_FILE"
echo "${SWAP_FILE}2 file 262140 0 -2" >"$PROC_SWAPS"
OUT="$(system_swap_ensure 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then t_ok "swapfile2 listed: ensure returns 0"; else t_bad "swapfile2 listed: rc=$RC"; fi
if grep -q '^mkswap' "$CALLS"; then t_ok "swapfile2 listed: file treated as NOT active (mkswap called)"; else t_bad "swapfile2 treated as active (substring match)"; fi
SWAP_FILE="$SWAP_FILE_SAVED"
: >"$PROC_SWAPS"

# 3. system_swap_add: a failing swapon returns 1 (no exit under set -e).
rm -f "$SWAP_FILE"
: >"$CALLS"
(
  set -e
  system_swap_add 1 >"$TMP/add.out" 2>&1
)
ADD_RC=$?
if [[ "$ADD_RC" -eq 1 ]]; then t_ok "system_swap_add returns 1 on swapon failure"; else t_bad "system_swap_add rc=$ADD_RC"; fi

# 4. system_swap_add: fallocate and dd both fail -> rc 1, no partial file left behind.
rm -f "$SWAP_FILE"
fallocate() { return 1; }
dd() { return 1; }
system_swap_add 1 >"$TMP/add2.out" 2>&1
ADD_RC=$?
unset -f fallocate dd
if [[ "$ADD_RC" -eq 1 ]]; then t_ok "system_swap_add returns 1 when file creation fails"; else t_bad "create-fail rc=$ADD_RC"; fi
if [[ -e "$SWAP_FILE" ]]; then t_bad "partial swap file left behind"; else t_ok "no partial swap file left"; fi

# 5. system_tune_install keeps going when system_swap_ensure returns 1.
: >"$CALLS"
system_swap_ensure() { return 1; }
system_disk_clean() { echo disk_clean >>"$CALLS"; }
system_enable_maintain_cron() { echo maintain_cron >>"$CALLS"; }
system_logrotate_install() { echo logrotate >>"$CALLS"; }
OUT="$(system_tune_install 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then t_ok "system_tune_install returns 0 when swap fails"; else t_bad "system_tune_install rc=$RC"; fi
for step in disk_clean maintain_cron logrotate; do
  if grep -qx "$step" "$CALLS"; then t_ok "system_tune_install ran $step"; else t_bad "system_tune_install skipped $step"; fi
done

echo "RESULT: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
