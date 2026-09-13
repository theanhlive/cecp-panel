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

# ---------------------------------------------------------------------------
# Edge HTML cache (Cache Rules). One rule per site, identified by its description, in the
# zone's http_request_cache_settings entrypoint; every other rule in that ruleset is kept.
# ---------------------------------------------------------------------------
cf_edge_rule_desc() { echo "cecp-panel: $1"; }

# Build the new entrypoint body from the current one (stdin): drop our rule for DOMAIN and,
# if TTL > 0, append a fresh one. Prints the JSON body for PUT.
cf_edge_rules_payload() {
  # The heredoc is python's stdin (the script), so the current ruleset travels in the env.
  local current
  current="$(cat)"
  CF_CURRENT_RULESET="$current" python3 - "$1" "$2" <<'PY'
import json, os, sys
domain, ttl = sys.argv[1], int(sys.argv[2])
try:
    cur = json.loads(os.environ.get("CF_CURRENT_RULESET") or "{}")
except ValueError:
    cur = {}
rules = (cur.get("result") or {}).get("rules") or [] if cur.get("success") else []
desc = f"cecp-panel: {domain}"
keep = []
for r in rules:
    if r.get("description") == desc:
        continue
    keep.append({k: r[k] for k in ("id", "description", "expression", "action", "action_parameters", "enabled") if k in r})
if ttl > 0:
    d = json.dumps(domain)
    expr = " and ".join([
        f"(http.host eq {d}",
        'not starts_with(http.request.uri.path, "/wp-admin")',
        'not starts_with(http.request.uri.path, "/wp-json")',
        'not http.request.uri.path in {"/wp-login.php" "/xmlrpc.php" "/wp-cron.php"}',
        'not http.request.uri.path contains "/cart"',
        'not http.request.uri.path contains "/checkout"',
        'not http.request.uri.path contains "/my-account"',
        'not http.request.uri.query contains "s="',
        'not http.request.uri.query contains "preview"',
        'not http.request.uri.query contains "wc-ajax"',
        'not http.request.uri.query contains "add-to-cart"',
        'not http.cookie contains "wordpress_logged_in"',
        'not http.cookie contains "wp-postpass"',
        'not http.cookie contains "woocommerce_items_in_cart"',
        'not http.cookie contains "woocommerce_cart_hash"',
        'not http.cookie contains "comment_author")',
    ])
    keep.append({
        "description": desc, "enabled": True, "expression": expr, "action": "set_cache_settings",
        "action_parameters": {"cache": True,
                              "edge_ttl": {"mode": "override_origin", "default": ttl},
                              "browser_ttl": {"mode": "respect_origin"}},
    })
print(json.dumps({"rules": keep}))
PY
}

cf_ttl_seconds() {
  local t="${1:-1h}" n unit
  [[ "$t" =~ ^([0-9]{1,5})([smhd]?)$ ]] || panel_die "Invalid TTL '$t' (e.g. 30m, 1h, 1d)"
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]:-s}"
  case "$unit" in
    s) echo "$n" ;;
    m) echo $(( n * 60 )) ;;
    h) echo $(( n * 3600 )) ;;
    d) echo $(( n * 86400 )) ;;
  esac
}

# cecp-panel cf edge-cache DOMAIN on [--ttl 1h] | off | status
cf_edge_cache() {
  local domain="${1:-}" action="${2:-status}"
  shift $(( $# < 2 ? $# : 2 ))
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local ttl=3600
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl) ttl="$(cf_ttl_seconds "${2:-}")"; shift 2 || true ;;
      *) panel_die "Usage: cecp-panel cf edge-cache DOMAIN on [--ttl 1h] | off | status" ;;
    esac
  done
  cf_load
  local zone zid path current body resp
  zone="$(cf_zone_for_domain "$domain")"
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || panel_die "Cloudflare zone not found for $domain"
  path="/zones/${zid}/rulesets/phases/http_request_cache_settings/entrypoint"
  current="$(dns_cf_api GET "$path" || true)"
  if [[ "$action" == "status" ]]; then
    python3 -c '
import json, sys
desc = "cecp-panel: " + sys.argv[1]
try:
    rules = (json.loads(sys.stdin.read()).get("result") or {}).get("rules") or []
except ValueError:
    rules = []
r = next((r for r in rules if r.get("description") == desc), None)
print("edge cache: " + ("on, edge TTL %ss" % r["action_parameters"]["edge_ttl"]["default"] if r else "off"))
' "$domain" <<<"$current"
    return 0
  fi
  case "$action" in
    on) (( ttl >= 60 && ttl <= 2592000 )) || panel_die "TTL must be between 60s and 30d" ;;
    off) ttl=0 ;;
    *) panel_die "Usage: cecp-panel cf edge-cache DOMAIN on [--ttl 1h] | off | status" ;;
  esac
  # The PUT replaces the whole ruleset: only build on "success" or "no entrypoint yet" (10003),
  # never on an unreadable response — that would drop the zone's other cache rules.
  python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(1)
sys.exit(0 if d.get("success") or any(e.get("code") == 10003 for e in d.get("errors") or []) else 1)
' <<<"$current" || panel_die "Could not read the zone's cache rules: ${current:0:300} — the API token needs Zone → Cache Rules → Edit"
  body="$(cf_edge_rules_payload "$domain" "$ttl" <<<"$current")"
  resp="$(dns_cf_api PUT "$path" "$body")"
  if ! python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.stdin.read()).get("success") else 1)' <<<"$resp" 2>/dev/null; then
    panel_die "Cloudflare rejected the cache rule: $resp — the API token needs Zone → Cache Rules → Edit"
  fi
  if (( ttl > 0 )); then
    site_json_set "$domain" cf_edge true cf_edge_ttl "$ttl"
    panel_log "Cloudflare edge cache ON for $domain (HTML cached ${ttl}s at the edge; logged-in/cart/admin bypass)"
    [[ "$(site_json_get_or "$domain" cache_autopurge false)" == "True" ]] \
      || panel_log "Tip: cecp-panel cache auto-purge $domain on — purges the edge when content changes"
  else
    site_json_set "$domain" cf_edge false cf_edge_ttl ""
    panel_log "Cloudflare edge cache OFF for $domain"
  fi
}

# Purge a list of URLs (stdin, one per line) at the Cloudflare edge — 30 per API call.
cf_purge_urls() {
  local domain="$1" zone zid body resp
  cf_load
  zone="$(cf_zone_for_domain "$domain")"
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || return 1
  local rc=0
  while IFS= read -r body; do
    [[ -n "$body" ]] || continue
    resp="$(dns_cf_api POST "/zones/${zid}/purge_cache" "$body")"
    python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.stdin.read()).get("success") else 1)' <<<"$resp" 2>/dev/null || rc=1
  done < <(python3 -c '
import json, sys
urls = [u.strip() for u in sys.stdin if u.strip()]
for i in range(0, len(urls), 30):
    print(json.dumps({"files": urls[i:i + 30]}))
')
  return "$rc"
}

# Purge everything cached at the edge for one hostname (not the whole zone).
cf_purge_host() {
  local domain="$1" zone zid resp
  cf_load
  zone="$(cf_zone_for_domain "$domain")"
  zid="$(dns_zone_id "$zone")"
  [[ -n "$zid" ]] || return 1
  resp="$(dns_cf_api POST "/zones/${zid}/purge_cache" "$(python3 -c 'import json,sys; print(json.dumps({"hosts": [sys.argv[1]]}))' "$domain")")"
  python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.stdin.read()).get("success") else 1)' <<<"$resp" 2>/dev/null
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
