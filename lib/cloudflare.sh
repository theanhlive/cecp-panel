#!/usr/bin/env bash
# Cloudflare edge helpers (purge, cache level, brotli recommendation)
set -euo pipefail

CF_REALIP_CONF="/etc/nginx/conf.d/cecp-cloudflare-realip.conf"
CF_IPS_FILE="$ETC_DIR/cloudflare-ips.txt"

# Write the nginx real-IP config (+ the plain list used by fail2ban ignoreip) from a CIDR list.
cf_realip_render() {
  local src="$1"
  mkdir -p "$ETC_DIR"
  python3 - "$src" "$CF_REALIP_CONF" "$CF_IPS_FILE" <<'PY'
import ipaddress, sys
src, conf, ips_out = sys.argv[1:4]
nets = []
for line in open(src, encoding="utf-8"):
    s = line.strip()
    if s and not s.startswith("#"):
        nets.append(str(ipaddress.ip_network(s, strict=True)))
if len(nets) < 10:
    sys.exit(f"cf_realip_render: only {len(nets)} ranges in {src}")
with open(conf, "w", encoding="utf-8") as f:
    f.write("# CECP Panel — real client IP behind Cloudflare. Managed file: cecp-panel cf realip\n")
    f.write("# Only Cloudflare edges may set CF-Connecting-IP; direct visitors keep their own IP.\n")
    for n in nets:
        f.write(f"set_real_ip_from {n};\n")
    f.write("real_ip_header CF-Connecting-IP;\n")
with open(ips_out, "w", encoding="utf-8") as f:
    f.write("\n".join(nets) + "\n")
PY
  chmod 644 "$CF_REALIP_CONF" "$CF_IPS_FILE"
}

# cecp-panel cf realip — refresh Cloudflare ranges (weekly cron), fall back to the bundled list.
cf_realip_update() {
  require_root
  local tmp
  tmp="$(mktemp)"
  if curl -fsS -m 15 https://www.cloudflare.com/ips-v4 >"$tmp" && echo >>"$tmp" \
     && curl -fsS -m 15 https://www.cloudflare.com/ips-v6 >>"$tmp" \
     && cf_realip_render "$tmp" 2>/dev/null; then
    panel_log "Cloudflare IP ranges refreshed ($(grep -c . "$CF_IPS_FILE") ranges)"
  else
    panel_log "WARN: could not fetch Cloudflare IP ranges — using the bundled list"
    cf_realip_render "$PANEL_ROOT/templates/cloudflare-ips.txt"
  fi
  rm -f "$tmp"
  printf '17 4 * * 1 root /usr/local/bin/cecp-panel cf realip >/dev/null 2>&1\n' >/etc/cron.d/cecp-cf-realip
  chmod 644 /etc/cron.d/cecp-cf-realip
  nginx_test_and_reload || panel_die "nginx rejected the real-IP config (rolled back)"
  if [[ -f /etc/fail2ban/jail.d/cecp-00-defaults.conf ]]; then
    security_fail2ban_defaults
    systemctl reload fail2ban 2>/dev/null || true
  fi
}

cf_load() {
  # shellcheck source=/dev/null
  source "$PANEL_ROOT/lib/dns.sh"
  dns_load_credentials
}

cf_zone_for_domain() {
  local domain="${1,,}"
  # try full domain as zone, then parent
  local zid
  zid="$(dns_zone_id "$domain" 2>/dev/null || true)"
  if [[ -n "$zid" ]]; then echo "$domain"; return 0; fi
  local parent="${domain#*.}"
  if [[ "$parent" != "$domain" ]]; then
    zid="$(dns_zone_id "$parent" 2>/dev/null || true)"
    if [[ -n "$zid" ]]; then echo "$parent"; return 0; fi
  fi
  echo "${CF_DEFAULT_ZONE:-}"
}

# Exit non-zero with the API errors unless a Cloudflare response says success.
cf_check_response() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("success"):
    raise SystemExit(str(d.get("errors") or d))
print(sys.argv[1])
' "$1"
}

