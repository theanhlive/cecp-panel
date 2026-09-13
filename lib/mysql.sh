#!/usr/bin/env bash
set -euo pipefail

# Temporary [client] option file (mode 600) so DB passwords never appear in argv (ps, /proc).
# Caller removes it; pass it as the FIRST option: --defaults-extra-file=FILE.
mysql_client_cnf() {
  local f
  f="$(mktemp)"
  chmod 600 "$f"
  printf '[client]\nuser=%s\npassword="%s"\n' "$1" "$2" >"$f"
  echo "$f"
}

mysql_ensure_running() {
  systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
}

mysql_secure_basics() {
  require_root
  mysql_ensure_running
  panel_log "Applying MariaDB baseline hardening..."
  mysql -e "DELETE FROM mysql.user WHERE User='' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
  mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
  mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
  # Remove remote root if any
  mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
  mysql -e "FLUSH PRIVILEGES;"
  # Bind localhost without sourcing security.sh (avoids recursion via apply-production)
  local bindf=""
  if [[ -d /etc/my.cnf.d ]]; then
    bindf=/etc/my.cnf.d/cecp-bind.cnf
  elif [[ -d /etc/mysql/mariadb.conf.d ]]; then
    bindf=/etc/mysql/mariadb.conf.d/99-cecp-bind.cnf
  fi
  if [[ -n "$bindf" ]]; then
    cat >"$bindf" <<'EOF'
[mysqld]
bind-address = 127.0.0.1
EOF
    systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
  fi
  panel_log "MariaDB baseline OK (local-only users, no test DB, bind 127.0.0.1 when possible)"
}

mysql_create_site_db() {
  local db_name="$2" db_user="$3" db_pass="$4"
  mysql_ensure_running
  [[ "$db_name" =~ ^[a-z0-9_]+$ && "$db_user" =~ ^[a-z0-9_]+$ && "$db_pass" =~ ^[A-Za-z0-9]+$ ]] \
    || panel_die "mysql_create_site_db: unexpected db name/user/password characters"
  # SQL via stdin, not `mysql -e`: keeps the password out of the process list.
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

mysql_drop_site_db() {
  local db_name="$1" db_user="$2"
  mysql_ensure_running
  mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null || true
  mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null || true
  mysql -e "FLUSH PRIVILEGES;"
}
