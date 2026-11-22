#!/usr/bin/env bash
# Upgrade test (T3): install a released baseline, create a WordPress site, upgrade the panel to
# THIS checkout the way CHANGELOG "Nâng cấp từ …" says, then check the site and the panel.
#   bash tests/upgrade/run.sh                  # FROM=1.12.1-beta
#   FROM=1.13.0-beta bash tests/upgrade/run.sh
#   KEEP=1 …        keep the container for debugging (docker exec -it cecp-panel-up bash)
#   SKIP_BUILD=1 …  use an already built cecp-panel-it:alma9 image (no docker build)
#   DOCKER_RUN_OPTS="…" / DOCKER_EXEC_OPTS="…"  extra args (e.g. a proxy) for run / exec
# Reuses the AlmaLinux 9 systemd image of tests/integration. Exit code = number of failures.
#
# Baseline bundle, first match wins:
#   1. tests/baseline/cecp-panel-$FROM.tar.gz (checked against tests/baseline/SHA256SUMS if listed)
#   2. the released dist/cecp-panel-$FROM.tar.gz at git tag v$FROM (checked against that tag's SHA256SUMS)
#   3. git archive of tag v$FROM (older tags without dist/)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export MSYS_NO_PATHCONV=1

FROM="${FROM:-1.12.1-beta}"
[[ "$FROM" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$ ]] || { echo "Invalid FROM: '$FROM'"; exit 2; }
TO="$(sed -nE 's/^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-([^}]+)\}"$/\1/p' lib/common.sh)"
IMG="cecp-panel-it:alma9"
NAME="cecp-panel-up"
WORK="$(mktemp -d)"
LOG="${UPGRADE_LOG:-/tmp/cecp-upgrade-${FROM}.log}"
read -r -a run_opts <<<"${DOCKER_RUN_OPTS:-}"
read -r -a exec_opts <<<"${DOCKER_EXEC_OPTS:-}"

# CI diagnostics on failure: what systemd and MariaDB say inside the container.
it_diag() {
  echo "::group::container diagnostics ($1)"
  docker logs --tail 40 "$1" 2>&1 || true
  docker exec "$1" bash -c 'systemctl is-system-running; systemctl --failed --no-pager;
    systemctl status mariadb mysql --no-pager -l 2>&1 | tail -30;
    journalctl -u mariadb -u mysql -n 60 --no-pager 2>&1;
    authselect current 2>&1 | head -3; grep -E "^(account|auth)" /etc/pam.d/sudo /etc/pam.d/system-auth /etc/pam.d/common-account 2>/dev/null; systemctl is-active sssd 2>&1; getent shadow root >/dev/null && echo shadow-ok; for u in $(getent passwd | cut -d: -f1 | grep "^site_"); do echo "== $u"; getent shadow "$u" | cut -d: -f1,3-9 || echo "no shadow entry"; sudo -n -u "$u" true 2>&1 | head -2; journalctl --no-pager -n 8 _COMM=sudo _COMM=unix_chkpwd 2>&1 | tail -8; done; grep Cap /proc/self/status; ls -l /etc/shadow; tail -5 /var/log/secure 2>/dev/null;
    ls -l /etc/my.cnf.d /etc/mysql/mariadb.conf.d 2>/dev/null; df -h / /var/lib/mysql 2>/dev/null' 2>&1 || true
  echo "::endgroup::"
}

