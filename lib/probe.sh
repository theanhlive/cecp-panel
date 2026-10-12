#!/usr/bin/env bash
# CECP Panel — post-upgrade site probe (read-only).
#
# Why: after the 1.12 upgrade the pool template disables putenv(); WooCommerce 6.2.2 calls it, so
# every UNCACHED page answered HTTP 500 for days while the home page kept coming from the page
# cache. A probe that only asks for the cached home page cannot see that. This one asks for pages
# that are never cached and reads the logs for the cause. It never writes, restarts or purges.
#
# Result model (per URL, judged on the FINAL status after up to 3 same-host redirects):
#   PASS = the request reached PHP and answered 2xx/3xx to a same-site URL
#   FAIL = HTTP >= 500
#   WARN = unverified: 000, 401/403/4xx before PHP, a redirect leaving the site or beyond 3 hops
# `site probe` exit: 2 any FAIL, 3 only unverified, 0 all verified.

PROBE_LOG_LINES=2000
PROBE_MAX_HOPS=3
PROBE_LOG_SLACK=5
PROBE_NGINX_LOG_DIR="${PROBE_NGINX_LOG_DIR:-/var/log/nginx}"
PROBE_POOL_LOG_GLOBS="${PROBE_POOL_LOG_GLOBS:-/var/log/php-fpm/*.log /var/log/php*-fpm/*.log}"
PROBE_POOL_CONF_DIR="${PROBE_POOL_CONF_DIR:-/etc/php-fpm.d}"

