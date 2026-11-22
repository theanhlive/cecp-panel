#!/usr/bin/env bash
# Build a systemd test image, install the panel from this checkout, run scenario.sh.
#   bash tests/integration/run.sh                  # AlmaLinux 9 (default)
#   OS=ubuntu22.04 bash tests/integration/run.sh   # alma9 | ubuntu22.04 | ubuntu24.04
#   KEEP=1 ...                                     # keep the container for debugging
# Behind an egress proxy (CI sandbox): IT_HTTPS_PROXY=http://HOST:PORT (reachable from inside
# containers) and IT_CA_FILE=/path/ca.pem (extra CA to trust) are passed to build and run.
# Not --privileged on purpose: /proc/sys stays read-only, so sysctl tuning cannot leak
# into the Docker host kernel (the scenario only checks the sysctl files).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export MSYS_NO_PATHCONV=1

OS="${OS:-alma9}"
case "$OS" in
  alma9) DOCKERFILE=tests/integration/Dockerfile ;;
  ubuntu22.04) DOCKERFILE=tests/integration/Dockerfile.ubuntu2204 ;;
  ubuntu24.04) DOCKERFILE=tests/integration/Dockerfile.ubuntu2404 ;;
  *) echo "Unknown OS='$OS' (use alma9, ubuntu22.04 or ubuntu24.04)" >&2; exit 2 ;;
esac
IMG="cecp-panel-it:${OS}"
# alma9 keeps the historical name; other OSes get their own so runs can go in parallel.
NAME="cecp-panel-it"
[[ "$OS" == alma9 ]] || NAME="cecp-panel-it-${OS//./}"
INSTALL_LOG=/tmp/cecp-it-install.log
[[ "$OS" == alma9 ]] || INSTALL_LOG="/tmp/cecp-it-install-${OS}.log"

build_args=()
exec_env=()
if [[ -n "${IT_HTTPS_PROXY:-}" ]]; then
  build_args+=(--build-arg "https_proxy=$IT_HTTPS_PROXY" --build-arg "HTTPS_PROXY=$IT_HTTPS_PROXY")
  # Test domains (*.test) and loopback must never go through the proxy.
  exec_env+=(-e "https_proxy=$IT_HTTPS_PROXY" -e "HTTPS_PROXY=$IT_HTTPS_PROXY"
             -e "no_proxy=localhost,127.0.0.1,::1,.test" -e "NO_PROXY=localhost,127.0.0.1,::1,.test")
fi
if [[ -n "${IT_CA_FILE:-}" ]]; then
  build_args+=(--secret "id=it_ca,src=$IT_CA_FILE")
fi

docker build -t "$IMG" -f "$DOCKERFILE" "${build_args[@]}" tests/integration
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --cap-add SYS_ADMIN --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  --tmpfs /run --tmpfs /run/lock \
  "$IMG" >/dev/null
# CI diagnostics on failure: what systemd and MariaDB say inside the container.
it_diag() {
  echo "::group::container diagnostics ($1)"
  docker logs --tail 40 "$1" 2>&1 || true
  docker exec "$1" bash -c 'systemctl is-system-running; systemctl --failed --no-pager;
    systemctl status mariadb mysql --no-pager -l 2>&1 | tail -30;
    journalctl -u mariadb -u mysql -n 60 --no-pager 2>&1;
    authselect current 2>&1 | head -3; grep -E "^(account|auth)" /etc/pam.d/sudo /etc/pam.d/system-auth /etc/pam.d/common-account 2>/dev/null; systemctl is-active sssd 2>&1; getent shadow root >/dev/null && echo shadow-ok; for u in $(getent passwd | cut -d: -f1 | grep "^site_"); do echo "== $u"; getent shadow "$u" | cut -d: -f1,3-9 || echo "no shadow entry"; sudo -n -u "$u" true 2>&1 | head -2; done; ls -l /etc/shadow; tail -5 /var/log/secure 2>/dev/null;
    ls -l /etc/my.cnf.d /etc/mysql/mariadb.conf.d 2>/dev/null; df -h / /var/lib/mysql 2>/dev/null' 2>&1 || true
  echo "::endgroup::"
}

cleanup() { [[ "${KEEP:-0}" == "1" ]] || docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

booted=0
for _ in $(seq 90); do
  state="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == "running" || "$state" == "degraded" ]]; then booted=1; break; fi
  sleep 1
done
[[ "$booted" == "1" ]] || { it_diag "$NAME"; echo "systemd did not boot in container ($OS)"; exit 1; }

# Some Docker hosts (sandboxed kernels) cannot set up the user namespace of Ubuntu 24.04's
# hardened redis-server unit (PrivateUsers=yes): it dies with 217/USER. Probe it once and relax
# only that setting when it happens — a test-host quirk, not a panel bug (real VPSes are fine).
docker exec "$NAME" bash -c 'systemctl cat redis-server >/dev/null 2>&1 || exit 0
  systemctl start redis-server 2>/dev/null
  if [ "$(systemctl show -p ExecMainStatus --value redis-server)" = 217 ]; then
    mkdir -p /etc/systemd/system/redis-server.service.d
    printf "[Service]\nPrivateUsers=false\n" >/etc/systemd/system/redis-server.service.d/it-no-userns.conf
    systemctl daemon-reload
    echo "note: redis-server needs PrivateUsers=false on this Docker host"
  fi
  systemctl stop redis-server; systemctl reset-failed redis-server 2>/dev/null; true'

tar --exclude=./.git --exclude=./dist -cf - . \
  | docker exec -i "$NAME" bash -c 'rm -rf /root/cecp-panel && mkdir -p /root/cecp-panel && tar -C /root/cecp-panel -xf -'

if [[ -n "${IT_HTTPS_PROXY:-}" ]]; then
  # The panel runs wp-cli through `sudo -u SITE_USER`, which drops proxy variables by default.
  docker exec "$NAME" bash -c 'echo "Defaults env_keep += \"https_proxy HTTPS_PROXY no_proxy NO_PROXY\"" >/etc/sudoers.d/it-proxy && chmod 440 /etc/sudoers.d/it-proxy'
  # No DNS inside the container (the proxy resolves names), but WordPress refuses download URLs
  # whose host it cannot resolve ("A valid URL was not provided"): any public address will do.
  docker exec "$NAME" bash -c 'for h in wordpress.org api.wordpress.org downloads.wordpress.org; do echo "198.143.164.252 $h" >>/etc/hosts; done'
fi

docker exec "${exec_env[@]}" "$NAME" bash /root/cecp-panel/install.sh >"$INSTALL_LOG" 2>&1 \
  || { it_diag "$NAME"; tail -40 "$INSTALL_LOG"; echo "install.sh failed ($OS)"; exit 1; }
echo "install.sh OK on $OS (log: $INSTALL_LOG)"

docker exec "${exec_env[@]}" -e "IT_OS=$OS" "$NAME" bash /root/cecp-panel/tests/integration/scenario.sh
