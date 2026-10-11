#!/usr/bin/env bash
# CECP Panel — post-upgrade site probe (read-only).
#
# Why: after the 1.12 upgrade the pool template disables putenv(); WooCommerce 6.2.2 calls it, so
# every UNCACHED page answered HTTP 500 for days while the home page kept coming from the page
# cache. A probe that only asks for the cached home page cannot see that. This one asks for pages
# that are never cached and reads the logs for the cause. It never writes, restarts or purges.

PROBE_LOG_LINES=200

# probe_domains — one panel domain per line.
probe_domains() {
  local f
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f" 2>/dev/null || true
  done
  shopt -u nullglob
}

# probe_http_code DOMAIN PATH — status of one local request (Host + SNI via --resolve), 000 when
# nothing answered. HTTPS first (self-signed or not: -k), plain HTTP when the site has no TLS.
probe_http_code() {
  local domain="$1" path="$2" code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve "${domain}:443:127.0.0.1" \
    -A "CECP-Probe/${CECP_PANEL_VERSION}" "https://${domain}${path}" 2>/dev/null || true)"
  if [[ -z "$code" || "$code" == 000 ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --resolve "${domain}:80:127.0.0.1" \
      -A "CECP-Probe/${CECP_PANEL_VERSION}" "http://${domain}${path}" 2>/dev/null || true)"
  fi
  echo "${code:-000}"
}

# probe_level CODE — PASS | WARN | FAIL
probe_level() {
  local code="$1"
  if [[ ! "$code" =~ ^[0-9]{3}$ || "$code" == 000 ]]; then echo WARN
  elif (( 10#$code >= 500 )); then echo FAIL
  elif (( 10#$code >= 200 && 10#$code < 400 )) || [[ "$code" == 401 || "$code" == 403 ]]; then echo PASS
  else echo WARN
  fi
}

# probe_log_names DOMAIN — function names the PHP logs blame, one per line (sorted, unique):
# "Call to undefined function NAME()" and "NAME() has been disabled for security reasons".
probe_log_names() {
  local domain="$1" f
  {
    tail -n "$PROBE_LOG_LINES" "/var/log/nginx/${domain}-error.log" 2>/dev/null || true
    shopt -s nullglob
    for f in /var/log/php-fpm/*.log /var/log/php*-fpm/*.log "$LOG_DIR"/php-fpm-"$(domain_slug "$domain")"*.log; do
      [[ -f "$f" ]] && tail -n "$PROBE_LOG_LINES" "$f" 2>/dev/null
    done
    shopt -u nullglob
  } | grep -oE 'Call to undefined function [A-Za-z0-9_]+\(\)|[A-Za-z0-9_]+\(\) has been disabled for security reasons' \
    | sed -E 's/^Call to undefined function //; s/\(\).*$//' | sort -u || true
}

# probe_remedy DOMAIN NAME — what to do about one blamed function.
probe_remedy() {
  local domain="$1" name="$2" list=""
  list="$(php_cfg_disable_functions "$domain" 2>/dev/null || true)"
  if [[ "$name" == putenv ]]; then
    echo "  putenv() is disabled in the pool of $domain. Fix: cecp-panel php config $domain allow_putenv=on"
    echo "    (this re-opens the LD_PRELOAD vector for that site: update the plugin that calls putenv instead when you can)"
  elif [[ ",${list}," == *",${name},"* ]]; then
    echo "  ${name}() is in the disable_functions of the pool of $domain (${list}); there is no per-site switch: update or replace the plugin that calls it"
  fi
}

# probe_site DOMAIN — prints the result lines; returns 2 when any request failed (HTTP >= 500).
probe_site() {
  local domain="$1" wp rc=0 paths=() p shown code level names n
  wp="$(site_json_get_or "$domain" wordpress "")"
  case "${wp,,}" in true|1|yes) paths+=("/wp-login.php" "/wp-json/") ;; esac
  paths+=("/?cecp_probe=$(rand_alnum 12)")
  for p in "${paths[@]}"; do
    code="$(probe_http_code "$domain" "$p")"
    level="$(probe_level "$code")"
    shown="$p"
    [[ "$p" != *\?* ]] || shown="${p%%\?*}?cecp_probe=<random>"
    printf '%s %s %s HTTP %s\n' "$level" "$domain" "$shown" "$code"
    [[ "$level" == FAIL ]] && rc=2
  done
  if (( rc != 0 )); then
    names="$(probe_log_names "$domain")"
    if [[ -n "$names" ]]; then
      while IFS= read -r n; do
        [[ -n "$n" ]] && probe_remedy "$domain" "$n"
      done <<<"$names"
    else
      echo "  no 'undefined function' / 'disabled for security reasons' line in the last ${PROBE_LOG_LINES} log lines: cecp-panel log nginx $domain"
      if [[ ",$(php_cfg_disable_functions "$domain" 2>/dev/null || true)," == *",putenv,"* ]]; then
        echo "  if a plugin calls putenv() (WooCommerce 6.x does): cecp-panel php config $domain allow_putenv=on"
        echo "    (this re-opens the LD_PRELOAD vector for that site: update the plugin instead when you can)"
      fi
    fi
  fi
  return "$rc"
}

# site probe [DOMAIN|--all]  (also: --summary, the quiet form used after upgrades)
site_probe() {
  local target="" summary=0 arg
  local usage="Usage: cecp-panel site probe DOMAIN|--all"
  for arg in "$@"; do
    case "$arg" in
      --all) target="--all" ;;
      --summary) summary=1 ;;
      -*) panel_die "$usage" ;;
      *) [[ -z "$target" ]] || panel_die "$usage"; target="${arg,,}" ;;
    esac
  done
  [[ -n "$target" ]] || panel_die "$usage"
  local -a doms=()
  if [[ "$target" == "--all" ]]; then
    mapfile -t doms < <(probe_domains)
  else
    validate_domain "$target"
    [[ -f "$(site_meta_path "$target")" ]] || panel_die "$target is not a panel site (cecp-panel site list)"
    doms=("$target")
  fi
  local d out rc=0 n_ok=0 n_bad=0
  for d in "${doms[@]}"; do
    [[ -n "$d" ]] || continue
    if (( summary )); then
      if out="$(probe_site "$d")"; then
        n_ok=$((n_ok + 1))
      else
        n_bad=$((n_bad + 1))
        echo "$out"
      fi
    else
      probe_site "$d" || rc=2
    fi
  done
  if (( summary )); then
    if (( n_bad == 0 )); then
      echo "Probe: ${n_ok} site(s) OK"
    else
      echo "Probe: ${n_bad} site(s) FAILED, ${n_ok} OK — run: cecp-panel site probe --all"
      rc=2
    fi
  fi
  return "$rc"
}

# probe_post_summary — non-fatal summary for the end of an upgrade or rebuild: never aborts the caller.
probe_post_summary() {
  echo "--- Probe (uncached pages) ---"
  site_probe --all --summary || true
  return 0
}