# probe_domains — one panel domain per line.
probe_domains() {
  local f
  shopt -s nullglob
  for f in "$SITES_DIR"/*.json; do
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f" 2>/dev/null || true
  done
  shopt -u nullglob
}

# probe_fetch DOMAIN PATH — "CODE REDIRECT_URL" of one local request (Host + SNI via --resolve);
# code 000 when nothing answered. HTTPS first (-k), plain HTTP when the site has no TLS.
probe_fetch() {
  local domain="$1" path="$2" out
  out="$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 --resolve "${domain}:443:127.0.0.1" \
    -A "CECP-Probe/${CECP_PANEL_VERSION}" "https://${domain}${path}" 2>/dev/null || true)"
  if [[ -z "$out" || "$out" == 000* ]]; then
    out="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 --resolve "${domain}:80:127.0.0.1" \
      -A "CECP-Probe/${CECP_PANEL_VERSION}" "http://${domain}${path}" 2>/dev/null || true)"
  fi
  echo "${out:-000 }"
}

# probe_request DOMAIN PATH — follows up to PROBE_MAX_HOPS same-host redirects by hand (keeps the
# loopback routing). Prints "CODE FINALPATH NOTE": NOTE is empty, "offsite" or "hops".
probe_request() {
  local domain="$1" path="$2" hop=0 res code loc host rest
  while :; do
    res="$(probe_fetch "$domain" "$path")"
    code="${res%% *}"
    loc=""
    [[ "$res" != *" "* ]] || loc="${res#* }"
    if [[ "$code" =~ ^3[0-9]{2}$ && -n "$loc" ]]; then
      if [[ "$loc" =~ ^https?://([^/:?#]+)(:[0-9]+)?(.*)$ ]]; then
        host="${BASH_REMATCH[1],,}"
        rest="${BASH_REMATCH[3]}"
        [[ -n "$rest" ]] || rest="/"
        [[ "$rest" == /* ]] || rest="/$rest"
        if [[ "$host" != "${domain,,}" ]]; then
          echo "$code $path offsite"
          return 0
        fi
      elif [[ "$loc" == /* ]]; then
        rest="$loc"
      else
        echo "$code $path offsite"
        return 0
      fi
      if (( hop >= PROBE_MAX_HOPS )); then
        echo "$code $path hops"
        return 0
      fi
      hop=$((hop + 1))
      path="$rest"
      continue
    fi
    echo "$code $path "
    return 0
  done
}

# probe_level CODE [NOTE] — PASS | WARN | FAIL for a FINAL status.
probe_level() {
  local code="$1" note="${2:-}"
  if [[ -n "$note" ]]; then echo WARN
  elif [[ ! "$code" =~ ^[0-9]{3}$ || "$code" == 000 ]]; then echo WARN
  elif (( 10#$code >= 500 )); then echo FAIL
  elif (( 10#$code >= 200 && 10#$code < 400 )); then echo PASS
  else echo WARN
  fi
}

# probe_since_stamp EPOCH — nginx-style "YYYY/MM/DD HH:MM:SS" of EPOCH minus the slack window.
probe_since_stamp() {
  date -d "@$(( $1 - PROBE_LOG_SLACK ))" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || true
}

# probe_filter_recent STAMP — keeps log lines newer than STAMP. Understands the nginx stamp
# ("2026/10/12 10:00:00 [error]") and the php-fpm one ("[12-Oct-2026 10:00:00]"); a line without
# a stamp is dropped (it cannot be attributed to the probe window).
probe_filter_recent() {
  awk -v since="$1" '
    BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i = 1; i <= 12; i++) mon[m[i]] = sprintf("%02d", i) }
    {
      ts = ""
      if ($1 ~ /^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9]$/) ts = $1 " " $2
      else if (match($0, /^\[[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9] [0-9:]+\]/)) {
        s = substr($0, RSTART + 1, RLENGTH - 2)
        split(s, a, /[- ]/)
        ts = a[3] "/" mon[a[2]] "/" a[1] " " a[4]
      }
      if (ts != "" && since != "" && ts >= since) print
    }'
}

# probe_recent_lines DOMAIN SINCE_STAMP — only this site's lines: its own nginx error log plus the
# pool-log lines that name its domain, docroot or pool; never lines of other sites.
probe_recent_lines() {
  local domain="$1" stamp="$2" f docroot slug
  docroot="$(site_json_get_or "$domain" docroot "" 2>/dev/null || true)"
  slug="$(domain_slug "$domain")"
  tail -n "$PROBE_LOG_LINES" "${PROBE_NGINX_LOG_DIR}/${domain}-error.log" 2>/dev/null | probe_filter_recent "$stamp" || true
  shopt -s nullglob
  # shellcheck disable=SC2086
  for f in $PROBE_POOL_LOG_GLOBS "${LOG_DIR:-/nonexistent}"/php-fpm-"${slug}"*.log; do
    [[ -f "$f" ]] || continue
    tail -n "$PROBE_LOG_LINES" "$f" 2>/dev/null | probe_filter_recent "$stamp" \
      | grep -F -e "$domain" -e "pool ${slug}" ${docroot:+-e "$docroot/"} || true
  done
  shopt -u nullglob
}

# probe_log_names LINES — function names the PHP logs blame, one per line (sorted, unique):
# "Call to undefined function NAME()" and "NAME() has been disabled for security reasons".
probe_log_names() {
  grep -oE 'Call to undefined function [A-Za-z0-9_]+\(\)|[A-Za-z0-9_]+\(\) has been disabled for security reasons' <<<"$1" \
    | sed -E 's/^Call to undefined function //; s/\(\).*$//' | sort -u || true
}

# probe_remedy DOMAIN NAME — what to do about one blamed function.
probe_remedy() {
  local domain="$1" name="$2" list=""
  list="$(php_cfg_disable_functions "$domain" 2>/dev/null || true)"
  if [[ "$name" == putenv && ",${list}," == *",putenv,"* ]]; then
    echo "  putenv() is disabled in the pool of $domain. Fix: cecp-panel php config $domain allow_putenv=on"
    echo "    (this re-opens the LD_PRELOAD vector for that site: update the plugin that calls putenv instead when you can)"
  elif [[ "$name" == putenv ]]; then
    echo "  putenv() is blamed in the log, but the pool of $domain does not disable it: the line is stale or the cause is elsewhere"
  elif [[ ",${list}," == *",${name},"* ]]; then
    echo "  ${name}() is in the disable_functions of the pool of $domain (${list}); there is no per-site switch: update or replace the plugin that calls it"
  else
    echo "  ${name}() is undefined for $domain (missing PHP extension or plugin file?): cecp-panel log nginx $domain"
  fi
}

# probe_perm_paths LINES — files PHP could not open ("Permission denied" / "Failed opening required").
probe_perm_paths() {
  {
    grep -E 'Failed to open stream: Permission denied' <<<"$1" \
      | sed -nE 's/.*\(([^()]+)\): [Ff]ailed to open stream: Permission denied.*/\1/p' || true
    grep -E 'Failed opening required' <<<"$1" | sed -nE "s/.*Failed opening required '([^']+)'.*/\1/p" || true
  } | sort -u
}

# probe_perm_remedy DOMAIN PATH — facts and remedy for one unreadable file (never runs the chown).
probe_perm_remedy() {
  local domain="$1" path="$2" su info
  su="$(site_json_get_or "$domain" site_user "" 2>/dev/null || true)"
  info="$(stat -c '%U:%G mode %a' "$path" 2>/dev/null || echo 'not found / not statable by root')"
  echo "  PHP cannot read ${path}: owner ${info}; pool user ${su:-?}"
  echo "    Fix: chown ${su:-SITE_USER}:${su:-SITE_USER} ${path}  (or: cecp-panel security harden-docroot ${domain})"
}

