#!/usr/bin/env bash
# Page cache management: TTL per site, auto-purge on content changes.
# WordPress (mu-plugin, runs as the site user) appends URLs to a queue in the site's private
# tmp dir; a systemd path unit runs `cache purge-queue` as root, which deletes the matching
# nginx cache files and, when edge cache is on, purges them at Cloudflare too.
set -euo pipefail

CACHE_PURGE_CRON="/etc/cron.d/cecp-cache-purge"

cache_queue_path() { echo "/home/$(site_json_get "$1" site_user)/tmp/cecp-purge.queue"; }

cache_install_units() {
  cat >/etc/systemd/system/cecp-purge@.path <<'EOF'
[Unit]
Description=CECP page-cache purge queue of site_%i
[Path]
PathModified=/home/site_%i/tmp/cecp-purge.queue
Unit=cecp-purge@%i.service
[Install]
WantedBy=paths.target
EOF
  # Bulk edits trigger many runs in a row: allow bursts; the cron job re-arms a tripped watcher.
  cat >/etc/systemd/system/cecp-purge@.service <<'EOF'
[Unit]
Description=CECP page-cache purge for site_%i
StartLimitIntervalSec=60
StartLimitBurst=30
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cecp-panel cache purge-queue %i
EOF
  systemctl daemon-reload
  # Safety net for missed path events.
  printf '*/2 * * * * root /usr/local/bin/cecp-panel cache purge-queue --all >>/var/log/cecp-panel/cache.log 2>&1\n' >"$CACHE_PURGE_CRON"
  chmod 644 "$CACHE_PURGE_CRON"
}

# cecp-panel cache auto-purge DOMAIN on|off|status
cache_auto_purge() {
  local domain="${1:-}" action="${2:-status}"
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  local slug su docroot mudir q
  slug="$(domain_slug "$domain")"
  su="$(site_json_get "$domain" site_user)"
  docroot="$(site_json_get "$domain" docroot)"
  mudir="$docroot/wp-content/mu-plugins"
  q="$(cache_queue_path "$domain")"
  case "$action" in
    on)
      [[ "$(wp_site_is_wordpress "$domain" 2>/dev/null)" == "True" ]] || panel_die "auto-purge needs a WordPress site"
      install -d -o "$su" -g "$su" -m 755 "$mudir"
      install -m 644 -o root -g root "$PANEL_ROOT/templates/mu-plugins/cecp-cache-purge.php" "$mudir/cecp-cache-purge.php"
      python3 -c 'import json,sys; print(json.dumps({"queue": sys.argv[1]}))' "$q" \
        | install -m 644 -o root -g root /dev/stdin "$mudir/cecp-cache-purge.json"
      site_ensure_tmp "$su"
      # The tmp dir belongs to the site user: never write through what they may have put there,
      # create the queue with their own privileges.
      [[ -L "$q" || ( -e "$q" && ! -f "$q" ) ]] && rm -rf --one-file-system "$q"
      runuser -u "$su" -- sh -c 'umask 077; : >>"$1"' _ "$q"
      cache_install_units
      systemctl enable --now "cecp-purge@${slug}.path" >/dev/null 2>&1 \
        || panel_log "WARN: could not start cecp-purge@${slug}.path — the 2-minute cron still processes the queue"
      site_json_set "$domain" cache_autopurge true
      panel_log "Auto-purge ON for $domain: pages are purged when content changes. Consider: cecp-panel cache ttl $domain 1h"
      ;;
    off)
      systemctl disable --now "cecp-purge@${slug}.path" >/dev/null 2>&1 || true
      rm -f "$mudir/cecp-cache-purge.php" "$mudir/cecp-cache-purge.json"
      site_json_set "$domain" cache_autopurge false
      panel_log "Auto-purge OFF for $domain"
      ;;
    status) cache_status "$domain" ;;
    *) panel_die "Usage: cecp-panel cache auto-purge DOMAIN on|off|status" ;;
  esac
}

