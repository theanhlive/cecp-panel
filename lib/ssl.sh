#!/usr/bin/env bash
set -euo pipefail

ssl_list() {
  echo "--- SSL certificates (certbot) ---"
  if command -v certbot &>/dev/null; then
    certbot certificates 2>/dev/null || echo "  (none or certbot error)"
  else
    echo "  certbot not installed"
  fi
}

# Reload nginx after every renewal (certbot runs hooks in this dir automatically).
ssl_install_deploy_hook() {
  local hook=/etc/letsencrypt/renewal-hooks/deploy/cecp-reload-nginx.sh
  mkdir -p "$(dirname "$hook")"
  printf '#!/bin/sh\nnginx -t -q && systemctl reload nginx\n' >"$hook"
  chmod 755 "$hook"
}

# Certs issued by older panels used certbot's nginx installer, which edits vhosts on renewal
# and would fight the panel-managed HTTPS template. Switch renewal to webroot, no installer.
# DNS-01 lineages (wildcards) keep their authenticator: only the installer line is dropped.
ssl_renewal_use_webroot() {
  local domain="${1,,}" conf docroot
  ssl_install_deploy_hook
  conf="/etc/letsencrypt/renewal/${domain}.conf"
  [[ -f "$conf" ]] || return 0
  docroot="$(site_json_get "$domain" docroot)"
  python3 - "$conf" "$domain" "$docroot" <<'PY'
import re, sys
conf, domain, docroot = sys.argv[1:4]
lines = open(conf, encoding="utf-8").read().splitlines()
auth = next((l.split("=", 1)[1].strip() for l in lines if re.match(r"\s*authenticator\s*=", l)), "")
if auth.startswith("dns-"):
    out = [l for l in lines if not re.match(r"\s*installer\s*=", l)]
    open(conf, "w", encoding="utf-8").write("\n".join(out) + "\n")
    sys.exit(0)
out, in_params, in_map = [], False, False
for line in lines:
    s = line.strip()
    if s.startswith("[") and not s.startswith("[["):
        in_params, in_map = (s == "[renewalparams]"), False
    elif s.startswith("[["):
        in_map = (s == "[[webroot_map]]")
        if in_map:
            continue
    if in_map:
        continue
    if in_params and s.split("=")[0].strip() in ("authenticator", "installer", "webroot_path"):
        continue
    out.append(line)
    if s == "[renewalparams]":
        out += ["authenticator = webroot", f"webroot_path = {docroot},"]
out += ["[[webroot_map]]", f"{domain} = {docroot}"]
open(conf, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

# Point nginx at an existing Let's Encrypt cert using the panel HTTPS template.
ssl_reattach_nginx() {
  local domain="${1,,}"
  validate_domain "$domain"
  site_cert_dir "$domain" >/dev/null || return 0
  panel_log "Attaching Let's Encrypt certificate to nginx for $domain ..."
  ssl_install_deploy_hook
  ssl_renewal_use_webroot "$domain"
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_die "nginx rejected the HTTPS vhost for $domain (config rolled back)"
}

# CECP_CERTBOT lets the integration test substitute a fake certbot (no Let's Encrypt in Docker).
CERTBOT_BIN="${CECP_CERTBOT:-certbot}"
CF_DNS_INI="/etc/letsencrypt/cecp-cloudflare.ini"

# cecp-panel ssl issue DOMAIN [--dns] [--wildcard]
#   default  : HTTP-01 webroot (the domain must reach this VPS over plain HTTP)
#   --dns    : DNS-01 through the Cloudflare API — works while the record is proxied
#   --wildcard: DOMAIN + *.DOMAIN (implies --dns); subdomain sites then reuse this cert
ssl_issue_for_domain() {
  local domain="${1,,}"
  shift || true
  local dns=0 wildcard=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dns) dns=1; shift ;;
      --wildcard) dns=1; wildcard=1; shift ;;
      *) panel_die "Usage: cecp-panel ssl issue DOMAIN [--dns] [--wildcard]" ;;
    esac
  done
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain (run: cecp-panel site add $domain)"
  if (( dns )); then
    ssl_issue_dns "$domain" "$wildcard"
    return
  fi
  local cert_dir
  if cert_dir="$(site_cert_dir "$domain")"; then
    ssl_reattach_nginx "$domain"
    panel_log "SSL OK (existing cert ${cert_dir##*/}): https://$domain"
    return 0
  fi
  panel_log "Issuing Let's Encrypt for $domain (webroot) ..."
  # certonly: certbot must not edit the panel-managed vhost; we render HTTPS ourselves.
  "$CERTBOT_BIN" certonly --webroot -w "$(site_json_get "$domain" docroot)" -d "$domain" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    || panel_die "certbot failed for $domain (DNS must point to this VPS; behind a proxied Cloudflare record use: ssl issue $domain --dns)"
  ssl_reattach_nginx "$domain"
  panel_log "SSL OK: https://$domain (HTTP/2 + HSTS)"
}

