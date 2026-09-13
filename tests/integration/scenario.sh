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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="hotfix.test"; SLUG="hotfix_test"; SU="site_hotfix_test"
D2="second.test"; SU2="site_second_test"
DOCROOT="/home/$SU/public_html"
DROPIN="/etc/ssh/sshd_config.d/cecp-${SU}.conf"
VERSION="$(sed -nE 's/^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-([^}]+)\}"$/\1/p' /opt/cecp-panel/lib/common.sh)"
for h in "$D" "$D2" a-b.test a.b.test; do
  grep -q " $h\$" /etc/hosts || echo "127.0.0.1 $h" >>/etc/hosts
done

# nginx/php-fpm reloads are asynchronous: allow a few seconds for new workers.
serves_wp() {
  for _ in 1 2 3 4 5; do
    curl -s "http://${1:-$D}/" | grep -q 'wp-content' && return 0
    sleep 1
  done
  return 1
}
status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# nginx reload is asynchronous: give new workers a moment before asserting on responses.
settle() { sleep 1.5; }
# expect_cache PATH STATUS [HOST] — dumps response headers into the check log on failure.
expect_cache() {
  curl -s -o /dev/null -D - "http://${3:-$D}$1" | tr -d '\r' | tee /dev/stderr \
    | awk -F': ' 'tolower($1)=="x-cecp-cache"{print $2}' | grep -qx "$2"
}

echo "=== CLI ==="
check "cli reports version $VERSION" bash -c "cecp-panel help | head -1 | grep -qF '$VERSION'"
check "update check runs" cecp-panel update check

echo "=== Input validation / injection ==="
check "invalid domain rejected" bash -c "! cecp-panel site add 'bad_domain' && ! cecp-panel site add 'x.test;id'"
check "path traversal in domain rejected" bash -c "! cecp-panel wp status '../../etc/passwd'"
check "cf purge-url rejects injection" bash -c "cecp-panel cf purge-url \"https://a.test/');import os;#\" 2>&1 | grep -q 'Invalid URL'"
check "dns add rejects bad IP" bash -c "cecp-panel dns add www 1.2.3.999 2>&1 | grep -q 'Invalid IPv4'"
check "backup configure rejects cron injection" \
  bash -c "! cecp-panel backup configure 2 15 \$'*\n* * * * * root touch /tmp/pwn' 7 6 12 && ! grep -qs pwn /etc/cron.d/cecp-panel-backup"
check "update mirror rejects shell metacharacters" bash -c "! cecp-panel update mirror 'https://x.test/\$(id)'"

echo "=== Site lifecycle ==="
check "site add --wp $D" cecp-panel site add "$D" --wp
check "site serves WordPress" serves_wp
check "site add --wp $D2" cecp-panel site add "$D2" --wp
settle
check "adding a site keeps the other site's PHP socket owned by nginx" test "$(stat -c %U /run/php-fpm/${SLUG}.sock)" = nginx
check "other site still reaches PHP (no 502)" expect_cache '/?s=after-add' BYPASS
check "WordPress admin is not 'admin'" \
  bash -c "! runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT user list --field=user_login | grep -qx admin"
WPPASS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("wp_admin_pass",""))' "/var/lib/cecp-panel/sites/$D.json")"
check "WP admin password stored in site meta (600)" \
  bash -c "[ -n '$WPPASS' ] && [ \"\$(stat -c %a /var/lib/cecp-panel/sites/$D.json)\" = 600 ]"
check "WP admin password never written to panel.log" bash -c "[ -n '$WPPASS' ] && ! grep -qF '$WPPASS' /var/log/cecp-panel/panel.log"
check "panel.log is not world-readable" bash -c "[ \"\$(stat -c %a /var/log/cecp-panel/panel.log)\" = 640 ]"
check "slug collision refused (a-b.test vs a.b.test)" \
  bash -c "cecp-panel site add a-b.test && ! cecp-panel site add a.b.test && cecp-panel site remove a-b.test"

echo "=== SFTP / sshd guard ==="
check "sftp-password writes a valid drop-in" \
  bash -c "cecp-panel site sftp-password $D && grep -qx 'Match User $SU' $DROPIN && sshd -t"
