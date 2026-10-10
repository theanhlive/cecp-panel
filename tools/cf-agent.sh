#!/usr/bin/env bash
# cf-agent.sh — audit and change one Cloudflare zone from the OPERATOR machine (where the AI agent
# runs), not from a VPS. Standalone: needs only bash, curl and python3; no panel libraries.
#
# Token: env CF_API_TOKEN, else the file named by CF_API_TOKEN_FILE. Never an argument. It travels
# to curl as a config on stdin (curl -K -), so it is not in argv / ps, and is never printed.
# Default is read-only. Guide: docs/CLOUDFLARE_AGENT_TOKEN.md
set -euo pipefail

CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
SNAP_DIR="${CF_SNAPSHOT_DIR:-./cf-snapshots}"
CF_TIMEOUT="${CF_TIMEOUT:-30}"
CF_TOKEN=""
CF_WRITE_OK=0
TMPD=""

usage() {
  cat <<'EOF'
Usage: cf-agent.sh COMMAND [ARGS]

Read-only:
  verify                         check the token, list the permission groups it can see
  zones                          zones visible to the token
  audit DOMAIN [--json]          zone, DNS proxy state, SSL mode, HTTPS, brotli, cache level,
                                 Cache Rules, WAF custom rules; flags risky settings
  snapshot DOMAIN                save settings + DNS + rulesets to ./cf-snapshots/<zone>-<ts>.json

Changes (each takes a snapshot first and prints before/after):
  apply DOMAIN [--ssl-strict --yes-i-approved] [--brotli] [--cache-level aggressive|basic|simplified]
               [--static-cache-rules]
               [--html-cache [--ttl 1h] --yes-i-approved]   HTML edge cache, same bypass as
                                                            "cecp-panel cf edge-cache"
               [--proxy-record FQDN --allow-dns]            turn on the Cloudflare proxy for a record
  rollback SNAPSHOT_FILE [--allow-dns]                      restore settings + Cache Rules
                                                            (+ DNS proxy state with --allow-dns)

Token: export CF_API_TOKEN, or CF_API_TOKEN_FILE=/path/to/git-ignored/file. Never pass it as an argument.
"Cache Everything" is never offered.
EOF
}

redact() {
  local s="$*"
  [[ -n "$CF_TOKEN" ]] && s="${s//"$CF_TOKEN"/[REDACTED]}"
  printf '%s' "$s"
}

die() {
  printf 'cf-agent: %s\n' "$(redact "$*")" >&2
  exit 1
}

refuse() {
  printf 'cf-agent: REFUSED: %s\n' "$*" >&2
  exit 3
}

cleanup() { [[ -n "$TMPD" && -d "$TMPD" ]] && rm -rf "$TMPD"; return 0; }

need_tools() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
}

validate_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "invalid domain: $1"
}

