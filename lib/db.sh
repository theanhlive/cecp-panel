#!/usr/bin/env bash
# Database tools: cecp-panel db export|import|shell|info|size|slow-log|slow-report
set -euo pipefail

DB_EXPORT_DIR="$VAR_LIB/db-exports"
DB_SLOW_LOG="/var/log/mariadb/slow.log"
DB_SLOW_CNF="/etc/my.cnf.d/cecp-slowlog.cnf"

db_require_site() {
  local domain="${1,,}"
  validate_domain "$domain"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  echo "$domain"
}

# A dump inside a web root would be downloadable: keep exports out of /home.
db_check_out_path() {
  local p
  p="$(realpath -m "$1")"
  [[ "$p" == /* ]] || panel_die "Use an absolute path"
  [[ "$p" != /home/* ]] || panel_die "Refusing to write a database dump under /home (web-reachable site files)"
  echo "$p"
}

# cecp-panel db export DOMAIN [FILE.sql.gz]
db_export() {
  local domain out
  domain="$(db_require_site "${1:-}")"
  require_root
  if [[ -n "${2:-}" ]]; then
    out="$(db_check_out_path "$2")"
  else
    out="$DB_EXPORT_DIR/$(domain_slug "$domain")-$(date +%Y%m%d_%H%M%S).sql.gz"
  fi
  (umask 077; mkdir -p "$(dirname "$out")")
  mysql_ensure_running
  (umask 077
   mysqldump --single-transaction --quick --routines --triggers "$(site_json_get "$domain" db_name)" | gzip -6 >"$out") \
    || { rm -f "$out"; panel_die "Export of $domain failed"; }
  chmod 600 "$out"
  panel_log "Exported $domain → $out ($(du -h "$out" | cut -f1))"
  echo "$out"
}

# cecp-panel db import DOMAIN FILE[.gz] [--replace-url OLD_DOMAIN] [--yes]
db_import() {
  local domain file="" old_url="" yes=0
  domain="$(db_require_site "${1:-}")"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --replace-url) old_url="${2:-}"; old_url="${old_url,,}"; shift 2 || true ;;
      --yes|-y) yes=1; shift ;;
      -*) panel_die "Unknown option: $1" ;;
      *) file="$1"; shift ;;
    esac
  done
  require_root
  [[ -n "$file" && -f "$file" && ! -L "$file" ]] || panel_die "Usage: cecp-panel db import DOMAIN FILE.sql[.gz] [--replace-url OLD_DOMAIN] [--yes]"
  [[ -z "$old_url" ]] || validate_domain "$old_url"
  local db_name
  db_name="$(site_json_get "$domain" db_name)"
  echo "Import $file into $db_name ($domain): the current database is REPLACED (a dump is saved first)."
  if (( ! yes )); then
    [[ -t 0 ]] || panel_die "Pass --yes when not running interactively"
    local answer
    read -r -p "Type the domain to continue: " answer
    [[ "$answer" == "$domain" ]] || panel_die "Aborted"
  fi
  site_lock "$domain"
  local before code
  before="$(db_export "$domain" "$DB_EXPORT_DIR/$(domain_slug "$domain")-$(date +%Y%m%d_%H%M%S)-before-import.sql.gz" | tail -1)"
  [[ -s "$before" ]] || panel_die "Could not save the current database of $domain — import aborted, nothing changed"
  if db_import_file "$domain" "$file" && db_after_import "$domain" "$old_url" && code="$(site_http_check "$domain")"; then
    panel_log "Imported $file into $domain (HTTP $code). Previous database: $before"
    return 0
  fi
  panel_log "ERROR: import failed or $domain does not answer — restoring the previous database"
  db_import_file "$domain" "$before" && db_after_import "$domain" "" \
    || panel_die "Restoring the previous database failed — manual action needed: $before"
  panel_die "Import failed; the previous database of $domain was restored"
}

# Import as the SITE's database user (it can only touch its own database, so a dump with
# USE/DROP of another database fails instead of damaging another site). DEFINER clauses from
# other servers need SUPER and are stripped.
db_import_file() {
  local domain="$1" file="$2" db_name cnf rc=0
  db_name="$(site_json_get "$domain" db_name)"
  mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`; CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  cnf="$(mysql_client_cnf "$(site_json_get "$domain" db_user)" "$(site_json_get "$domain" db_pass)")"
  if [[ "$file" == *.gz ]]; then
    gzip -dc "$file" | sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' | mysql --defaults-extra-file="$cnf" "$db_name" || rc=1
  else
    sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$file" | mysql --defaults-extra-file="$cnf" "$db_name" || rc=1
  fi
  rm -f "$cnf"
  return "$rc"
}

db_after_import() {
  local domain="$1" old="$2" scheme=http
  if [[ "$(wp_site_is_wordpress "$domain")" == "True" ]]; then
    if [[ -n "$old" && "$old" != "$domain" ]]; then
      site_cert_dir "$domain" >/dev/null && scheme=https
      wp_site_exec "$domain" search-replace "//${old}" "//${domain}" --all-tables --skip-columns=guid --quiet || return 1
      wp_site_exec "$domain" search-replace "\\/\\/${old}" "\\/\\/${domain}" --all-tables --skip-columns=guid --quiet 2>/dev/null || true
      wp_site_exec "$domain" cache flush >/dev/null 2>&1 || true
      ( site_wp_set_urls "$domain" "${scheme}://${domain}" ) || return 1
    fi
    wp_site_exec "$domain" cache flush >/dev/null 2>&1 || true
  fi
  optimize_purge_cache "$domain" >/dev/null 2>&1 || true
}

# cecp-panel db shell DOMAIN — mysql client as the site's DB user (password never in argv).
db_shell() {
  local domain
  domain="$(db_require_site "${1:-}")"
  require_root
  exec mysql --defaults-extra-file=<(printf '[client]\nuser=%s\npassword="%s"\n' \
    "$(site_json_get "$domain" db_user)" "$(site_json_get "$domain" db_pass)") "$(site_json_get "$domain" db_name)"
}

# cecp-panel db info DOMAIN — credentials + SSH tunnel recipe for desktop tools.
db_info() {
  local domain
  domain="$(db_require_site "${1:-}")"
  require_root
  cat <<EOF
Database of $domain
  name: $(site_json_get "$domain" db_name)
  user: $(site_json_get "$domain" db_user)
  host: 127.0.0.1:3306 (MariaDB listens on localhost only)
Desktop client (TablePlus, DBeaver, HeidiSQL): connect "over SSH" to this server, then to
127.0.0.1:3306 with the user above. Or tunnel: ssh -L 3307:127.0.0.1:3306 root@THIS_SERVER
EOF
  panel_secret "DB password: $(site_json_get "$domain" db_pass)"
}

# cecp-panel db size — size of every site database
db_size() {
  require_root
  mysql -Nse "SELECT table_schema, ROUND(SUM(data_length + index_length) / 1048576, 1), COUNT(*)
              FROM information_schema.tables GROUP BY table_schema ORDER BY 2 DESC" \
    | python3 -c '
import glob, json, sys
owner = {}
for p in glob.glob(sys.argv[1] + "/*.json"):
    d = json.load(open(p))
    owner[d.get("db_name")] = d.get("domain")
print("%-32s %-28s %10s %7s" % ("site", "database", "size MB", "tables"))
for line in sys.stdin:
    db, mb, n = line.rstrip("\n").split("\t")
    if db in owner:
        print("%-32s %-28s %10s %7s" % (owner[db], db, mb, n))
' "$SITES_DIR"
}

# cecp-panel db slow-log on [SECONDS] | off | status
db_slow_log() {
  local action="${1:-status}" secs="${2:-2}"
  require_root
  case "$action" in
    on)
      [[ "$secs" =~ ^[0-9]{1,3}(\.[0-9]{1,2})?$ ]] || panel_die "SECONDS: e.g. 1 or 0.5"
      install -d -o mysql -g mysql -m 750 "$(dirname "$DB_SLOW_LOG")" 2>/dev/null || true
      printf '[mysqld]\nslow_query_log = 1\nslow_query_log_file = %s\nlong_query_time = %s\n' "$DB_SLOW_LOG" "$secs" >"$DB_SLOW_CNF"
      mysql -e "SET GLOBAL slow_query_log_file='${DB_SLOW_LOG}'; SET GLOBAL long_query_time=${secs}; SET GLOBAL slow_query_log=1;"
      printf '%s {\n    weekly\n    rotate 4\n    compress\n    missingok\n    notifempty\n    copytruncate\n}\n' "$DB_SLOW_LOG" \
        >/etc/logrotate.d/cecp-mariadb-slow
      panel_log "MariaDB slow query log ON (>= ${secs}s) → $DB_SLOW_LOG. Report: cecp-panel db slow-report"
      ;;
    off)
      rm -f "$DB_SLOW_CNF"
      mysql -e "SET GLOBAL slow_query_log=0;"
      panel_log "MariaDB slow query log OFF"
      ;;
    status)
      mysql -Nse "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('slow_query_log','long_query_time','slow_query_log_file')" \
        | sed 's/^/  /'
      ;;
    *) panel_die "Usage: cecp-panel db slow-log on [SECONDS] | off | status" ;;
  esac
}

# cecp-panel db slow-report [TOP] — slowest query shapes (numbers/strings folded), per database.
db_slow_report() {
  local top="${1:-15}"
  require_root
  [[ "$top" =~ ^[0-9]{1,3}$ ]] || panel_die "TOP must be a number"
  [[ -f "$DB_SLOW_LOG" ]] || panel_die "No slow log yet ($DB_SLOW_LOG) — enable it: cecp-panel db slow-log on"
  python3 - "$DB_SLOW_LOG" "$top" <<'PY'
import re, sys
from collections import defaultdict
path, top = sys.argv[1], int(sys.argv[2])
stats = defaultdict(lambda: [0, 0.0, 0.0, 0])  # count, total, max, rows examined
db, qt, rows, buf = "?", 0.0, 0, []

def flush():
    global buf
    sql = " ".join(l.strip() for l in buf if not l.startswith(("#", "SET timestamp", "use ")))
    buf = []
    if not sql:
        return
    shape = re.sub(r"'(?:[^'\\]|\\.)*'", "?", sql)
    shape = re.sub(r"\b\d+\b", "N", shape)
    shape = re.sub(r"\s+", " ", shape)[:160]
    s = stats[(db, shape)]
    s[0] += 1; s[1] += qt; s[2] = max(s[2], qt); s[3] += rows

for line in open(path, encoding="utf-8", errors="replace"):
    if line.startswith("# Time:") or line.startswith("# User@Host:"):
        flush()
    # MariaDB: "# Thread_id: 8  Schema: db_x  QC_hit: No"; MySQL-style logs use "use db;".
    m = re.search(r"\bSchema: (\S+)", line) if line.startswith("#") else re.match(r"use `?(\w+)`?;", line)
    if m:
        db = m.group(1)
    m = re.search(r"Query_time: ([\d.]+).*?Rows_examined: (\d+)", line)
    if m:
        qt, rows = float(m.group(1)), int(m.group(2))
    elif not line.startswith("#"):
        buf.append(line)
flush()
if not stats:
    print("No slow queries recorded yet.")
    sys.exit(0)
print("%6s %9s %8s %11s  %-14s %s" % ("count", "total s", "max s", "rows exam.", "database", "query"))
for (d, shape), (n, tot, mx, rx) in sorted(stats.items(), key=lambda kv: -kv[1][1])[:top]:
    print("%6d %9.2f %8.2f %11d  %-14s %s" % (n, tot, mx, rx, d[:14], shape))
PY
}
