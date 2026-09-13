#!/usr/bin/env bash
# Staging copies: cecp-panel site staging DOMAIN | site staging-push DOMAIN
# A staging site is a normal panel site (own user, pool, DB, Redis ACL) with meta
# staging_of=DOMAIN, noindex, optional site-wide basic auth and a guard mu-plugin that blocks
# e-mail and background jobs. Pushing copies its files and/or database onto the live site
# after a safety copy, and puts the live site back if it does not answer afterwards.
set -euo pipefail

STAGING_WORK_DIR="$VAR_LIB/staging-push"

# cecp-panel site staging DOMAIN [--name staging.DOMAIN] [--no-auth]
site_staging() {
  local src="${1:-}"
  shift || true
  src="${src,,}"
  require_root
  validate_domain "$src"
  [[ -f "$(site_meta_path "$src")" ]] || panel_die "Site not found: $src"
  [[ -z "$(site_json_get_or "$src" staging_of "")" ]] || panel_die "$src is itself a staging copy"
  local existing dst="staging.${src}" auth=1
  existing="$(site_json_get_or "$src" staging_site "")"
  [[ -z "$existing" || ! -f "$(site_meta_path "$existing")" ]] \
    || panel_die "$src already has a staging copy: $existing (push it, or remove it: cecp-panel site remove $existing)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) dst="${2:-}"; dst="${dst,,}"; shift 2 || true ;;
      --no-auth) auth=0; shift ;;
      *) panel_die "Usage: cecp-panel site staging DOMAIN [--name staging.DOMAIN] [--no-auth]" ;;
    esac
  done
  validate_domain "$dst"
  [[ ! -f "$(site_meta_path "$dst")" ]] || panel_die "Site already exists: $dst"
  site_lock "$src"
  panel_log "Creating staging copy $dst of $src ..."
  CECP_DUPLICATE_NO_CRON=1 site_duplicate "$src" "$dst"
  site_json_set "$dst" staging_of "$src" noindex true
  site_json_set "$src" staging_site "$dst"
  if [[ "$(wp_site_is_wordpress "$dst")" == "True" ]]; then
    local mudir
    mudir="$(site_json_get "$dst" docroot)/wp-content/mu-plugins"
    install -d -o "$(site_json_get "$dst" site_user)" -g "$(site_json_get "$dst" site_user)" -m 755 "$mudir"
    install -m 644 -o root -g root "$PANEL_ROOT/templates/mu-plugins/cecp-staging.php" "$mudir/cecp-staging.php"
    wp_site_exec "$dst" config set WP_ENVIRONMENT_TYPE staging --type=constant >/dev/null
    wp_site_exec "$dst" option update blog_public 0 >/dev/null 2>&1 || true  # "error" when already 0
  fi
  if (( auth )); then
    site_auth "$dst" on --user staging
  else
    site_render_vhost "$dst"
    nginx_test_and_reload || panel_die "nginx rejected the vhost for $dst (config rolled back)"
  fi
  local scheme=http
  [[ "$(site_json_get_or "$dst" ssl false)" == "True" ]] && scheme=https
  panel_log "Staging ready: ${scheme}://$dst (noindex, e-mail blocked$( (( auth )) && echo ", basic auth"))"
  [[ "$scheme" == https ]] || panel_log "  DNS: point $dst at this server, then: cecp-panel ssl issue $dst (or a *.$src wildcard)"
  panel_log "  Push to live: cecp-panel site staging-push $src [--files-only|--db-only]"
}

