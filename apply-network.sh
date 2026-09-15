#!/usr/bin/env bash
# FS150: reconnect the saved Wi-Fi profile so IPv4/DNS/routes take effect.
# This drops SSH if you are on that link. Configure writes; this applies.
#
# Usage:
#   sudo bash apply-network.sh --yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
xgc2_load_site() {
  local f="${XGC2_SITE_ENV:-}"
  if [[ -z "${f}" ]]; then
    if [[ -f "${SCRIPT_DIR}/../site.env" ]]; then
      f="${SCRIPT_DIR}/../site.env"
    elif [[ -f "${HOME}/Documents/XGC/UserScripts/site.env" ]]; then
      f="${HOME}/Documents/XGC/UserScripts/site.env"
    fi
  fi
  if [[ -n "${f}" && -f "${f}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${f}"
    set +a
  fi
}
xgc2_load_site

YES=0
WIFI_SSID="${FS150_WIFI_SSID:-${XGC2_WIFI_SSID:-}}"

usage() {
  cat <<'EOF'
Usage: apply-network.sh --yes [options]

Reconnects the field Wi-Fi profile. SSH on this link may drop.

Options:
  --yes                     required; refuse to run without it
  --wifi-ssid SSID          from site.env / env; no in-script default
  -h, --help                show this help
EOF
}

log() { printf '+ %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --wifi-ssid) WIFI_SSID="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --site-env) export XGC2_SITE_ENV="${2:?}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done


xgc2_load_site
WIFI_SSID="${WIFI_SSID:-${XGC2_WIFI_SSID:-}}"
WIFI_PASSWORD="${WIFI_PASSWORD:-${XGC2_WIFI_PASSWORD:-}}"
if [[ -z "${WIFI_SSID}" ]]; then
  die "need --wifi-ssid or site.env XGC2_WIFI_SSID"
fi

[[ "${YES}" -eq 1 ]] || die "refusing to run without --yes (see --help)"
[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
command -v nmcli >/dev/null 2>&1 || die "missing command: nmcli"

profile="$(nmcli -t -f NAME,UUID,TYPE connection show \
  | awk -F: -v ssid="${WIFI_SSID}" '$1 == ssid && $3 == "802-11-wireless" { print $1; exit }')"
if [[ -z "${profile}" ]]; then
  profile="$(nmcli -t -f NAME,TYPE connection show --active \
    | awk -F: '$2 == "802-11-wireless" { print $1; exit }')"
fi
[[ -n "${profile}" ]] || die "no Wi-Fi profile to reconnect; run configure network first"

log "reconnect ${profile} (SSH on this link may drop)"
nmcli connection up "${profile}"
log "up ${profile}"