load_token() {
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    CF_TOKEN="$CF_API_TOKEN"
  elif [[ -n "${CF_API_TOKEN_FILE:-}" ]]; then
    [[ -r "$CF_API_TOKEN_FILE" ]] || die "CF_API_TOKEN_FILE is not readable: $CF_API_TOKEN_FILE"
    CF_TOKEN="$(tr -d ' \t\r\n' <"$CF_API_TOKEN_FILE")"
  else
    die "no token: export CF_API_TOKEN or set CF_API_TOKEN_FILE (see docs/CLOUDFLARE_AGENT_TOKEN.md)"
  fi
  unset CF_API_TOKEN
  [[ -n "$CF_TOKEN" ]] || die "the token is empty"
  [[ "$CF_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || { CF_TOKEN=""; die "the token has unexpected characters"; }
}

# curl config on stdin: the token never reaches argv. The body is JSON on one line.
curl_config() {
  local body="$1"
  printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN"
  printf 'header = "Content-Type: application/json"\n'
  if [[ -n "$body" ]]; then
    printf 'data-binary = "%s"\n' "$(printf '%s' "$body" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  fi
}

# api METHOD PATH OUTFILE [BODY] — response JSON goes to OUTFILE.
api() {
  local method="$1" path="$2" out="$3" body="${4:-}"
  if [[ "$method" != "GET" && "$CF_WRITE_OK" != "1" ]]; then
    die "internal: $method $path refused in read-only mode"
  fi
  if ! curl_config "$body" | curl -sS -m "$CF_TIMEOUT" -X "$method" "${CF_API_BASE}${path}" -K - \
      >"$out" 2>"$TMPD/curl.err"; then
    die "API $method $path failed: $(head -c 300 "$TMPD/curl.err")"
  fi
}

# All JSON work. Data arrives as file paths in argv (stdin is this script).
py() {
  python3 - "$@" <<'PY'
import json, os, sys, time

MANAGED = ("ssl", "always_use_https", "brotli", "cache_level")
STATIC_EXT = ("css", "js", "mjs", "png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "ico",
              "woff", "woff2", "ttf", "otf", "eot", "mp4", "webm", "pdf")
NON_WEB = ("mail.", "smtp.", "imap.", "pop.", "pop3.", "ftp.", "autodiscover.", "autoconfig.",
           "cpanel.", "webmail.", "_")


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def ok(d):
    return isinstance(d, dict) and bool(d.get("success"))


def errs(d):
    if not isinstance(d, dict):
        return "unexpected response"
    e = d.get("errors") or []
    return "; ".join(f"{x.get('code')}: {x.get('message')}" for x in e if isinstance(x, dict)) or "unexpected response"


def no_entrypoint(d):
    return isinstance(d, dict) and any(isinstance(e, dict) and e.get("code") == 10003 for e in d.get("errors") or [])


def settings_map(d):
    r = d.get("result") if ok(d) else None
    if isinstance(r, list):
        return {s.get("id"): s.get("value") for s in r if isinstance(s, dict)}
    return {}


def rules_of(d):
    if not ok(d):
        return []
    return (d.get("result") or {}).get("rules") or []


def keep_rule(r):
    return {k: r[k] for k in ("id", "description", "expression", "action", "action_parameters", "enabled") if k in r}


def norm_rule(r):
    return {k: r[k] for k in ("description", "expression", "action", "action_parameters", "enabled") if k in r}


def html_rule(domain, ttl):
    # Must stay identical to cf_edge_rules_payload in lib/cloudflare.sh (cecp-panel cf edge-cache).
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
    return {
        "description": f"cecp-panel: {domain}", "enabled": True, "expression": expr, "action": "set_cache_settings",
        "action_parameters": {"cache": True,
                              "edge_ttl": {"mode": "override_origin", "default": ttl},
                              "browser_ttl": {"mode": "respect_origin"}},
    }


def static_rule(domain):
    exts = " ".join(json.dumps(e) for e in STATIC_EXT)
    expr = "(http.host eq " + json.dumps(domain) + " and http.request.uri.path.extension in {" + exts + "})"
    return {
        "description": f"cf-agent static: {domain}", "enabled": True, "expression": expr, "action": "set_cache_settings",
        "action_parameters": {"cache": True,
                              "edge_ttl": {"mode": "override_origin", "default": 2592000},
                              "browser_ttl": {"mode": "respect_origin"}},
    }


def web_records(d):
    out = []
    for r in (d.get("result") or []) if ok(d) else []:
        if isinstance(r, dict) and r.get("type") in ("A", "AAAA", "CNAME"):
            out.append(r)
    return out


def is_web_name(name):
    return not any(name.startswith(p) for p in NON_WEB)


def rule_summary(rules, domain):
    descs = [r.get("description") or "(no description)" for r in rules]
    html = f"cecp-panel: {domain}" in descs
    static = f"cf-agent static: {domain}" in descs
    return f"{len(rules)} rule(s); html edge cache={'on' if html else 'off'}; static rule={'on' if static else 'off'}"


def cmd_zone_id(path, cand):
    d = load(path)
    if not ok(d):
        sys.exit("zone lookup failed: " + errs(d))
    r = d.get("result") or []
    if r:
        print(f"{r[0].get('id', '')}\t{r[0].get('name') or cand}")


def cmd_verify(vpath, ppath):
    v = load(vpath)
    if not ok(v):
        sys.exit("token verify failed: " + errs(v))
    r = v.get("result") or {}
    print(f"token status: {r.get('status', '?')}" + (f", expires {r['expires_on']}" if r.get("expires_on") else ""))
    p = load(ppath)
    if ok(p):
        names = sorted({g.get("name", "?") for g in p.get("result") or [] if isinstance(g, dict)})
        print(f"permission groups visible to this token: {len(names)}")
        for n in names:
            print(f"  - {n}")
    else:
        print("permission groups: not visible to this token (" + errs(p) + ") — check the token in the dashboard")


def cmd_zones(path):
    d = load(path)
    if not ok(d):
        sys.exit("zone list failed: " + errs(d))
    for z in d.get("result") or []:
        plan = (z.get("plan") or {}).get("name", "")
        print(f"{z.get('name', '?'):40} {z.get('status', '?'):10} {plan}")


def cmd_audit(domain, zone, zid, spath, dpath, cpath, wpath, as_json):
    s, dn, c, w = load(spath), load(dpath), load(cpath), load(wpath)
    findings = []

    def add(level, code, msg):
        findings.append({"level": level, "code": code, "message": msg})

    settings = settings_map(s)
    if not ok(s):
        add("WARN", "settings_unreadable", "cannot read zone settings (" + errs(s) + ") — token needs Zone Settings Read")
    ssl = settings.get("ssl")
    if ssl in ("off", "flexible"):
        add("FAIL", "ssl_mode", f"SSL mode is '{ssl}': use Full (strict) after the origin has a valid certificate")
    elif ssl == "full":
        add("WARN", "ssl_mode", "SSL mode is 'full': prefer 'strict' (origin certificate is not validated)")
    if settings.get("always_use_https") == "off":
        add("WARN", "always_use_https", "Always Use HTTPS is off")
    if settings.get("brotli") == "off":
        add("WARN", "brotli", "Brotli is off")

    dns = []
    if not ok(dn):
        add("WARN", "dns_unreadable", "cannot read DNS records (" + errs(dn) + ") — token needs DNS Read")
    for r in web_records(dn):
        name = r.get("name", "")
        dns.append({"type": r.get("type"), "name": name, "proxied": bool(r.get("proxied"))})
        if not r.get("proxied") and is_web_name(name):
            add("WARN", "unproxied", f"{r.get('type')} {name} is not proxied (origin IP exposed, no edge cache/WAF)")

    if ok(c):
        rules = rules_of(c)
    elif no_entrypoint(c):
        rules = []
    else:
        rules = None
        add("WARN", "cache_rules_unreadable", "cannot read Cache Rules (" + errs(c) + ") — token needs Cache Rules Read")
    for r in rules or []:
        ap = r.get("action_parameters") or {}
        expr = r.get("expression") or ""
        if r.get("action") == "set_cache_settings" and ap.get("cache") and r.get("enabled", True) \
                and "wordpress_logged_in" not in expr and "path.extension" not in expr:
            add("WARN", "cache_everything", f"Cache Rule '{r.get('description') or r.get('id')}' caches without a login/cart bypass")

    if ok(w):
        waf = len(rules_of(w))
    elif no_entrypoint(w):
        waf = 0
    else:
        waf = None
        add("WARN", "waf_unreadable", "cannot read WAF custom rules (" + errs(w) + ")")

    report = {
        "domain": domain, "zone": zone, "zone_id": zid,
        "settings": {k: settings.get(k) for k in MANAGED},
        "dns": dns,
        "cache_rules": None if rules is None else [r.get("description") or r.get("id") for r in rules],
        "waf_custom_rules": waf,
        "findings": findings,
    }
    if as_json == "1":
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return
    print(f"=== Cloudflare audit: {domain} (zone {zone}, id {zid}) ===")
    for k in MANAGED:
        print(f"  {k:20} = {settings.get(k, '(unknown)')}")
    print(f"  {'Cache Rules':20} = " + ("(unreadable)" if rules is None else f"{len(rules)} " + str(report["cache_rules"])))
    print(f"  {'WAF custom rules':20} = " + ("(unreadable)" if waf is None else str(waf)))
    print("  DNS web records:")
    for r in dns:
        print(f"    {r['type']:6} {r['name']:45} {'proxied' if r['proxied'] else 'DNS only'}")
    if not dns:
        print("    (none)")
    for f in findings:
        print(f"{f['level']} {f['message']}")
    nfail = sum(f["level"] == "FAIL" for f in findings)
    nwarn = sum(f["level"] == "WARN" for f in findings)
    print(f"RESULT: {nfail} FAIL, {nwarn} WARN")


def cmd_snapshot(out, domain, zone, zid, spath, dpath, cpath, wpath):
    s, dn, c, w = load(spath), load(dpath), load(cpath), load(wpath)
    if not ok(s):
        sys.exit("snapshot refused: cannot read zone settings (" + errs(s) + ")")
    if not ok(c) and not no_entrypoint(c):
        sys.exit("snapshot refused: cannot read Cache Rules (" + errs(c) + ") — a rollback would drop them")
    snap = {
        "tool": "cf-agent", "format": 1, "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "domain": domain, "zone": zone, "zone_id": zid,
        "settings": s.get("result") if isinstance(s.get("result"), list) else [],
        "dns_records": web_records(dn) if ok(dn) else None,
        "cache_rules": {"exists": ok(c), "rules": [keep_rule(r) for r in rules_of(c)]},
        "waf_custom_rules": [norm_rule(r) for r in rules_of(w)] if ok(w) else None,
    }
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(snap, f, indent=2, ensure_ascii=False)
        f.write("\n")


def cmd_snap_field(path, field):
    print(load(path).get(field) or "")


def cmd_setting(path):
    d = load(path)
    if not ok(d):
        sys.exit(errs(d))
    print((d.get("result") or {}).get("value", "?"))


def cmd_entrypoint_ok(path):
    d = load(path)
    if not (ok(d) or no_entrypoint(d)):
        sys.exit(errs(d))


def cmd_rules_summary(path, domain):
    print(rule_summary(rules_of(load(path)), domain))


def cmd_rules_body(path, domain, which, ttl):
    keep = []
    if which == "html":
        drop, new = f"cecp-panel: {domain}", html_rule(domain, int(ttl))
    else:
        drop, new = f"cf-agent static: {domain}", static_rule(domain)
    for r in rules_of(load(path)):
        if r.get("description") != drop:
            keep.append(keep_rule(r))
    keep.append(new)
    print(json.dumps({"rules": keep}, separators=(",", ":")))


def cmd_value_body(value):
    print(json.dumps({"value": value}))


def cmd_dns_find(path, name):
    for r in web_records(load(path)):
        if r.get("name") == name:
            print(f"{r.get('id')}\t{r.get('type')}\t{str(bool(r.get('proxied'))).lower()}")


def cmd_rollback_plan(snap_path, spath, cpath, dpath):
    snap = load(snap_path)
    if snap.get("tool") != "cf-agent":
        sys.exit("not a cf-agent snapshot")
    cur_s = settings_map(load(spath))
    for st in snap.get("settings") or []:
        sid, val = st.get("id"), st.get("value")
        if sid in MANAGED and sid in cur_s and cur_s[sid] != val:
            print(f"SETTING\t{sid}\t{json.dumps({'value': val})}")
    c = load(cpath)
    if not ok(c) and not no_entrypoint(c):
        sys.exit("cannot read current Cache Rules (" + errs(c) + ")")
    want = [norm_rule(r) for r in (snap.get("cache_rules") or {}).get("rules") or []]
    have = [norm_rule(r) for r in rules_of(c)]
    if want != have:
        print("RULES\t" + json.dumps({"rules": want}, separators=(",", ":")))
    saved = snap.get("dns_records")
    if saved is not None:
        cur = {r.get("id"): r for r in web_records(load(dpath))}
        for r in saved:
            now = cur.get(r.get("id"))
            if now is not None and bool(now.get("proxied")) != bool(r.get("proxied")):
                print(f"DNS\t{r.get('id')}\t{r.get('name')}\t{json.dumps({'proxied': bool(r.get('proxied'))})}")


cmd, args = sys.argv[1], sys.argv[2:]
{
    "zone-id": cmd_zone_id, "verify": cmd_verify, "zones": cmd_zones, "audit": cmd_audit,
    "snapshot": cmd_snapshot, "snap-field": cmd_snap_field, "setting": cmd_setting,
    "entrypoint-ok": cmd_entrypoint_ok, "rules-summary": cmd_rules_summary, "rules-body": cmd_rules_body,
    "value-body": cmd_value_body, "dns-find": cmd_dns_find, "rollback-plan": cmd_rollback_plan,
}[cmd](*args)
PY
}

# Longest active zone suffix that holds DOMAIN → "ZID<TAB>ZONE".
resolve_zone() {
  local cand="$1" line
  while [[ "$cand" == *.* ]]; do
    api GET "/zones?name=${cand}&status=active" "$TMPD/zone.json"
    line="$(py zone-id "$TMPD/zone.json" "$cand")" || die "$line"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
    cand="${cand#*.}"
  done
  die "no active Cloudflare zone visible to this token for $1"
}

CACHE_EP="rulesets/phases/http_request_cache_settings/entrypoint"
WAF_EP="rulesets/phases/http_request_firewall_custom/entrypoint"

fetch_state() {
  local zid="$1"
  api GET "/zones/${zid}/settings" "$TMPD/settings.json"
  api GET "/zones/${zid}/dns_records?per_page=500" "$TMPD/dns.json"
  api GET "/zones/${zid}/${CACHE_EP}" "$TMPD/cache.json"
  api GET "/zones/${zid}/${WAF_EP}" "$TMPD/waf.json"
}

# take_snapshot DOMAIN ZID ZONE → prints the snapshot path.
take_snapshot() {
  local domain="$1" zid="$2" zone="$3" ts out n=1
  fetch_state "$zid"
  mkdir -p "$SNAP_DIR"
  chmod 700 "$SNAP_DIR" 2>/dev/null || true
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$SNAP_DIR/${zone}-${ts}.json"
  while [[ -e "$out" ]]; do
    n=$(( n + 1 ))
    out="$SNAP_DIR/${zone}-${ts}-${n}.json"
  done
  py snapshot "$out" "$domain" "$zone" "$zid" "$TMPD/settings.json" "$TMPD/dns.json" \
    "$TMPD/cache.json" "$TMPD/waf.json" >&2 || die "snapshot failed"
  printf '%s\n' "$out"
}

ttl_seconds() {
  local t="$1" n unit
  [[ "$t" =~ ^([0-9]{1,5})([smhd]?)$ ]] || die "invalid TTL '$t' (e.g. 30m, 1h, 1d)"
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]:-s}"
  case "$unit" in
    s) echo "$n" ;;
    m) echo $(( n * 60 )) ;;
    h) echo $(( n * 3600 )) ;;
    d) echo $(( n * 86400 )) ;;
  esac
}

