#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------
security_audit_log() {
  mkdir -p "$LOG_DIR"
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) user=$(whoami 2>/dev/null || echo unknown) cmd=$*"
  echo "$line" >>"$LOG_DIR/audit.log"
  chmod 640 "$LOG_DIR/audit.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------
security_fail2ban_status() {
  echo "--- fail2ban ---"
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "  [OK] active"
    fail2ban-client status 2>/dev/null | head -30 || true
    local j
    for j in sshd nginx-limit-req nginx-http-auth nginx-botsearch; do
      fail2ban-client status "$j" 2>/dev/null | head -8 | sed "s/^/  [$j] /" || true
    done
  else
    echo "  [--] not active"
  fi
}

security_firewall_status() {
  echo "--- Firewall ---"
  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --state 2>/dev/null || true
    firewall-cmd --list-all 2>/dev/null || firewall-cmd --list-services 2>/dev/null || true
  elif command -v ufw &>/dev/null; then
    ufw status verbose 2>/dev/null || true
  else
    echo "  (no firewalld/ufw)"
  fi
}

security_ssh_show() {
  echo "--- SSH ---"
  grep -E '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|ChallengeResponseAuthentication|KbdInteractiveAuthentication)' \
    /etc/ssh/sshd_config 2>/dev/null | grep -v '^#' || true
  # drop-ins
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    echo "--- drop-ins ---"
    grep -rEh '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' \
      /etc/ssh/sshd_config.d 2>/dev/null | grep -v '^#' || true
  fi
  [[ -f "$ETC_DIR/ssh-hardening.txt" ]] && echo "Hints: $ETC_DIR/ssh-hardening.txt"
}

# ---------------------------------------------------------------------------
# SSH hardening
# ---------------------------------------------------------------------------
security_apply_ssh_key_only() {
  require_root
  security_audit_log "security ssh-key-only"
  local cfg="/etc/ssh/sshd_config" bak
  bak="${cfg}.bak-cecp-$(date +%Y%m%d%H%M%S)"
  cp -a "$cfg" "$bak"
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$cfg" 2>/dev/null || true
  sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$cfg" 2>/dev/null || true
  # sshd keeps the FIRST value it reads and drop-ins load alphabetically, so a "99-" file loses
  # to e.g. 50-cloud-init.conf (PasswordAuthentication yes). "00-" makes the setting effective.
  if ! sshd_apply_dropin /etc/ssh/sshd_config.d/00-cecp-keyonly.conf "PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no"; then
    cp -a "$bak" "$cfg"
    panel_die "SSH key-only NOT applied (sshd config test failed; restored $cfg)"
  fi
  rm -f /etc/ssh/sshd_config.d/99-cecp-keyonly.conf
  panel_log "SSH: PasswordAuthentication=no (ensure your SSH key works before disconnecting!)"
}

security_ssh_set_port() {
  require_root
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || panel_die "Usage: cecp-panel security ssh-port PORT"
  (( port >= 22 && port <= 65535 )) || panel_die "Port must be 22-65535"
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    panel_die "sshd is socket-activated (ssh.socket): Port in sshd_config is ignored. Change ListenStream in ssh.socket instead."
  fi
  security_audit_log "security ssh-port $port"
  # SELinux (Alma/Rocky default): sshd cannot bind a port not labelled ssh_port_t -> lockout on restart.
  if (( port != 22 )) && command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    command -v semanage &>/dev/null || dnf -y install policycoreutils-python-utils >/dev/null 2>&1 || true
    command -v semanage &>/dev/null || panel_die "SELinux is enabled but semanage is missing — refusing to change SSH port"
    semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$port" \
      || panel_die "semanage could not label port $port as ssh_port_t"
  fi
  # firewall allow new port before reload
  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  elif command -v ufw &>/dev/null; then
    ufw allow "${port}/tcp" 2>/dev/null || true
  fi
  sshd_apply_dropin /etc/ssh/sshd_config.d/99-cecp-port.conf "Port ${port}" \
    || panel_die "SSH port NOT changed (sshd config test failed)"
  panel_log "SSH port set to ${port}. Keep current session open; test new port before closing."
}

security_ssh_harden() {
  # Non-destructive defaults: prohibit password root, keep password auth unless key-only applied
  require_root
  security_audit_log "security ssh-harden"
  # "00-" so these win over distro drop-ins (first value wins, e.g. 50-redhat.conf X11Forwarding yes).
  sshd_apply_dropin /etc/ssh/sshd_config.d/00-cecp-harden.conf "PermitRootLogin prohibit-password
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30" || panel_die "SSH harden NOT applied (sshd config test failed)"
  rm -f /etc/ssh/sshd_config.d/99-cecp-harden.conf
  panel_log "SSH harden applied (PermitRootLogin=prohibit-password). Use ssh-key-only after key verified."
}