# Re-render sites one label below DOMAIN that have no certificate of their own, so they follow
# the *.DOMAIN certificate (issued → HTTPS, removed → back to HTTP). Caller reloads nginx.
ssl_rerender_subsites() {
  local domain="$1" f sub
  shopt -s nullglob
  for f in "$SITES_DIR"/*."${domain}".json; do
    sub="$(basename "$f" .json)"
    [[ "${sub%."$domain"}" != *.* && ! -f "/etc/letsencrypt/live/${sub}/fullchain.pem" ]] || continue
    site_render_vhost "$sub"
    panel_log "  $sub: vhost re-rendered for the *.$domain certificate change"
  done
  shopt -u nullglob
}

ssl_issue_dns() {
  local domain="$1" wildcard="$2"
  dns_load_credentials
  if [[ -z "${CECP_CERTBOT:-}" ]] && ! certbot plugins 2>/dev/null | grep -q dns-cloudflare; then
    panel_log "Installing certbot Cloudflare DNS plugin ..."
    dnf -y install python3-certbot-dns-cloudflare >/dev/null 2>&1 \
      || apt-get install -y python3-certbot-dns-cloudflare >/dev/null 2>&1 \
      || panel_die "Could not install python3-certbot-dns-cloudflare"
  fi
  [[ -d /etc/letsencrypt ]] || install -d -m 755 /etc/letsencrypt
  (umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" >"$CF_DNS_INI")
  chmod 600 "$CF_DNS_INI"
  local -a names=(-d "$domain")
  local label="$domain"
  if (( wildcard )); then
    names+=(-d "*.${domain}")
    label="$domain + *.$domain"
  fi
  panel_log "Issuing Let's Encrypt for $label via Cloudflare DNS-01 ..."
  "$CERTBOT_BIN" certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_DNS_INI" \
    --dns-cloudflare-propagation-seconds 30 --cert-name "$domain" "${names[@]}" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    || panel_die "certbot DNS-01 failed for $domain (token needs Zone → DNS → Edit on the zone)"
  site_json_set "$domain" ssl_method dns ssl_wildcard "$([[ "$wildcard" == 1 ]] && echo true || echo false)"
  ssl_reattach_nginx "$domain"
  if (( wildcard )); then
    ssl_rerender_subsites "$domain"
    nginx_test_and_reload || panel_die "nginx rejected a vhost after the wildcard certificate (config rolled back)"
  fi
  local mode
  mode="$(ssl_cf_get_ssl_mode "$(cf_zone_for_domain "$domain")" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value",""))' 2>/dev/null || true)"
  if [[ "$mode" == "flexible" || "$mode" == "off" ]]; then
    panel_log "WARN: Cloudflare SSL mode is '$mode' — with HTTPS at the origin this causes a redirect loop. Run: cecp-panel dns ssl-mode strict"
  fi
  panel_log "SSL OK: $label (DNS-01, renews automatically)"
}

# cecp-panel ssl hsts DOMAIN on|off|subdomains
ssl_set_hsts() {
  local domain="${1,,}" mode="${2:-}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  case "$mode" in
    on|off|subdomains) ;;
    *) panel_die "Usage: cecp-panel ssl hsts DOMAIN on|off|subdomains" ;;
  esac
  site_json_set "$domain" hsts "$mode"
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
  panel_log "HSTS for $domain: $mode"
}

ssl_status() {
  echo "--- Let's Encrypt certificates ---"
  if ! command -v certbot &>/dev/null; then
    echo "  certbot not installed"
    return 0
  fi
  certbot certificates 2>/dev/null || true
  echo ""
  echo "--- Days until expiry (LE 90d; plan renew when <= 2 days left) ---"
  local d dir end end_epoch now days
  now=$(date +%s)
  shopt -s nullglob
  for dir in /etc/letsencrypt/live/*/; do
    d="$(basename "$dir")"
    [[ "$d" == "README" ]] && continue
    [[ -f "$dir/fullchain.pem" ]] || continue
    end="$(openssl x509 -enddate -noout -in "$dir/fullchain.pem" 2>/dev/null | cut -d= -f2-)"
    end_epoch=$(date -d "$end" +%s 2>/dev/null) || continue
    days=$(( (end_epoch - now) / 86400 ))
    printf "  %-40s %4d days left\n" "$d" "$days"
  done
  shopt -u nullglob
  echo ""
  echo "Cron: weekly (/etc/cron.d/cecp-certbot-renew). certbot renew only inside LE window (~30d before expiry)."
}

