#!/usr/bin/env bash
# Runs INSIDE the AlmaLinux test container after install.sh. Exit code = number of failures.
set -uo pipefail

PASS=0
FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() {
  local desc="$1"
  shift
  if "$@" >/tmp/it-last.log 2>&1; then
    ok "$desc"
  else
    bad "$desc"
    tail -25 /tmp/it-last.log | sed 's/^/        /'
  fi
}

D="hotfix.test"
SLUG="hotfix_test"
SU="site_hotfix_test"
DROPIN="/etc/ssh/sshd_config.d/cecp-${SU}.conf"
VERSION="$(sed -nE 's/^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-([^}]+)\}"$/\1/p' /opt/cecp-panel/lib/common.sh)"
grep -q " $D\$" /etc/hosts || echo "127.0.0.1 $D" >>/etc/hosts

echo "=== CLI ==="
check "cli reports version $VERSION" bash -c "cecp-panel help | head -1 | grep -qF '$VERSION'"
check "update check runs" cecp-panel update check

echo "=== Site lifecycle ==="
# nginx/php-fpm reloads are asynchronous: allow a few seconds for new workers.
serves_wp() {
  for _ in 1 2 3 4 5; do
    curl -s "http://$D/" | grep -q 'wp-content' && return 0
    sleep 1
  done
  return 1
}
check "site add --wp" cecp-panel site add "$D" --wp
check "site serves WordPress" serves_wp
grep -q " second.test\$" /etc/hosts || echo "127.0.0.1 second.test" >>/etc/hosts
check "adding another site keeps this site's PHP socket owned by nginx" \
  bash -c "cecp-panel site add second.test && [ \"\$(stat -c %U /run/php-fpm/${SLUG}.sock)\" = nginx ]"
check "this site still reaches PHP (no 502)" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' 'http://$D/?s=probe')\" = 200 ]"
check "remove the second site" cecp-panel site remove second.test

echo "=== SFTP / sshd guard ==="
check "sftp-password writes a valid drop-in" \
  bash -c "cecp-panel site sftp-password $D && grep -qx 'Match User $SU' $DROPIN && sshd -t"
check "sftp-info prints the site user" bash -c "cecp-panel site sftp-info $D | grep -q 'User: $SU'"
check "empty site user is refused" \
  bash -c "! (source /opt/cecp-panel/lib/common.sh; source /opt/cecp-panel/lib/site.sh; site_sftp_enable '')"
printf 'Match User \n    ChrootDirectory /home/\n' >"$DROPIN"
check "precondition: damaged 1.5.0 drop-in breaks sshd -t" bash -c '! sshd -t'
check "security ssh-repair restores a valid config" \
  bash -c "cecp-panel security ssh-repair && sshd -t && grep -qx 'Match User $SU' $DROPIN"
check "ssh-harden applies through sshd -t" \
  bash -c "cecp-panel security ssh-harden && sshd -t && test -f /etc/ssh/sshd_config.d/99-cecp-harden.conf"

echo "=== WordPress system cron ==="
cron_line="$(grep -v '^#' "/etc/cron.d/cecp-wp-${SLUG}" | head -1)"
cron_cmd="${cron_line#*"$SU" }"
cron_log="$(grep -oE '>>[^ ]+' <<<"$cron_line" | tr -d '>')"
check "wp-cron command succeeds as the site user and logs" \
  bash -c "runuser -u $SU -- bash -c '$cron_cmd' && test -s '$cron_log'"

echo "=== optimize stack ==="
check "optimize stack completes" cecp-panel optimize stack
check "sysctl file requests bbr" grep -qx 'net.ipv4.tcp_congestion_control = bbr' /etc/sysctl.d/99-cecp-bbr.conf
check "nginx perf conf installed" test -f /etc/nginx/conf.d/cecp-perf.conf
check "opcache ini installed" test -f /etc/php.d/99-cecp-opcache.ini
check "mariadb tune installed" test -f /etc/my.cnf.d/cecp-tune.cnf
check "redis secured and running" bash -c 'test -f /etc/cecp-panel/redis.env && systemctl is-active --quiet redis'
check "site still serves WordPress after tuning" serves_wp

echo "=== update panel (file:// mirror) ==="
mkdir -p /tmp/mirror/dist
tar -C /root --exclude=cecp-panel/tests -czf "/tmp/mirror/dist/cecp-panel-${VERSION}.tar.gz" cecp-panel
check "update panel from mirror" \
  bash -c "cecp-panel update mirror file:///tmp/mirror && cecp-panel update panel && grep -qF '\"version\": \"$VERSION\"' /etc/cecp-panel/panel.json"

echo "=== site remove ==="
check "site remove" cecp-panel site remove "$D"
check "site artifacts are gone" bash -c "
  ! test -e /var/lib/cecp-panel/sites/$D.json &&
  ! test -e /etc/nginx/conf.d/cecp-$SLUG.conf &&
  ! test -e /etc/php-fpm.d/cecp-$SLUG.conf &&
  ! test -e /etc/cron.d/cecp-wp-$SLUG &&
  ! test -e $DROPIN &&
  ! id $SU &&
  ! mysql -e 'USE db_$SLUG'"
check "sshd config valid after remove" sshd -t
check "nginx config valid after remove" nginx -t

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
exit "$FAIL"