cf_purge() {
  local target="${1:-}"
  require_root
  cf_load
  local zone zid origin_target="all"
  if [[ -z "$target" || "$target" == "--all" || "$target" == "all" ]]; then
    zone="$CF_DEFAULT_ZONE"
  elif [[ "$target" == http* ]]; then
    panel_die "Pass zone or domain, not full URL (or use cf purge-url)"
  else
    target="${target,,}"
    validate_domain "$target"
    zone="$(cf_zone_for_domain "$target")"
    [[ -f "$(site_meta_path "$target")" ]] && origin_target="$target"
  fi
  [[ -n "$zone" ]] || panel_die "No zone resolved"
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  panel_log "Cloudflare purge everything zone=$zone ..."
  dns_cf_api POST "/zones/${zid}/purge_cache" '{"purge_everything":true}' | cf_check_response "CF purge OK: $zone"
  if declare -F optimize_purge_cache >/dev/null 2>&1; then
    optimize_purge_cache "$origin_target" || true
  fi
}

cf_purge_url() {
  local url="${1:-}"
  require_root
  [[ -n "$url" ]] || panel_die "Usage: cecp-panel cf purge-url https://domain/path"
  validate_url "$url"
  cf_load
  local host zone zid body
  host="$(python3 -c 'import sys; from urllib.parse import urlparse; print(urlparse(sys.argv[1]).hostname or "")' "$url")"
  validate_domain "$host"
  zone="$(cf_zone_for_domain "$host")"
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found for $host"
  body="$(python3 -c 'import json,sys; print(json.dumps({"files": [sys.argv[1]]}))' "$url")"
  dns_cf_api POST "/zones/${zid}/purge_cache" "$body" | cf_check_response "CF purge URL OK"
  if declare -F optimize_purge_url >/dev/null 2>&1; then
    optimize_purge_url "$url" || true
  fi
}

cf_set_cache_level() {
  local level="${1:-aggressive}"
  local zone="${2:-}"
  require_root
  cf_load
  zone="${zone:-$CF_DEFAULT_ZONE}"
  case "$level" in
    aggressive|basic|simplified) ;;
    *) panel_die "Usage: cecp-panel cf cache-level aggressive|basic|simplified [ZONE]" ;;
  esac
  local zid
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  dns_cf_api PATCH "/zones/${zid}/settings/cache_level" "{\"value\":\"${level}\"}" \
    | cf_check_response "CF cache_level → ${level}"
}

cf_set_brotli() {
  local onoff="${1:-on}"
  local zone="${2:-}"
  require_root
  cf_load
  zone="${zone:-$CF_DEFAULT_ZONE}"
  local val="on"
  [[ "$onoff" == "off" || "$onoff" == "0" ]] && val="off"
  local zid
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  dns_cf_api PATCH "/zones/${zid}/settings/brotli" "{\"value\":\"${val}\"}" \
    | cf_check_response "CF brotli → ${val}"
}

cf_set_minify() {
  echo "Cloudflare retired Auto Minify (August 2024); the API setting no longer exists."
  echo "Minify at build time or with a WordPress optimisation plugin instead."
}

cf_recommend() {
  cat <<'EOF'
=== Cloudflare edge recommendations (WordPress) ===
1. SSL/TLS mode: Full (strict) — after origin has valid LE cert
   cecp-panel dns ssl-mode strict
2. Brotli: ON
   cecp-panel cf brotli on
3. Cache Level: Standard/aggressive for mostly-static WP
   cecp-panel cf cache-level aggressive
4. Purge after deploy:
   cecp-panel cf purge example.com
5. Optional: APO for WordPress (Cloudflare dashboard / paid)
6. Always Online + Under Attack mode only when needed
EOF
}

cf_status() {
  require_root
  cf_load
  local zone="${1:-$CF_DEFAULT_ZONE}"
  zone="${zone,,}"
  local zid
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  echo "=== Cloudflare zone: $zone ($zid) ==="
  for s in ssl brotli cache_level security_level; do
    dns_cf_api GET "/zones/${zid}/settings/${s}" 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin).get("result") or {}
print("  %-20s = %s" % (r.get("id", sys.argv[1]), r.get("value")))
' "$s" 2>/dev/null || echo "  $s = (unavailable)"
  done
}