ssl_renew_all() {
  require_root
  panel_log "Renewing only if certbot eligibility window (not a forced early renew)..."
  certbot renew --quiet || certbot renew
  nginx_test_and_reload
  panel_log "Renewal check complete"
}

ssl_remove_for_domain() {
  local domain="${1,,}"
  require_root
  validate_domain "$domain"
  if [[ ! -d "/etc/letsencrypt/live/${domain}" ]]; then
    panel_log "No certificate for $domain — nothing to remove"
    return 0
  fi
  "$CERTBOT_BIN" delete --cert-name "$domain" --non-interactive 2>/dev/null || \
    panel_die "Could not delete cert for $domain"
  # The HTTPS vhost would now point at deleted files and fail the next nginx reload.
  [[ -f "$(site_meta_path "$domain")" ]] && site_render_vhost "$domain"
  ssl_rerender_subsites "$domain"
  nginx_test_and_reload || panel_log "WARN: nginx rejected the config after removing the certificate of $domain"
  panel_log "Removed cert: $domain"
}

# ──────────────────────────────────────────────
# SSL fix — detect Cloudflare vs origin cert conflicts and auto-resolve
# ──────────────────────────────────────────────

ssl_cf_detect_zone() {
  local domain="$1"
  local zone candidate ns
  # Extract root domain (e.g. sub.example.com -> example.com)
  zone="$(python3 -c '
import sys
parts = sys.argv[1].split(".")
if len(parts) > 2 and parts[-2] in ("com", "net", "org", "vn", "info", "io", "co", "me"):
    print(".".join(parts[-3:]))
elif len(parts) > 2:
    print(".".join(parts[-2:]))
else:
    print(".".join(parts))
' "$domain" 2>/dev/null || echo "$domain")"

  # First: try CF API if credentials exist
  if [[ -f "$ETC_DIR/credentials.env" ]]; then
    secure_source "$ETC_DIR/credentials.env"
    if [[ -n "${CF_API_TOKEN:-}" ]]; then
      candidate="$(dns_zone_id "$zone" 2>/dev/null || true)"
      if [[ -n "$candidate" ]]; then
        echo "$zone"; return 0
      fi
    fi
  fi
  # Fallback: check NS records for cloudflare
  if command -v dig &>/dev/null; then
    ns="$(dig +short NS "$zone" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    if echo "$ns" | grep -q 'cloudflare\.com'; then
      echo "$zone"; return 0
    fi
  fi
  return 1
}

ssl_cf_has_credentials() {
  [[ -f "$ETC_DIR/credentials.env" ]] || return 1
  secure_source "$ETC_DIR/credentials.env"
  [[ -n "${CF_API_TOKEN:-}" ]]
}

ssl_cf_get_a_proxy() {
  local domain="$1" zone="$2"
  ssl_cf_has_credentials || return 1
  local zid
  zid="$(dns_zone_id "$zone" 2>/dev/null)" || return 1
  [[ -n "$zid" ]] || return 1
  dns_cf_api GET "/zones/${zid}/dns_records?type=A&name=${domain}" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(1)
results = d.get('result') or []
if results:
    r = results[0]
    print(json.dumps({'proxied': r.get('proxied', False), 'content': r.get('content', ''), 'id': r.get('id', '')}))
else:
    print(json.dumps({'proxied': None, 'content': '', 'id': ''}))
" 2>/dev/null || echo '{"proxied":null,"content":"","id":""}'
}

