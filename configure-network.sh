#!/usr/bin/env bash
# FS150 field network: write Wi-Fi + static IPv4. Does not reconnect.
# Next step is apply-network.sh.
#
# Requires --lan-address. SSID/PSK from site.env or flags.
# /32 is rewritten to /24.
#
# Usage:
#   sudo bash configure-network.sh --yes --lan-address 192.168.51.XX
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
WIFI_PASSWORD="${FS150_WIFI_PASSWORD:-${XGC2_WIFI_PASSWORD:-}}"
WIFI_IFACE="${FS150_WIFI_IFACE:-wlan0}"
LAN_ADDRESS="${FS150_LAN_ADDRESS:-}"
LAN_GATEWAY="${FS150_LAN_GATEWAY:-192.168.51.1}"
LAN_DNS="${FS150_LAN_DNS:-192.168.51.1}"

usage() {
  cat <<'EOF'
Usage: configure-network.sh --yes --lan-address A.B.C.D[/24] [options]

Options:
  --yes                     required; refuse to run without it
  --lan-address A.B.C.D[/24]  required; static IPv4, prefix /24
  --lan-gateway ADDR        default 192.168.51.1
  --lan-dns ADDR            default 192.168.51.1
  --wifi-ssid SSID          from site.env / env; no in-script default
  --wifi-password PASS      from site.env / env / flag; no in-script default
  --wifi-iface IFACE        default wlan0
  -h, --help                show this help
EOF
}

log() { printf '+ %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --lan-address) LAN_ADDRESS="${2:?}"; shift 2 ;;
    --lan-gateway) LAN_GATEWAY="${2:?}"; shift 2 ;;
    --lan-dns) LAN_DNS="${2:?}"; shift 2 ;;
    --wifi-ssid) WIFI_SSID="${2:?}"; shift 2 ;;
    --wifi-password) WIFI_PASSWORD="${2:?}"; shift 2 ;;
    --wifi-iface) WIFI_IFACE="${2:?}"; shift 2 ;;
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
[[ -n "${LAN_ADDRESS}" ]] || die "need --lan-address"
require_root
need_cmd nmcli
need_cmd ip

normalize_lan_cidr() {
  local raw="$1" host prefix
  raw="${raw//[[:space:]]/}"
  [[ -n "${raw}" ]] || return 1
  if [[ "${raw}" == */* ]]; then
    host="${raw%/*}"
    prefix="${raw##*/}"
  else
    host="${raw}"
    prefix="24"
  fi
  [[ "${host}" == *.*.*.* ]] || return 1
  if [[ "${prefix}" == "32" ]]; then
    warn "refusing IPv4 /32 (breaks on-link ARP); using ${host}/24"
    prefix="24"
  fi
  [[ "${prefix}" == "24" ]] || die "field IPv4 must be /24, got ${host}/${prefix}"
  printf '%s/%s\n' "${host}" "${prefix}"
}

active_wifi_connection() {
  nmcli -t -f NAME,TYPE connection show --active \
    | awk -F: '$2 == "802-11-wireless" { print $1; exit }'
}

apply_static_ipv4() {
  local profile="$1"
  local cidr="$2"
  nmcli connection modify "${profile}" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    ipv4.method manual \
    ipv4.addresses "${cidr}" \
    ipv4.gateway "${LAN_GATEWAY}" \
    ipv4.dns "${LAN_DNS}" \
    ipv4.ignore-auto-dns yes
}

apply_live_ipv4_prefix() {
  local iface="$1"
  local cidr="$2"
  local host="${cidr%/*}"
  local live live_host
  live="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4; exit}')"
  [[ -n "${live}" ]] || return 0
  live_host="${live%/*}"
  if [[ "${live_host}" != "${host}" ]]; then
    warn "live ${iface} is ${live}, profile now ${cidr}; not applying (would drop SSH)"
    return 0
  fi
  if [[ "${live}" == "${cidr}" ]]; then
    log "${iface} already ${cidr}"
  else
    log "same host ${host}; apply ${live} -> ${cidr} without reconnect"
    ip addr add "${cidr}" dev "${iface}" 2>/dev/null || true
    ip addr del "${live}" dev "${iface}" 2>/dev/null || true
  fi
  if nmcli device reapply "${iface}"; then
    log "nmcli device reapply ${iface}"
  else
    warn "reapply failed; kernel may already be ${cidr} until next NM refresh"
  fi
}

cidr="$(normalize_lan_cidr "${LAN_ADDRESS}")" \
  || die "invalid --lan-address: ${LAN_ADDRESS}"
[[ "${cidr}" == *.*.*.*/* ]] || die "expected IPv4 CIDR, got ${cidr}"

profile=""
if [[ -n "${WIFI_SSID}" ]]; then
  profile="$(nmcli -t -f NAME,UUID,TYPE connection show \
    | awk -F: -v ssid="${WIFI_SSID}" '$1 == ssid && $3 == "802-11-wireless" { print $1; exit }')"
else
  profile="$(active_wifi_connection)"
  [[ -n "${profile}" ]] || die "no active Wi-Fi; pass --wifi-ssid to name the profile"
  log "no --wifi-ssid; using active Wi-Fi profile '${profile}'"
fi

if [[ -n "${profile}" ]]; then
  log "write static IPv4 on profile '${profile}' (no reconnect)"
  apply_static_ipv4 "${profile}" "${cidr}"
  if [[ -n "${WIFI_SSID}" ]]; then
    nmcli connection modify "${profile}" 802-11-wireless.ssid "${WIFI_SSID}"
  fi
  if [[ -n "${WIFI_PASSWORD}" ]]; then
    nmcli connection modify "${profile}" \
      802-11-wireless-security.key-mgmt wpa-psk \
      802-11-wireless-security.psk "${WIFI_PASSWORD}"
  fi
else
  [[ -n "${WIFI_PASSWORD}" ]] || die "no existing '${WIFI_SSID}' profile; pass --wifi-password to create one"
  log "create Wi-Fi profile '${WIFI_SSID}' on ${WIFI_IFACE} (no connect now)"
  nmcli connection add type wifi ifname "${WIFI_IFACE}" con-name "${WIFI_SSID}" \
    ssid "${WIFI_SSID}" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "${WIFI_PASSWORD}" \
    ipv4.method manual \
    ipv4.addresses "${cidr}" \
    ipv4.gateway "${LAN_GATEWAY}" \
    ipv4.dns "${LAN_DNS}" \
    ipv4.ignore-auto-dns yes
  profile="${WIFI_SSID}"
fi
log "NM saved ${profile} -> ${cidr} gw ${LAN_GATEWAY} dns ${LAN_DNS}"
apply_live_ipv4_prefix "${WIFI_IFACE}" "${cidr}"
log "next: Insert apply network"