# Repair SFTP drop-ins damaged by 1.5.0 ("Match User" written without a user name).
security_ssh_repair() {
  require_root
  security_audit_log "security ssh-repair"
  local qdir f user
  qdir="$VAR_LIB/quarantine/sshd-$(date +%Y%m%d%H%M%S)"
  local -a users=()
  shopt -s nullglob
  for f in /etc/ssh/sshd_config.d/cecp-site_*.conf; do
    user="$(basename "$f" .conf)"
    user="${user#cecp-}"
    grep -qE "^Match User ${user}\$" "$f" && continue
    mkdir -p "$qdir"
    mv "$f" "$qdir/"
    panel_log "Quarantined damaged SFTP drop-in: $f -> $qdir/"
    if id "$user" &>/dev/null; then users+=("$user"); fi
  done
  shopt -u nullglob
  if [[ ! -d "$qdir" ]]; then
    panel_log "No damaged SFTP drop-ins found"
    return 0
  fi
  sshd_test_and_reload || panel_die "sshd -t still failing — inspect /etc/ssh/sshd_config.d manually"
  for user in "${users[@]}"; do
    site_sftp_enable "$user"
    panel_log "Rewrote SFTP drop-in for $user"
  done
  panel_log "SSH drop-in repair done"
}

# ---------------------------------------------------------------------------
# Nginx / PHP surface hardening
# ---------------------------------------------------------------------------
security_nginx_hide_version() {
  require_root
  local f=/etc/nginx/conf.d/cecp-security.conf
  cat >"$f" <<'EOF'
# CECP Panel — hide version + baseline TLS headers on HTTP (HSTS only useful on HTTPS)
server_tokens off;
more_clear_headers Server 2>/dev/null; # no-op if module missing
EOF
  # more_clear_headers may fail nginx -t if module absent — use pure tokens only
  cat >"$f" <<'EOF'
# CECP Panel — hide nginx version
server_tokens off;
EOF
  panel_log "nginx server_tokens off -> $f"
}

security_php_hide_version() {
  require_root
  # System php.ini paths (Alma + Ubuntu)
  local f
  for f in /etc/php.ini /etc/php/*/fpm/php.ini /etc/opt/remi/php*/php.ini; do
    [[ -f "$f" ]] || continue
    if grep -qE '^\s*expose_php\s*=' "$f" 2>/dev/null; then
      sed -i 's/^\s*expose_php\s*=.*/expose_php = Off/' "$f"
    else
      echo "expose_php = Off" >>"$f"
    fi
  done
  panel_log "PHP expose_php=Off applied where php.ini found"
}

# ---------------------------------------------------------------------------
# Fail2Ban jails
# ---------------------------------------------------------------------------
# [DEFAULT] for all jails: incremental bans, and never ban Cloudflare edges (without real-IP
# every proxied visitor appears to come from them, so one ban would take sites offline).
security_fail2ban_defaults() {
  local ignore="127.0.0.1/8 ::1"
  if [[ -f "$CF_IPS_FILE" ]]; then
    ignore+=" $(grep -vE '^\s*(#|$)' "$CF_IPS_FILE" | tr '\n' ' ')"
  fi
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/cecp-00-defaults.conf <<EOF
[DEFAULT]
ignoreip = ${ignore}
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
EOF
}