# cecp-panel site staging-push DOMAIN [--files-only|--db-only] [--dry-run] [--yes]
site_staging_push() {
  local live="${1:-}"
  shift || true
  live="${live,,}"
  require_root
  validate_domain "$live"
  [[ -f "$(site_meta_path "$live")" ]] || panel_die "Site not found: $live"
  local stg files=1 db=1 dry=0 yes=0
  stg="$(site_json_get_or "$live" staging_site "")"
  [[ -n "$stg" && -f "$(site_meta_path "$stg")" ]] || panel_die "$live has no staging copy (create one: cecp-panel site staging $live)"
  [[ "$(site_json_get_or "$stg" staging_of "")" == "$live" ]] || panel_die "$stg is not a staging copy of $live"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --files-only) db=0; shift ;;
      --db-only) files=0; shift ;;
      --dry-run) dry=1; shift ;;
      --yes|-y) yes=1; shift ;;
      *) panel_die "Usage: cecp-panel site staging-push DOMAIN [--files-only|--db-only] [--dry-run] [--yes]" ;;
    esac
  done
  (( files || db )) || panel_die "--files-only and --db-only exclude each other"
  echo "=== Push staging → live ==="
  echo "  from:  $stg (created $(site_json_get_or "$stg" installed_at ?))"
  echo "  to:    $live"
  (( files )) && echo "  files: replaced by the staging files (live wp-config.php is kept)"
  (( db )) && echo "  DB:    REPLACED by the staging database — orders, comments, users and form entries"
  (( db )) && echo "         created on the live site since the staging copy was made will be LOST"
  echo "  safety: live files + DB saved first; automatic rollback if the site does not answer"
  if (( dry )); then
    panel_log "Dry run only — nothing changed"
    return 0
  fi
  if (( ! yes )); then
    [[ -t 0 ]] || panel_die "Pushing replaces the live site; pass --yes when not running interactively"
    local answer
    read -r -p "Type the live domain to continue: " answer
    [[ "$answer" == "$live" ]] || panel_die "Aborted"
  fi
  site_lock "$live"
  site_lock "$stg"
  local stamp work docroot sql archive code blog_public="" scheme=http
  stamp="$(date +%Y%m%d_%H%M%S)"
  work="$STAGING_WORK_DIR/$(domain_slug "$live")-${stamp}"
  docroot="$(site_json_get "$live" docroot)"
  (umask 077; mkdir -p "$work/stg")
  panel_log "Saving the live site ($live) ..."
  backup_restore_safety_copy "$live" "$work/pre" || { rm -rf "$work"; panel_die "Could not save the live site — push aborted, nothing changed"; }
  if [[ "$(wp_site_is_wordpress "$live")" == "True" ]]; then
    blog_public="$(wp_site_exec "$live" option get blog_public 2>/dev/null || echo 1)"
  fi
  sql="$work/pre/database.sql"
  archive="$work/pre/public_html.tar.gz"
  if (( db )); then
    panel_log "Exporting the staging database ..."
    mysqldump --single-transaction --quick --routines --triggers "$(site_json_get "$stg" db_name)" >"$work/stg/database.sql" \
      || { rm -rf "$work"; panel_die "Staging database export failed — nothing changed"; }
    sql="$work/stg/database.sql"
  fi
  if (( files )); then
    local stg_doc
    stg_doc="$(site_json_get "$stg" docroot)"
    panel_log "Packing the staging files ..."
    # Archive root must be the live docroot's basename (both are public_html).
    tar -C "$(dirname "$stg_doc")" -czf "$work/stg/public_html.tar.gz" \
      --transform "s,^$(basename "$stg_doc"),$(basename "$docroot")," "$(basename "$stg_doc")" \
      || { rm -rf "$work"; panel_die "Packing staging files failed — nothing changed"; }
    archive="$work/stg/public_html.tar.gz"
  fi
  panel_log "Replacing $live ..."
  if backup_restore_apply "$live" "$sql" "$archive" "$stamp" && staging_push_fixup "$live" "$stg" "$work" "$files" "$db" "$blog_public"; then
    sleep 1
    if code="$(site_http_check "$live")"; then
      rm -rf "$work/stg"
      [[ "$(site_json_get_or "$live" cf_edge false)" == "True" ]] && { ( cf_purge_host "$live" ) || panel_log "WARN: Cloudflare purge failed for $live"; }
      panel_log "Staging pushed to $live (HTTP $code). Pre-push copy kept in $work/pre"
      notify_event staging_pushed info "Staging $stg pushed to $live ($( (( files )) && echo files)$( (( files && db )) && echo " + ")$( (( db )) && echo database))" "$live"
      return 0
    fi
    panel_log "ERROR: $live answers HTTP $code after the push — rolling back"
  else
    panel_log "ERROR: push step failed — rolling back"
  fi
  if backup_restore_apply "$live" "$work/pre/database.sql" "$work/pre/public_html.tar.gz" "${stamp}-rb" \
     && code="$(site_http_check "$live")"; then
    rm -rf "${docroot}.pre-restore-${stamp}"
    notify_event staging_push_rolled_back critical "Push of $stg to $live failed; live site restored (HTTP $code)" "$live"
    panel_die "Push failed; the live site was put back (HTTP $code). Staging export left in $work/stg"
  fi
  notify_event staging_push_failed critical "Push of $stg to $live FAILED and rollback did not bring the site back — manual action needed ($work)" "$live"
  panel_die "Push and rollback failed — manual action needed. Safety copy: $work/pre"
}

# After the staging files/DB landed on live: keep live's wp-config.php, drop the staging guard,
# rewrite staging URLs to live, restore live's search-engine visibility.
staging_push_fixup() {
  local live="$1" stg="$2" work="$3" files="$4" db="$5" blog_public="$6" docroot scheme=http
  docroot="$(site_json_get "$live" docroot)"
  if (( files )); then
    tar -xzf "$work/pre/public_html.tar.gz" -O "$(basename "$docroot")/wp-config.php" >"$docroot/wp-config.php" 2>/dev/null \
      || panel_log "WARN: could not restore the live wp-config.php (kept the staging one with live DB credentials)"
    site_wp_config_sync "$live"
    rm -f "$docroot/wp-content/mu-plugins/cecp-staging.php"
    if [[ "$(site_json_get_or "$live" cache_autopurge false)" == "True" ]]; then
      cache_auto_purge "$live" on >/dev/null
    fi
  fi
  [[ "$(wp_site_is_wordpress "$live")" == "True" ]] || return 0
  if (( db )); then
    site_cert_dir "$live" >/dev/null && scheme=https
    wp_site_exec "$live" search-replace "//${stg}" "//${live}" --all-tables --skip-columns=guid --quiet || return 1
    wp_site_exec "$live" search-replace "\\/\\/${stg}" "\\/\\/${live}" --all-tables --skip-columns=guid --quiet 2>/dev/null || true
    if [[ "$scheme" == https ]]; then
      wp_site_exec "$live" search-replace "http://${live}" "https://${live}" --all-tables --skip-columns=guid --quiet 2>/dev/null || true
    fi
    # Direct SQL above: drop the (Redis) object cache before reading/writing options.
    wp_site_exec "$live" cache flush >/dev/null 2>&1 || true
    ( site_wp_set_urls "$live" "${scheme}://${live}" ) || return 1
    wp_site_exec "$live" option update blog_public "${blog_public:-1}" >/dev/null 2>&1 || true
  fi
  wp_site_exec "$live" cache flush >/dev/null 2>&1 || true
  optimize_purge_cache "$live" >/dev/null 2>&1 || true
}