cmd_verify() {
  load_token
  api GET "/user/tokens/verify" "$TMPD/verify.json"
  api GET "/user/tokens/permission_groups" "$TMPD/perms.json"
  py verify "$TMPD/verify.json" "$TMPD/perms.json" || die "verify failed"
}

cmd_zones() {
  load_token
  api GET "/zones?per_page=50" "$TMPD/zones.json"
  py zones "$TMPD/zones.json" || die "zone list failed"
}

cmd_audit() {
  local domain="${1:-}" as_json=0
  [[ -n "$domain" ]] || { usage; exit 2; }
  shift
  domain="${domain,,}"
  validate_domain "$domain"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) as_json=1; shift ;;
      *) die "unknown option for audit: $1" ;;
    esac
  done
  load_token
  local zid zone
  IFS=$'\t' read -r zid zone < <(resolve_zone "$domain")
  [[ -n "$zid" ]] || die "zone not found for $domain"
  fetch_state "$zid"
  py audit "$domain" "$zone" "$zid" "$TMPD/settings.json" "$TMPD/dns.json" "$TMPD/cache.json" \
    "$TMPD/waf.json" "$as_json"
}

cmd_snapshot() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || { usage; exit 2; }
  domain="${domain,,}"
  validate_domain "$domain"
  load_token
  local zid zone
  IFS=$'\t' read -r zid zone < <(resolve_zone "$domain")
  [[ -n "$zid" ]] || die "zone not found for $domain"
  echo "snapshot: $(take_snapshot "$domain" "$zid" "$zone")"
}