security_fail2ban_full() {
  require_root
  security_audit_log "security fail2ban-full"
  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d

  # Prefer systemd backend when available (Alma/RHEL); else file-based
  local ssh_backend="auto"
  if systemctl is-system-running &>/dev/null; then
    ssh_backend="systemd"
  fi

  [[ -f "$CF_IPS_FILE" ]] || cf_realip_render "$PANEL_ROOT/templates/cloudflare-ips.txt"
  security_fail2ban_defaults

  # Firewall bans cannot stop traffic arriving through Cloudflare's proxy; an nginx-level
  # deny (evaluated on the real client IP) can.
  cat >/etc/fail2ban/action.d/cecp-nginx-deny.conf <<'EOF'
[Definition]
actionstart = touch /etc/nginx/conf.d/cecp-f2b-deny.conf
actionstop =
actioncheck =
actionban = grep -qxF 'deny <ip>;' /etc/nginx/conf.d/cecp-f2b-deny.conf || echo 'deny <ip>;' >> /etc/nginx/conf.d/cecp-f2b-deny.conf
            nginx -t -q && systemctl reload nginx
actionunban = sed -i '/^deny <ip>;$/d' /etc/nginx/conf.d/cecp-f2b-deny.conf
              nginx -t -q && systemctl reload nginx
EOF

  cat >/etc/fail2ban/jail.d/cecp-sshd.conf <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
backend = ${ssh_backend}
maxretry = 5
EOF

  cat >/etc/fail2ban/jail.d/cecp-nginx.conf <<'EOF'
[nginx-limit-req]
enabled = true
filter = nginx-limit-req
action = %(action_)s
         cecp-nginx-deny
logpath = /var/log/nginx/*error.log
maxretry = 20
findtime = 60

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
action = %(action_)s
         cecp-nginx-deny
logpath = /var/log/nginx/*error.log
maxretry = 5
EOF

  # botsearch only if stock filter exists (avoid fail2ban crash on missing filter)
  if [[ -f /etc/fail2ban/filter.d/nginx-botsearch.conf ]]; then
    cat >>/etc/fail2ban/jail.d/cecp-nginx.conf <<'EOF'

[nginx-botsearch]
enabled = true
filter = nginx-botsearch
port = http,https
action = %(action_)s
         cecp-nginx-deny
logpath = /var/log/nginx/*access.log
maxretry = 2
bantime = 1d
EOF
  fi

  # Repeat offenders across all jails: long ban. Only when fail2ban logs to a file.
  if [[ -f /var/log/fail2ban.log ]]; then
    cat >/etc/fail2ban/jail.d/cecp-recidive.conf <<'EOF'
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
findtime = 1d
maxretry = 5
bantime = 1w
EOF
  fi

  cat >/etc/fail2ban/filter.d/cecp-wordpress.conf <<'EOF'
[Definition]
failregex = ^<HOST> .*"(GET|POST) /wp-login\.php
            ^<HOST> .*"(GET|POST) /xmlrpc\.php
ignoreregex =
EOF

  cat >/etc/fail2ban/jail.d/cecp-wordpress.conf <<'EOF'
[cecp-wordpress]
enabled = true
filter = cecp-wordpress
port = http,https
action = %(action_)s
         cecp-nginx-deny
logpath = /var/log/nginx/*access.log
maxretry = 15
findtime = 300
bantime = 2h
EOF

  systemctl enable --now fail2ban 2>/dev/null || true
  if ! systemctl reload fail2ban 2>/dev/null; then
    systemctl restart fail2ban 2>/dev/null || panel_log "WARN: fail2ban restart failed — check jail filters"
  fi
  panel_log "fail2ban: sshd, nginx-limit-req, nginx-http-auth, cecp-wordpress (+botsearch, recidive); incremental bans; Cloudflare never banned"
}

# Keep old name as alias
security_fail2ban_nginx() {
  security_fail2ban_full
}

# ---------------------------------------------------------------------------
# MariaDB network bind
# ---------------------------------------------------------------------------
security_mariadb_bind_local() {
  require_root
  security_audit_log "security mariadb-bind"
  local f
  if [[ -d /etc/my.cnf.d ]]; then
    f=/etc/my.cnf.d/cecp-bind.cnf
  elif [[ -d /etc/mysql/mariadb.conf.d ]]; then
    f=/etc/mysql/mariadb.conf.d/99-cecp-bind.cnf
  else
    f=/etc/mysql/conf.d/cecp-bind.cnf
    mkdir -p "$(dirname "$f")"
  fi
  cat >"$f" <<'EOF'
[mysqld]
bind-address = 127.0.0.1
skip-networking = 0
EOF
  systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
  panel_log "MariaDB bind-address=127.0.0.1 ($f)"
}

# ---------------------------------------------------------------------------
# Firewall baseline (idempotent)
# ---------------------------------------------------------------------------
security_firewall_baseline() {
  require_root
  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  elif command -v ufw &>/dev/null; then
    ufw allow OpenSSH 2>/dev/null || true
    ufw allow 'Nginx Full' 2>/dev/null || true
    # do not force enable ufw if user has custom policy
  fi
  panel_log "Firewall baseline: ssh/http/https allowed"
}

# ---------------------------------------------------------------------------
# HTTPS security snippet (HSTS helpers for after certbot)
# ---------------------------------------------------------------------------
security_https_snippet_install() {
  require_root
  ensure_nginx_global
  panel_log "Installed nginx snippets cecp-headers.conf + cecp-ssl-params.conf (used by panel HTTPS vhosts)"
}

# Logs must not be world-readable (they used to contain passwords); scrub secrets that
# older versions wrote. LOG_DIR stays traversable (711) for per-site wp-cron logs.
security_fix_permissions() {
  require_root
  chmod 700 "$ETC_DIR" 2>/dev/null || true
  install -d -m 711 "$LOG_DIR"
  find "$LOG_DIR" -maxdepth 1 -type f -exec chmod 640 {} + 2>/dev/null || true
  chmod 600 "$SITES_DIR"/*.json 2>/dev/null || true
  if [[ -f "$LOG_DIR/panel.log" ]]; then
    sed -i -E \
      -e 's/(pass: )[A-Za-z0-9!@#%^_+=.,-]+( \(save now\))/\1[REDACTED]\2/' \
      -e 's/(Password: )[A-Za-z0-9!@#%^_+=.,-]+/\1[REDACTED]/' \
      "$LOG_DIR/panel.log"
  fi
  panel_log "Permissions: $ETC_DIR 700, $LOG_DIR 711, logs 640, site meta 600; old secrets redacted"
}

# ---------------------------------------------------------------------------
# Production profile — one shot
# ---------------------------------------------------------------------------
security_apply_production() {
  require_root
  security_audit_log "security apply-production"
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/optimize.sh"
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/mysql.sh"

  panel_log "Applying production security profile..."
  security_fix_permissions
  system_logrotate_install
  security_firewall_baseline
  security_nginx_hide_version
  security_php_hide_version
  security_https_snippet_install
  optimize_nginx_global
  cf_realip_update
  security_fail2ban_full
  security_ssh_harden
  security_mariadb_bind_local
  mysql_secure_basics
  if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P httpd_enable_homedirs 1 2>/dev/null || true
    setsebool -P httpd_read_user_content 1 2>/dev/null || true
  fi
  nginx_test_and_reload || true
  php_fpm_reload || true
  panel_log "Production profile applied:"
  panel_log "  - permissions + log redaction, firewall baseline, server_tokens off, expose_php=Off"
  panel_log "  - Cloudflare real IP, fail2ban (incremental, nginx deny), SSH harden (key root only)"
  panel_log "  - MariaDB bind localhost + baseline secure"
  panel_log "Next: cecp-panel site rebuild-vhost --all   # apply new vhost/pool templates"
  panel_log "Recommended: cecp-panel security ssh-key-only (after SSH key verified)"
}

security_self_check() {
  local pass=0 warn=0 fail=0
  _ck() {
    case "$1" in
      PASS) pass=$((pass + 1)) ;;
      WARN) warn=$((warn + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
    esac
    printf '  [%s] %s\n' "$1" "$2"
  }
  echo "=== CECP Security self-check ==="

  echo "--- SSH ---"
  if sshd -t 2>/dev/null; then _ck PASS "sshd -t: config valid"; else _ck FAIL "sshd -t: config INVALID (restart would lock SSH out)"; fi
  local eff
  eff="$(sshd -T 2>/dev/null || true)"
  if grep -qx 'passwordauthentication no' <<<"$eff"; then _ck PASS "effective PasswordAuthentication no"
  else _ck WARN "effective PasswordAuthentication yes (run security ssh-key-only once your key works)"; fi
  if grep -qE '^permitrootlogin (no|prohibit-password|without-password)$' <<<"$eff"; then _ck PASS "root password login disabled"
  else _ck WARN "root can log in with a password (run security ssh-harden)"; fi
  if grep -lE '^Match User *$' /etc/ssh/sshd_config.d/cecp-*.conf >/dev/null 2>&1; then
    _ck FAIL "damaged SFTP drop-in (empty Match User) — run: cecp-panel security ssh-repair"
  fi

  echo "--- nginx ---"
  if nginx -t 2>/dev/null; then _ck PASS "nginx -t: config valid"; else _ck FAIL "nginx -t: config INVALID"; fi
  if [[ -f "$CF_REALIP_CONF" ]]; then _ck PASS "Cloudflare real-IP configured"
  else _ck WARN "Cloudflare real-IP missing (rate limit / fail2ban see Cloudflare IPs) — run: cecp-panel cf realip"; fi
  local f dom vhost deny_line php_line
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    dom="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    vhost="/etc/nginx/conf.d/cecp-$(domain_slug "$dom").conf"
    [[ -f "$vhost" ]] || { _ck FAIL "$dom: vhost missing"; continue; }
    deny_line="$(grep -nF '(?:uploads|files)' "$vhost" | grep -v ':\s*#' | head -1 | cut -d: -f1)"
    php_line="$(grep -nE '^\s*location ~ \\\.php\$' "$vhost" | head -1 | cut -d: -f1)"
    if [[ -n "$deny_line" && -n "$php_line" && "$deny_line" -lt "$php_line" ]]; then
      _ck PASS "$dom: PHP execution in uploads blocked"
    else
      _ck FAIL "$dom: uploaded .php files can execute — run: cecp-panel site rebuild-vhost $dom"
    fi
    if grep -q 'cecp-headers.conf' "$vhost"; then _ck PASS "$dom: security headers on every response"
    else _ck WARN "$dom: old vhost (headers dropped on PHP/static) — run: cecp-panel site rebuild-vhost $dom"; fi
    local sock
    sock="$(site_json_get_or "$dom" php_sock "")"
    if [[ -S "$sock" && "$(stat -c %U "$sock")" != "nginx" ]] && id nginx &>/dev/null; then
      _ck FAIL "$dom: PHP-FPM socket owned by $(stat -c %U:%G "$sock") — nginx gets 502 (run: systemctl restart php-fpm)"
    fi
  done
  shopt -u nullglob

  echo "--- files / secrets ---"
  [[ "$(stat -c %a "$ETC_DIR" 2>/dev/null)" == "700" ]] && _ck PASS "$ETC_DIR is 700" || _ck FAIL "$ETC_DIR not 700"
  if [[ -f "$LOG_DIR/panel.log" ]] && (( (8#$(stat -c %a "$LOG_DIR/panel.log") & 8#004) != 0 )); then
    _ck FAIL "panel.log is world-readable — run: cecp-panel security apply-production"
  else
    _ck PASS "panel.log not world-readable"
  fi
  if grep -qE 'pass: [A-Za-z0-9]{8,} \(save now\)|Password: [A-Za-z0-9]{8,}' "$LOG_DIR/panel.log" 2>/dev/null; then
    _ck FAIL "panel.log contains plaintext passwords — run: cecp-panel security apply-production"
  fi

  echo "--- services ---"
  systemctl is-active --quiet fail2ban 2>/dev/null && _ck PASS "fail2ban active" || _ck WARN "fail2ban not active"
  [[ -f /etc/fail2ban/jail.d/cecp-00-defaults.conf ]] && _ck PASS "fail2ban never bans Cloudflare" \
    || _ck WARN "fail2ban defaults missing — run: cecp-panel security fail2ban-full"
  [[ -f /etc/cron.d/cecp-monitor ]] && _ck PASS "monitoring enabled (alerts + auto-restart)" \
    || _ck WARN "monitoring disabled — run: cecp-panel monitor enable"
  local bad_backups
  bad_backups="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    d = {}
print(" ".join(k for k, v in sorted(d.items()) if v.get("last_error") or v.get("last_verify_error")))
' "$BACKUP_STATE")"
  [[ -z "$bad_backups" ]] || _ck WARN "backup/verify errors for: $bad_backups (cecp-panel backup status)"
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then _ck PASS "TCP BBR active"
  else _ck WARN "TCP BBR not active (cecp-panel optimize kernel)"; fi
  if command -v mysql &>/dev/null; then
    local bind
    bind="$(mysql -Nse "SELECT @@bind_address" 2>/dev/null || true)"
    [[ "$bind" == "127.0.0.1" || "$bind" == "localhost" ]] && _ck PASS "MariaDB bound to localhost" \
      || _ck WARN "MariaDB bind_address='${bind:-?}' (security mariadb-bind)"
  fi

  echo ""
  echo "RESULT: ${pass} pass, ${warn} warn, ${fail} fail"
  [[ "$fail" == "0" ]]
}

security_unattended_updates() {
  require_root
  security_audit_log "security unattended-updates"
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
    dnf -y install dnf-automatic 2>/dev/null || true
    if [[ -f /etc/dnf/automatic.conf ]]; then
      sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
      sed -i 's/^upgrade_type.*/upgrade_type = security/' /etc/dnf/automatic.conf 2>/dev/null || true
    fi
    systemctl enable --now dnf-automatic.timer 2>/dev/null \
      || systemctl enable --now dnf-automatic-install.timer 2>/dev/null || true
    panel_log "dnf-automatic enabled (security updates)"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y unattended-upgrades apt-listchanges 2>/dev/null || true
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null || true
    panel_log "unattended-upgrades enabled"
  fi
}
