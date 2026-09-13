#!/usr/bin/env bash
# Lint gate: bash -n, truncation/inline-python check, shellcheck (local binary or Docker).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

files=(cecp-panel lib/*.sh ./*.sh)
while IFS= read -r f; do files+=("$f"); done < <(find tests -name '*.sh' | sort)

fail=0
for f in "${files[@]}"; do
  bash -n "$f" || { echo "bash -n FAIL: $f"; fail=1; }
done

py="$(command -v python3 || command -v python || true)"
[[ -n "$py" ]] || { echo "python3 required"; exit 2; }
"$py" tests/check_truncation.py || fail=1

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning -f gcc "${files[@]}" || fail=1
elif command -v docker >/dev/null 2>&1; then
  host_dir="$(pwd -W 2>/dev/null || pwd)"
  MSYS_NO_PATHCONV=1 docker run --rm -v "${host_dir}:/mnt" -w /mnt koalaman/shellcheck:stable \
    -S warning -f gcc "${files[@]}" || fail=1
else
  echo "WARN: shellcheck not available (install it or Docker) — skipped"
fi

if [[ "$fail" == "0" ]]; then echo "lint: OK"; else echo "lint: FAILED"; fi
exit "$fail"
