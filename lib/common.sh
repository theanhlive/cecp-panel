#!/usr/bin/env bash
# Shared helpers for CECP Panel (sourced, not executed directly)
# shellcheck disable=SC2034  # globals consumed by other lib files
set -euo pipefail

CECP_PANEL_VERSION="${CECP_PANEL_VERSION:-1.11.0-beta}"
PANEL_ROOT="${PANEL_ROOT:-/opt/cecp-panel}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/cecp-panel}"
ETC_DIR="/etc/cecp-panel"
VAR_LIB="/var/lib/cecp-panel"
SITES_DIR="$VAR_LIB/sites"
LOG_DIR="/var/log/cecp-panel"
BIN_PATH="/usr/local/bin/cecp-panel"

panel_log() {
  echo "[cecp-panel] $*"
  [[ -d "$LOG_DIR" ]] || install -d -m 711 "$LOG_DIR" 2>/dev/null || true
  [[ -f "$LOG_DIR/panel.log" ]] || install -m 640 /dev/null "$LOG_DIR/panel.log" 2>/dev/null || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$LOG_DIR/panel.log" 2>/dev/null || true
}
panel_die() { echo "[cecp-panel] ERROR: $*" >&2; exit 1; }
# Show a secret to the operator's terminal only — never write it to panel.log.
panel_secret() { echo "[cecp-panel] $*"; }

# Host names without the `hostname` binary (absent on minimal images). panel_host_short matches
# `hostname -s`, which older releases used as restic's --host: keep it identical.
panel_host_short() {
  local h
  h="$(cat /proc/sys/kernel/hostname 2>/dev/null || true)"
  h="${h%%.*}"
  echo "${h:-localhost}"
}
panel_host_fqdn() { python3 -c 'import socket; print(socket.getfqdn())' 2>/dev/null || panel_host_short; }
# First non-loopback IPv4 (fallback when ifconfig.me is unreachable).
panel_local_ipv4() { ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || panel_die "Run as root: sudo cecp-panel $*"
}

domain_slug() {
  local d="${1,,}"
  d="${d//./_}"
  d="${d//-/_}"
  echo "${d:0:28}"
}

site_user_for_domain() {
  echo "site_$(domain_slug "$1")"
}

rand_alnum() {
  local n="${1:-16}"
  [[ "$n" =~ ^[0-9]{1,3}$ ]] || panel_die "rand_alnum: invalid length '$n'"
  python3 -c 'import secrets,string,sys; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(int(sys.argv[1]))))' "$n"
}

