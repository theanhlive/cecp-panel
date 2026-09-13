#!/usr/bin/env bash
# certbot stand-in for scenario.sh (no Let's Encrypt inside Docker), used via CECP_CERTBOT.
# Records its arguments in /tmp/certbot.args; `certonly` writes a self-signed lineage whose
# SANs are the -d names plus a renewal conf; `delete` removes the lineage.
set -euo pipefail
printf '%s\n' "$*" >>/tmp/certbot.args
cmd="${1:-}"
shift || true
name="" auth="webroot"
sans=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert-name) name="$2"; shift 2 ;;
    -d) sans+=("$2"); shift 2 ;;
    --dns-cloudflare) auth="dns-cloudflare"; shift ;;
    --dns-cloudflare-credentials)
      [[ "$(stat -c '%a %U' "$2")" == "600 root" ]] || { echo "credentials file must be 600 root" >&2; exit 1; }
      grep -q '^dns_cloudflare_api_token = ' "$2" || { echo "no token in credentials file" >&2; exit 1; }
      shift 2
      ;;
    *) shift ;;
  esac
done
name="${name:-${sans[0]:-}}"
[[ -n "$name" ]] || { echo "no certificate name" >&2; exit 1; }
case "$cmd" in
  certonly)
    live="/etc/letsencrypt/live/$name"
    mkdir -p "$live" /etc/letsencrypt/renewal
    san="$(printf 'DNS:%s,' "${sans[@]}")"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=${sans[0]}" \
      -addext "subjectAltName=${san%,}" -keyout "$live/privkey.pem" -out "$live/fullchain.pem" >/dev/null 2>&1
    cat >"/etc/letsencrypt/renewal/$name.conf" <<EOF
version = 2.11.0
archive_dir = /etc/letsencrypt/archive/$name
fullchain = $live/fullchain.pem

[renewalparams]
account = abc
authenticator = $auth
installer = nginx
server = https://acme-v02.api.letsencrypt.org/directory
EOF
    ;;
  delete)
    rm -rf "/etc/letsencrypt/live/$name" "/etc/letsencrypt/archive/$name" "/etc/letsencrypt/renewal/$name.conf"
    ;;
  *) echo "fake certbot: unsupported command $cmd" >&2; exit 1 ;;
esac
