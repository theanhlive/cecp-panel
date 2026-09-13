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
for h in "$D" "$D2" a-b.test a.b.test "shop.$D" "staging.$D"; do
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
# An entry cached minutes ago (before optimize stack) may be expired: background_update would
# then answer STALE/UPDATING. Start from an empty cache.
cecp-panel optimize purge "$D" >/dev/null
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

echo "=== Events + signed webhook (n8n) ==="
WH=/tmp/webhook.log
rm -f "$WH"
python3 "$HERE/webhook_rx.py" 8799 "$WH" & WHPID=$!
sleep 1
wh_count() { python3 "$HERE/webhook_rx.py" count "$WH" "$1"; }
wait_event() {  # wait_event EVENT [MIN_COUNT] — deliveries are synchronous but give the receiver a moment
  for _ in 1 2 3 4 5; do
    [ "$(wh_count "$1")" -ge "${2:-1}" ] && return 0
    sleep 1
  done
  return 1
}
check "notify webhook URL configures URL + secret" cecp-panel notify webhook http://127.0.0.1:8799/hook
WHSECRET="$(sed -nE 's/^WEBHOOK_SECRET=(.*)$/\1/p' /etc/cecp-panel/notify.env)"
check "webhook received a correctly signed event" \
  bash -c "sleep 1; python3 $HERE/webhook_rx.py check $WH '$WHSECRET' webhook_configured"
check "wrong secret does not validate" bash -c "! python3 $HERE/webhook_rx.py check $WH wrongsecret webhook_configured"
check "events.log records the event (640)" \
  bash -c "grep -q '\"event\":\"webhook_configured\"' /var/log/cecp-panel/events.log && [ \"\$(stat -c %a /var/log/cecp-panel/events.log)\" = 640 ]"
check "webhook secret not written to panel.log" bash -c "! grep -qF '$WHSECRET' /var/log/cecp-panel/panel.log"

echo "=== wp-login rate limit + protect-admin ==="
settle
check "protect-admin on (basic auth)" cecp-panel site protect-admin "$D" on
settle
APASS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("admin_protect_pass",""))' "/var/lib/cecp-panel/sites/$D.json")"
check "wp-login.php asks for credentials (401)" test "$(status_of "http://$D/wp-login.php")" = 401
check "wp-admin asks for credentials (401)" test "$(status_of "http://$D/wp-admin/")" = 401
# wp_harden sets FORCE_SSL_ADMIN, so WordPress answers wp-login.php over http with 302 → https.
reaches_wp_login() { [[ "$(status_of "$@" "http://$D/wp-login.php")" =~ ^(200|302)$ ]]; }
check "correct credentials pass through to WordPress" reaches_wp_login -u "cecp:$APASS"
check "wp-admin with credentials reaches WordPress (not 401)" \
  bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -u 'cecp:$APASS' http://$D/wp-admin/)\" != 401 ]"
check "admin-ajax.php stays public" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://$D/wp-admin/admin-ajax.php)\" != 401 ]"
check "front end unaffected" serves_wp
check "basic-auth password not in panel.log" bash -c "! grep -qF '$APASS' /var/log/cecp-panel/panel.log"
check "protect-admin IP allowlist blocks other IPs (403)" \
  bash -c "cecp-panel site protect-admin $D on --ip 203.0.113.0/24 --no-auth && sleep 1.5 && [ \"\$(curl -s -o /dev/null -w '%{http_code}' http://$D/wp-login.php)\" = 403 ]"
check "protect-admin IP allowlist lets listed IPs in" cecp-panel site protect-admin "$D" on --ip 127.0.0.1/32 --no-auth
settle
check "listed IP reaches wp-login.php" reaches_wp_login
check "protect-admin rejects invalid CIDRs" bash -c "! cecp-panel site protect-admin $D on --ip '1.2.3.4/99'"
check "protect-admin off" cecp-panel site protect-admin "$D" off
settle
check "wp-login.php open again" reaches_wp_login
# Last in this section: the flood uses up the login bucket for a while.
check "wp-login.php is rate-limited (429 after the burst)" \
  bash -c "for i in \$(seq 30); do curl -s -o /dev/null -w '%{http_code}\n' http://$D/wp-login.php; done | grep -q 429"

echo "=== Backup: local repository, failure reporting, verify ==="
wp_d() { runuser -u "$SU" -- php /usr/local/bin/wp --path="$DOCROOT" "$@"; }
printf 'RESTIC_REPOSITORY=/var/backups/cecp-restic\n' | install -m 600 /dev/stdin /etc/cecp-panel/backup.env
check "backup setup with a local repository" cecp-panel backup setup
check "backup run succeeds" cecp-panel backup run "$D"
bstate() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], {}).get(sys.argv[3], ""))' /var/lib/cecp-panel/backup-state.json "$D" "$1"; }
check "backup state records last_ok" test -n "$(bstate last_ok)"
check "snapshot includes site config (vhost, pool)" \
  bash -c "RESTIC_PASSWORD_FILE=/etc/cecp-panel/restic-password restic -r /var/backups/cecp-restic ls latest --tag $D | grep -q config.tar.gz"