patch_setting() {  # ZID SETTING VALUE
  local zid="$1" setting="$2" value="$3" before after
  api GET "/zones/${zid}/settings/${setting}" "$TMPD/s.json"
  before="$(py setting "$TMPD/s.json" 2>&1)" || before="(unreadable: $before)"
  api PATCH "/zones/${zid}/settings/${setting}" "$TMPD/s.json" "$(py value-body "$value")"
  after="$(py setting "$TMPD/s.json" 2>&1)" || die "Cloudflare rejected ${setting}=${value}: $after — token needs Zone Settings Edit"
  echo "  ${setting}: ${before} -> ${after}"
}

put_cache_rule() {  # ZID DOMAIN html|static TTL
  local zid="$1" domain="$2" which="$3" ttl="$4" err before after
  api GET "/zones/${zid}/${CACHE_EP}" "$TMPD/cache.json"
  # The PUT replaces the whole ruleset: build only on a readable one (or "none yet", 10003).
  err="$(py entrypoint-ok "$TMPD/cache.json" 2>&1)" \
    || die "cannot read Cache Rules: $err — token needs Cache Rules Read/Edit"
  before="$(py rules-summary "$TMPD/cache.json" "$domain")"
  api PUT "/zones/${zid}/${CACHE_EP}" "$TMPD/put.json" "$(py rules-body "$TMPD/cache.json" "$domain" "$which" "$ttl")"
  err="$(py entrypoint-ok "$TMPD/put.json" 2>&1)" \
    || die "Cloudflare rejected the cache rule: $err — token needs Cache Rules Edit"
  api GET "/zones/${zid}/${CACHE_EP}" "$TMPD/cache.json"
  after="$(py rules-summary "$TMPD/cache.json" "$domain")"
  echo "  cache rules: ${before} -> ${after}"
}