cleanup() {
  rm -rf "$WORK"
  [[ "${KEEP:-0}" == "1" ]] || docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- baseline bundle -------------------------------------------------------------------------
BASE="$WORK/baseline.tar.gz"
name="cecp-panel-${FROM}.tar.gz"
if [[ -f "tests/baseline/$name" ]]; then
  cp "tests/baseline/$name" "$BASE"
  want="$(awk -v f="$name" '$2 == f {print $1}' tests/baseline/SHA256SUMS 2>/dev/null || true)"
  src="tests/baseline/$name"
else
  git rev-parse -q --verify "refs/tags/v$FROM" >/dev/null \
    || git fetch -q origin "refs/tags/v$FROM:refs/tags/v$FROM" 2>/dev/null \
    || { echo "No tests/baseline/$name and no git tag v$FROM"; exit 2; }
  if git cat-file -e "v$FROM:dist/$name" 2>/dev/null; then
    git show "v$FROM:dist/$name" >"$BASE"
    want="$(git show "v$FROM:dist/SHA256SUMS" | awk -v f="$name" '{n=$2; sub(/^\*/, "", n); if (n == f) print $1}')"
    src="tag v$FROM dist/$name"
  else
    git archive --format=tar.gz --prefix=cecp-panel/ "v$FROM" >"$BASE"
    want=""
    src="git archive v$FROM"
  fi
fi
got="$(sha256sum "$BASE" | cut -d' ' -f1)"
if [[ -n "${want:-}" && "$want" != "$got" ]]; then
  echo "Baseline checksum mismatch ($src): expected $want, got $got"
  exit 2
fi
base_ver="$(tar xzOf "$BASE" cecp-panel/lib/common.sh | sed -nE 's/^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-([^}]+)\}"$/\1/p')"
[[ "$base_ver" == "$FROM" ]] || { echo "Baseline $src reports version '$base_ver', not $FROM"; exit 2; }
echo "Upgrade test: $FROM ($src, sha256 ${got:0:12}…) -> $TO (this checkout)"

# --- container -------------------------------------------------------------------------------
[[ "${SKIP_BUILD:-0}" == "1" ]] || docker build -t "$IMG" tests/integration
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --cap-add SYS_ADMIN --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  --tmpfs /run --tmpfs /run/lock \
  "${run_opts[@]}" "$IMG" >/dev/null

booted=0
for _ in $(seq 90); do
  state="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == "running" || "$state" == "degraded" ]]; then booted=1; break; fi
  sleep 1
done
[[ "$booted" == "1" ]] || { it_diag "$NAME"; echo "systemd did not boot in container"; exit 1; }

# Baseline as a customer gets it (the released bundle), unpacked to /root/baseline/cecp-panel.
docker exec -i "$NAME" bash -c 'rm -rf /root/baseline && mkdir -p /root/baseline && tar -C /root/baseline -xzf -' <"$BASE"
# Target: this checkout (tests included; the scenario builds the customer bundle without them).
tar --exclude=./.git --exclude=./dist -cf - . \
  | docker exec -i "$NAME" bash -c 'rm -rf /root/cecp-panel && mkdir -p /root/cecp-panel && tar -C /root/cecp-panel -xf -'

docker exec "${exec_opts[@]}" "$NAME" bash /root/baseline/cecp-panel/install.sh >"$LOG" 2>&1 \
  || { it_diag "$NAME"; tail -40 "$LOG"; echo "baseline $FROM install.sh failed (log: $LOG)"; exit 1; }
echo "baseline $FROM install.sh OK (log: $LOG)"

# Test-container workaround (never on a VPS): on GitHub's runner, sudo's PAM account step fails
# in the AlmaLinux container ("unix_chkpwd: could not obtain user info (root)" ->
# "PAM account management error"), and baselines <= 1.13.1 install WordPress with `sudo -u`.
# The current panel uses runuser (no PAM account step), so only the old baseline needs this.
docker exec "$NAME" bash -c 'f=/etc/pam.d/sudo; [ -f "$f" ] && sed -i "s/^account[[:space:]].*/account    sufficient   pam_permit.so/" "$f"'

docker exec "${exec_opts[@]}" -e FROM="$FROM" -e TO="$TO" "$NAME" \
  bash /root/cecp-panel/tests/upgrade/scenario.sh || { rc=$?; it_diag "$NAME"; exit "$rc"; }