cp -a /etc/cecp-panel/restic-password /tmp/restic-password.good
echo wrongpassword >/etc/cecp-panel/restic-password
check "a failing backup exits non-zero" bash -c "! cecp-panel backup run $D"
check "failure is recorded in backup state" test -n "$(bstate last_error)"
check "backup_failed event delivered" wait_event backup_failed
cp -a /tmp/restic-password.good /etc/cecp-panel/restic-password
check "backup works again and reports recovery" bash -c "cecp-panel backup run $D && sleep 1 && [ \"\$(python3 $HERE/webhook_rx.py count $WH backup_recovered)\" -ge 1 ]"
check "backup verify restores and test-imports the latest dump" bash -c "cecp-panel backup verify $D | grep -q 'Verify OK'"
check "backup status shows per-site state" bash -c "cecp-panel backup status | grep -q 'last_ok='"

echo "=== Live restore with automatic rollback ==="
ORIG_NAME="$(wp_d option get blogname)"
wp_d option update blogname "Changed after backup" >/dev/null
check "restore --live --dry-run changes nothing" \
  bash -c "cecp-panel backup restore $D latest --live --dry-run | grep -q 'Live restore plan' && [ \"\$(runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT option get blogname)\" = 'Changed after backup' ]"
check "restore --live refuses without --yes when not interactive" bash -c "! cecp-panel backup restore $D latest --live </dev/null"
check "restore --live --yes" cecp-panel backup restore "$D" latest --live --yes
check "database content is back (blogname)" test "$(wp_d option get blogname)" = "$ORIG_NAME"
check "site serves WordPress after restore" serves_wp
check "restore_done event delivered" wait_event restore_done
cp -a "$DOCROOT/index.php" /tmp/index.php.good
printf '<?php http_response_code(500); exit;\n' >"$DOCROOT/index.php"
cecp-panel backup run "$D" >/dev/null 2>&1
BROKEN_SNAP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["last_snapshot"])' /var/lib/cecp-panel/backup-state.json "$D")"
install -m 644 -o "$SU" -g "$SU" /tmp/index.php.good "$DOCROOT/index.php"
# OPcache revalidates every 60 s: reload so file edits take effect immediately.
php_live() { systemctl reload php-fpm; settle; }
uncached_ok() { [[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Cookie: wordpress_logged_in_x=1' "http://$D/")" =~ ^(200|301|302)$ ]]; }
php_live
check "precondition: site healthy (uncached) before restoring a broken snapshot" uncached_ok
check "restoring a broken snapshot fails and rolls back" bash -c "! cecp-panel backup restore $D $BROKEN_SNAP --live --yes"
check "site answers (uncached) after rollback" uncached_ok
check "site still serves WordPress after rollback" serves_wp
check "rolled-back files are the pre-restore ones" cmp -s /tmp/index.php.good "$DOCROOT/index.php"
check "restore_rolled_back event delivered" wait_event restore_rolled_back

echo "=== Monitoring + self-healing ==="
check "monitor enable" cecp-panel monitor enable
check "restart-on-failure drop-in installed" test -f /etc/systemd/system/nginx.service.d/cecp-restart.conf
check "first run raises no alerts on a healthy host" test "$(wh_count site_down)" = 0
check "monitor status lists checks" bash -c "cecp-panel monitor status | grep -q 'site:$D'"
systemctl stop php-fpm
check "stopped php-fpm is restarted by the monitor" bash -c "cecp-panel monitor run && systemctl is-active --quiet php-fpm"
check "service_restarted event delivered" wait_event service_restarted
printf '<?php http_response_code(500); exit;\n' >"$DOCROOT/index.php"
php_live
cecp-panel monitor run >/dev/null 2>&1
check "site_down alert raised" wait_event site_down 1
cecp-panel monitor run >/dev/null 2>&1
check "no repeated alert while still down" test "$(wh_count site_down)" = 1
install -m 644 -o "$SU" -g "$SU" /tmp/index.php.good "$DOCROOT/index.php"
php_live
cecp-panel monitor run >/dev/null 2>&1
check "site_recovered alert raised" wait_event site_recovered
chown root:root "/run/php-fpm/${SLUG}.sock"
check "monitor repairs PHP-FPM socket ownership" \
  bash -c "cecp-panel monitor run && [ \"\$(stat -c %U /run/php-fpm/${SLUG}.sock)\" = nginx ]"
check "socket_fixed event delivered" wait_event socket_fixed
cecp-panel backup enable-cron >/dev/null
touch -d '3 days ago' /etc/cron.d/cecp-panel-backup
python3 - /var/lib/cecp-panel/backup-state.json "$D" <<'PY'
import json, sys, time
p, d = sys.argv[1], sys.argv[2]
data = json.load(open(p))
data[d]["last_ok"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3 * 86400))
json.dump(data, open(p, "w"))
PY
cecp-panel monitor run >/dev/null 2>&1
check "stale backups are reported" wait_event backup_stale
check "backup cron also schedules weekly verify" grep -q 'backup verify --all' /etc/cron.d/cecp-panel-backup
kill "$WHPID" 2>/dev/null

echo "=== Log rotation ==="
check "logrotate rule installed" bash -c "cecp-panel system tune >/dev/null 2>&1; test -f /etc/logrotate.d/cecp-panel"
check "logrotate rule is valid" logrotate -d /etc/logrotate.d/cecp-panel
check "per-site nginx logs are covered by a rotate rule" bash -c "grep -rqE '/var/log/nginx/\\*\\.?log' /etc/logrotate.d/"

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

echo "=== Image negotiation (WebP / AVIF sidecars) ==="
UP="$DOCROOT/wp-content/uploads"
for f in neg.jpg:ORIG-JPEG neg.webp:SIDECAR-WEBP neg.avif:SIDECAR-AVIF plain.png:ORIG-PNG; do
  runuser -u "$SU" -- bash -c "printf '%s' '${f#*:}' >$UP/${f%%:*}"
done
img_is() {  # img_is PATH ACCEPT CONTENT_TYPE BODY_MARK
  local h
  h="$(curl -s -D - -o /tmp/img.body -H "Accept: $2" "http://$D$1" | tr -d '\r')"
  echo "$h"; cat /tmp/img.body; echo
  grep -qi "^content-type: $3" <<<"$h" && grep -qi '^vary: .*accept' <<<"$h" && grep -qx "$4" /tmp/img.body
}
check "WebP sidecar served to browsers that accept WebP" img_is /wp-content/uploads/neg.jpg 'image/webp,*/*' image/webp SIDECAR-WEBP
check "original served to browsers without WebP" img_is /wp-content/uploads/neg.jpg 'image/png,*/*' image/jpeg ORIG-JPEG
check "AVIF not served while AVIF is off" img_is /wp-content/uploads/neg.jpg 'image/avif,image/webp,*/*' image/webp SIDECAR-WEBP
check "image without a sidecar falls back to itself" img_is /wp-content/uploads/plain.png 'image/avif,image/webp,*/*' image/png ORIG-PNG
check "missing image is 404" test "$(status_of -H 'Accept: image/webp' "http://$D/wp-content/uploads/nope.jpg")" = 404
check "media enable rejects a non-numeric quality" bash -c "! cecp-panel media enable $D --quality abc"
check "media enable --avif" cecp-panel media enable "$D" --avif --no-cron
settle
check "AVIF sidecar served to browsers that accept AVIF" img_is /wp-content/uploads/neg.jpg 'image/avif,image/webp,*/*' image/avif SIDECAR-AVIF
check "WebP still served to WebP-only browsers" img_is /wp-content/uploads/neg.jpg 'image/webp,*/*' image/webp SIDECAR-WEBP

echo "=== Page cache: TTL + auto-purge on content change ==="
check "cache ttl 1h" bash -c "cecp-panel cache ttl $D 1h && grep -q 'fastcgi_cache_valid 200 301 302 1h;' /etc/nginx/conf.d/cecp-$SLUG.conf"
check "cache ttl rejects bad values" bash -c "! cecp-panel cache ttl $D 5x && ! cecp-panel cache ttl $D 2d && ! cecp-panel cache ttl $D '1h;'"
Q="/home/$SU/tmp/cecp-purge.queue"
check "mu-plugins are valid PHP" bash -c "php -l /opt/cecp-panel/templates/mu-plugins/cecp-cache-purge.php && php -l /opt/cecp-panel/templates/mu-plugins/cecp-media-optimize.php"
check "cache auto-purge on" cecp-panel cache auto-purge "$D" on
check "mu-plugin installed root-owned (site cannot change it)" \
  bash -c "[ \"\$(stat -c '%U %a' $DOCROOT/wp-content/mu-plugins/cecp-cache-purge.php)\" = 'root 644' ] && grep -qF '$Q' $DOCROOT/wp-content/mu-plugins/cecp-cache-purge.json"
check "queue owned by the site user (600)" test "$(stat -c '%U %a' "$Q")" = "$SU 600"
check "purge watcher active" systemctl is-active --quiet "cecp-purge@${SLUG}.path"
check "cron fallback installed" grep -q 'cache purge-queue --all' /etc/cron.d/cecp-cache-purge
check "cache status" bash -c "cecp-panel cache status $D | grep -q 'auto-purge:  True'"
PID="$(wp_d post create --post_title='Alpha title' --post_status=publish --porcelain)"
PURL="$(wp_d post list --post__in="$PID" --field=url --post_type=post)"
PPATH="/${PURL#http*://*/}"
UNI="$(wp_d post create --post_title='Unicode' --post_name='日本' --post_status=publish --porcelain)"
UPATH="/%E6%97%A5%E6%9C%AC/"  # browsers send uppercase %xx; WordPress permalinks are lowercase
warm() { curl -s -o /dev/null "http://${2:-$D}$1"; curl -s -o /dev/null "http://${2:-$D}$1"; }
cache_of() { curl -s -o /dev/null -D - "http://${2:-$D}$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cecp-cache"{print $2}'; }
wait_miss() {  # wait_miss PATH [HOST] — the path unit purges asynchronously
  for _ in $(seq 15); do
    [ "$(cache_of "$1" "${2:-$D}")" != HIT ] && return 0
    sleep 1
  done
  return 1
}
warm "$PPATH"; warm /; warm "$UPATH"
check "precondition: post cached" expect_cache "$PPATH" HIT
check "precondition: unicode post cached (browser spelling)" expect_cache "$UPATH" HIT
wp_d post update "$PID" --post_title='Beta title' >/dev/null
check "updating a post purges its page" wait_miss "$PPATH"
check "the page shows the new title" bash -c "curl -s http://$D$PPATH | grep -q 'Beta title'"
check "the home page is purged too" test "$(cache_of /)" = MISS
wp_d post update "$UNI" --post_title='Unicode 2' >/dev/null
check "percent-encoded (unicode) slug purged for the browser's spelling" wait_miss "$UPATH"
check "purge logged" bash -c "grep -q 'cache: purged .* URL(s) of $D' /var/log/cecp-panel/panel.log"
warm /; warm / "$D2"
runuser -u "$SU" -- bash -c "printf '%s\n' 'http://$D2/' 'https://evil.test/x' 'file:///etc/passwd' 'http://$D/ spaced' >>$Q"
sleep 3
check "queue lines for other hosts / schemes are ignored (other site still cached)" test "$(cache_of / "$D2")" = HIT
check "malformed lines purge nothing" test "$(cache_of /)" = HIT
check "queue was consumed" test ! -s "$Q"
runuser -u "$SU" -- bash -c "echo '*' >>$Q"
check "'*' purges the whole site" wait_miss /
check "... and only this site" test "$(cache_of / "$D2")" = HIT
cp -a /etc/shadow /tmp/shadow.before
runuser -u "$SU" -- bash -c "rm -f $Q && ln -s /etc/shadow $Q"
check "symlinked queue is refused and its target untouched" \
  bash -c "cecp-panel cache purge-queue $SLUG && cmp -s /etc/shadow /tmp/shadow.before"
check "auto-purge on replaces a planted symlink with a real queue" \
  bash -c "cecp-panel cache auto-purge $D on && [ ! -L $Q ] && [ \"\$(stat -c '%U %a %F' $Q)\" = '$SU 600 regular empty file' ]"
check "unknown slug rejected" bash -c "! cecp-panel cache purge-queue 'no_such_site'"
check "nginx config valid" nginx -t

echo "=== Cloudflare HTML edge cache ==="
python3 "$HERE/mock_cf.py" 8788 /tmp/mockcf2.log 0 & MOCK=$!
printf 'CF_API_TOKEN=%s\nCF_DEFAULT_ZONE=%s\nCF_API_BASE=http://127.0.0.1:8788\n' "$TOKEN" "$D" \
  | install -m 600 /dev/stdin /etc/cecp-panel/credentials.env
sleep 1
RS=http://127.0.0.1:8788/zones/zone123/rulesets/phases/http_request_cache_settings/entrypoint
curl -s -X PUT -d '{"rules":[{"description":"manual: keep me","expression":"(http.host eq \"other.test\")","action":"set_cache_settings","action_parameters":{"cache":false}}]}' "$RS" >/dev/null
rules_check() {  # rules_check PYTHON_EXPR  (r = our rule or None, rules = all)
  curl -s "$RS" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rules = (d.get("result") or {}).get("rules") or []
r = next((x for x in rules if x.get("description") == "cecp-panel: " + sys.argv[1]), None)
print(json.dumps(rules, indent=1))
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$D" "$1"
}
check "cf edge-cache on --ttl 2h" cecp-panel cf edge-cache "$D" on --ttl 2h
check "edge rule: host, TTL, admin/cookie bypass" \
  rules_check "r and r['action_parameters']['edge_ttl']['default'] == 7200 and 'http.host eq \"$D\"' in r['expression'] and 'wordpress_logged_in' in r['expression'] and '/wp-admin' in r['expression'] and 'woocommerce_items_in_cart' in r['expression']"
check "the zone's other cache rules are kept" rules_check "any(x['description'] == 'manual: keep me' and x['id'] == 'rule1' for x in rules)"
check "re-running keeps a single rule for the site" \
  bash -c "cecp-panel cf edge-cache $D on --ttl 1h >/dev/null && curl -s $RS | grep -o 'cecp-panel: $D' | wc -l | grep -qx 1"
check "cf edge-cache status" bash -c "cecp-panel cf edge-cache $D status | grep -q 'on, edge TTL 3600s'"
touch /tmp/mockcf.fail-rulesets
check "unreadable ruleset: refuse to overwrite the zone's rules" bash -c "! cecp-panel cf edge-cache $D off"
rm -f /tmp/mockcf.fail-rulesets
check "... rules untouched" rules_check "r is not None and len(rules) == 2"
: >/tmp/mockcf2.log
wp_d post update "$PID" --post_title='Gamma title' >/dev/null
check "content change purges the post URL at the edge" \
  bash -c "for i in \$(seq 15); do grep -q 'purge_cache.*\"files\".*$PPATH' /tmp/mockcf2.log && exit 0; sleep 1; done; cat /tmp/mockcf2.log; exit 1"
runuser -u "$SU" -- bash -c "echo '*' >>$Q"
check "'*' purges the site's host at the edge (not the zone)" \
  bash -c "for i in \$(seq 15); do grep -q 'purge_cache.*\"hosts\": \[\"$D\"\]' /tmp/mockcf2.log && exit 0; sleep 1; done; cat /tmp/mockcf2.log; exit 1"
check "no zone-wide purge_everything" bash -c "! grep -q purge_everything /tmp/mockcf2.log"
check "cf edge-cache off" cecp-panel cf edge-cache "$D" off
check "... removes only our rule" rules_check "[x['description'] for x in rules] == ['manual: keep me']"
check "edge purge stops once edge cache is off" \
  bash -c ": >/tmp/mockcf2.log; echo '*' | runuser -u $SU -- tee -a $Q >/dev/null; sleep 3; ! grep -q purge_cache /tmp/mockcf2.log"

echo "=== SSL: DNS-01 via Cloudflare, wildcard ==="
chmod +x "$HERE/fake_certbot.sh"
export CECP_CERTBOT="$HERE/fake_certbot.sh"
rm -f /tmp/certbot.args
check "ssl issue --wildcard" cecp-panel ssl issue "$D" --wildcard
check "certbot used DNS-01 for DOMAIN and *.DOMAIN" \
  bash -c "grep -q -- '--dns-cloudflare ' /tmp/certbot.args && grep -qF -- '-d $D -d *.$D' /tmp/certbot.args && grep -qF -- '--cert-name $D' /tmp/certbot.args"
check "API token not on the certbot command line" bash -c "! grep -qF '$TOKEN' /tmp/certbot.args"
check "Cloudflare credentials file is 600 root" test "$(stat -c '%a %U' /etc/letsencrypt/cecp-cloudflare.ini)" = "600 root"
check "DNS-01 renewal kept (not converted to webroot), installer dropped" \
  bash -c "grep -qx 'authenticator = dns-cloudflare' /etc/letsencrypt/renewal/$D.conf && ! grep -q '^installer' /etc/letsencrypt/renewal/$D.conf && ! grep -q webroot /etc/letsencrypt/renewal/$D.conf"
settle
check "site served over HTTPS with the new certificate" \
  bash -c "[[ \"\$(curl -sk -o /dev/null -w '%{http_code}' --resolve $D:443:127.0.0.1 https://$D/)\" =~ ^(200|301|302)$ ]] && openssl s_client -connect 127.0.0.1:443 -servername $D </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | grep -qF 'DNS:$D'"
meta_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "/var/lib/cecp-panel/sites/$D.json" "$1"; }
check "site meta records the wildcard" test "$(meta_get ssl_wildcard) $(meta_get ssl_method)" = "True dns"
check "new subdomain site uses the parent wildcard" \
  bash -c "cecp-panel site add shop.$D && grep -qE 'ssl_certificate +/etc/letsencrypt/live/$D/fullchain.pem;' /etc/nginx/conf.d/cecp-shop_${SLUG}.conf"
settle
check "subdomain served over HTTPS with *.$D" \
  bash -c "openssl s_client -connect 127.0.0.1:443 -servername shop.$D </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | grep -qF '*.$D'"
check "removing the wildcard falls back to HTTP for both sites, nginx valid" \
  bash -c "cecp-panel ssl remove $D && nginx -t && ! grep -q 'listen 443' /etc/nginx/conf.d/cecp-shop_${SLUG}.conf && ! grep -q 'listen 443' /etc/nginx/conf.d/cecp-$SLUG.conf"
settle
check "site serves WordPress over HTTP after certificate removal" serves_wp
check "site remove shop.$D" cecp-panel site remove "shop.$D"
unset CECP_CERTBOT
kill "$MOCK" 2>/dev/null
rm -f /etc/cecp-panel/credentials.env

meta_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "/var/lib/cecp-panel/sites/$1.json" "$2"; }
POOL="/etc/php-fpm.d/cecp-$SLUG.conf"
VHOST="/etc/nginx/conf.d/cecp-$SLUG.conf"
runuser -u "$SU" -- bash -c "printf '%s' '<?php echo ini_get(\"memory_limit\"), \"|\", ini_get(\"upload_max_filesize\"), \"|\", ini_get(\"max_input_vars\");' >$DOCROOT/cecp-ini.php"
php_ini() { curl -s "http://$D/cecp-ini.php?r=$RANDOM"; }

echo "=== Per-site PHP settings ==="
check "php config shows defaults" bash -c "cecp-panel php config $D | grep -q 'memory_limit *256M *(default)'"
check "php config sets values" cecp-panel php config "$D" memory_limit=512M upload_max_filesize=128M max_execution_time=300 max_input_vars=5000
check "pool has the values; post_max_size raised to the upload size" \
  bash -c "grep -q 'memory_limit\] = 512M' $POOL && grep -q 'upload_max_filesize\] = 128M' $POOL && grep -q 'post_max_size\] = 128M' $POOL && grep -q 'max_input_vars\] = 5000' $POOL"
check "nginx body size and FastCGI timeout follow PHP" \
  bash -c "grep -q 'client_max_body_size 129m;' $VHOST && grep -q 'fastcgi_read_timeout 330s;' $VHOST"
settle
check "PHP sees the new values" test "$(php_ini)" = "512M|128M|5000"
head -c 5000000 /dev/zero >/tmp/5m.bin
check "5 MB upload is not refused by nginx (was 413 with the 1m default)" \
  bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -F f=@/tmp/5m.bin http://$D/?upload-probe)\" != 413 ]"
check "invalid PHP settings rejected" bash -c "! cecp-panel php config $D memory_limit=99T && ! cecp-panel php config $D foo=1 && ! cecp-panel php config $D max_execution_time=5 && ! cecp-panel php config $D 'memory_limit=512M;id'"
check "php config --reset" bash -c "cecp-panel php config $D --reset memory_limit >/dev/null && grep -q 'memory_limit\] = 256M' $POOL"

echo "=== Per-site resource limits (own PHP-FPM) ==="
check "site limits --cpu 50 --mem 768M --tasks 128" cecp-panel site limits "$D" --cpu 50 --mem 768M --tasks 128
UNIT="cecp-php-fpm@$SLUG.service"
check "limited PHP-FPM unit active" systemctl is-active --quiet "$UNIT"
check "systemd carries the limits" \
  bash -c "p=\$(systemctl show -p CPUQuotaPerSecUSec -p MemoryMax -p TasksMax $UNIT); echo \"\$p\"; grep -qx 'CPUQuotaPerSecUSec=500ms' <<<\"\$p\" && grep -qx 'MemoryMax=805306368' <<<\"\$p\" && grep -qx 'TasksMax=128' <<<\"\$p\""
check "vhost uses the unit's socket; pool left the shared FPM" \
  bash -c "grep -q 'unix:/run/cecp-php-fpm/$SLUG/php.sock' $VHOST && [ ! -e $POOL ]"
check "site serves WordPress through its own PHP-FPM" serves_wp
check "the site's PHP workers run in the limited cgroup" \
  bash -c "php_pid=\$(pgrep -u $SU -f 'pool $SLUG' | head -1); [ -n \"\$php_pid\" ] && grep -q 'cecp-php-fpm@$SLUG.service' /proc/\$php_pid/cgroup"
systemctl restart php-fpm
settle
check "restarting the shared PHP-FPM does not cut the limited site off" serves_wp
check "other sites unaffected" serves_wp "$D2"
check "php config applies to the limited site" bash -c "cecp-panel php config $D memory_limit=384M >/dev/null && sleep 1.5 && [ \"\$(curl -s http://$D/cecp-ini.php?r=\$RANDOM)\" = '384M|128M|5000' ]"
check "site limits show" bash -c "cecp-panel site limits $D show | grep -q 'CPU 50% of one core'"
check "rebuild-vhost keeps the limited site on its own PHP-FPM" \
  bash -c "cecp-panel site rebuild-vhost $D >/dev/null && systemctl is-active --quiet $UNIT && [ ! -e $POOL ] && sleep 1.5 && curl -s http://$D/ | grep -q wp-content"
check "invalid limits rejected" bash -c "! cecp-panel site limits $D --cpu 5 && ! cecp-panel site limits $D --mem 1T && ! cecp-panel site limits $D --tasks x"
check "monitor watches the limited PHP-FPM" bash -c "cecp-panel monitor run >/dev/null 2>&1; cecp-panel monitor status | grep -q 'service:cecp-php-fpm@$SLUG'"
check "site limits off" cecp-panel site limits "$D" off
settle
check "back on the shared PHP-FPM" bash -c "grep -q 'unix:/run/php-fpm/$SLUG.sock' $VHOST && [ -e $POOL ] && ! systemctl is-active --quiet $UNIT"
check "site serves WordPress after limits off" serves_wp

echo "=== Staging ==="
SD="staging.$D"; SSU="site_staging_${SLUG}"; SDOC="/home/$SSU/public_html"
wp_s() { runuser -u "$SSU" -- php /usr/local/bin/wp --path="$SDOC" "$@"; }
wp_d option update blogname "Live Name" >/dev/null
check "site staging $D" cecp-panel site staging "$D"
check "staging linked to its live site" test "$(meta_of "$SD" staging_of) $(meta_of "$D" staging_site)" = "$D $SD"
check "staging wp-config uses the staging database (not live)" \
  bash -c "grep -q \"'DB_NAME', 'db_staging_${SLUG}'\" $SDOC/wp-config.php && ! grep -q \"'db_${SLUG}'\" $SDOC/wp-config.php"
check "staging has its own Redis ACL user" bash -c "grep -q \"cecp_staging_${SLUG}\" $SDOC/wp-config.php && ! grep -q \"'cecp_${SLUG}'\" $SDOC/wp-config.php"
check "staging URLs rewritten, live untouched" test "$(wp_s option get home) $(wp_d option get home)" = "http://$SD http://$D"
SPASS="$(meta_of "$SD" site_auth_pass)"
check "staging asks for a password (401)" test "$(status_of "http://$SD/")" = 401
check "staging serves WordPress with the password, marked noindex" \
  bash -c "curl -s -u 'staging:$SPASS' http://$SD/ | grep -q wp-content && curl -sI -u 'staging:$SPASS' http://$SD/ | grep -qi '^x-robots-tag: noindex'"
check "live site is not noindex" bash -c "! curl -sI http://$D/ | grep -qi x-robots-tag"
check "staging guard mu-plugin (root-owned) blocks e-mail" \
  bash -c "[ \"\$(stat -c %U $SDOC/wp-content/mu-plugins/cecp-staging.php)\" = root ] && [ \"\$(runuser -u $SSU -- php /usr/local/bin/wp --path=$SDOC eval 'var_export(wp_mail(\"x@example.com\", \"t\", \"b\"));')\" = false ]"
check "monitor passes staging basic auth" bash -c "cecp-panel monitor run >/dev/null 2>&1; cecp-panel monitor status | grep 'site:$SD' | grep -q OK"
wp_s option update blogname "From Staging" >/dev/null
runuser -u "$SSU" -- bash -c "mkdir -p $SDOC/wp-content/uploads && echo staging-only >$SDOC/wp-content/uploads/staging-only.txt"
check "staging-push --dry-run changes nothing" \
  bash -c "cecp-panel site staging-push $D --dry-run | grep -q 'will be LOST' && [ \"\$(runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT option get blogname)\" = 'Live Name' ]"
check "staging-push refuses without --yes when not interactive" bash -c "! cecp-panel site staging-push $D </dev/null"
check "staging-push --yes" cecp-panel site staging-push "$D" --yes
check "live has the staging content" test "$(wp_d option get blogname)" = "From Staging"
check "live keeps its own URLs, DB credentials and search visibility" \
  bash -c "[ \"\$(runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT option get home)\" = 'http://$D' ] && grep -q \"'DB_NAME', 'db_${SLUG}'\" $DOCROOT/wp-config.php && [ \"\$(runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT option get blog_public)\" = 1 ]"
check "staging files arrived, staging guard did not" \
  bash -c "[ -f $DOCROOT/wp-content/uploads/staging-only.txt ] && [ ! -e $DOCROOT/wp-content/mu-plugins/cecp-staging.php ] && [ -f $DOCROOT/wp-content/mu-plugins/cecp-cache-purge.php ]"
check "live serves WordPress after the push" serves_wp
cp -a "$SDOC/index.php" /tmp/staging-index.php
printf '<?php http_response_code(500); exit;\n' >"$SDOC/index.php"
check "a broken push is rolled back" bash -c "! cecp-panel site staging-push $D --files-only --yes"
check "live answers after the rolled-back push" serves_wp
staging_link_cleared() { cecp-panel site remove "$SD" && [ -z "$(meta_of "$D" staging_site)" ]; }
check "site remove staging clears the link" staging_link_cleared

echo "=== Safe WordPress updates ==="
check "precondition: old plugin installed (hello-dolly 1.6)" wp_d plugin install hello-dolly --version=1.6 --force --activate
check "wp update --dry-run lists the update" bash -c "cecp-panel wp update $D --dry-run | grep -q 'hello-dolly 1.6 ->'"
check "wp update" cecp-panel wp update "$D"
plugin_updated() { [ "$(wp_d plugin get hello-dolly --field=version)" != 1.6 ] && [ "$(meta_of "$D" wp_last_update_result)" = ok ]; }
check "plugin updated, result recorded" plugin_updated
check "site serves WordPress after the update" serves_wp
wp_d plugin install hello-dolly --version=1.6 --force >/dev/null 2>&1
# A mu-plugin that turns fatal once hello-dolly is newer than 1.6: an update that breaks the site.
runuser -u "$SU" -- bash -c "cat >$DOCROOT/wp-content/mu-plugins/zz-break.php" <<'PHP'
<?php
$f = WP_PLUGIN_DIR . '/hello-dolly/hello.php';
if (is_file($f) && preg_match('/Version:\s*([0-9.]+)/', (string) file_get_contents($f), $m) && version_compare($m[1], '1.6', '>')) {
    throw new Error('cecp test: incompatible plugin update');
}
PHP
check "an update that breaks WordPress is rolled back" bash -c "! cecp-panel wp update $D"
check "plugin is back on the old version" test "$(wp_d plugin get hello-dolly --field=version)" = 1.6
check "site serves WordPress after the rollback" serves_wp
check "rollback recorded" bash -c "cecp-panel wp auto-update $D status | grep -q 'rolled_back'"
rm -f "$DOCROOT/wp-content/mu-plugins/zz-break.php"
check "wp rollback (manual undo) works" bash -c "cecp-panel wp rollback $D --yes && sleep 1 && curl -s http://$D/ | grep -q wp-content"
rm -f "$DOCROOT/wp-content/mu-plugins/zz-break.php"  # the undo brought back the pre-update files
check "wp auto-update on installs the daily job" \
  bash -c "cecp-panel wp auto-update $D on --exclude akismet && grep -q 'wp update --scheduled' /etc/cron.d/cecp-wp-update"
check "wp auto-update rejects bad exclusions" bash -c "! cecp-panel wp auto-update $D on --exclude 'a;id'"

echo "=== status --json ==="
status_json_ok() {
  cecp-panel status --json >/tmp/status.json || return 1
  python3 - "$D" /tmp/status.json <<'PY'
import json, sys
dom, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
s = next(x for x in d["sites"] if x["domain"] == dom)
assert d["schema"] == 2 and dom in d["domains_hosted"] and d["services"]["nginx"] == "active", d
assert s["cache"]["ttl"] == "1h" and s["cache"]["auto_purge"] is True, s
assert s["disk_mb"] and s["disk_mb"] > 0 and s["db_mb"] is not None and s["wp"]["auto_update"] is True, s
assert s["php_version"] == "80" and s["limits"] is None, s
PY
}
heartbeat_ok() {
  cecp-panel agent install >/dev/null 2>&1
  python3 - /var/lib/cecp-panel/agent/heartbeat.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == 2 and d["sites"], d
PY
}
check "status --json describes sites" status_json_ok
check "agent heartbeat uses the status document" heartbeat_ok

echo "=== Database tools ==="
check "db export" bash -c "f=\$(cecp-panel db export $D | tail -1) && [ \"\$(stat -c %a \$f)\" = 600 ] && gzip -t \$f && zcat \$f | grep -q 'CREATE TABLE .wp_options.'"
check "db export refuses a web-reachable path" bash -c "! cecp-panel db export $D $DOCROOT/dump.sql.gz && [ ! -e $DOCROOT/dump.sql.gz ]"
check "db size lists the site" bash -c "cecp-panel db size | grep -q '^$D '"
EXPORT="$(find /var/lib/cecp-panel/db-exports -name "${SLUG}-*.sql.gz" ! -name '*before-import*' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2)"
wp_d option update blogname "Changed after export" >/dev/null
check "db import --yes restores the exported data" \
  bash -c "cecp-panel db import $D $EXPORT --yes && [ \"\$(runuser -u $SU -- php /usr/local/bin/wp --path=$DOCROOT option get blogname)\" = 'From Staging' ]"
printf 'DROP DATABASE db_second_test;\n' >/tmp/evil.sql
check "a dump touching another site's database fails (runs as the site DB user)" bash -c "! cecp-panel db import $D /tmp/evil.sql --yes"
check "the other site's database survived" mysql -e 'USE db_second_test'
check "site restored after the failed import" serves_wp
check "slow query log on" cecp-panel db slow-log on 0.1
mysql -e 'SELECT SLEEP(0.3)' >/dev/null
check "slow-report shows the slow query" bash -c "cecp-panel db slow-report | grep -qi sleep"
check "slow query log off" cecp-panel db slow-log off

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
check "protect-admin htpasswd removed" test ! -e "/etc/nginx/cecp-auth/${SLUG}.htpasswd"
check "purge watcher removed with the site" bash -c "! systemctl is-enabled --quiet cecp-purge@${SLUG}.path"
check "sshd config valid after remove" sshd -t
check "nginx config valid after remove" nginx -t

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
exit "$FAIL"
