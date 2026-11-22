#!/usr/bin/env bash
# OS components + CECP Panel self-update
set -euo pipefail

PANEL_ENV="$ETC_DIR/panel.env"
CECP_PANEL_DEFAULT_RAW_BASE="https://raw.githubusercontent.com/theanhlive/cecp-panel/main"
# From 2.0.0 an unset channel means stable; panels that chose beta keep it.
CECP_PANEL_DEFAULT_CHANNEL="stable"
# Public key the INSTALLED panel trusts for dist/<channel>/SHA256SUMS.minisig. A placeholder
# without a key line = signatures not enforced yet (warning); a real key = mandatory.
CECP_RELEASE_PUBKEY="$PANEL_ROOT/keys/cecp-release.pub"

update_validate_mirror() {
  [[ "${1:-}" =~ ^(https://|http://|file:///)[A-Za-z0-9._~%/:@+-]+$ ]] \
    || panel_die "Invalid mirror URL: '${1:-}' (https://… or file:///…)"
}

update_save_mirror() {
  local base="${1:-}"
  [[ -n "$base" ]] || return 0
  update_validate_mirror "$base"
  mkdir -p "$ETC_DIR"
  env_set "$PANEL_ENV" CECP_PANEL_RAW_BASE "$base"
}

update_load_mirror() {
  CECP_PANEL_RAW_BASE=""
  CECP_PANEL_CHANNEL=""
  if [[ -f "$PANEL_ENV" ]]; then
    secure_source "$PANEL_ENV"
  fi
  CECP_PANEL_RAW_BASE="${CECP_PANEL_RAW_BASE:-${CECP_PANEL_BUNDLE_URL:-}}"
  CECP_PANEL_RAW_BASE="${CECP_PANEL_RAW_BASE:-$CECP_PANEL_DEFAULT_RAW_BASE}"
  CECP_PANEL_CHANNEL="${CECP_PANEL_CHANNEL:-$CECP_PANEL_DEFAULT_CHANNEL}"
  validate_channel "$CECP_PANEL_CHANNEL"
}

# cecp-panel update channel [stable|beta] — no argument shows the current channel.
update_channel_cmd() {
  local ch="${1:-}"
  if [[ -z "$ch" ]]; then
    update_load_mirror
    echo "Channel: $CECP_PANEL_CHANNEL (source: ${CECP_PANEL_RAW_BASE%/}/dist/$CECP_PANEL_CHANNEL/, falls back to dist/ on mirrors without channels)"
    return 0
  fi
  require_root
  validate_channel "$ch"
  mkdir -p "$ETC_DIR"
  env_set "$PANEL_ENV" CECP_PANEL_CHANNEL "$ch"
  panel_log "Update channel set to $ch. Apply: cecp-panel update panel latest"
}

# 0 = the installed panel carries a real release key (signatures are mandatory).
update_release_key_present() {
  [[ -f "$CECP_RELEASE_PUBKEY" ]] && grep -qE '^RW[A-Za-z0-9+/]{54}$' "$CECP_RELEASE_PUBKEY"
}

# update_verify_signature SUMS SIG — minisign if installed, else openssl (lib/minisign_verify.py).
update_verify_signature() {
  local sums="$1" sig="$2" out
  if command -v minisign &>/dev/null; then
    out="$(minisign -V -p "$CECP_RELEASE_PUBKEY" -m "$sums" -x "$sig" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  elif command -v openssl &>/dev/null && [[ -f "$PANEL_ROOT/lib/minisign_verify.py" ]]; then
    out="$(python3 -I "$PANEL_ROOT/lib/minisign_verify.py" "$CECP_RELEASE_PUBKEY" "$sig" "$sums" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  else
    echo "neither minisign nor openssl is installed (dnf/apt install minisign)" >&2
    return 1
  fi
  out="$(grep -m1 '^Trusted comment:' <<<"$out" || true)"
  panel_log "Signature OK (${out:-no trusted comment})"
}

update_check() {
  echo "--- CECP Panel ---"
  [[ -f "$ETC_DIR/panel.json" ]] && cat "$ETC_DIR/panel.json" || echo "  (not installed)"
  echo "  CLI version: $CECP_PANEL_VERSION"
  echo ""
  echo "--- System packages ---"
  for p in nginx mariadb-server php-fpm restic rclone certbot; do
    rpm -q "$p" 2>/dev/null | sed 's/^/  /' || dpkg -l "$p" 2>/dev/null | awk '/^ii/{print "  "$2" "$3}' || echo "  $p: (not from pkg mgr)"
  done
  command -v php &>/dev/null && echo "  $(php -v | head -1)"
  update_load_mirror
  if [[ -n "${CECP_PANEL_RAW_BASE:-}" ]]; then
    echo ""
    echo "  Update mirror: $CECP_PANEL_RAW_BASE"
  fi
  echo "  Update channel: $CECP_PANEL_CHANNEL"
  if update_release_key_present; then
    echo "  Release signature: required (key $CECP_RELEASE_PUBKEY)"
  else
    echo "  Release signature: NOT enforced (no release key yet — SHA256SUMS only)"
  fi
}

update_component() {
  local comp="${1:-all}"
  require_root
  panel_log "Updating component: $comp ..."
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release ]]; then
    case "$comp" in
      nginx) dnf -y update nginx ;;
      mariadb|mysql) dnf -y update mariadb-server mariadb ;;
      php) dnf -y update php\* php-fpm ;;
      certbot) dnf -y update certbot python3-certbot-nginx ;;
      restic) dnf -y update restic ;;
      rclone) dnf -y update rclone ;;
      fail2ban) dnf -y update fail2ban ;;
      os|all)
        [[ "$comp" == "all" ]] && dnf -y update
        ;;
      *) panel_die "Unknown component: $comp (nginx|mariadb|php|certbot|restic|rclone|fail2ban|os|all)" ;;
    esac
  else
    apt-get update -y
    case "$comp" in
      nginx) apt-get install -y --only-upgrade nginx ;;
      mariadb) apt-get install -y --only-upgrade mariadb-server ;;
      php) apt-get install -y --only-upgrade 'php*' ;;
      certbot) apt-get install -y --only-upgrade certbot ;;
      restic) apt-get install -y --only-upgrade restic ;;
      rclone) apt-get install -y --only-upgrade rclone ;;
      os|all) apt-get upgrade -y ;;
      *) panel_die "Unknown component: $comp" ;;
    esac
  fi
  panel_log "Update done: $comp"
}