# Heuristic: detect CF proxy without API credentials
ssl_cf_detect_proxy_heuristic() {
  local domain="$1"
  # Method 1: Check if HTTP response has cf-ray header (definite proxy)
  local cf_ray
  cf_ray="$(curl -4 -sI -m 5 "http://${domain}/" 2>/dev/null | grep -i '^cf-ray:' | head -1 || true)"
  if [[ -n "$cf_ray" ]]; then
    echo "true"
    return 0
  fi
  # Method 2: DNS resolves to VPS IP? If not, and CF NS → likely proxied
  local my_ip dns_ip
  my_ip="$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || panel_local_ipv4)"
  dns_ip="$(dig +short A "$domain" 2>/dev/null | grep -v '\.$' | head -1 || true)"
  if [[ -n "$dns_ip" && -n "$my_ip" ]]; then
    if [[ "$dns_ip" != "$my_ip" ]]; then
      # DNS points elsewhere — likely CF proxy edge IPs
      # CF edge IPs are in 104.x, 172.64.x, etc — but simple mismatch is enough hint
      echo "likely_true"
      return 0
    fi
  fi
  # Method 3: HTTPS response has CF headers
  cf_ray="$(curl -4 -sI -m 5 "https://${domain}/" 2>/dev/null | grep -i '^cf-ray:' | head -1 || true)"
  if [[ -n "$cf_ray" ]]; then
    echo "true"
    return 0
  fi
  echo "false"
}

ssl_cf_get_ssl_mode() {
  local zone="$1"
  ssl_cf_has_credentials || return 1
  local zid
  zid="$(dns_zone_id "$zone" 2>/dev/null)" || return 1
  [[ -n "$zid" ]] || return 1
  dns_cf_api GET "/zones/${zid}/settings/ssl" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('success'): print(json.dumps(d.get('result',{})))
" 2>/dev/null || true
}

ssl_cf_set_ssl_mode() {
  local zone="$1" mode="$2"
  ssl_cf_has_credentials || return 1
  local zid
  zid="$(dns_zone_id "$zone" 2>/dev/null)" || return 1
  dns_cf_api PATCH "/zones/${zid}/settings/ssl" "{\"value\":\"${mode}\"}" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print('Cloudflare SSL mode ->', d['result']['value'])
"
}

ssl_cf_set_proxy() {
  local domain="$1" zone="$2" proxied="$3" rec_id="$4"
  ssl_cf_has_credentials || return 1
  local zid
  zid="$(dns_zone_id "$zone" 2>/dev/null)" || return 1
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"proxied": sys.argv[1].lower() in ("true", "1")}))' "$proxied")"
  dns_cf_api PATCH "/zones/${zid}/dns_records/${rec_id}" "$body" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print(d['result']['name'], 'proxied ->', d['result'].get('proxied'))
"
}

