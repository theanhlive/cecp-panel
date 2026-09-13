#!/usr/bin/env bash
# Optional ModSecurity + OWASP CRS for nginx (advanced, can break WP — off by default)
set -euo pipefail

modsec_status() {
  echo "=== ModSecurity ==="
  if [[ -f /etc/nginx/conf.d/cecp-modsecurity.conf ]]; then
    echo "  config: present (/etc/nginx/conf.d/cecp-modsecurity.conf)"
  else
    echo "  config: not installed"
  fi
  if nginx -V 2>&1 | grep -qi modsecurity; then
    echo "  nginx module: linked"
  else
    echo "  nginx module: not detected in nginx -V"
  fi
  rpm -q nginx-mod-security-waf 2>/dev/null || true
  dpkg -l 'libnginx-mod-http-modsecurity' 2>/dev/null | tail -1 || true
}

modsec_install() {
  require_root
  panel_log "Installing ModSecurity (optional — may break WordPress admin/forms)"
  local ok=0
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
    dnf -y install nginx-mod-security-waf mod_security_crs 2>/dev/null && ok=1 || \
      dnf -y install mod_security 2>/dev/null && ok=1 || true
  else
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y libnginx-mod-http-modsecurity 2>/dev/null && ok=1 || true
  fi
  if [[ "$ok" != "1" ]]; then
    panel_log "Package install failed or incomplete. Manual: https://github.com/owasp-modsecurity/ModSecurity"
    echo "RESULT: modsec=package_unavailable"
    return 0
  fi

  mkdir -p /etc/nginx/modsec
  # Minimal ruleset — DetectionOnly first (safe)
  cat >/etc/nginx/modsec/main.conf <<'EOF'
# CECP Panel ModSecurity — DetectionOnly (log, do not block)
SecRuleEngine DetectionOnly
SecRequestBodyAccess On
SecResponseBodyAccess Off
SecAuditEngine RelevantOnly
SecAuditLog /var/log/nginx/modsec_audit.log
SecAuditLogParts ABIJDEFHZ
# Basic XSS/SQLi sample (replace with full CRS after testing)
SecRule ARGS "@rx (?i)(union\s+select|or\s+1=1|<script)" \
  "id:1001,phase:2,deny,status:403,msg:'CECP basic attack pattern',log"
EOF

  cat >/etc/nginx/conf.d/cecp-modsecurity.conf <<'EOF'
# CECP — load only if module available; comment out to disable
# modsecurity on;
# modsecurity_rules_file /etc/nginx/modsec/main.conf;
# DISABLED by default after install — enable with: cecp-panel modsec enable
EOF

  if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
  fi
  panel_log "ModSecurity packages installed. Rules in DetectionOnly mode."
  panel_log "Enable carefully: cecp-panel modsec enable"
  panel_log "Disable anytime: cecp-panel modsec disable"
  echo "RESULT: modsec=installed_disabled"
}

modsec_enable() {
  require_root
  [[ -f /etc/nginx/modsec/main.conf ]] || panel_die "Run: cecp-panel modsec install first"
  cat >/etc/nginx/conf.d/cecp-modsecurity.conf <<'EOF'
# CECP ModSecurity enabled (DetectionOnly in main.conf — change to On carefully)
modsecurity on;
modsecurity_rules_file /etc/nginx/modsec/main.conf;
EOF
  if nginx -t 2>/tmp/modsec-t.err; then
    systemctl reload nginx
    panel_log "ModSecurity ENABLED (engine still DetectionOnly unless you edit main.conf)"
    notify_send "ModSecurity enabled on $(panel_host_fqdn)" 2>/dev/null || true
  else
    rm -f /etc/nginx/conf.d/cecp-modsecurity.conf
    panel_log "nginx -t failed — ModSecurity NOT enabled (module missing?)"
    cat /tmp/modsec-t.err >&2 || true
    return 1
  fi
}

modsec_disable() {
  require_root
  rm -f /etc/nginx/conf.d/cecp-modsecurity.conf
  if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
  fi
  panel_log "ModSecurity disabled"
}

modsec_blocking() {
  # Switch engine to On (real blocking) — high risk for WP
  require_root
  [[ -f /etc/nginx/modsec/main.conf ]] || panel_die "modsec not installed"
  sed -i 's/^SecRuleEngine .*/SecRuleEngine On/' /etc/nginx/modsec/main.conf
  nginx -t && systemctl reload nginx
  panel_log "SecRuleEngine=On (blocking). Monitor /var/log/nginx/modsec_audit.log"
  panel_log "If WP breaks: cecp-panel modsec disable"
}
