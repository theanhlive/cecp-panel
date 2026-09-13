#!/usr/bin/env bash
# Safe WordPress updates: cecp-panel wp update DOMAIN | wp auto-update | wp rollback
# Plan (core / plugins / themes with an update) → local safety copy (files + DB) → update as
# the site user → health checks (WordPress loads with every plugin, home page answers,
# uncached) → keep, or put the safety copy back and report what broke it.
set -euo pipefail

WP_UPDATE_DIR="$VAR_LIB/wp-update"
WP_UPDATE_CRON="/etc/cron.d/cecp-wp-update"
WP_UPDATE_LOG="$LOG_DIR/wp-update.log"

# Prints the pending updates as JSON: {"core": "6.x"|"", "plugins": [[name, from, to]], "themes": [...]}
wp_update_plan() {
  local domain="$1" exclude="$2" no_major="$3" core plugins themes
  core="$(wp_site_exec "$domain" core check-update --format=json 2>/dev/null || true)"
  plugins="$(wp_site_exec "$domain" plugin list --update=available --fields=name,version,update_version --format=json 2>/dev/null || echo '[]')"
  themes="$(wp_site_exec "$domain" theme list --update=available --fields=name,version,update_version --format=json 2>/dev/null || echo '[]')"
  CORE="$core" PLUGINS="$plugins" THEMES="$themes" python3 - "$exclude" "$no_major" \
    "$(wp_site_exec "$domain" core version 2>/dev/null || echo 0)" <<'PY'
import json, os, sys
exclude = {x.strip() for x in sys.argv[1].split(",") if x.strip()}
no_major, current = sys.argv[2] == "1", sys.argv[3]

def load(name):
    raw = (os.environ.get(name) or "").strip()
    try:
        return json.loads(raw) if raw.startswith("[") else []
    except ValueError:
        return []

core = ""
for c in load("CORE"):
    v = str(c.get("version", ""))
    if no_major and c.get("update_type") == "major":
        continue
    if v and not core:
        core = v
pick = lambda items: [[i["name"], i.get("version", ""), i.get("update_version", "")]
                      for i in items if i.get("name") not in exclude]
print(json.dumps({"current": current, "core": core, "plugins": pick(load("PLUGINS")), "themes": pick(load("THEMES"))}))
PY
}

wp_update_health() {
  local domain="$1" out code
  out="$(wp_site_exec "$domain" eval 'echo "cecp-wp-ok";' 2>&1)" || true
  if [[ "$out" != *cecp-wp-ok* ]]; then
    echo "WordPress does not load: $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-300)"
    return 1
  fi
  if ! code="$(site_http_check "$domain")"; then
    echo "home page answers HTTP $code"
    return 1
  fi
}

# cecp-panel wp update DOMAIN [--exclude a,b] [--no-major] [--dry-run]
#                   wp update --scheduled   (sites with auto-update on; used by cron)
wp_update_site() {
  local domain="${1:-}"
  shift || true
  if [[ "$domain" == "--scheduled" ]]; then
    wp_update_scheduled
    return
  fi
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  [[ "$(wp_site_is_wordpress "$domain")" == "True" ]] || panel_die "Not a WordPress site: $domain"
  local exclude no_major dry=0
  exclude="$(site_json_get_or "$domain" wp_update_exclude "")"
  no_major="$([[ "$(site_json_get_or "$domain" wp_update_no_major false)" == "True" ]] && echo 1 || echo 0)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude) exclude="${2:-}"; shift 2 || true ;;
      --no-major) no_major=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) panel_die "Usage: cecp-panel wp update DOMAIN [--exclude plugin,theme] [--no-major] [--dry-run]" ;;
    esac
  done
  [[ -z "$exclude" || "$exclude" =~ ^[a-z0-9._,-]+$ ]] || panel_die "--exclude: comma-separated plugin/theme slugs"
  wp_ensure_cli
  local plan summary
  plan="$(wp_update_plan "$domain" "$exclude" "$no_major")"
  summary="$(python3 -c '
import json, sys
p = json.loads(sys.argv[1])
parts = []
if p["core"]:
    parts.append("core %s -> %s" % (p["current"], p["core"]))
