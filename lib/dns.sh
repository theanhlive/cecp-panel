#!/usr/bin/env bash
set -euo pipefail

CREDENTIALS_ENV="$ETC_DIR/credentials.env"

dns_load_credentials() {
  [[ -f "$CREDENTIALS_ENV" ]] || panel_die "Missing $CREDENTIALS_ENV (copy from templates/credentials.env.example)"
  secure_source "$CREDENTIALS_ENV"
  [[ -n "${CF_API_TOKEN:-}" ]] || panel_die "Set CF_API_TOKEN in $CREDENTIALS_ENV"
  [[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || panel_die "CF_API_TOKEN has unexpected characters"
  : "${CF_DEFAULT_ZONE:=theanhlive.com}"
  validate_domain "$CF_DEFAULT_ZONE"
}

dns_cf_api() {
  local method="$1" path="$2"
  shift 2
  local body="${1:-}"
  local args=(-sS -X "$method" "${CF_API_BASE:-https://api.cloudflare.com/client/v4}${path}")
  args+=(-H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(-d "$body")
  # Token via a config fd, not argv: other local users (site users) can read argv from /proc.
  curl "${args[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN")
}

dns_zone_id() {
  local zone="$1"
  validate_domain "$zone"
  dns_cf_api GET "/zones?name=${zone}&status=active" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
r=d.get('result') or []
print(r[0]['id'] if r else '')
" 
}

dns_add_a() {
  local name="${1,,}" ip="$2" proxied="${3:-true}"
  require_root
  validate_dns_name "$name"
  validate_ipv4 "$ip"
  dns_load_credentials
  local zone="$CF_DEFAULT_ZONE" sub fqdn
  if [[ "$name" == *.* ]]; then
    fqdn="${name,,}"
    zone="${fqdn#*.}"
    sub="${fqdn%%.${zone}}"
    [[ "$sub" == "$fqdn" ]] && panel_die "Cannot parse domain: $name"
  else
    sub="$name"
    fqdn="${sub}.${zone}"
  fi
  local zid
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  local proxied_flag="True"
  [[ "$proxied" == "false" || "$proxied" == "no" || "$proxied" == "0" ]] && proxied_flag="False"
  local existing
  existing="$(dns_cf_api GET "/zones/${zid}/dns_records?type=A&name=${fqdn}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print((d.get('result') or [{}])[0].get('id',''))
")"
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],"proxied":sys.argv[3]=="True","ttl":1}))' "$fqdn" "$ip" "$proxied_flag")"
  if [[ -n "$existing" ]]; then
    dns_cf_api PUT "/zones/${zid}/dns_records/${existing}" "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print('Updated', d['result']['name'], '→', d['result']['content'])
"
  else
    dns_cf_api POST "/zones/${zid}/dns_records" "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print('Created', d['result']['name'], '→', d['result']['content'])
"
  fi
}

dns_list_a() {
  dns_load_credentials
  local zid
  zid="$(dns_zone_id "$CF_DEFAULT_ZONE")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $CF_DEFAULT_ZONE"
  dns_cf_api GET "/zones/${zid}/dns_records?type=A&per_page=100" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('result') or []:
    print(f\"{r['name']:40} {r['content']:16} proxied={r.get('proxied')}\")
"
}

dns_point_site() {
  local domain="${1,,}"
  local ip="${2:-}"
  [[ -n "$domain" ]] || panel_die "Usage: cecp-panel dns point DOMAIN [IP]"
  validate_domain "$domain"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
  fi
  validate_ipv4 "$ip"
  local sub="${domain%%.*}"
  dns_add_a "$sub" "$ip" "${3:-true}"
}

dns_set_ssl_mode() {
  local mode="${1:-}"
  local zone="${2:-}"
  require_root
  dns_load_credentials
  zone="${zone:-$CF_DEFAULT_ZONE}"
  validate_domain "$zone"
  case "$mode" in
    off|flexible|full|strict) ;;
    *) panel_die "Usage: cecp-panel dns ssl-mode off|flexible|full|strict [ZONE]" ;;
  esac
  local zid
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Zone not found: $zone"
  dns_cf_api PATCH "/zones/${zid}/settings/ssl" "{\"value\":\"${mode}\"}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d.get('success'): raise SystemExit(d.get('errors',d))
print('Cloudflare SSL mode →', d['result']['value'])
"
  panel_log "Zone $zone SSL/TLS encryption mode: $mode"
}