SFTP_PASS_LOGGED="$(grep -c 'SFTP password:' /var/log/cecp-panel/panel.log || true)"
check "SFTP password not written to panel.log" test "$SFTP_PASS_LOGGED" = 0
check "sftp-info prints the site user" bash -c "cecp-panel site sftp-info $D | grep -q 'User: $SU'"
ROOTHASH="$(getent shadow root | cut -d: -f2)"
check "chpasswd injection rejected" bash -c "! cecp-panel site sftp-password $D \$'Abcdefghijkl1\nroot:pwned12345678'"
check "root password unchanged" test "$(getent shadow root | cut -d: -f2)" = "$ROOTHASH"
check "empty site user is refused" \
  bash -c "! (source /opt/cecp-panel/lib/common.sh; source /opt/cecp-panel/lib/site.sh; site_sftp_enable '')"
printf 'Match User \n    ChrootDirectory /home/\n' >"$DROPIN"
check "precondition: damaged 1.5.0 drop-in breaks sshd -t" bash -c '! sshd -t'
check "security ssh-repair restores a valid config" \
  bash -c "cecp-panel security ssh-repair && sshd -t && grep -qx 'Match User $SU' $DROPIN"
check "ssh-harden applies through sshd -t (00- drop-in wins)" \
  bash -c "cecp-panel security ssh-harden && sshd -t && sshd -T | grep -qx 'x11forwarding no'"

echo "=== WordPress system cron ==="
cron_line="$(grep -v '^#' "/etc/cron.d/cecp-wp-${SLUG}" | head -1)"
cron_cmd="${cron_line#*"$SU" }"
cron_log="$(grep -oE '>>[^ ]+' <<<"$cron_line" | tr -d '>')"
check "wp-cron command succeeds as the site user and logs" \
  bash -c "runuser -u $SU -- bash -c '$cron_cmd' && test -s '$cron_log'"

echo "=== optimize stack ==="
check "optimize stack completes" cecp-panel optimize stack
settle
check "sysctl file requests bbr" grep -qx 'net.ipv4.tcp_congestion_control = bbr' /etc/sysctl.d/99-cecp-bbr.conf
check "tcp_bbr loaded at boot" grep -qx tcp_bbr /etc/modules-load.d/cecp-bbr.conf
check "nginx perf conf installed" test -f /etc/nginx/conf.d/cecp-perf.conf
check "opcache ini installed" test -f /etc/php.d/99-cecp-opcache.ini
check "mariadb tune installed" grep -q 'table_open_cache = 2000' /etc/my.cnf.d/cecp-tune.cnf
check "redis secured and running" bash -c 'test -f /etc/cecp-panel/redis.env && systemctl is-active --quiet redis'
check "redis config not world-readable" bash -c '[ "$(stat -c %a /etc/redis/cecp.conf)" = 640 ]'
check "site still serves WordPress after tuning" serves_wp

echo "=== PHP-FPM pool isolation ==="
check "open_basedir uses per-site tmp (no shared /tmp)" \
  grep -qx "php_admin_value\[open_basedir\] = $DOCROOT:/home/$SU/tmp" "/etc/php-fpm.d/cecp-$SLUG.conf"
check "sessions in per-site tmp" grep -qx "php_admin_value\[session.save_path\] = /home/$SU/tmp" "/etc/php-fpm.d/cecp-$SLUG.conf"
check "per-site tmp is 700 and owned by the site user" test "$(stat -c '%a %U' "/home/$SU/tmp")" = "700 $SU"
check "pm.max_children sized (4..32)" bash -c "v=\$(sed -nE 's/^pm.max_children = ([0-9]+)$/\1/p' /etc/php-fpm.d/cecp-$SLUG.conf); [ \"\$v\" -ge 4 ] && [ \"\$v\" -le 32 ]"

echo "=== nginx hardening ==="
check "security headers on PHP responses" \
  bash -c "curl -sI http://$D/ | grep -qi '^x-frame-options: SAMEORIGIN' && curl -sI http://$D/ | grep -qi '^x-content-type-options: nosniff'"
check "security headers + cache headers on static files" \
  bash -c "h=\$(curl -sI http://$D/wp-includes/css/dashicons.min.css); grep -qi '^x-content-type-options: nosniff' <<<\"\$h\" && grep -qi 'max-age=2592000' <<<\"\$h\""
check "no HSTS on plain HTTP" bash -c "! curl -sI http://$D/ | grep -qi strict-transport-security"
runuser -u "$SU" -- mkdir -p "$DOCROOT/wp-content/uploads"
runuser -u "$SU" -- bash -c "printf '%s' '<?php echo \"EXECUTED\";' >$DOCROOT/wp-content/uploads/cecp-probe.php"
check "PHP in uploads is blocked (403, not executed)" \
  bash -c "[ \"\$(curl -s -o /tmp/probe.out -w '%{http_code}' http://$D/wp-content/uploads/cecp-probe.php)\" = 403 ] && ! grep -q EXECUTED /tmp/probe.out"