parts += ["%s %s -> %s" % tuple(x) for x in p["plugins"]]
parts += ["theme %s %s -> %s" % tuple(x) for x in p["themes"]]
print("; ".join(parts))
' "$plan")"
  if [[ -z "$summary" ]]; then
    panel_log "WordPress $domain is up to date$([[ -n "$exclude" ]] && echo " (excluded: $exclude)")"
    site_json_set "$domain" wp_last_update_check "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
  fi
  echo "=== WordPress update plan: $domain ==="
  tr ';' '\n' <<<"$summary" | sed 's/^ */  /'
  if (( dry )); then
    panel_log "Dry run only — nothing changed"
    return 0
  fi
  site_lock "$domain"
  local why
  if ! why="$(wp_update_health "$domain")"; then
    panel_die "$domain is not healthy BEFORE updating ($why) — fix that first; nothing changed"
  fi
  local stamp work docroot need avail
  stamp="$(date +%Y%m%d_%H%M%S)"
  work="$WP_UPDATE_DIR/$(domain_slug "$domain")-${stamp}"
  docroot="$(site_json_get "$domain" docroot)"
  need="$(du -sk "$docroot" 2>/dev/null | cut -f1)"
  mkdir -p "$WP_UPDATE_DIR"
  avail="$(df -Pk "$WP_UPDATE_DIR" | awk 'NR==2 {print $4}')"
  (( avail > need * 2 )) || panel_die "Not enough free disk for a safety copy of $domain (need ~$(( need * 2 / 1024 ))M) — nothing changed"
  panel_log "Safety copy of $domain ..."
  backup_restore_safety_copy "$domain" "$work/pre" || { rm -rf "$work"; panel_die "Could not save $domain — update aborted, nothing changed"; }
  printf '%s\n' "$plan" >"$work/plan.json"
  panel_log "Updating $domain: $summary"
  local log="$work/update.log" rc=0 names
  local -a core_args=()
  [[ "$no_major" == 1 ]] && core_args+=(--minor)
  {
    if [[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["core"])' "$plan")" != "" ]]; then
      wp_site_exec "$domain" core update "${core_args[@]}" || rc=1
      wp_site_exec "$domain" core update-db || rc=1
    fi
    names="$(python3 -c 'import json,sys; print(" ".join(x[0] for x in json.loads(sys.argv[1])["plugins"]))' "$plan")"
    if [[ -n "$names" ]]; then
      # shellcheck disable=SC2086  # slugs validated by WordPress, split on purpose
      wp_site_exec "$domain" plugin update $names || rc=1
    fi
    names="$(python3 -c 'import json,sys; print(" ".join(x[0] for x in json.loads(sys.argv[1])["themes"]))' "$plan")"
    if [[ -n "$names" ]]; then
      # shellcheck disable=SC2086
      wp_site_exec "$domain" theme update $names || rc=1
    fi
    wp_site_exec "$domain" language core update --quiet || true
    wp_site_exec "$domain" language plugin update --all --quiet || true
    wp_site_exec "$domain" language theme update --all --quiet || true
  } >>"$log" 2>&1
  rm -f "$docroot/.maintenance"
  # New code must be what the checks see: OPcache would serve the old files for up to 60 s.
  php_fpm_reload_all >/dev/null 2>&1 || true
  optimize_purge_cache "$domain" >/dev/null 2>&1 || true
  wp_site_exec "$domain" cache flush >/dev/null 2>&1 || true
  sleep 1
  if (( rc == 0 )) && why="$(wp_update_health "$domain")"; then
    # Keep only this safety copy (manual undo: cecp-panel wp rollback DOMAIN).
    find "$WP_UPDATE_DIR" -maxdepth 1 -name "$(domain_slug "$domain")-*" ! -path "$work" -exec rm -rf {} + 2>/dev/null || true
    site_json_set "$domain" wp_last_update "$(date -u +%Y-%m-%dT%H:%M:%SZ)" wp_last_update_result ok \
      wp_last_update_check "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    panel_log "WordPress update OK: $domain ($summary). Undo: cecp-panel wp rollback $domain"
    notify_event wp_update_done info "WordPress updated: $domain — $summary" "$domain" \
      "$(python3 -c 'import json,sys; print(json.dumps({"plan": json.loads(sys.argv[1])}))' "$plan")"
    return 0
  fi
  (( rc == 0 )) || why="an update command failed (see $log)"
  panel_log "ERROR: after updating, $why — rolling back"
  if backup_restore_apply "$domain" "$work/pre/database.sql" "$work/pre/public_html.tar.gz" "${stamp}-rb" \
     && wp_update_health "$domain" >/dev/null; then
    site_json_set "$domain" wp_last_update "$(date -u +%Y-%m-%dT%H:%M:%SZ)" wp_last_update_result "rolled_back: $why"
    notify_event wp_update_rolled_back critical "WordPress update of $domain rolled back: $why. Updates tried: $summary" "$domain" \
      "$(python3 -c 'import json,sys; print(json.dumps({"reason": sys.argv[2], "plan": json.loads(sys.argv[1])}))' "$plan" "$why")"
    panel_die "Update rolled back — $domain is back to its previous state. Details: $log"
  fi
  site_json_set "$domain" wp_last_update_result "failed: $why"
  notify_event wp_update_failed critical "WordPress update of $domain FAILED and rollback did not bring it back — manual action needed ($work)" "$domain"
  panel_die "Update and rollback failed — manual action needed. Safety copy: $work/pre"
}

