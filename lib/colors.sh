#!/usr/bin/env bash
# ANSI colors — safe when not a TTY
# shellcheck disable=SC2034  # palette consumed by other lib files
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
  C_MAGENTA=$'\033[35m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=; C_MAGENTA=
fi

c_ok()   { echo -e "${C_GREEN}$*${C_RESET}"; }
c_warn() { echo -e "${C_YELLOW}$*${C_RESET}"; }
c_err()  { echo -e "${C_RED}$*${C_RESET}"; }
c_info() { echo -e "${C_CYAN}$*${C_RESET}"; }
c_title(){ echo -e "${C_BOLD}${C_BLUE}$*${C_RESET}"; }

svc_dot() {
  local s="$1"
  if systemctl is-active --quiet "$s" 2>/dev/null; then
    echo -e "  ${C_GREEN}●${C_RESET} $s"
  else
    echo -e "  ${C_RED}○${C_RESET} $s"
  fi
}
