#!/usr/bin/env bash
# Build the AlmaLinux 9 systemd image, install the panel from this checkout, run scenario.sh.
#   bash tests/integration/run.sh          # KEEP=1 keeps the container for debugging
# Not --privileged on purpose: /proc/sys stays read-only, so sysctl tuning cannot leak
# into the Docker host kernel (the scenario only checks the sysctl files).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export MSYS_NO_PATHCONV=1

IMG="cecp-panel-it:alma9"
NAME="cecp-panel-it"

docker build -t "$IMG" tests/integration
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
  --tmpfs /run --tmpfs /run/lock \
  "$IMG" >/dev/null
cleanup() { [[ "${KEEP:-0}" == "1" ]] || docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

booted=0
for _ in $(seq 90); do
  state="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == "running" || "$state" == "degraded" ]]; then booted=1; break; fi
  sleep 1
done
[[ "$booted" == "1" ]] || { echo "systemd did not boot in container"; exit 1; }

tar --exclude=./.git --exclude=./dist -cf - . \
  | docker exec -i "$NAME" bash -c 'rm -rf /root/cecp-panel && mkdir -p /root/cecp-panel && tar -C /root/cecp-panel -xf -'

docker exec "$NAME" bash /root/cecp-panel/install.sh >/tmp/cecp-it-install.log 2>&1 \
  || { tail -40 /tmp/cecp-it-install.log; echo "install.sh failed"; exit 1; }
echo "install.sh OK (log: /tmp/cecp-it-install.log)"

docker exec "$NAME" bash /root/cecp-panel/tests/integration/scenario.sh