check "wp-config.php denied" test "$(status_of "http://$D/wp-config.php")" = 403
check "wp-includes/*.php denied" test "$(status_of "http://$D/wp-includes/version.php")" = 403
check "xmlrpc.php denied" test "$(status_of "http://$D/xmlrpc.php")" = 403
runuser -u "$SU" -- bash -c "echo SECRET=1 >$DOCROOT/.env"
check "dotfiles denied" test "$(status_of "http://$D/.env")" = 403

echo "=== FastCGI cache ==="
curl -s -o /dev/null "http://$D/"; curl -s -o /dev/null "http://$D/"
check "second request is a cache HIT" expect_cache / HIT
check "fbclid does not bust the cache" expect_cache '/?fbclid=IwAR0abc' HIT
check "utm_* does not bust the cache" expect_cache '/?utm_source=fb&utm_medium=cpc' HIT
check "search bypasses the cache" expect_cache '/?s=hello' BYPASS
check "ids= is not treated as search" bash -c "[ \"\$(curl -s -o /dev/null -D - 'http://$D/?ids=1' | tr -d '\r' | awk -F': ' 'tolower(\$1)==\"x-cecp-cache\"{print \$2}')\" != BYPASS ]"
curl -s -o /dev/null "http://$D2/"; curl -s -o /dev/null "http://$D2/"
check "purge DOMAIN clears only that site" \
  bash -c "cecp-panel optimize purge $D >/dev/null && [ \"\$(curl -s -o /dev/null -D - http://$D/ | tr -d '\r' | awk -F': ' 'tolower(\$1)==\"x-cecp-cache\"{print \$2}')\" = MISS ] && [ \"\$(curl -s -o /dev/null -D - http://$D2/ | tr -d '\r' | awk -F': ' 'tolower(\$1)==\"x-cecp-cache\"{print \$2}')\" = HIT ]"
curl -s -o /dev/null "http://$D/sample-page/"; curl -s -o /dev/null "http://$D/sample-page/"
check "precondition: sample page cached" expect_cache /sample-page/ HIT
check "purge-url removes exactly that URL" \
  bash -c "cecp-panel optimize purge-url http://$D/sample-page/ | grep -q '(2 entries)\|(1 entries)' && [ \"\$(curl -s -o /dev/null -D - http://$D/sample-page/ | tr -d '\r' | awk -F': ' 'tolower(\$1)==\"x-cecp-cache\"{print \$2}')\" = MISS ]"
check "optimize report shows hit ratio" bash -c "cecp-panel optimize report $D | grep -q HIT"

echo "=== Real client IP ==="
check "Cloudflare real-IP config installed" grep -q 'real_ip_header CF-Connecting-IP' /etc/nginx/conf.d/cecp-cloudflare-realip.conf
curl -s -o /dev/null -H 'CF-Connecting-IP: 198.51.100.7' "http://$D/?realip-probe"
check "non-Cloudflare clients cannot spoof CF-Connecting-IP" \
  bash -c "grep 'realip-probe' /var/log/nginx/$D-access.log | tail -1 | grep -q '^127.0.0.1 '"

echo "=== HTTPS (panel template) ==="
mkdir -p "/etc/letsencrypt/live/$D" /etc/letsencrypt/renewal
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$D" \
  -keyout "/etc/letsencrypt/live/$D/privkey.pem" -out "/etc/letsencrypt/live/$D/fullchain.pem" >/dev/null 2>&1
cat >"/etc/letsencrypt/renewal/$D.conf" <<EOF
version = 3.1.0
archive_dir = /etc/letsencrypt/archive/$D
fullchain = /etc/letsencrypt/live/$D/fullchain.pem

# Options used in the renewal process
[renewalparams]
account = abc
authenticator = nginx
installer = nginx
server = https://acme-v02.api.letsencrypt.org/directory
EOF
check "rebuild-vhost renders HTTPS when a cert exists" cecp-panel site rebuild-vhost "$D"
settle
check "HTTPS served over HTTP/2" \
  test "$(curl -sk --http2 -o /dev/null -w '%{http_version}' --resolve "$D:443:127.0.0.1" "https://$D/")" = 2
check "HSTS on HTTPS (no includeSubDomains by default)" \
  bash -c "curl -skI --resolve $D:443:127.0.0.1 https://$D/ | grep -i strict-transport-security | grep -q 'max-age=15552000' && ! curl -skI --resolve $D:443:127.0.0.1 https://$D/ | grep -qi includesubdomains"