proxy_record() {  # ZID FQDN
  local zid="$1" name="$2" id type proxied found=0
  api GET "/zones/${zid}/dns_records?per_page=500" "$TMPD/dns.json"
  while IFS=$'\t' read -r id type proxied; do
    [[ -n "$id" ]] || continue
    found=1
    if [[ "$proxied" == "true" ]]; then
      echo "  dns ${type} ${name}: already proxied"
      continue
    fi
    api PATCH "/zones/${zid}/dns_records/${id}" "$TMPD/rec.json" '{"proxied":true}'
    py entrypoint-ok "$TMPD/rec.json" >/dev/null 2>&1 || die "Cloudflare rejected the DNS change for $name — token needs DNS Edit"
    echo "  dns ${type} ${name}: DNS only -> proxied"
  done < <(py dns-find "$TMPD/dns.json" "$name")
  [[ "$found" == 1 ]] || die "no A/AAAA/CNAME record named $name in the zone"
}

cmd_apply() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || { usage; exit 2; }
  shift
  domain="${domain,,}"
  validate_domain "$domain"
  local ssl=0 brotli=0 level="" static=0 html=0 approved=0 allow_dns=0 ttl=3600 proxy_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssl-strict) ssl=1; shift ;;
      --brotli) brotli=1; shift ;;
      --cache-level)
        level="${2:-}"
        [[ "$level" =~ ^(aggressive|basic|simplified)$ ]] || die "--cache-level aggressive|basic|simplified"
        shift 2 ;;
      --static-cache-rules) static=1; shift ;;
      --html-cache) html=1; shift ;;
      --ttl) ttl="$(ttl_seconds "${2:-}")"; shift 2 || shift ;;
      --yes-i-approved) approved=1; shift ;;
      --proxy-record) proxy_name="${2:-}"; shift 2 || shift ;;
      --allow-dns) allow_dns=1; shift ;;
      --cache-everything) refuse "\"Cache Everything\" is never applied (it caches logged-in, cart and admin pages)" ;;
      *) die "unknown option for apply: $1" ;;
    esac
  done
  if [[ "$ssl" == 1 && "$approved" != 1 ]]; then
    refuse "--ssl-strict changes the SSL mode of the WHOLE zone (every subdomain); the owner must approve it, then pass --yes-i-approved"
  fi
  if [[ "$html" == 1 && "$approved" != 1 ]]; then
    refuse "--html-cache caches HTML at the edge; the site owner must approve it, then pass --yes-i-approved"
  fi
  if [[ -n "$proxy_name" && "$allow_dns" != 1 ]]; then
    refuse "--proxy-record writes a DNS record; pass --allow-dns once the owner approved the DNS change"
  fi
  if [[ -n "$proxy_name" ]]; then
    proxy_name="${proxy_name,,}"
    validate_domain "$proxy_name"
  fi
  if [[ "$html" == 1 ]]; then
    (( ttl >= 60 && ttl <= 2592000 )) || die "TTL must be between 60s and 30d"
  fi
  [[ "$ssl$brotli$static$html" != "0000" || -n "$level" || -n "$proxy_name" ]] \
    || die "nothing to apply (see: cf-agent.sh help)"

  load_token
  local zid zone snap
  IFS=$'\t' read -r zid zone < <(resolve_zone "$domain")
  [[ -n "$zid" ]] || die "zone not found for $domain"
  snap="$(take_snapshot "$domain" "$zid" "$zone")"
  echo "snapshot: $snap   (undo: tools/cf-agent.sh rollback $snap)"
  CF_WRITE_OK=1
  echo "apply on zone $zone for $domain:"
  if [[ "$ssl" == 1 ]]; then
    echo "  note: the SSL mode applies to the WHOLE zone ($zone), every subdomain included"
    patch_setting "$zid" ssl strict
  fi
  [[ "$brotli" == 1 ]] && patch_setting "$zid" brotli on
  [[ -n "$level" ]] && patch_setting "$zid" cache_level "$level"
  [[ "$static" == 1 ]] && put_cache_rule "$zid" "$domain" static 0
  [[ "$html" == 1 ]] && put_cache_rule "$zid" "$domain" html "$ttl"
  [[ -n "$proxy_name" ]] && proxy_record "$zid" "$proxy_name"
  CF_WRITE_OK=0
  echo "done. Check: tools/cf-agent.sh audit $domain"
}