# cecp-panel cache ttl DOMAIN 5m|30m|1h|6h|1d
cache_ttl() {
  local domain="${1:-}" ttl="${2:-}" n unit secs
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  [[ "$ttl" =~ ^([0-9]{1,4})([smhd])$ ]] || panel_die "Usage: cecp-panel cache ttl DOMAIN 5m|30m|1h|6h|1d"
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "$unit" in s) secs=$n ;; m) secs=$(( n * 60 )) ;; h) secs=$(( n * 3600 )) ;; d) secs=$(( n * 86400 )) ;; esac
  (( secs >= 60 && secs <= 86400 )) || panel_die "TTL must be between 1m and 1d"
  if (( secs > 600 )) && [[ "$(site_json_get_or "$domain" cache_autopurge false)" != "True" ]]; then
    panel_log "WARN: without auto-purge, edits can take up to $ttl to appear (cecp-panel cache auto-purge $domain on)"
  fi
  site_json_set "$domain" cache_ttl "$ttl"
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
  panel_log "Page cache TTL for $domain: $ttl"
}

cache_status() {
  local domain="${1,,}" slug q unit
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  slug="$(domain_slug "$domain")"
  q="$(cache_queue_path "$domain")"
  unit="$(systemctl is-active "cecp-purge@${slug}.path" 2>/dev/null || true)"
  echo "=== Page cache: $domain ==="
  echo "  origin TTL:  $(site_json_get_or "$domain" cache_ttl 5m)"
  echo "  auto-purge:  $(site_json_get_or "$domain" cache_autopurge false) (watcher: ${unit:-inactive})"
  echo "  edge cache:  $(site_json_get_or "$domain" cf_edge false) (edge TTL: $(site_json_get_or "$domain" cf_edge_ttl -)s)"
  echo "  queue:       $q ($( [[ -f "$q" && ! -L "$q" ]] && wc -l <"$q" || echo 0) pending)"
}

# A watcher whose service hit the start limit stays failed until reset.
cache_rearm_watcher() {
  local slug="$1"
  systemctl is-failed --quiet "cecp-purge@${slug}.path" 2>/dev/null || return 0
  systemctl reset-failed "cecp-purge@${slug}.path" "cecp-purge@${slug}.service" 2>/dev/null || true
  systemctl start "cecp-purge@${slug}.path" 2>/dev/null || true
}

# cecp-panel cache purge-queue SLUG|--all  (run by systemd/cron as root)
cache_purge_queue() {
  require_root
  local target="${1:-}" f d
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    d="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    if [[ "$target" == "--all" ]]; then
      [[ "$(site_json_get_or "$d" cache_autopurge false)" == "True" ]] || continue
      cache_purge_queue_site "$d"
      cache_rearm_watcher "$(domain_slug "$d")"
    elif [[ "$(domain_slug "$d")" == "$target" ]]; then
      shopt -u nullglob
      cache_purge_queue_site "$d"
      return 0
    fi
  done
  shopt -u nullglob
  [[ "$target" == "--all" ]] || panel_die "Usage: cecp-panel cache purge-queue SLUG|--all (no site with slug '$target')"
}

