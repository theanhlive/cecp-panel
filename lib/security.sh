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
  local cfg="/etc/ssh/sshd_config"
  cp -a "$cfg" "${cfg}.bak-cecp-$(date +%Y%m%d%H%M%S)"
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$cfg" 2>/dev/null || true
  sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$cfg" 2>/dev/null || true
  # drop-in wins on modern OpenSSH
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-cecp-keyonly.conf <<'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
  panel_log "SSH: PasswordAuthentication=no (ensure your SSH key works before disconnecting!)"
}

security_ssh_set_port() {
  require_root
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || panel_die "Usage: cecp-panel security ssh-port PORT"
  (( port >= 22 && port <= 65535 )) || panel_die "Port must be 22-65535"
  security_audit_log "security ssh-port $port"
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-cecp-port.conf <<EOF
Port ${port}
EOF
  # firewall allow new port before reload
  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  elif command -v ufw &>/dev/null; then
    ufw allow "${port}/tcp" 2>/dev/null || true
  fi
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
  panel_log "SSH port set to ${port}. Keep current session open; test new port before closing."
}

security_ssh_harden() {
  # Non-destructive defaults: prohibit password root, keep password auth unless key-only applied
  require_root
  security_audit_log "security ssh-harden"
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-cecp-harden.conf <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
EOF
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  panel_log "SSH harden applied (PermitRootLogin=prohibit-password). Use ssh-key-only after key verified."
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
security_fail2ban_full() {
  require_root
  security_audit_log "security fail2ban-full"
  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d

  # Prefer systemd backend when available (Alma/RHEL); else file-based
  local ssh_backend="auto"
  if systemctl is-system-running &>/dev/null; then
    ssh_backend="systemd"
  fi

  cat >/etc/fail2ban/jail.d/cecp-sshd.conf <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
backend = ${ssh_backend}
maxretry = 5
findtime = 600
bantime = 3600
EOF

  cat >/etc/fail2ban/jail.d/cecp-nginx.conf <<'EOF'
[nginx-limit-req]
enabled = true
filter = nginx-limit-req
action = %(action_)s
logpath = /var/log/nginx/*error.log
maxretry = 20
findtime = 60
bantime = 3600

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/*error.log
maxretry = 5
findtime = 600
bantime = 3600
EOF

  # botsearch only if stock filter exists (avoid fail2ban crash on missing filter)
  if [[ -f /etc/fail2ban/filter.d/nginx-botsearch.conf ]]; then
    cat >>/etc/fail2ban/jail.d/cecp-nginx.conf <<'EOF'

[nginx-botsearch]
enabled = true
filter = nginx-botsearch
port = http,https
logpath = /var/log/nginx/*access.log
maxretry = 2
findtime = 600
bantime = 86400
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
logpath = /var/log/nginx/*access.log
maxretry = 15
findtime = 300
bantime = 7200
EOF

  systemctl enable --now fail2ban 2>/dev/null || true
  if ! systemctl reload fail2ban 2>/dev/null; then
    systemctl restart fail2ban 2>/dev/null || panel_log "WARN: fail2ban restart failed — check jail filters"
  fi
  panel_log "fail2ban jails: sshd, nginx-limit-req, nginx-http-auth, cecp-wordpress (+ botsearch if available)"
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
  mkdir -p /etc/nginx/snippets
  cat >/etc/nginx/snippets/cecp-ssl-params.conf <<'EOF'
# CECP — include inside server { listen 443 ssl; ... }
ssl_session_cache shared:CECPSSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF
  panel_log "Installed /etc/nginx/snippets/cecp-ssl-params.conf (use after SSL; certbot may already set headers)"
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
  security_firewall_baseline
  security_nginx_hide_version
  security_php_hide_version
  security_https_snippet_install
  optimize_nginx_global
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
  panel_log "  - firewall baseline, server_tokens off, expose_php=Off"
  panel_log "  - fail2ban full jails, SSH harden (key root only)"
  panel_log "  - MariaDB bind localhost + baseline secure"
  panel_log "  - nginx gzip/rate-limit/fastcgi zones"
  panel_log "Recommended next: cecp-panel security ssh-key-only (after SSH key verified)"
  panel_log "Optional: cecp-panel security ssh-port 2222"
}

security_self_check() {
  echo "=== CECP Security self-check ==="
  security_ssh_show
  echo ""
  security_firewall_status
  echo ""
  security_fail2ban_status
  echo ""
  echo "--- nginx tokens ---"
  nginx -T 2>/dev/null | grep -i server_tokens | head -5 || echo "  (run as root for full dump)"
  echo ""
  echo "--- MariaDB bind ---"
  if command -v mysql &>/dev/null; then
    mysql -Nse "SHOW VARIABLES LIKE 'bind_address';" 2>/dev/null || true
  fi
  echo ""
  echo "Audit log: $LOG_DIR/audit.log"
  [[ -f "$LOG_DIR/audit.log" ]] && tail -5 "$LOG_DIR/audit.log" || echo "  (empty)"
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