# cecp-panel update panel [VERSION|latest] [--sha256 HASH]
# The bundle must match dist/<channel>/SHA256SUMS on the mirror (or the pinned hash): the panel
# runs as root, so an unverified download is remote code execution for whoever controls the
# mirror. SHA256SUMS comes from the same mirror, so once a release key is installed its minisign
# signature (made offline, see docs/RELEASING.md) is what actually ties the bundle to the owner.
update_panel() {
  local ver="" pin=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha256) pin="${2:-}"; shift 2 || true ;;
      *) ver="$1"; shift ;;
    esac
  done
  require_root
  update_load_mirror
  local base="${CECP_PANEL_RAW_BASE:-}"
  [[ -n "$base" ]] || panel_die "No update source (default: $CECP_PANEL_DEFAULT_RAW_BASE). Override: cecp-panel update mirror URL"
  update_validate_mirror "$base"
  ver="${ver:-$CECP_PANEL_VERSION}"
  [[ "$ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?|latest)$ ]] || panel_die "Invalid version: '$ver'"
  [[ -z "$pin" || "$pin" =~ ^[0-9a-f]{64}$ ]] || panel_die "--sha256 expects 64 hex chars"

  local tmp bak name expected actual chan="$CECP_PANEL_CHANNEL" dir has_sums=0
  tmp="$(mktemp -d)"
  # dist/<channel>/ when the mirror has it (detected by its SHA256SUMS); mirrors published
  # before channels existed only have dist/, which is the beta line.
  dir="${base%/}/dist/${chan}"
  if curl -fsSL "${dir}/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
    has_sums=1
    panel_log "Channel $chan: ${dir}/"
  else
    dir="${base%/}/dist"
    panel_log "WARN: mirror has no dist/${chan}/ — using legacy dist/ (pre-channel layout)"
    curl -fsSL "${dir}/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null && has_sums=1
  fi
  if [[ -n "$pin" ]]; then
    expected="$pin"
    update_release_key_present && panel_log "Pinned --sha256: release signature not checked (you vouch for this hash)"
  else
    (( has_sums )) \
      || { rm -rf "$tmp"; panel_die "Mirror has no SHA256SUMS in ${dir}/ — refusing an unverified update (or pass --sha256 HASH)"; }
    if update_release_key_present; then
      curl -fsSL "${dir}/SHA256SUMS.minisig" -o "$tmp/SHA256SUMS.minisig" 2>/dev/null \
        || { rm -rf "$tmp"; panel_die "Mirror has no SHA256SUMS.minisig in ${dir}/ — refusing an unsigned update (release key is installed)"; }
      update_verify_signature "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.minisig" \
        || { rm -rf "$tmp"; panel_die "Signature check FAILED for ${dir}/SHA256SUMS — update refused (mirror tampered or wrong key)"; }
    else
      panel_log "WARN: no release signing key installed ($CECP_RELEASE_PUBKEY) — SHA256SUMS is not signature-checked"
    fi
  fi
  name="cecp-panel-${ver}.tar.gz"
  panel_log "Downloading panel $ver ..."
  if ! curl -fsSL "${dir}/${name}" -o "$tmp/bundle.tar.gz"; then
    name="cecp-panel-latest.tar.gz"
    curl -fsSL "${dir}/${name}" -o "$tmp/bundle.tar.gz" || { rm -rf "$tmp"; panel_die "Download failed"; }
  fi
  if [[ -z "$pin" ]]; then
    expected="$(awk -v f="$name" '{n=$2; sub(/^\*/, "", n); if (n == f) print $1}' "$tmp/SHA256SUMS" | head -1)"
  fi
  actual="$(sha256sum "$tmp/bundle.tar.gz" | cut -d' ' -f1)"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    rm -rf "$tmp"
    panel_die "Checksum mismatch for $name (expected ${expected:-none}, got $actual) — update aborted"
  fi
  panel_log "Checksum OK ($actual)"

  tar xzf "$tmp/bundle.tar.gz" -C "$tmp"
  local f
  [[ -f "$tmp/cecp-panel/cecp-panel" && -f "$tmp/cecp-panel/lib/common.sh" ]] || { rm -rf "$tmp"; panel_die "Bad bundle layout"; }
  for f in "$tmp/cecp-panel/cecp-panel" "$tmp/cecp-panel"/lib/*.sh; do
    bash -n "$f" || { rm -rf "$tmp"; panel_die "Bundle has a syntax error in $(basename "$f") — update aborted"; }
  done

  mkdir -p "$VAR_LIB/backups"
  bak="$(mktemp -d "$VAR_LIB/backups/panel-$(date +%Y%m%d_%H%M%S)-XXXX")"
  [[ -d "$INSTALL_ROOT" ]] && cp -a "$INSTALL_ROOT" "$bak/opt-cecp-panel"
  cp -a "$BIN_PATH" "$bak/cecp-panel.bin" 2>/dev/null || true
  panel_log "Backup previous panel at $bak"
  if ! { if command -v rsync &>/dev/null; then
           # bin/ holds the agent heartbeat script generated on the VPS (cron calls it)
           rsync -a --delete --exclude 'etc/' --exclude 'bin/' "$tmp/cecp-panel/" "$INSTALL_ROOT/"
         else
           cp -a "$tmp/cecp-panel/." "$INSTALL_ROOT/"
         fi \
         && chmod +x "$INSTALL_ROOT/cecp-panel" "$INSTALL_ROOT"/lib/*.sh \
         && install -m 0755 "$INSTALL_ROOT/cecp-panel" "$BIN_PATH"; }; then
    rm -rf "$INSTALL_ROOT"
    cp -a "$bak/opt-cecp-panel" "$INSTALL_ROOT"
    [[ -f "$bak/cecp-panel.bin" ]] && install -m 0755 "$bak/cecp-panel.bin" "$BIN_PATH"
    rm -rf "$tmp"
    panel_die "Install failed — previous panel restored from $bak"
  fi
  if [[ -f "$INSTALL_ROOT/templates/cecp-panel.bash-completion" ]]; then
    install -D -m 0644 "$INSTALL_ROOT/templates/cecp-panel.bash-completion" /etc/bash_completion.d/cecp-panel 2>/dev/null || true
  fi
  # "latest" is a download alias, not a version: record what the bundle actually contains.
  local installed_ver="$ver"
  if [[ "$ver" == "latest" ]]; then
    installed_ver="$(grep -m1 -oE '^CECP_PANEL_VERSION="\$\{CECP_PANEL_VERSION:-[0-9][^}"]*' "$tmp/cecp-panel/lib/common.sh" | sed 's/.*:-//' || true)"
    [[ "$installed_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$ ]] || installed_ver="$ver"
  fi
  python3 - "$ETC_DIR/panel.json" "$installed_ver" "$bak" "$actual" <<'PY'
import json, os, sys
from datetime import datetime, timezone
p, ver, bak, sha = sys.argv[1:5]
d = {}
if os.path.isfile(p):
    try:
        d = json.load(open(p))
    except ValueError:
        d = {}
d.update(version=ver, updated_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
         previous_backup=bak, bundle_sha256=sha, standalone=True)
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.chmod(p, 0o600)
PY
  rm -rf "$tmp"
  panel_log "Panel updated to $ver. Config in $ETC_DIR preserved."
  # Non-fatal, run by the NEW code: a failing probe never aborts or rolls back the update.
  echo "--- Probe (uncached pages) ---"
  "$BIN_PATH" site probe --all --summary || true
}

update_mirror_set() {
  require_root
  [[ -n "${1:-}" ]] || panel_die "Usage: cecp-panel update mirror URL (default source: $CECP_PANEL_DEFAULT_RAW_BASE)"
  update_save_mirror "$1"
  panel_log "Update mirror saved (overrides default GitHub raw base). Use: cecp-panel update panel latest"
}

UPDATE_ALL_CRON="/etc/cron.d/cecp-panel-update-all"
UPDATE_ALL_LOG="$LOG_DIR/update-all.log"

# cecp-panel update all [--skip-os] [--skip-wp] [--skip-panel]
# One-shot maintenance: OS packages (nginx/PHP/MariaDB/Redis/restic/rclone/certbot/fail2ban),
# wp-cli, WordPress core+plugins+themes of every site (same safety copy + rollback as
# `wp update`), then the panel itself (only if an update mirror is configured). Each step is
# isolated in a subshell so one failure (panel_die) does not abort the rest.
update_all() {
  require_root
  local skip_os=0 skip_wp=0 skip_panel=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-os) skip_os=1; shift ;;
      --skip-wp) skip_wp=1; shift ;;
      --skip-panel) skip_panel=1; shift ;;
      *) panel_die "Usage: cecp-panel update all [--skip-os] [--skip-wp] [--skip-panel]" ;;
    esac
  done
  panel_log "=== update all: starting ==="
  local -a lines=()

  if (( skip_os )); then
    lines+=("os packages: skipped (--skip-os)")
  else
    panel_log "Updating OS packages (nginx, PHP, MariaDB, Redis, restic, rclone, certbot, fail2ban) ..."
    if ( update_component all ); then lines+=("os packages: updated"); else lines+=("os packages: FAILED (see panel.log)"); fi
    # New binaries only take effect after a reload/restart; nginx/PHP-FPM reload gracefully
    # (rollback on a bad config), MariaDB/Redis need a short restart to run the new binary.
    nginx_test_and_reload || panel_log "WARN: nginx -t failed after the OS update — check manually"
    php_fpm_reload_all || true
    systemctl try-restart mariadb 2>/dev/null || systemctl try-restart mysql 2>/dev/null || true
    systemctl try-restart redis 2>/dev/null || systemctl try-restart redis-server 2>/dev/null || true
    if declare -F monitor_run >/dev/null 2>&1; then
      monitor_run >/dev/null 2>&1 || true  # restarts + alerts on anything the update left down
    fi
    if command -v needs-restarting &>/dev/null; then
      needs-restarting -r &>/dev/null || lines+=("REBOOT recommended (kernel or a core library changed)")
    elif [[ -f /var/run/reboot-required ]]; then
      lines+=("REBOOT recommended (/var/run/reboot-required)")
    fi
  fi

  if ( wp_ensure_cli && wp_update_cli ); then lines+=("wp-cli: up to date"); else lines+=("wp-cli: FAILED (see panel.log)"); fi

  if (( skip_wp )); then
    lines+=("wordpress sites: skipped (--skip-wp)")
  else
    panel_log "Updating WordPress core/plugins/themes on every site ..."
    local f d ok=0 rolled=0 failed=0 staging=0
    shopt -s nullglob
    for f in "$SITES_DIR"/*.json; do
      d="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f" 2>/dev/null)" || continue
      [[ "$(wp_site_is_wordpress "$d" 2>/dev/null)" == "True" ]] || continue
      if [[ -n "$(site_json_get_or "$d" staging_of "")" ]]; then
        staging=$((staging + 1))
        continue
      fi
      if ( wp_update_site "$d" ); then
        ok=$((ok + 1))
      elif [[ "$(site_json_get_or "$d" wp_last_update_result "")" == rolled_back:* ]]; then
        rolled=$((rolled + 1))
      else
        failed=$((failed + 1))
      fi
    done
    shopt -u nullglob
    lines+=("wordpress sites: $ok up to date/updated, $rolled rolled back, $failed failed, $staging staging copies skipped")
  fi

  if (( skip_panel )); then
    lines+=("panel: skipped (--skip-panel)")
  else
    update_load_mirror
    if [[ -z "${CECP_PANEL_RAW_BASE:-}" ]]; then
      lines+=("panel: no update source — skipped")
    elif ( update_panel latest ); then
      lines+=("panel: updated")
    else
      lines+=("panel: FAILED (see panel.log)")
    fi
  fi

  panel_log "=== update all: summary ==="
  local line
  for line in "${lines[@]}"; do panel_log "  - $line"; done
  if declare -F notify_event >/dev/null 2>&1; then
    notify_event update_all_done info "$(printf '%s\n' "${lines[@]}")"
  fi
  panel_log "=== update all: done ==="
}

update_all_enable_cron() {
  require_root
  cat >"$UPDATE_ALL_CRON" <<EOF
# CECP Panel — periodic full update (OS packages, wp-cli, WordPress sites, panel itself)
10 4 * * 0 root /usr/local/bin/cecp-panel update all >>${UPDATE_ALL_LOG} 2>&1
EOF
  chmod 644 "$UPDATE_ALL_CRON"
  panel_log "Periodic update enabled: weekly Sunday 04:10 UTC ($UPDATE_ALL_CRON). Log: $UPDATE_ALL_LOG"
}

update_all_disable_cron() {
  require_root
  rm -f "$UPDATE_ALL_CRON"
  panel_log "Periodic update (cron) disabled"
}