check "HTTP redirects to HTTPS" bash -c "curl -sI http://$D/ | tr -d '\r' | grep -qi '^location: https://$D/'"
check "ACME challenge path still served over HTTP" \
  bash -c "mkdir -p $DOCROOT/.well-known/acme-challenge && echo tok >$DOCROOT/.well-known/acme-challenge/t1 && [ \"\$(curl -s http://$D/.well-known/acme-challenge/t1)\" = tok ]"
check "renewal switched to webroot, no nginx installer" \
  bash -c "grep -qx 'authenticator = webroot' /etc/letsencrypt/renewal/$D.conf && ! grep -q '^installer' /etc/letsencrypt/renewal/$D.conf && grep -qx '$D = $DOCROOT' /etc/letsencrypt/renewal/$D.conf"
check "renewal deploy hook reloads nginx" test -x /etc/letsencrypt/renewal-hooks/deploy/cecp-reload-nginx.sh
check "ssl hsts subdomains" \
  bash -c "cecp-panel ssl hsts $D subdomains && sleep 1.5 && curl -skI --resolve $D:443:127.0.0.1 https://$D/ | grep -qi includesubdomains"
check "ssl hsts off" \
  bash -c "cecp-panel ssl hsts $D off && sleep 1.5 && ! curl -skI --resolve $D:443:127.0.0.1 https://$D/ | grep -qi strict-transport-security"
rm -rf "/etc/letsencrypt/live/$D" "/etc/letsencrypt/renewal/$D.conf"
check "back to HTTP vhost without cert" cecp-panel site rebuild-vhost "$D"
settle
check "site serves WordPress over HTTP again" serves_wp

echo "=== Secrets stay out of argv ==="
TOKEN="cecpTestToken_0123456789abcdefXYZ"
printf '%s\n' "$TOKEN" >/tmp/token.pat
printf 'CF_API_TOKEN=%s\nCF_DEFAULT_ZONE=%s\n' "$TOKEN" "$D" | install -m 600 /dev/stdin /etc/cecp-panel/credentials.env
python3 "$HERE/mock_cf.py" 8787 /tmp/mockcf.log & MOCK=$!
sleep 1
(CF_API_BASE=http://127.0.0.1:8787 cecp-panel dns add www 192.0.2.10 >/tmp/dns.out 2>&1) &
CMD=$!
leak=0
while kill -0 "$CMD" 2>/dev/null; do
  grep -qaF -f /tmp/token.pat /proc/[0-9]*/cmdline 2>/dev/null && leak=1
  sleep 0.1
done
wait "$CMD"; rc=$?
kill "$MOCK" 2>/dev/null
check "dns add via (mock) Cloudflare API succeeds" test "$rc" = 0
check "API received the bearer token" grep -qF "auth=Bearer $TOKEN" /tmp/mockcf.log
check "token never visible in any process argv" test "$leak" = 0
chmod 666 /etc/cecp-panel/credentials.env
check "world-writable credentials file is refused" bash -c "cecp-panel dns list 2>&1 | grep -q 'Refusing to source'"
rm -f /etc/cecp-panel/credentials.env

echo "=== Redis per-site ACL ==="
check "redis-wp $D" cecp-panel optimize redis-wp "$D"
check "redis-wp $D2" cecp-panel optimize redis-wp "$D2"
UA="cecp_${SLUG}"
PA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("redis_pass",""))' "/var/lib/cecp-panel/sites/$D.json")"
check "$D object cache connected via its ACL user" \
  bash -c "runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT redis status | grep -qi 'status: connected'"
check "site A can write its own keys" bash -c "[ \"\$(redis-cli --no-auth-warning --user $UA --pass $PA SET ${UA}_probe 1)\" = OK ]"
check "site A cannot read site B keys" bash -c "redis-cli --no-auth-warning --user $UA --pass $PA GET cecp_second_test_probe 2>&1 | grep -q NOPERM"
check "site A cannot FLUSHALL" bash -c "redis-cli --no-auth-warning --user $UA --pass $PA FLUSHALL 2>&1 | grep -q NOPERM"
OLDPASS="$(sed -nE 's/^REDIS_PASSWORD=(.*)$/\1/p' /etc/cecp-panel/redis.env)"
check "shared Redis password not in wp-config" bash -c "! grep -qF '$OLDPASS' $DOCROOT/wp-config.php"
check "redis-acl --all rotates the shared password" \
  bash -c "cecp-panel optimize redis-acl --all && [ \"\$(sed -nE 's/^REDIS_PASSWORD=(.*)$/\1/p' /etc/cecp-panel/redis.env)\" != '$OLDPASS' ]"