# probe_diagnose DOMAIN SINCE_STAMP — classify this site's recent log lines and print the remedy.
probe_diagnose() {
  local domain="$1" stamp="$2" lines names n paths p found=0 line
  lines="$(probe_recent_lines "$domain" "$stamp")"
  if [[ -n "$lines" ]]; then
    names="$(probe_log_names "$lines")"
    if [[ -n "$names" ]]; then
      found=1
      while IFS= read -r n; do
        [[ -n "$n" ]] && probe_remedy "$domain" "$n"
      done <<<"$names"
    fi
    paths="$(probe_perm_paths "$lines")"
    if [[ -n "$paths" ]]; then
      found=1
      while IFS= read -r p; do
        [[ -n "$p" ]] && probe_perm_remedy "$domain" "$p"
      done <<<"$paths"
    fi
    if grep -q 'Allowed memory size' <<<"$lines"; then
      found=1
      echo "  PHP ran out of memory: cecp-panel php config $domain memory_limit=512M"
    fi
    if grep -q 'open_basedir restriction' <<<"$lines"; then
      found=1
      local conf ob
      line="$(grep -m1 'open_basedir restriction' <<<"$lines")"
      conf="${PROBE_POOL_CONF_DIR}/cecp-$(domain_slug "$domain").conf"
      ob="$(grep -hm1 'open_basedir' "$conf" 2>/dev/null | sed -E 's/^[^=]*= *//' || true)"
      echo "  open_basedir blocked a path: $(sed -nE 's/.*(File\([^)]*\)|Unknown\([^)]*\)).*/\1/p' <<<"$line")"
      echo "    pool open_basedir: ${ob:-$(sed -nE 's/.*allowed path\(s\): \(([^)]*)\).*/\1/p' <<<"$line")}"
    fi
  fi
  if (( found == 0 )); then
    echo "  cause not found in this site's log: cecp-panel log nginx $domain"
  fi
}

# probe_site DOMAIN — prints the result lines. Returns 2 when any request failed (HTTP >= 500),
# 3 when none failed but at least one is unverified, 0 when every request is verified.
probe_site() {
  local domain="$1" wp rc=0 paths=() p shown res code final note level via start stamp
  start="$(date +%s)"
  stamp="$(probe_since_stamp "$start")"
  wp="$(site_json_get_or "$domain" wordpress "")"
  case "${wp,,}" in true|1|yes) paths+=("/wp-login.php" "/wp-json/") ;; esac
  paths+=("/?cecp_probe=$(rand_alnum 12)")
  for p in "${paths[@]}"; do
    res="$(probe_request "$domain" "$p")"
    code="${res%% *}"
    res="${res#* }"
    final="${res%% *}"
    note="${res#* }"
    [[ "$note" != "$res" ]] || note=""
    level="$(probe_level "$code" "$note")"
    shown="$p"
    [[ "$p" != *\?* ]] || shown="${p%%\?*}?cecp_probe=<random>"
    via=""
    if [[ "$final" != "$p" ]]; then
      via=" (after redirect to ${final%%\?*})"
    fi
    case "$note" in
      offsite) via+=" (redirect leaves the site: unverified)" ;;
      hops) via+=" (more than ${PROBE_MAX_HOPS} redirects: unverified)" ;;
    esac
    printf '%s %s %s HTTP %s%s\n' "$level" "$domain" "$shown" "$code" "$via"
    if [[ "$level" == FAIL ]]; then rc=2
    elif [[ "$level" == WARN && "$rc" == 0 ]]; then rc=3
    fi
  done
  if (( rc == 2 )); then
    probe_diagnose "$domain" "$stamp"
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
  local d out prc rc=0 n_ok=0 n_unv=0 n_bad=0
  for d in "${doms[@]}"; do
    [[ -n "$d" ]] || continue
    prc=0
    if (( summary )); then
      out="$(probe_site "$d")" || prc=$?
      case "$prc" in
        0) n_ok=$((n_ok + 1)) ;;
        3) n_unv=$((n_unv + 1)); echo "$out" ;;
        *) n_bad=$((n_bad + 1)); echo "$out" ;;
      esac
    else
      probe_site "$d" || prc=$?
      case "$prc" in
        0) n_ok=$((n_ok + 1)) ;;
        3) n_unv=$((n_unv + 1)) ;;
        *) n_bad=$((n_bad + 1)) ;;
      esac
    fi
  done
  if (( n_bad > 0 )); then rc=2
  elif (( n_unv > 0 )); then rc=3
  fi
  if (( summary )); then
    echo "Probe: ${n_ok} verified, ${n_unv} unverified, ${n_bad} FAILED"
    if (( rc != 0 )); then echo "  details: cecp-panel site probe --all"; fi
  fi
  return "$rc"
}

# probe_post_summary — non-fatal summary for the end of an upgrade or rebuild: never aborts the caller.
probe_post_summary() {
  echo "--- Probe (uncached pages) ---"
  site_probe --all --summary || true
  return 0
}