wp_update_scheduled() {
  require_root
  local f d failed=0
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    d="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    [[ "$(site_json_get_or "$d" wp_autoupdate false)" == "True" ]] || continue
    # Each site in a subshell: a rollback (panel_die) must not stop the other sites.
    ( wp_update_site "$d" ) || failed=$((failed + 1))
  done
  shopt -u nullglob
  (( failed == 0 )) || panel_log "Scheduled WordPress updates: $failed site(s) rolled back or failed"
  return 0
}

# cecp-panel wp auto-update DOMAIN on [--exclude a,b] [--no-major] | off
wp_auto_update() {
  local domain="${1:-}" action="${2:-status}"
  shift $(( $# < 2 ? $# : 2 ))
  domain="${domain,,}"
  require_root
  validate_domain "$domain"
  [[ "$(wp_site_is_wordpress "$domain")" == "True" ]] || panel_die "Not a WordPress site: $domain"
  case "$action" in
    on)
      local exclude="" no_major=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --exclude) exclude="${2:-}"; shift 2 || true ;;
          --no-major) no_major=true; shift ;;
          *) panel_die "Unknown option: $1" ;;
        esac
      done
      [[ -z "$exclude" || "$exclude" =~ ^[a-z0-9._,-]+$ ]] || panel_die "--exclude: comma-separated plugin/theme slugs"
      site_json_set "$domain" wp_autoupdate true wp_update_exclude "$exclude" wp_update_no_major "$no_major"
      printf '# CECP Panel — safe WordPress updates with rollback (sites with wp auto-update on)\n40 3 * * * root /usr/local/bin/cecp-panel wp update --scheduled >>%s 2>&1\n' \
        "$WP_UPDATE_LOG" >"$WP_UPDATE_CRON"
      chmod 644 "$WP_UPDATE_CRON"
      panel_log "Auto-update ON for $domain (daily 03:40; rollback on failure)$([[ -n "$exclude" ]] && echo "; excluded: $exclude")"
      ;;
    off)
      site_json_set "$domain" wp_autoupdate false
      panel_log "Auto-update OFF for $domain"
      ;;
    status)
      echo "Auto-update for $domain: $(site_json_get_or "$domain" wp_autoupdate false) (exclude: $(site_json_get_or "$domain" wp_update_exclude -), no major: $(site_json_get_or "$domain" wp_update_no_major false))"
      echo "Last update: $(site_json_get_or "$domain" wp_last_update never) — $(site_json_get_or "$domain" wp_last_update_result -)"
      ;;
    *) panel_die "Usage: cecp-panel wp auto-update DOMAIN on [--exclude a,b] [--no-major] | off | status" ;;
  esac
}

# cecp-panel wp rollback DOMAIN [--yes] — put back the safety copy of the last update.
wp_update_rollback() {
  local domain="${1:-}" yes=0 work code
  domain="${domain,,}"
  [[ "${2:-}" == "--yes" || "${2:-}" == "-y" ]] && yes=1
  require_root
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  work="$(find "$WP_UPDATE_DIR" -maxdepth 1 -type d -name "$(domain_slug "$domain")-*" 2>/dev/null | sort | tail -1)"
  [[ -n "$work" && -s "$work/pre/database.sql" ]] || panel_die "No update safety copy for $domain"
  echo "Roll $domain back to its state before the update of $(basename "$work" | sed -E 's/.*-([0-9]{8})_([0-9]{6})$/\1 \2/')."
  echo "Everything changed on the site since then (posts, orders, uploads) will be lost."
  if (( ! yes )); then
    [[ -t 0 ]] || panel_die "Pass --yes when not running interactively"
    local answer
    read -r -p "Type the domain to continue: " answer
    [[ "$answer" == "$domain" ]] || panel_die "Aborted"
  fi
  site_lock "$domain"
  backup_restore_apply "$domain" "$work/pre/database.sql" "$work/pre/public_html.tar.gz" "$(date +%Y%m%d_%H%M%S)-undo" \
    || panel_die "Rollback failed (safety copy: $work/pre)"
  code="$(site_http_check "$domain" || true)"
  site_json_set "$domain" wp_last_update_result "manually rolled back"
  notify_event wp_update_rolled_back warning "WordPress update of $domain rolled back by the operator (HTTP $code)" "$domain"
  panel_log "Rolled back $domain (HTTP $code)"
}
