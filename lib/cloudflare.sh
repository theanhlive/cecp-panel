#!/usr/bin/env bash
# Cloudflare edge helpers (purge, cache level, brotli recommendation)
set -euo pipefail

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

cf_purge() {
  local target="${1:-}"
  require_root
  cf_load
  local zone zid
  if [[ -z "$target" || "$target" == "--all" || "$target" == "all" ]]; then
    zone="$CF_DEFAULT_ZONE"
  elif [[ "$target" == http* ]]; then
    panel_die "Pass zone or domain, not full URL (or use cf purge-url)"
  else
    zone="$(cf_zone_for_domain "$target")"
  fi
  [[ -n "$zone" ]] || panel_die "No zone resolved"
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  panel_log "Cloudflare purge everything zone=$zone ..."
  dns_cf_api POST "/zones/${zid}/purge_cache" '{"purge_everything":true}' | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'):
    raise SystemExit(str(d.get('errors') or d))
print('CF purge OK:', '$zone')
"
  # also purge origin FastCGI if available
  if declare -F optimize_purge_cache >/dev/null 2>&1; then
    optimize_purge_cache all 2>/dev/null || true
  fi
}

cf_purge_url() {
  local url="${1:-}"
  require_root
  [[ -n "$url" ]] || panel_die "Usage: cecp-panel cf purge-url https://domain/path"
  cf_load
  local host zone zid
  host="$(python3 -c "from urllib.parse import urlparse; print(urlparse('$url').hostname or '')")"
  [[ -n "$host" ]] || panel_die "Invalid URL"
  zone="$(cf_zone_for_domain "$host")"
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found for $host"
  local body
  body="$(python3 -c "import json; print(json.dumps({'files':['$url']}))")"
  dns_cf_api POST "/zones/${zid}/purge_cache" "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'):
    raise SystemExit(str(d.get('errors') or d))
print('CF purge URL OK')
"
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
  dns_cf_api PATCH "/zones/${zid}/settings/cache_level" "{\"value\":\"${level}\"}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print('CF cache_level →', d['result']['value'])
"
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
  dns_cf_api PATCH "/zones/${zid}/settings/brotli" "{\"value\":\"${val}\"}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print('CF brotli →', d['result']['value'])
"
}

cf_set_minify() {
  local zone="${1:-}"
  require_root
  cf_load
  zone="${zone:-$CF_DEFAULT_ZONE}"
  local zid
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  dns_cf_api PATCH "/zones/${zid}/settings/minify" \
    '{"value":{"css":"on","html":"on","js":"on"}}' | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print('CF minify css/html/js ON')
"
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
  local zid
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  echo "=== Cloudflare zone: $zone ($zid) ==="
  for s in ssl brotli cache_level minify security_level; do
    dns_cf_api GET "/zones/${zid}/settings/${s}" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('result') or {}
print(f\"  {r.get('id','$s'):20} = {r.get('value')}\")
" 2>/dev/null || echo "  $s = (unavailable)"
  done
}