check "old shared password no longer works" bash -c "REDISCLI_AUTH='$OLDPASS' redis-cli ping 2>&1 | grep -qv PONG"
check "$D still connected after rotation" \
  bash -c "runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT redis status | grep -qi 'status: connected'"
check "ACL users survive a Redis restart" \
  bash -c "systemctl restart redis && sleep 1 && [ \"\$(redis-cli --no-auth-warning --user $UA --pass $PA PING)\" = PONG ]"

echo "=== fail2ban ==="
check "fail2ban-full applies" cecp-panel security fail2ban-full
check "Cloudflare ranges in ignoreip" grep -q '173.245.48.0/20' /etc/fail2ban/jail.d/cecp-00-defaults.conf
if systemctl is-active --quiet fail2ban; then
  fail2ban-client set cecp-wordpress banip 203.0.113.9 >/dev/null 2>&1
  for _ in $(seq 10); do grep -qs 'deny 203.0.113.9;' /etc/nginx/conf.d/cecp-f2b-deny.conf && break; sleep 1; done
  check "ban writes an nginx deny (works behind Cloudflare)" grep -qx 'deny 203.0.113.9;' /etc/nginx/conf.d/cecp-f2b-deny.conf
  fail2ban-client set cecp-wordpress unbanip 203.0.113.9 >/dev/null 2>&1
  for _ in $(seq 10); do grep -qs 'deny 203.0.113.9;' /etc/nginx/conf.d/cecp-f2b-deny.conf || break; sleep 1; done
  check "unban removes the nginx deny" bash -c "! grep -qs 'deny 203.0.113.9;' /etc/nginx/conf.d/cecp-f2b-deny.conf"
  check "nginx config valid after ban/unban" nginx -t
else
  bad "fail2ban is not running in the container"
fi

echo "=== Production profile + self-check ==="
echo "2026-01-01T00:00:00Z WordPress admin user: admin | pass: Legacy1234Secret (save now)" >>/var/log/cecp-panel/panel.log
chmod 644 /var/log/cecp-panel/panel.log
check "apply-production" cecp-panel security apply-production
settle
check "old plaintext password redacted" bash -c "! grep -q Legacy1234Secret /var/log/cecp-panel/panel.log"
check "security check has no FAIL" cecp-panel security check
check "site still serves WordPress after apply-production" serves_wp

echo "=== update panel (checksummed file:// mirror) ==="
mkdir -p /tmp/mirror/dist
build_bundle() {
  tar -C /root --exclude=cecp-panel/tests -czf "/tmp/mirror/dist/cecp-panel-${VERSION}.tar.gz" cecp-panel
  (cd /tmp/mirror/dist && sha256sum "cecp-panel-${VERSION}.tar.gz" >SHA256SUMS)
}
build_bundle
check "update panel with valid checksum" \
  bash -c "cecp-panel update mirror file:///tmp/mirror && cecp-panel update panel && grep -qF '\"version\": \"$VERSION\"' /etc/cecp-panel/panel.json"
printf 'x' >>"/tmp/mirror/dist/cecp-panel-${VERSION}.tar.gz"
check "tampered bundle is refused" bash -c "cecp-panel update panel 2>&1 | grep -q 'Checksum mismatch'"
check "panel still works after refused update" bash -c "cecp-panel help | head -1 | grep -qF '$VERSION'"
build_bundle
GOOD="$(cut -d' ' -f1 /tmp/mirror/dist/SHA256SUMS)"
rm -f /tmp/mirror/dist/SHA256SUMS
check "missing SHA256SUMS is refused" bash -c "cecp-panel update panel 2>&1 | grep -q 'refusing an unverified update'"
check "pinned --sha256 works" cecp-panel update panel "$VERSION" --sha256 "$GOOD"

echo "=== site remove ==="
check "site remove $D2" cecp-panel site remove "$D2"
check "site files removed with the site" test ! -e "/home/$SU2"
check "site remove $D" cecp-panel site remove "$D"
check "site artifacts are gone" bash -c "
  ! test -e /var/lib/cecp-panel/sites/$D.json &&
  ! test -e /etc/nginx/conf.d/cecp-$SLUG.conf &&
  ! test -e /etc/php-fpm.d/cecp-$SLUG.conf &&
  ! test -e /etc/cron.d/cecp-wp-$SLUG &&
  ! test -e $DROPIN &&
  ! id $SU && ! id $SU2 &&
  ! mysql -e 'USE db_$SLUG'"
check "Redis ACL users removed" bash -c "! grep -q $UA /etc/redis/cecp-acl.conf"
check "sshd config valid after remove" sshd -t
check "nginx config valid after remove" nginx -t

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
exit "$FAIL"