cmd_rollback() {
  local file="${1:-}" allow_dns=0
  [[ -n "$file" ]] || { usage; exit 2; }
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-dns) allow_dns=1; shift ;;
      *) die "unknown option for rollback: $1" ;;
    esac
  done
  [[ -f "$file" ]] || die "snapshot not found: $file"
  local domain zid zone
  domain="$(py snap-field "$file" domain)"
  zid="$(py snap-field "$file" zone_id)"
  zone="$(py snap-field "$file" zone)"
  validate_domain "$domain"
  [[ "$zid" =~ ^[A-Za-z0-9]+$ ]] || die "snapshot has no valid zone id"
  load_token
  local pre
  pre="$(take_snapshot "$domain" "$zid" "$zone")"
  echo "snapshot of the current state: $pre"
  local plan
  plan="$(py rollback-plan "$file" "$TMPD/settings.json" "$TMPD/cache.json" "$TMPD/dns.json" 2>&1)" \
    || die "rollback plan failed: $plan"
  if [[ -z "$plan" ]]; then
    echo "nothing to roll back: the zone already matches $file"
    return 0
  fi
  CF_WRITE_OK=1
  local kind a b c err skipped=0
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      SETTING)
        api PATCH "/zones/${zid}/settings/${a}" "$TMPD/r.json" "$b"
        err="$(py setting "$TMPD/r.json" 2>&1)" || die "Cloudflare rejected ${a}: $err"
        echo "  ${a} -> ${err}" ;;
      RULES)
        api PUT "/zones/${zid}/${CACHE_EP}" "$TMPD/r.json" "$a"
        err="$(py entrypoint-ok "$TMPD/r.json" 2>&1)" || die "Cloudflare rejected the Cache Rules restore: $err"
        echo "  cache rules restored" ;;
      DNS)
        if [[ "$allow_dns" != 1 ]]; then
          echo "  SKIPPED dns ${b}: proxy state differs from the snapshot (pass --allow-dns to restore)"
          skipped=1
          continue
        fi
        api PATCH "/zones/${zid}/dns_records/${a}" "$TMPD/r.json" "$c"
        py entrypoint-ok "$TMPD/r.json" >/dev/null 2>&1 || die "Cloudflare rejected the DNS restore for $b"
        echo "  dns ${b} -> ${c}" ;;
    esac
  done <<<"$plan"
  CF_WRITE_OK=0
  echo "rollback done from $file"
  [[ "$skipped" == 0 ]] || echo "note: DNS differences were left untouched"
}

main() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
  esac
  local a
  for a in "$@"; do
    case "$a" in
      --token|--token=*|--api-token|--api-token=*) die "the token is never an argument: export CF_API_TOKEN or set CF_API_TOKEN_FILE" ;;
    esac
  done
  need_tools
  umask 077
  TMPD="$(mktemp -d)"
  trap cleanup EXIT
  case "$cmd" in
    verify) cmd_verify "$@" ;;
    zones) cmd_zones "$@" ;;
    audit) cmd_audit "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    apply) cmd_apply "$@" ;;
    rollback) cmd_rollback "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