# The queue is written by the site user: open it without following symlinks, require that the
# site user owns it, and accept only http(s) URLs of this site's own host.
cache_purge_queue_site() {
  local domain="$1" su result
  su="$(site_json_get "$domain" site_user)"
  result="$(python3 - "$(cache_queue_path "$domain")" "$su" "$domain" "$CECP_CACHE_DIR" <<'PY'
import fcntl, hashlib, json, os, pwd, re, stat, sys
from urllib.parse import urlsplit
q, user, domain, root = sys.argv[1:5]
empty = {"all": False, "urls": [], "deleted": 0}
try:
    uid = pwd.getpwnam(user).pw_uid
    fd = os.open(q, os.O_RDWR | os.O_NOFOLLOW)
except (KeyError, OSError):
    print(json.dumps(empty)); sys.exit(0)
st = os.fstat(fd)
if not stat.S_ISREG(st.st_mode) or st.st_uid != uid:
    os.close(fd); print(json.dumps(dict(empty, error="queue file rejected (not a regular file owned by the site user)"))); sys.exit(0)
fcntl.flock(fd, fcntl.LOCK_EX)
data = os.read(fd, 2_000_000).decode("utf-8", "replace")
if data:  # truncating an empty queue would itself fire the path unit again
    os.ftruncate(fd, 0)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
hosts = {domain, "www." + domain}
track = re.compile(r"^(?:(?:utm_[a-z_]+|fbclid|gclid|gbraid|wbraid|dclid|msclkid|ttclid|twclid|igshid|mc_cid|mc_eid|_ga|_gl)=[^&]*&?)+$")
purge_all, urls = False, []
for line in data.splitlines():
    line = line.strip()
    if not line:
        continue
    if line == "*":
        purge_all = True
        continue
    if len(line) > 2000 or any(c.isspace() or ord(c) < 32 for c in line):
        continue
    u = urlsplit(line)
    if u.scheme in ("http", "https") and (u.hostname or "").lower() in hosts:
        urls.append(line)
# WordPress writes non-ASCII slugs with lowercase %xx, browsers send uppercase: the nginx key is
# the raw request URI, so purge both spellings (Vietnamese slugs hit this constantly).
pct = re.compile(r"%[0-9a-fA-F]{2}")
variants = []
for url in dict.fromkeys(urls):
    for v in (url, pct.sub(lambda m: m.group(0).upper(), url), pct.sub(lambda m: m.group(0).lower(), url)):
        if v not in variants:
            variants.append(v)
if len(variants) > 600:
    purge_all = True
deleted = 0
if not purge_all:
    for url in variants:
        u = urlsplit(url)
        path = u.path or "/"
        uri = path if (u.query and track.match(u.query)) else path + ("?" + u.query if u.query else "")
        for scheme in ("http", "https"):
            for method in ("GET", "HEAD"):
                h = hashlib.md5(f"{scheme}{method}{(u.hostname or '').lower()}{uri}".encode()).hexdigest()
                try:
                    os.unlink(f"{root}/{h[-1]}/{h[-3:-1]}/{h}")
                    deleted += 1
                except FileNotFoundError:
                    pass
print(json.dumps({"all": purge_all, "urls": variants if not purge_all else [], "count": len(dict.fromkeys(urls)), "deleted": deleted}))
PY
)"
  local purge_all n
  purge_all="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print("1" if d.get("all") else "0")' <<<"$result")"
  n="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("count", 0) if d.get("urls") else 0)' <<<"$result")"
  if grep -q '"error"' <<<"$result"; then
    panel_log "WARN: cache purge-queue $domain: $(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["error"])' <<<"$result")"
    return 0
  fi
  [[ "$purge_all" == "1" || "$n" != "0" ]] || return 0
  if [[ "$purge_all" == "1" ]]; then
    optimize_purge_cache "$domain" >/dev/null
  fi
  # Subshells: a credentials problem (panel_die) must not abort the purge of other sites.
  if [[ "$(site_json_get_or "$domain" cf_edge false)" == "True" ]]; then
    if [[ "$purge_all" == "1" ]]; then
      ( cf_purge_host "$domain" ) || panel_log "WARN: Cloudflare host purge failed for $domain"
    else
      python3 -c 'import json,sys; print("\n".join(json.loads(sys.stdin.read())["urls"]))' <<<"$result" \
        | ( cf_purge_urls "$domain" ) || panel_log "WARN: Cloudflare URL purge failed for $domain"
    fi
  fi
  if [[ "$purge_all" == "1" ]]; then
    panel_log "cache: purged all pages of $domain (content change)"
  else
    panel_log "cache: purged $n URL(s) of $domain (content change)"
  fi
}