# ---------------------------------------------------------------------------
# Input validation — arguments may come from CECP Core, n8n or the menu, so they
# are untrusted. Call these at the top of every function that takes such input.
# ---------------------------------------------------------------------------
validate_domain() {
  local d="${1:-}"
  local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
  if (( ${#d} > 253 )) || [[ ! "$d" =~ $re ]] || [[ "${d##*.}" =~ ^[0-9]+$ ]]; then
    panel_die "Invalid domain: '${d}'"
  fi
}

# A DNS record name: either a single label ("test2") or a full domain.
validate_dns_name() {
  local n="${1:-}"
  [[ "$n" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || validate_domain "$n"
}

validate_ipv4() {
  local ip="${1:-}" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || panel_die "Invalid IPv4: '${ip}'"
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || panel_die "Invalid IPv4: '${ip}'"
  done
}

validate_url() {
  local u="${1:-}"
  local re='^https?://[a-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/:@!$&()*+,;=?#-]*)?$'
  [[ "$u" =~ $re ]] || panel_die "Invalid URL: '${u}'"
}

validate_int_range() {
  local v="${1:-}" lo="$2" hi="$3" what="${4:-value}"
  [[ "$v" =~ ^[0-9]{1,6}$ ]] && (( 10#$v >= lo && 10#$v <= hi )) || panel_die "Invalid ${what}: '${v}' (expected ${lo}-${hi})"
}

# Set KEY=VALUE in a shell env file that is later sourced by root; the value is %q-quoted.
env_set() {
  local file="$1" key="$2" val="$3" tmp
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || panel_die "env_set: bad key '$key'"
  tmp="$(mktemp "${file}.XXXXXX")"
  [[ -f "$file" ]] && grep -v "^${key}=" "$file" >"$tmp" || true
  printf '%s=%q\n' "$key" "$val" >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

env_unset() {
  local file="$1" key="$2" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${file}.XXXXXX")"
  grep -v "^${key}=" "$file" >"$tmp" || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# Source a config file as root only if root owns it and nobody else can write it
# (anyone who can write a sourced file can run code as root).
secure_source() {
  local f="$1" owner mode
  [[ -f "$f" ]] || return 1
  owner="$(stat -c %u "$f")"
  mode="$(stat -c %a "$f")"
  [[ "$owner" == "0" ]] || panel_die "Refusing to source $f: not owned by root"
  (( (8#$mode & 8#022) == 0 )) || panel_die "Refusing to source $f: writable by group/others (mode $mode)"
  # shellcheck source=/dev/null
  source "$f"
}

# Serialize destructive operations on one site (live restore, WP update, staging push). The
# lock is held until the panel process exits.
site_lock() {
  local f
  f="$VAR_LIB/locks/$(domain_slug "$1").lock"
  mkdir -p "$VAR_LIB/locks"
  exec {CECP_LOCK_FD}>"$f"
  flock -n "$CECP_LOCK_FD" || panel_die "Another panel operation is running on $1 (lock $f) — try again later"
}

site_meta_path() {
  local d="${1,,}"
  [[ -n "$d" && "$d" != *"/"* && "$d" != *".."* ]] || panel_die "Invalid site name: '${1:-}'"
  echo "$SITES_DIR/${d}.json"
}

load_site_meta() {
  local domain="$1"
  local f
  f="$(site_meta_path "$domain")"
  [[ -f "$f" ]] || return 1
  cat "$f"
}

site_json_get() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$(site_meta_path "$1")" "$2"
}

site_json_get_or() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], sys.argv[3]))' \
    "$(site_meta_path "$1")" "$2" "$3"
}

# site_json_set DOMAIN KEY VALUE [KEY VALUE ...] — "true"/"false" are stored as booleans.
site_json_set() {
  local path
  path="$(site_meta_path "$1")"
  shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path, kv = sys.argv[1], sys.argv[2:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
for k, v in zip(kv[::2], kv[1::2]):
    data[k] = {"true": True, "false": False}.get(v, v)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  chmod 600 "$path"
}

save_site_meta() {
  local domain="$1" json="$2"
  mkdir -p "$SITES_DIR"
  echo "$json" >"$(site_meta_path "$domain")"
  chmod 600 "$(site_meta_path "$domain")"
}

site_set_ssl_flag() {
  local v=false
  [[ "${2,,}" =~ ^(1|true|yes|on)$ ]] && v=true
  site_json_set "$1" ssl "$v"
}

detect_php_fpm_sock_dir() {
  if [[ -d /run/php-fpm ]]; then
    echo /run/php-fpm
  elif [[ -d /var/run/php-fpm ]]; then
    echo /var/run/php-fpm
  else
    echo /run/php-fpm
  fi
}

NGINX_LKG_DIR="${NGINX_LKG_DIR:-/var/lib/cecp-panel/nginx-lkg}"

# Save the current (known-good) nginx conf.d as the rollback point.
nginx_save_known_good() {
  mkdir -p "$NGINX_LKG_DIR"
  rm -rf "$NGINX_LKG_DIR/conf.d"
  cp -a /etc/nginx/conf.d "$NGINX_LKG_DIR/conf.d" 2>/dev/null || true
}

# Test nginx config; reload on success. On failure, automatically roll back
# conf.d to the last known-good snapshot so a single bad vhost can never take
# the whole nginx (and therefore every site on the box) down.
nginx_test_and_reload() {
  local errlog
  errlog="$(mktemp)"
  if nginx -t 2>"$errlog"; then
    systemctl reload nginx
    nginx_save_known_good
    rm -f "$errlog"
    return 0
  fi

  # nginx -t failed — the running nginx is still up (reload did not happen),
  # but on-disk config is broken and would fail on the next restart/reboot.
  panel_log "ERROR: nginx config test failed:"
  sed 's/^/    /' "$errlog" >&2

  if [[ -d "$NGINX_LKG_DIR/conf.d" ]]; then
    panel_log "Rolling back /etc/nginx/conf.d to last known-good snapshot ..."
    local quarantine
    quarantine="/var/lib/cecp-panel/nginx-broken-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$quarantine"
    cp -a /etc/nginx/conf.d "$quarantine/conf.d" 2>/dev/null || true
    rm -rf /etc/nginx/conf.d
    cp -a "$NGINX_LKG_DIR/conf.d" /etc/nginx/conf.d
    if nginx -t 2>/dev/null; then
      systemctl reload nginx 2>/dev/null || true
      panel_log "Rollback OK. Broken config saved at $quarantine for inspection."
    else
      panel_log "Rollback restored snapshot but nginx -t still fails — manual check needed. Broken config at $quarantine."
    fi
  else
    panel_log "No known-good snapshot yet; left config as-is (running nginx untouched). Fix the error above and retry."
  fi
  rm -f "$errlog"
  return 1
}

# Validate sshd config before reloading so a bad drop-in can never lock SSH out.
sshd_test_and_reload() {
  local sshd_bin errlog
  sshd_bin="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
  # Debian/Ubuntu: `sshd -t` needs the privsep dir even when sshd is socket-activated.
  [[ -f /etc/debian_version ]] && mkdir -p /run/sshd
  errlog="$(mktemp)"
  if ! "$sshd_bin" -t 2>"$errlog"; then
    panel_log "ERROR: sshd -t failed:"
    sed 's/^/    /' "$errlog" >&2
    rm -f "$errlog"
    return 1
  fi
  rm -f "$errlog"
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
}

# Write an sshd drop-in, then test+reload; on failure restore the previous file (or remove it).
sshd_apply_dropin() {
  local file="$1" content="$2" backup=""
  mkdir -p /etc/ssh/sshd_config.d
  if [[ -f "$file" ]]; then
    backup="$(mktemp)"
    cp -a "$file" "$backup"
  fi
  printf '%s\n' "$content" >"$file"
  chmod 600 "$file"
  if sshd_test_and_reload; then
    [[ -z "$backup" ]] || rm -f "$backup"
    return 0
  fi
  if [[ -n "$backup" ]]; then mv -f "$backup" "$file"; else rm -f "$file"; fi
  panel_log "ERROR: reverted $file — sshd NOT reloaded"
  return 1
}

# listen lines for the HTTPS server block: `http2 on;` exists from nginx 1.25.1, older
# versions (AlmaLinux 9: 1.20/1.22/1.24) need `listen ... ssl http2`.
nginx_listen_ssl_lines() {
  local v
  v="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -n "$v" && "$(printf '%s\n%s\n' 1.25.1 "$v" | sort -V | head -1)" == "1.25.1" ]]; then
    printf '    listen 443 ssl;\n    listen [::]:443 ssl;\n    http2 on;'
  else
    printf '    listen 443 ssl http2;\n    listen [::]:443 ssl http2;'
  fi
}

# pm.max_children per pool: ~50% of RAM at ~60 MB/worker, shared by all sites, 4..32.
php_pool_max_children() {
  local ram_mb sites n
  ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
  sites="$(find "$SITES_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
  (( sites < 1 )) && sites=1
  n=$(( ram_mb / 2 / 60 / sites ))
  (( n < 4 )) && n=4
  (( n > 32 )) && n=32
  echo "$n"
}

# After ADDING a pool, restart instead of reload: on reload PHP-FPM (seen with AlmaLinux 9
# php-fpm 8.0.30) re-owns every inherited socket as root:root, so nginx gets EACCES and the
# OTHER sites answer 502 until the next restart.
php_fpm_restart_for_new_pool() {
  local svc="${1:-php-fpm}"
  systemctl restart "$svc" 2>/dev/null || panel_log "WARN: could not restart $svc"
  php_fpm_fix_socket_owner
}

# Safety net: every panel pool socket must be owned by nginx (listen.owner).
php_fpm_fix_socket_owner() {
  id nginx &>/dev/null || return 0
  local f sock owner
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    sock="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("php_sock",""))' "$f")"
    [[ -n "$sock" ]] || continue
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [[ -S "$sock" ]] && break
      sleep 0.3
    done
    [[ -S "$sock" ]] || continue
    owner="$(stat -c %U:%G "$sock")"
    if [[ "$owner" != "nginx:nginx" ]]; then
      chown nginx:nginx "$sock"
      chmod 660 "$sock"
      panel_log "Fixed PHP-FPM socket owner $sock (was $owner)"
    fi
  done
  shopt -u nullglob
}

# Reload the default PHP-FPM, every running Remi php*-php-fpm service and every per-site
# master of sites with resource limits (cecp-php-fpm@SLUG).
php_fpm_reload_all() {
  php_fpm_reload
  local svc
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
  done < <(systemctl list-units 'php*-php-fpm.service' 'cecp-php-fpm@*.service' --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}')
}

php_fpm_reload() {
  if systemctl is-active --quiet php-fpm 2>/dev/null; then
    systemctl reload php-fpm 2>/dev/null || systemctl restart php-fpm
  elif systemctl is-active --quiet php8.2-fpm 2>/dev/null; then
    systemctl reload php8.2-fpm 2>/dev/null || systemctl restart php8.2-fpm
  else
    systemctl restart php-fpm 2>/dev/null || true
  fi
}

# template_render TPL OUT KEY VALUE ... — replaces {{KEY}}. Done in Python: bash 5.2's
# patsub_replacement would turn "&" inside values (nginx regexes) into the matched text.
template_render() {
  local tpl="$1" out="$2"
  shift 2
  python3 - "$tpl" "$out" "$@" <<'PY'
import re, sys
tpl, out, kv = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(tpl, encoding="utf-8") as f:
    s = f.read()
for k, v in zip(kv[::2], kv[1::2]):
    s = s.replace("{{" + k + "}}", v)
left = re.findall(r"\{\{[A-Z_]+\}\}", s)
if left:
    sys.exit(f"template_render: unresolved {sorted(set(left))} in {tpl}")
with open(out, "w", encoding="utf-8") as f:
    f.write(s)
PY
}

selinux_fixup_path() {
  command -v restorecon &>/dev/null || return 0
  restorecon -RF "$1" 2>/dev/null || true
}
