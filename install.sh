#!/usr/bin/env bash
# CECP Panel — ONE install per VPS (stack + cecp-panel CLI). Not per-site.
# Sites/domains/SSL are added later via: cecp-panel (Phase 1+).
#
# Usage (on VPS):
#   sudo bash install.sh
#   curl -fsSL <url>/install.sh | sudo bash
#
# Usage (from your Mac — one command, pipes this script):
#   ssh -i ~/.ssh/KEY root@VPS_IP 'bash -s' < scripts/cecp-panel/install.sh
set -euo pipefail

CECP_PANEL_VERSION="${CECP_PANEL_VERSION:-1.9.0-beta}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/cecp-panel}"
ETC_DIR="/etc/cecp-panel"
VAR_LIB="/var/lib/cecp-panel"
LOG_DIR="/var/log/cecp-panel"
BIN_PATH="/usr/local/bin/cecp-panel"

# When piped via `ssh ... bash -s`, BASH_SOURCE may not point at a real directory.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" ]]; then
  _sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || true
  if [[ -f "${_sd}/cecp-panel" ]]; then
    SCRIPT_DIR="$_sd"
  fi
fi

log() { echo "[cecp-panel] $*"; }
die() { echo "[cecp-panel] ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash install.sh"

detect_os() {
  if [[ -f /etc/almalinux-release ]]; then
    OS_FAMILY=rhel
    OS_VERSION="$(rpm -E '%{rhel}' 2>/dev/null || echo 9)"
  elif [[ -f /etc/rocky-release ]]; then
    OS_FAMILY=rhel
    OS_VERSION="$(rpm -E '%{rhel}' 2>/dev/null || echo 9)"
  elif [[ -f /etc/redhat-release ]] && grep -qi centos /etc/redhat-release 2>/dev/null; then
    OS_FAMILY=rhel
    OS_VERSION="8"
  elif [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      OS_FAMILY=debian
      OS_VERSION="${VERSION_ID:-22.04}"
    else
      die "Unsupported OS: ${ID:-unknown} (use AlmaLinux 8/9, Rocky 8/9, Ubuntu 22.04)"
    fi
  else
    die "Cannot detect OS"
  fi
  log "Detected: family=$OS_FAMILY version=$OS_VERSION"
}

install_packages_rhel() {
  log "Installing packages (dnf)..."
  dnf -y install epel-release
  local -a extra=()
  # Minimal/cloud images ship curl-minimal, which conflicts with the full curl package.
  command -v curl &>/dev/null || extra+=(curl)
  dnf -y install nginx mariadb-server mariadb fail2ban firewalld \
    python3 python3-pip wget tar unzip policycoreutils-python-utils \
    php php-fpm php-mysqlnd php-cli php-gd php-xml php-mbstring php-json php-opcache \
    certbot python3-certbot-nginx restic rclone "${extra[@]}"
  if ! command -v wp &>/dev/null; then
    local wpbase="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar" wptmp
    wptmp="$(mktemp -d)"
    curl -fsSL "$wpbase/wp-cli.phar" -o "$wptmp/wp-cli.phar"
    curl -fsSL "$wpbase/wp-cli.phar.sha512" -o "$wptmp/wp-cli.phar.sha512"
    [[ "$(sha512sum "$wptmp/wp-cli.phar" | cut -d' ' -f1)" == "$(tr -dc '0-9a-f' <"$wptmp/wp-cli.phar.sha512")" ]] \
      || die "wp-cli.phar checksum mismatch"
    install -m 755 "$wptmp/wp-cli.phar" /usr/local/bin/wp
    rm -rf "$wptmp"
  fi
  systemctl enable --now nginx mariadb fail2ban firewalld 2>/dev/null || true
}

install_packages_debian() {
  log "Installing packages (apt)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx mariadb-server mariadb-client fail2ban ufw \
    python3 python3-pip curl wget tar unzip \
    php-fpm php-mysql php-cli php-gd php-xml php-mbstring php-curl \
    certbot python3-certbot-nginx restic rclone
  systemctl enable --now nginx mariadb fail2ban 2>/dev/null || true
}

harden_ssh_basics() {
  log "SSH hardening hints written to $ETC_DIR/ssh-hardening.txt"
  cat >"$ETC_DIR/ssh-hardening.txt" <<'EOF'
Recommended (apply manually after install):
  - Use SSH keys only; disable PasswordAuthentication in sshd_config
  - Consider changing SSH port (document in firewall)
  - fail2ban is enabled for sshd
EOF
}

configure_firewall() {
  if [[ "$OS_FAMILY" == "rhel" ]]; then
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  else
    ufw allow OpenSSH 2>/dev/null || true
    ufw allow 'Nginx Full' 2>/dev/null || true
  fi
}

secure_mariadb() {
  systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
  mysql -e "SELECT 1" &>/dev/null || die "MariaDB did not start"
  log "MariaDB baseline hardening..."
  mysql -e "DELETE FROM mysql.user WHERE User='' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
  mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
  mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
  mysql -e "FLUSH PRIVILEGES;"
}

configure_nginx_defaults() {
  mkdir -p /run/php-fpm
  chown nginx:nginx /run/php-fpm 2>/dev/null || true
  if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.cecp-disabled 2>/dev/null || true
  fi
  # Hide version early
  cat >/etc/nginx/conf.d/cecp-security.conf <<'EOF'
server_tokens off;
EOF
  if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P httpd_enable_homedirs 1 2>/dev/null || true
    setsebool -P httpd_read_user_content 1 2>/dev/null || true
  fi
  nginx -t && systemctl reload nginx 2>/dev/null || true
}

install_certbot_cron() {
  cat >/etc/cron.d/cecp-certbot-renew <<'EOF'
# Weekly SSL check (Sunday 04:00 UTC). certbot renew only renews inside LE window (~30d before 90d expiry).
# Manual: cecp-panel ssl status  |  Force check: cecp-panel ssl renew
0 4 * * 0 root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
  chmod 644 /etc/cron.d/cecp-certbot-renew
  rm -f /etc/cron.d/certbot-renew /etc/cron.d/certbot 2>/dev/null || true
}

fetch_panel_bundle_if_needed() {
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/cecp-panel" ]]; then
    return 0
  fi
  local url="${CECP_PANEL_BUNDLE_URL:-}"
  if [[ -z "$url" && -n "${CECP_PANEL_RAW_BASE:-}" ]]; then
    url="${CECP_PANEL_RAW_BASE%/}/dist/cecp-panel-${CECP_PANEL_VERSION}.tar.gz"
  fi
  if [[ -z "$url" ]]; then
    die "Use customer installer: curl -fsSL <URL>/install-cecp-panel.sh | sudo bash
Or: CECP_PANEL_RAW_BASE=https://.../scripts/cecp-panel bash install-cecp-panel.sh"
  fi
  log "Downloading panel bundle $url ..."
  local tmp expected actual
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/bundle.tar.gz"
  # Refuse an unverified bundle: it is installed and run as root.
  if [[ -n "${CECP_PANEL_BUNDLE_SHA256:-}" ]]; then
    expected="$CECP_PANEL_BUNDLE_SHA256"
  elif [[ -n "${CECP_PANEL_RAW_BASE:-}" ]]; then
    curl -fsSL "${CECP_PANEL_RAW_BASE%/}/dist/SHA256SUMS" -o "$tmp/SHA256SUMS" || die "Mirror has no dist/SHA256SUMS"
    expected="$(awk -v f="$(basename "$url")" '{n=$2; sub(/^\*/, "", n); if (n == f) print $1}' "$tmp/SHA256SUMS" | head -1)"
  else
    die "Set CECP_PANEL_BUNDLE_SHA256 when using CECP_PANEL_BUNDLE_URL"
  fi
  actual="$(sha256sum "$tmp/bundle.tar.gz" | cut -d' ' -f1)"
  [[ -n "$expected" && "$expected" == "$actual" ]] || die "Bundle checksum mismatch (expected ${expected:-none}, got $actual)"
  tar xzf "$tmp/bundle.tar.gz" -C "$tmp"
  SCRIPT_DIR="$tmp/cecp-panel"
  [[ -f "$SCRIPT_DIR/cecp-panel" ]] || die "Bundle missing cecp-panel/ directory"
}

install_panel_files() {
  fetch_panel_bundle_if_needed
  log "Installing full panel to $INSTALL_ROOT ..."
  mkdir -p "$INSTALL_ROOT" "$ETC_DIR" "$VAR_LIB/sites" "$LOG_DIR"
  chmod 700 "$ETC_DIR"
  cp -a "${SCRIPT_DIR}/." "$INSTALL_ROOT/"
  chmod +x "$INSTALL_ROOT/cecp-panel" "$INSTALL_ROOT"/lib/*.sh 2>/dev/null || true
  install -m 0755 "$INSTALL_ROOT/cecp-panel" "$BIN_PATH"
  cat >"$ETC_DIR/panel.json" <<EOF
{
  "version": "$CECP_PANEL_VERSION",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "os_family": "$OS_FAMILY",
  "os_version": "$OS_VERSION",
  "standalone": true,
  "cecp_agent": false
}
EOF
  chmod 600 "$ETC_DIR/panel.json"
  [[ -f "$ETC_DIR/panel.env" ]] || touch "$ETC_DIR/panel.env"
  chmod 600 "$ETC_DIR/panel.env"
}

main() {
  echo "========================================================================="
  echo "  CECP Panel installer $CECP_PANEL_VERSION"
  echo "  Standalone — does not require CECP control plane"
  echo "========================================================================="
  detect_os
  case "$OS_FAMILY" in
    rhel) install_packages_rhel ;;
    debian) install_packages_debian ;;
    *) die "unsupported family" ;;
  esac
  mkdir -p "$ETC_DIR" "$VAR_LIB/sites" "$LOG_DIR"
  chmod 700 "$ETC_DIR"
  secure_mariadb
  configure_firewall
  configure_nginx_defaults
  install_certbot_cron
  harden_ssh_basics
  install_panel_files
  if [[ -x /usr/local/bin/cecp-panel ]]; then
    /usr/local/bin/cecp-panel system tune-install 2>/dev/null || log "WARN: system tune skipped (run: cecp-panel system tune)"
  fi
  log "Done. Full CECP Panel stack + CLI installed (v$CECP_PANEL_VERSION)."
  log "Next (recommended):"
  log "  cecp-panel security apply-production   # SSH/fail2ban/nginx/MariaDB harden"
  log "  cecp-panel optimize stack              # BBR + Redis + OPcache JIT + MariaDB tune"
  log "  cecp-panel onboard                     # Cloudflare + GDrive (optional)"
  log "WP site: cecp-panel site add domain.com --wordpress"
  log "         cecp-panel optimize redis-wp domain.com"
  log "         cecp-panel ssl issue domain.com"
}

main "$@"