ssl_fix_for_domain() {
  local domain="${1,,}"
  local auto_mode="${2:-no}"
  require_root
  validate_domain "$domain"
  [[ -n "$domain" ]] || panel_die "Usage: cecp-panel ssl fix DOMAIN [--auto]"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain (run: cecp-panel site add $domain)"

  echo "═══════════════════════════════════════════"
  echo " SSL Fix: $domain"
  echo "═══════════════════════════════════════════"

  # ── 1. Gather facts ──
  local cf_zone cf_has_api
  cf_zone="$(ssl_cf_detect_zone "$domain" 2>/dev/null)" || true
  cf_has_api=false
  ssl_cf_has_credentials && cf_has_api=true

  local has_le=false
  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && has_le=true

  local nginx_ssl_conf
  nginx_ssl_conf="/etc/nginx/conf.d/cecp-$(domain_slug "$domain").conf"
  local nginx_has_ssl=false
  grep -q "listen.*443 ssl" "$nginx_ssl_conf" 2>/dev/null && nginx_has_ssl=true

  local my_ip
  my_ip="$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || panel_local_ipv4)"

  echo ""
  echo "  Cloudflare       : ${cf_zone:-none (direct DNS)}"
  echo "  CF API available : $cf_has_api"
  echo "  Let's Encrypt    : $has_le"
  echo "  Nginx SSL conf   : $nginx_has_ssl"
  echo "  VPS IP           : ${my_ip:-unknown}"
  echo ""

  local answer="n"

  # ── 2. Determine proxy state ──
  if [[ -n "$cf_zone" ]]; then
    local cf_proxied="" cf_ssl_mode="" cf_record_ip=""

    # Try API first
    if $cf_has_api; then
      local cf_proxy_json cf_ssl_json
      cf_proxy_json="$(ssl_cf_get_a_proxy "$domain" "$cf_zone" 2>/dev/null || echo '{}')"
      cf_proxied="$(echo "$cf_proxy_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('proxied', ''))" 2>/dev/null || echo '')"
      cf_record_ip="$(echo "$cf_proxy_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('content', ''))" 2>/dev/null || echo '')"
      cf_ssl_json="$(ssl_cf_get_ssl_mode "$cf_zone" 2>/dev/null || echo '{}')"
      cf_ssl_mode="$(echo "$cf_ssl_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('value', ''))" 2>/dev/null || echo '')"
    fi

    # Fallback: heuristic when no API
    local heuristic_proxy=""
    if [[ -z "$cf_proxied" || "$cf_proxied" == "None" ]]; then
      heuristic_proxy="$(ssl_cf_detect_proxy_heuristic "$domain" 2>/dev/null)" || heuristic_proxy="false"
      if [[ "$heuristic_proxy" == "true" ]]; then
        cf_proxied="True"
        panel_log "Proxy detected via cf-ray / DNS mismatch heuristic"
      elif [[ "$heuristic_proxy" == "likely_true" ]]; then
        cf_proxied="True"
        panel_log "Proxy likely (DNS resolves to non-VPS IP) — treating as proxied"
      else
        cf_proxied="False"
        panel_log "No CF proxy detected (DNS points directly to VPS)"
      fi
    fi

    # Display diagnostics
    if [[ -n "$cf_record_ip" && "$cf_record_ip" != "" ]]; then
      echo "  CF A record      : $cf_record_ip (proxied=$cf_proxied)"
    else
      echo "  CF A record      : ${heuristic_proxy:+heuristic → }proxied=$cf_proxied"
    fi
    if [[ -n "$cf_ssl_mode" ]]; then
      echo "  CF SSL mode      : ${cf_ssl_mode}"
    elif $cf_has_api; then
      echo "  CF SSL mode      : unknown (could not read)"
    else
      echo "  CF SSL mode      : unknown (no CF API — check manually in dashboard)"
    fi
    echo ""

    # ── 3. Conflict detection + fix ──
    if [[ "$cf_proxied" == "True" || "$cf_proxied" == "true" ]]; then
      if $has_le; then
        if [[ "$cf_ssl_mode" == "flexible" || "$cf_ssl_mode" == "off" ]]; then
          echo "  ⚠  CONFLICT DETECTED"
          echo "     CF proxied + ${cf_ssl_mode} mode → CF calls HTTP to origin"
          echo "     But nginx redirects HTTP→HTTPS (LE cert present)"
          echo "     Result: redirect loop or SSL errors"
          echo ""
          if $cf_has_api; then
            echo "  → Fix: Set CF SSL mode to Full (strict)"
            echo "     CF will connect to origin via HTTPS, trusting your LE cert"
            if [[ "$auto_mode" == "yes" ]]; then
              answer="y"
            else
              read -r -p "  Apply this fix? [Y/n] " answer
              answer="${answer:-y}"
            fi
            if [[ "$answer" =~ ^[Yy]$ ]]; then
              ssl_cf_set_ssl_mode "$cf_zone" "strict" && \
                panel_log "SSL fixed: CF SSL mode → strict for $domain" || \
                echo "  ✗ Failed. Update manually in CF dashboard: SSL/TLS → Full (strict)"
            fi
          else
            echo "  → Manual fix needed:"
            echo "     1. Go to Cloudflare Dashboard → ${cf_zone} → SSL/TLS"
            echo "     2. Set encryption mode to: Full (strict)"
            echo "     Or configure CF API credentials: /etc/cecp-panel/credentials.env"
          fi
        elif [[ "$cf_ssl_mode" == "full" || "$cf_ssl_mode" == "strict" ]]; then
          echo "  ✓ OK: CF Full/Strict + LE on origin — no conflict"
        elif [[ -z "$cf_ssl_mode" && "$cf_has_api" == "true" ]]; then
          echo "  ⚠  Could not read CF SSL mode. Recommend: Full (strict)"
          if [[ "$auto_mode" == "yes" ]]; then
            answer="y"
          else
            read -r -p "  Set CF SSL mode to strict? [Y/n] " answer
            answer="${answer:-y}"
          fi
          if [[ "$answer" =~ ^[Yy]$ ]]; then
            ssl_cf_set_ssl_mode "$cf_zone" "strict" || echo "  ✗ Failed"
          fi
        else
          echo "  ⚠  CF SSL mode unknown (no API access)"
          echo "  → Verify in CF dashboard: SSL/TLS should be Full (strict), not Flexible"
          echo "     Flexible + origin LE cert = redirect loop"
        fi
      else
        echo "  ✓ CF proxied, no origin LE cert — CF edge SSL handles HTTPS"
        if [[ "$cf_ssl_mode" == "flexible" ]]; then
          echo "  ⚠  Flexible mode: CF-to-origin traffic is unencrypted HTTP"
          echo "  → Best practice: install LE + switch to Full (strict)"
          echo "     Run: cecp-panel ssl issue $domain"
          if [[ "$auto_mode" != "yes" ]]; then
            read -r -p "  Issue Let's Encrypt now? [Y/n] " answer
            answer="${answer:-y}"
          fi
          if [[ "$answer" =~ ^[Yy]$ ]]; then
            ssl_issue_for_domain "$domain"
            if $cf_has_api; then
              ssl_cf_set_ssl_mode "$cf_zone" "strict" || true
            fi
          fi
        fi
      fi
    elif [[ "$cf_proxied" == "False" || "$cf_proxied" == "false" ]]; then
      if ! $has_le; then
        echo "  ⚠  CF DNS-only, no origin cert — users get SSL warnings"
        echo "  → Run: cecp-panel ssl issue $domain"
        if [[ "$auto_mode" == "yes" ]]; then
          answer="y"
        else
          read -r -p "  Issue Let's Encrypt now? [Y/n] " answer
          answer="${answer:-y}"
        fi
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          ssl_issue_for_domain "$domain"
        fi
      else
        echo "  ✓ CF DNS-only + LE on origin — OK"
      fi
    else
      echo "  ⚠  Cannot determine CF proxy state"
      echo "  → Check CF dashboard: DNS → $domain → orange/gray cloud"
      if ! $has_le; then
        echo "  → Regardless, SSL is missing on origin"
        if [[ "$auto_mode" == "yes" ]]; then
          answer="y"
        else
          read -r -p "  Issue Let's Encrypt? [Y/n] " answer
          answer="${answer:-y}"
        fi
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          ssl_issue_for_domain "$domain"
        fi
      fi
    fi
  else
    # ── No Cloudflare — direct DNS ──
    if $has_le && $nginx_has_ssl; then
      echo "  ✓ Direct DNS + LE cert — OK"
    elif $has_le && ! $nginx_has_ssl; then
      echo "  ⚠  LE cert exists but nginx SSL config missing"
      if [[ "$auto_mode" == "yes" ]]; then
        answer="y"
      else
        read -r -p "  Re-attach LE to nginx? [Y/n] " answer
        answer="${answer:-y}"
      fi
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        ssl_reattach_nginx "$domain"
      fi
    else
      echo "  ⚠  Direct DNS, no SSL"
      if [[ "$auto_mode" == "yes" ]]; then
        answer="y"
      else
        read -r -p "  Issue Let's Encrypt? [Y/n] " answer
        answer="${answer:-y}"
      fi
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        ssl_issue_for_domain "$domain"
      fi
    fi
  fi

  echo ""
  echo "═══════════════════════════════════════════"
  echo " Done."
  echo "═══════════════════════════════════════════"
}

ssl_fix_all() {
  require_root
  panel_log "SSL fix for all sites..."
  local f domain count=0
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f" 2>/dev/null)" || continue
    [[ -n "$domain" ]] || continue
    count=$((count + 1))
    echo ""
    ssl_fix_for_domain "$domain" "yes"
  done
  if [[ $count -eq 0 ]]; then
    panel_log "No sites found."
  else
    panel_log "Checked $count site(s)."
  fi
}
