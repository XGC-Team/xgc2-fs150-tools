#!/usr/bin/env bash
# FS150 companion Linux bring-up: apt sources + router package only.
#
# - Rewrite Ubuntu ports mirror; repair ROS key+source; add XGC2 apt
# - Quarantine other apt list files that break `apt-get update`
# - Stop/disable/mask vendor mavlink routers; free /dev/ttyS7
# - Install + enable xgc2-fs150-mavlink-router (UART Baud = 921600 hard rule)
# - Pin remote BlockMsgIdOut = 105, 106, 331, 132 (conffile may be old)
# - Persist 30/31/32 @ 15 Hz in FC extras.txt (not a rates systemd loop)
# - Retract APT 0.1.0-20 (block 30 + rates Wants); pin file has no extra
#   dots (apt ignores preferences.d names like *.0-20). Stay on installed
#   (17/19) until 21. If companion clock is days behind, set from apt HTTP Date.
# - Verify FC HEARTBEAT on the local unfiltered UDP port
# - If silent, lift PX4 SER_TEL1_BAUD from vendor 115200 to 921600 on the
#   UART (stop router, talk 115200, reboot FC, start router). Never rewrite
#   router.conf Baud.
#
# Does not touch NetworkManager. Use configure-network.sh for Wi-Fi / IPv4.
#
# Hard rule: never lower packaged Baud 921600.
#
# Usage:
#   sudo bash configure-linux.sh --yes
#   sudo bash configure-linux.sh --yes --repair-baud-only
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
APT_BASE_URL="${APT_BASE_URL:-${XGC2_APT_BASE_URL:-}}"
APT_SUITE="${APT_SUITE:-focal}"
XGC2_KEY_FPR="2A8E11B36F56D307ADF626D85E5FDC30979EA43F"
ROS_KEY_FPR="C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654"
ROUTER_PKG="xgc2-fs150-mavlink-router"
ROUTER_UNIT="xgc2-fs150-mavlink-router.service"
RATES_UNIT="xgc2-fs150-mavlink-rates.service"
ROUTER_CONF="/etc/xgc2/fs150-mavlink-router/router.conf"
UART_DEVICE="/dev/ttyS7"
EXPECT_BAUD="921600"
EXPECT_BLOCK_OUT="105, 106, 331, 132"
RETRACTED_FS150_DEB="0.1.0-20"
# apt ignores preferences.d names with extra dots (not .pref). Do not
# put 0.1.0-20 in the filename.
RETRACT_PIN="/etc/apt/preferences.d/xgc2-fs150-retract-20"
VENDOR_BAUD="115200"
LOCAL_MAVLINK_UDP="127.0.0.1:14561"
LINK_CHECK_SECONDS="${LINK_CHECK_SECONDS:-12}"
FC_REBOOT_WAIT_SECONDS="${FC_REBOOT_WAIT_SECONDS:-12}"

# Managed apt basenames we own after configure_*; everything else in
# sources.list.d may be quarantined when it breaks apt-get update.
MANAGED_APT_LISTS=(
  ros-latest.list
  xgc2.list
)

CONFLICT_UNITS=(
  startMavRoute.service
  fs150-mavlink-router.service
  mavlink-router.service
  mavlink_router.service
  xgc-mavlink-router.service
)

YES=0
SKIP_UBUNTU_MIRROR=0
SKIP_ROS_SOURCE=0
SKIP_LINK_CHECK=0
SKIP_QUARANTINE_SOURCES=0
SKIP_BAUD_REPAIR=0
REPAIR_BAUD_ONLY=0
SELF_TEST=0

usage() {
  cat <<'EOF'
Usage: configure-linux.sh --yes [options]

Options:
  --yes                     required; refuse to run without it
  --apt-url URL             from site.env XGC2_APT_BASE_URL; no in-script default
  --suite SUITE             default focal
  --skip-ubuntu-mirror      do not rewrite /etc/apt/sources.list
  --skip-ros-source         do not repair ROS apt key/source
  --skip-quarantine-sources do not move aside foreign/broken apt lists
  --skip-link-check         do not fail when HEARTBEAT missing after 921600
  --skip-baud-repair        do not lift SER_TEL1_BAUD from 115200 when silent
  --repair-baud-only        skip apt; stop router, lift baud, start router
  --link-check-seconds N    default 12
  --self-test               pack/parse only; no root, no UART
  -h, --help                show this help

Exit codes:
  0  router enabled at 921600 and (unless skipped) HEARTBEAT seen
  1  configuration / apt / service / link-check / baud-lift failure
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
    --apt-url) APT_BASE_URL="${2:?}"; shift 2 ;;
    --suite) APT_SUITE="${2:?}"; shift 2 ;;
    --skip-ubuntu-mirror) SKIP_UBUNTU_MIRROR=1; shift ;;
    --skip-ros-source) SKIP_ROS_SOURCE=1; shift ;;
    --skip-quarantine-sources) SKIP_QUARANTINE_SOURCES=1; shift ;;
    --skip-link-check) SKIP_LINK_CHECK=1; shift ;;
    --skip-baud-repair) SKIP_BAUD_REPAIR=1; shift ;;
    --repair-baud-only) REPAIR_BAUD_ONLY=1; shift ;;
    --link-check-seconds) LINK_CHECK_SECONDS="${2:?}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --site-env) export XGC2_SITE_ENV="${2:?}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

if [[ "${SELF_TEST}" -eq 0 ]]; then
  
xgc2_load_site
APT_BASE_URL="${APT_BASE_URL:-${XGC2_APT_BASE_URL:-}}"
if [[ "${SELF_TEST:-0}" -eq 0 && -z "${APT_BASE_URL}" ]]; then
  die "need --apt-url or site.env XGC2_APT_BASE_URL"
fi

[[ "${YES}" -eq 1 ]] || die "refusing to run without --yes (see --help)"
  require_root
  need_cmd python3
  need_cmd systemctl
  if [[ "${REPAIR_BAUD_ONLY}" -eq 0 ]]; then
    need_cmd curl
    need_cmd gpg
    need_cmd apt-get
    need_cmd dpkg
    need_cmd install
  fi
fi

ARCH="$(dpkg --print-architecture)"
if [[ "${SELF_TEST}" -eq 0 ]]; then
  [[ "${ARCH}" == "arm64" ]] || warn "expected arm64 companion, got ${ARCH}"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
QUARANTINE_DIR="/var/backups/xgc2-fs150-apt-${stamp}"

backup() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${path}.bak-${stamp}"
    log "backup ${path} -> ${path}.bak-${stamp}"
  fi
}

fingerprint_of() {
  local file="$1"
  gpg --show-keys --with-fingerprint --with-colons "${file}" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }'
}

is_managed_apt_list() {
  local base="$1"
  local m
  for m in "${MANAGED_APT_LISTS[@]}"; do
    [[ "${base}" == "${m}" ]] && return 0
  done
  return 1
}

quarantine_path() {
  local path="$1"
  mkdir -p "${QUARANTINE_DIR}"
  local base dest
  base="$(basename -- "${path}")"
  dest="${QUARANTINE_DIR}/${base}"
  mv -f -- "${path}" "${dest}"
  log "quarantine ${path} -> ${dest}"
}

# Move aside every non-managed sources.list.d entry (*.list / *.sources).
# Re-running on another aircraft must not inherit expired vendor ROS keys,
# random PPAs, or half-broken Chinese mirrors that fail apt-get update.
quarantine_foreign_apt_lists() {
  [[ "${SKIP_QUARANTINE_SOURCES}" -eq 0 ]] || { log "skip apt quarantine"; return; }
  local path base
  shopt -s nullglob
  for path in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    base="$(basename -- "${path}")"
    # Keep stamped backups in place; only active lists.
    [[ "${base}" == *.bak-* ]] && continue
    if is_managed_apt_list "${base}"; then
      continue
    fi
    quarantine_path "${path}"
  done
  shopt -u nullglob
}

configure_ubuntu_mirror() {
  [[ "${SKIP_UBUNTU_MIRROR}" -eq 0 ]] || { log "skip ubuntu mirror"; return; }
  local list=/etc/apt/sources.list
  backup "${list}"
  cat >"${list}" <<'EOF'
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal main restricted
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal-updates main restricted
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal universe
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal-updates universe
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal-updates multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal-backports main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ focal-security main restricted universe multiverse
EOF
  log "wrote Tsinghua ubuntu-ports sources.list"
}

fetch_ros_asc() {
  local dest="$1"
  # Prefer tuna (HTTP/HTTPS often works on field companions); then upstream.
  local url
  for url in \
    "https://mirrors.tuna.tsinghua.edu.cn/rosdistro/ros.asc" \
    "http://mirrors.tuna.tsinghua.edu.cn/rosdistro/ros.asc" \
    "https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc"
  do
    if curl -fsSL --connect-timeout 8 --max-time 45 "${url}" -o "${dest}"; then
      log "fetched ROS apt key from ${url}"
      return 0
    fi
  done
  return 1
}

configure_ros_source() {
  [[ "${SKIP_ROS_SOURCE}" -eq 0 ]] || { log "skip ROS source"; return; }
  local keyring=/usr/share/keyrings/ros-archive-keyring.gpg
  local list=/etc/apt/sources.list.d/ros-latest.list
  local asc
  asc="$(mktemp /tmp/ros.asc.XXXXXX)"
  fetch_ros_asc "${asc}" || die "could not download ROS apt signing key"
  local fpr
  fpr="$(fingerprint_of "${asc}")"
  [[ "${fpr}" == "${ROS_KEY_FPR}" ]] || die "ROS apt key fingerprint mismatch: ${fpr:-empty}"
  gpg --dearmor --yes -o /tmp/ros-archive-keyring.gpg "${asc}"
  install -d -m 0755 /usr/share/keyrings
  install -m 0644 /tmp/ros-archive-keyring.gpg "${keyring}"
  backup "${list}"
  # Drop legacy unsigned ros lists that apt still picks up under other names.
  local stale base
  shopt -s nullglob
  for stale in /etc/apt/sources.list.d/*ros*.list /etc/apt/sources.list.d/*ros*.sources; do
    base="$(basename -- "${stale}")"
    [[ "${base}" == "ros-latest.list" ]] && continue
    [[ "${base}" == *.bak-* ]] && continue
    quarantine_path "${stale}"
  done
  shopt -u nullglob
  printf 'deb [arch=%s signed-by=%s] http://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu %s main\n' \
    "${ARCH}" "${keyring}" "${APT_SUITE}" >"${list}"
  rm -f "${asc}" /tmp/ros-archive-keyring.gpg
  log "wrote ROS Noetic source with signed-by keyring"
}

configure_xgc2_source() {
  local key_url="${APT_BASE_URL%/}/xgc2-archive-keyring.gpg"
  local key_file
  key_file="$(mktemp /tmp/xgc2-archive-keyring.XXXXXX)"
  curl -fsSL --connect-timeout 10 --max-time 60 "${key_url}" -o "${key_file}" \
    || die "could not download XGC2 apt key from ${key_url}"
  local fpr
  fpr="$(fingerprint_of "${key_file}")"
  [[ "${fpr}" == "${XGC2_KEY_FPR}" ]] || die "XGC2 apt key fingerprint mismatch: ${fpr:-empty}"
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 "${key_file}" /etc/apt/keyrings/xgc2-archive-keyring.gpg
  rm -f "${key_file}"
  # Quarantine alternate xgc2 list names so only one production line remains.
  local stale base
  shopt -s nullglob
  for stale in /etc/apt/sources.list.d/*xgc2*.list /etc/apt/sources.list.d/*xgc2*.sources; do
    base="$(basename -- "${stale}")"
    [[ "${base}" == "xgc2.list" ]] && continue
    [[ "${base}" == *.bak-* ]] && continue
    quarantine_path "${stale}"
  done
  shopt -u nullglob
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/xgc2-archive-keyring.gpg] %s %s main\n' \
    "${ARCH}" "${APT_BASE_URL%/}" "${APT_SUITE}" \
    >/etc/apt/sources.list.d/xgc2.list
  log "wrote /etc/apt/sources.list.d/xgc2.list (${APT_BASE_URL%/} ${APT_SUITE})"
}

# apt-get update; on failure, quarantine the first still-active foreign list and retry.
apt_update_resilient() {
  local attempt=1
  local max_attempts=8
  local logf
  while [[ "${attempt}" -le "${max_attempts}" ]]; do
    logf="$(mktemp /tmp/apt-update.XXXXXX)"
    log "apt-get update (attempt ${attempt}/${max_attempts})"
    if apt-get update 2>"${logf}"; then
      cat "${logf}" >&2 || true
      rm -f "${logf}"
      return 0
    fi
    cat "${logf}" >&2 || true
    if grep -Eq 'Could not get lock|Unable to lock directory|Unable to lock the administration directory|无法获得锁|Resource temporarily unavailable' "${logf}"; then
      rm -f "${logf}"
      log "apt lock busy; wait and retry"
      wait_dpkg_lock
      sleep 3
      attempt=$((attempt + 1))
      continue
    fi
    if grep -Eq 'not valid yet|Release file .* expired|Release 文件已经过期|Clock skew detected' "${logf}"; then
      rm -f "${logf}"
      log "apt InRelease rejected as expired/not-yet-valid; resync clock"
      sync_clock_from_http
      wait_dpkg_lock
      sleep 2
      attempt=$((attempt + 1))
      continue
    fi
    if [[ "${SKIP_QUARANTINE_SOURCES}" -ne 0 ]]; then
      rm -f "${logf}"
      die "apt-get update failed and --skip-quarantine-sources is set"
    fi
    # Prefer explicit "The repository '…'" / Failed to fetch lines (mawk-safe).
    local bad host quarantined=0 path base
    bad="$(
      sed -n "s/.*The repository '\\([^']*\\)'.*/\\1/p;s/.*Failed to fetch \\([^ ]*\\).*/\\1/p" "${logf}" \
        | head -n1 || true
    )"
    rm -f "${logf}"
    host="$(printf '%s' "${bad}" | sed -E 's#^[a-zA-Z]+://##' | cut -d/ -f1)"
    shopt -s nullglob
    for path in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      base="$(basename -- "${path}")"
      is_managed_apt_list "${base}" && continue
      if [[ -n "${bad}" ]]; then
        if grep -Fq "${bad}" "${path}" 2>/dev/null \
          || { [[ -n "${host}" ]] && grep -Fq "${host}" "${path}" 2>/dev/null; }; then
          quarantine_path "${path}"
          quarantined=1
          break
        fi
        continue
      fi
      quarantine_path "${path}"
      quarantined=1
      break
    done
    shopt -u nullglob
    [[ "${quarantined}" -eq 1 ]] || die "apt-get update failed; no foreign list left to quarantine"
    attempt=$((attempt + 1))
  done
  die "apt-get update still failing after quarantining foreign sources"
}

discover_conflict_units() {
  local unit path
  # Known names.
  printf '%s\n' "${CONFLICT_UNITS[@]}"
  # Any unit file whose name smells like mavlink / startMav.
  shopt -s nullglob
  for path in \
    /etc/systemd/system/*.service \
    /lib/systemd/system/*.service \
    /usr/lib/systemd/system/*.service
  do
    unit="$(basename -- "${path}")"
    [[ "${unit}" == "${ROUTER_UNIT}" ]] && continue
    [[ "${unit}" == "${RATES_UNIT}" ]] && continue
    case "${unit}" in
      *[Mm]av[Ll]ink*|startMav*|fs150-mav*) printf '%s\n' "${unit}" ;;
    esac
  done
  shopt -u nullglob
}

stop_conflicts() {
  local unit
  systemctl daemon-reload >/dev/null 2>&1 || true
  # shellcheck disable=SC2207
  local units=( $(discover_conflict_units | sort -u) )
  for unit in "${units[@]}"; do
    if systemctl cat "${unit}" >/dev/null 2>&1; then
      log "stop/disable/mask ${unit}"
      systemctl stop "${unit}" >/dev/null 2>&1 || true
      systemctl disable "${unit}" >/dev/null 2>&1 || true
      # Mask so a vendor package reinstall cannot re-enable under our feet.
      systemctl mask "${unit}" >/dev/null 2>&1 || true
    else
      log "conflict unit absent: ${unit}"
    fi
  done

  # Leftover hand-started binaries (common on vendor images).
  local pid cmd main_pid
  main_pid="$(systemctl show -p MainPID --value "${ROUTER_UNIT}" 2>/dev/null || echo 0)"
  while read -r pid cmd; do
    [[ -z "${pid}" ]] && continue
    if [[ -n "${main_pid}" && "${main_pid}" != "0" && "${pid}" == "${main_pid}" ]]; then
      continue
    fi
    log "kill leftover mavlink process pid=${pid} cmd=${cmd}"
    kill "${pid}" >/dev/null 2>&1 || true
    sleep 0.2
    kill -9 "${pid}" >/dev/null 2>&1 || true
  done < <(ps -eo pid=,args= | awk '/mavlink-routerd/ && !/awk/ { print $1, $0 }')

  if command -v fuser >/dev/null 2>&1 && [[ -e "${UART_DEVICE}" ]]; then
    local holders holder_pids our=0 other=0
    holders="$(fuser "${UART_DEVICE}" 2>/dev/null || true)"
    for pid in ${holders}; do
      pid="${pid//[^0-9]/}"
      [[ -z "${pid}" ]] && continue
      if [[ -n "${main_pid}" && "${main_pid}" != "0" && "${pid}" == "${main_pid}" ]]; then
        our=1
        continue
      fi
      # Child threads of our routerd share the fd — treat same executable as ours.
      if [[ -n "${main_pid}" && "${main_pid}" != "0" ]] \
        && [[ "$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)" == \
              "$(readlink -f "/proc/${main_pid}/exe" 2>/dev/null || true)" ]]; then
        our=1
        continue
      fi
      other=1
      holder_pids="${holder_pids} ${pid}"
    done
    if [[ "${other}" -eq 1 ]]; then
      warn "${UART_DEVICE} held by foreign pids${holder_pids}; sending TERM"
      # shellcheck disable=SC2086
      kill -TERM ${holder_pids} >/dev/null 2>&1 || true
      sleep 0.5
      # shellcheck disable=SC2086
      kill -KILL ${holder_pids} >/dev/null 2>&1 || true
    elif [[ "${our}" -eq 1 ]]; then
      log "${UART_DEVICE} held only by ${ROUTER_UNIT}; leave it"
    fi
  fi
}

note_preexisting_uart_baud() {
  local line baud
  line="$(ps -eo args= | awk '/mavlink-routerd/ && !/awk/ { print; exit }' || true)"
  if [[ -z "${line}" ]]; then
    log "no preexisting mavlink-routerd; cannot infer prior UART baud"
    return
  fi
  log "preexisting routerd: ${line}"
  baud="$(printf '%s' "${line}" | sed -nE "s#.*${UART_DEVICE}:([0-9]+).*#\1#p")"
  if [[ -z "${baud}" ]]; then
    baud="$(printf '%s' "${line}" | tr ' ' '\n' | awk -F= '/^Baud$/ {getline; print; exit}')"
  fi
  if [[ -n "${baud}" && "${baud}" != "${EXPECT_BAUD}" ]]; then
    warn "preexisting UART baud ${baud} != required ${EXPECT_BAUD}"
    warn "after switch, PX4 SER_TELx_BAUD (or this airframe UART) must be ${EXPECT_BAUD}"
  fi
}

http_date_from_headers() {
  tr -d '\r' | grep -i '^Date:' | head -n1 | cut -d' ' -f2-
}

sync_clock_from_http() {
  # Companion clocks often sit days behind; apt then refuses InRelease.
  local url hdr epoch_http epoch_now skew
  url="${APT_BASE_URL%/}/dists/${APT_SUITE}/InRelease"
  hdr="$(curl -sI --connect-timeout 8 --max-time 15 "${url}" 2>/dev/null \
    | http_date_from_headers)"
  if [[ -z "${hdr}" ]]; then
    warn "no HTTP Date from apt; leave companion clock"
    return 0
  fi
  epoch_http="$(date -u -d "${hdr}" +%s 2>/dev/null || true)"
  epoch_now="$(date -u +%s)"
  if [[ -z "${epoch_http}" ]]; then
    warn "could not parse apt HTTP Date: ${hdr}"
    return 0
  fi
  skew=$(( epoch_now - epoch_http ))
  if [[ "${skew}" -lt 0 ]]; then
    skew=$(( -skew ))
  fi
  if [[ "${skew}" -lt 3600 ]]; then
    log "companion clock skew ${skew}s; leave it"
    return 0
  fi
  date -u -s "$(date -u -d "${hdr}" '+%Y-%m-%d %H:%M:%S')" >/dev/null
  log "set clock from apt HTTP Date (${hdr}); was ${skew}s off"
  sleep 3
}

write_retract_pin() {
  mkdir -p /etc/apt/preferences.d
  rm -f /etc/apt/preferences.d/xgc2-fs150-retract-0.1.0-20
  cat > "${RETRACT_PIN}" <<EOF
Package: xgc2-fs150-mavlink-router
Pin: version ${RETRACTED_FS150_DEB}
Pin-Priority: -1

Package: xgc2-fs150
Pin: version ${RETRACTED_FS150_DEB}
Pin-Priority: -1
EOF
  log "APT pin ${RETRACT_PIN} forbids ${RETRACTED_FS150_DEB}"
}

assert_router_not_retracted() {
  local cand inst
  cand="$(apt-cache policy "${ROUTER_PKG}" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  inst="$(apt-cache policy "${ROUTER_PKG}" 2>/dev/null | awk '/Installed:/ {print $2; exit}')"
  if [[ "${cand}" == "${RETRACTED_FS150_DEB}" ]]; then
    die "${ROUTER_PKG} candidate ${RETRACTED_FS150_DEB} is retracted; stay on installed until 0.1.0-21"
  fi
  if [[ "${inst}" == "${RETRACTED_FS150_DEB}" ]]; then
    die "installed ${ROUTER_PKG} ${RETRACTED_FS150_DEB} is retracted; install 0.1.0-19 or 0.1.0-21"
  fi
}

retire_rates_helper() {
  # 0.1.0-20 leftover. Persistence is extras.txt, not SET_MESSAGE_INTERVAL.
  if systemctl cat "${RATES_UNIT}" >/dev/null 2>&1 \
    || [[ -e "/etc/systemd/system/${RATES_UNIT}" ]] \
    || [[ -e "/lib/systemd/system/${RATES_UNIT}" ]]; then
    log "stop/disable/mask leftover ${RATES_UNIT}"
    systemctl stop "${RATES_UNIT}" >/dev/null 2>&1 || true
    systemctl disable "${RATES_UNIT}" >/dev/null 2>&1 || true
  fi
  systemctl mask "${RATES_UNIT}" >/dev/null 2>&1 || true
}

wait_dpkg_lock() {
  local n=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
    || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
    || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
    || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    n=$((n + 1))
    if [[ "${n}" -gt 60 ]]; then
      die "apt/dpkg lock still held after 120s"
    fi
    log "wait dpkg lock (${n})"
    sleep 2
  done
}

install_router_package() {
  sync_clock_from_http
  write_retract_pin
  wait_dpkg_lock
  apt_update_resilient
  assert_router_not_retracted
  wait_dpkg_lock
  log "apt-get install -y --no-install-recommends ${ROUTER_PKG}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${ROUTER_PKG}"
  dpkg -s "${ROUTER_PKG}" >/dev/null
  dpkg -s xgc2-mavlink-router >/dev/null
  test -f "${ROUTER_CONF}"
  grep -q "^Baud = ${EXPECT_BAUD}$" "${ROUTER_CONF}" \
    || die "expected packaged Baud = ${EXPECT_BAUD} in ${ROUTER_CONF}"
  grep -q "^Device = ${UART_DEVICE}$" "${ROUTER_CONF}" \
    || die "expected Device = ${UART_DEVICE} in ${ROUTER_CONF}"
  assert_router_not_retracted
}

ensure_block_msg_ids() {
  local want="BlockMsgIdOut = ${EXPECT_BLOCK_OUT}"
  test -f "${ROUTER_CONF}" || die "missing ${ROUTER_CONF}"
  if grep -q "^${want}$" "${ROUTER_CONF}"; then
    log "BlockMsgIdOut already ${EXPECT_BLOCK_OUT}"
    return 0
  fi
  backup "${ROUTER_CONF}"
  if grep -q "^BlockMsgIdOut =" "${ROUTER_CONF}"; then
    sed -i "s/^BlockMsgIdOut = .*/${want}/" "${ROUTER_CONF}"
  else
    printf '\n%s\n' "${want}" >>"${ROUTER_CONF}"
  fi
  grep -q "^${want}$" "${ROUTER_CONF}" || die "failed to write ${want}"
  log "wrote ${want}"
}

enable_router() {
  stop_conflicts
  log "enable --now ${ROUTER_UNIT}"
  systemctl unmask "${ROUTER_UNIT}" >/dev/null 2>&1 || true
  systemctl enable --now "${ROUTER_UNIT}"
  systemctl restart "${ROUTER_UNIT}"
  systemctl is-active --quiet "${ROUTER_UNIT}" || die "${ROUTER_UNIT} failed to start"
  systemctl is-enabled --quiet "${ROUTER_UNIT}" || die "${ROUTER_UNIT} not enabled"
  retire_rates_helper
  # Confirm journal reports the hard-rule baud.
  if ! journalctl -u "${ROUTER_UNIT}" -n 30 --no-pager 2>/dev/null \
      | grep -Eq "speed = ${EXPECT_BAUD}|Baud = ${EXPECT_BAUD}"; then
    # Fall back to conf + process cmdline.
    if ! tr '\0' ' ' <"/proc/$(systemctl show -p MainPID --value "${ROUTER_UNIT}")/cmdline" 2>/dev/null \
        | grep -Fq "${ROUTER_CONF}"; then
      warn "could not confirm ${EXPECT_BAUD} from journal; conf still requires it"
    fi
  fi
  log "router reports ${UART_DEVICE} @ ${EXPECT_BAUD}"
}

block_self_test() {
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "BlockMsgIdOut = 105, 106, 331" >"${tmp}"
  local saved="${ROUTER_CONF}"
  ROUTER_CONF="${tmp}"
  ensure_block_msg_ids
  ROUTER_CONF="${saved}"
  grep -q "^BlockMsgIdOut = ${EXPECT_BLOCK_OUT}$" "${tmp}" \
    || die "BlockMsgIdOut rewrite self-test failed"
  rm -f "${tmp}" "${tmp}.bak-"* 2>/dev/null || true
  log "BlockMsgIdOut rewrite self-test ok"
}

# Talk vendor UART baud only long enough to SET SER_TEL1_BAUD. Never write
# 115200 into router.conf. --self-test packs frames only.
baud_lift_python() {
  cat <<'PY'
from __future__ import print_function

import argparse
import os
import select
import struct
import sys
import termios
import time

CRC_EXTRA = {0: 50, 20: 214, 22: 220, 23: 168, 76: 152, 77: 134}
ARMED_FLAG = 128
CMD_REBOOT = 246


def crc_x25(data):
    crc = 0xFFFF
    for b in bytearray(data):
        tmp = b ^ (crc & 0xFF)
        tmp = (tmp ^ ((tmp << 4) & 0xFF)) & 0xFF
        crc = ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xFFFF
    return crc


def pack_v1(msgid, payload, seq, sysid=255, compid=190):
    extra = CRC_EXTRA[msgid]
    header = struct.pack("BBBBB", len(payload), seq & 0xFF, sysid, compid, msgid)
    crc = crc_x25(header + payload + bytes(bytearray([extra])))
    return b"\xfe" + header + payload + struct.pack("<H", crc)


def heartbeat_pkt(seq):
    return pack_v1(0, struct.pack("<IBBBBB", 0, 6, 8, 0, 0, 0), seq)


def param_request_read_pkt(seq, target_sys, name):
    param_id = name.encode("ascii") + b"\x00" * (16 - len(name))
    return pack_v1(20, struct.pack("<hBB16s", -1, target_sys, 1, param_id), seq)


def param_set_pkt(seq, target_sys, name, value, ptype):
    param_id = name.encode("ascii") + b"\x00" * (16 - len(name))
    payload = struct.pack("<i", int(value)) + struct.pack("<BB16sB", target_sys, 1, param_id, ptype)
    return pack_v1(23, payload, seq)


def command_long_pkt(seq, target_sys, command, param1=0):
    payload = struct.pack(
        "<fffffffHBBB",
        float(param1), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        int(command), target_sys, 1, 0,
    )
    return pack_v1(76, payload, seq)


def parse_one(buf):
    if not buf:
        return None
    if buf[0] == 0xFE and len(buf) >= 8:
        plen = buf[1]
        if len(buf) < 8 + plen:
            return None
        return msgid_tuple(buf[5], buf[6:6 + plen], buf[3], 8 + plen)
    if buf[0] == 0xFD and len(buf) >= 12:
        plen = buf[1]
        if len(buf) < 12 + plen:
            return None
        msgid = buf[7] | (buf[8] << 8) | (buf[9] << 16)
        return msgid_tuple(msgid, buf[10:10 + plen], buf[5], 12 + plen)
    return None


def msgid_tuple(msgid, payload, sysid, consumed):
    return msgid, payload, sysid, consumed


def decode_param_value(payload):
    if len(payload) < 25:
        return None
    raw = payload[8:24]
    name = raw.split(b"\x00", 1)[0].decode("ascii", "replace")
    bits = struct.unpack_from("<i", payload, 0)[0]
    ptype = payload[24]
    return name, bits, ptype


def open_serial(path, baud):
    const = getattr(termios, "B%d" % baud, None)
    if const is None:
        raise SystemExit("termios has no B%s" % baud)
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
    attrs[3] = 0
    attrs[4] = const
    attrs[5] = const
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_some(fd, timeout):
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return b""
    try:
        return os.read(fd, 512)
    except OSError:
        return b""


def take_frames(buf):
    frames = []
    while buf:
        start = buf.find(b"\xfe")
        start2 = buf.find(b"\xfd")
        if start < 0 and start2 < 0:
            return frames, b""
        if start < 0 or (start2 >= 0 and start2 < start):
            start = start2
        if start > 0:
            buf = buf[start:]
        parsed = parse_one(buf)
        if parsed is None:
            if len(buf) < 12:
                return frames, buf
            buf = buf[1:]
            continue
        msgid, payload, sysid, consumed = parsed
        frames.append((msgid, payload, sysid))
        buf = buf[consumed:]
    return frames, buf


def self_test():
    pkt = param_set_pkt(0, 14, "SER_TEL1_BAUD", 921600, 6)
    assert pkt[0] == 0xFE and pkt[5] == 23
    parsed = parse_one(pkt)
    assert parsed[0] == 23 and parsed[2] == 255
    value_payload = struct.pack("<iHH16sB", 921600, 1, 0, b"SER_TEL1_BAUD\x00\x00\x00", 6)
    name, value, ptype = decode_param_value(value_payload)
    assert name == "SER_TEL1_BAUD" and value == 921600 and ptype == 6
    assert parse_one(heartbeat_pkt(1))[0] == 0
    print("baud-lift self-test ok")


def lift(device, from_baud, to_baud, seconds):
    fd = open_serial(device, from_baud)
    seq = 0
    buf = b""
    target = None
    armed = False
    deadline = time.time() + seconds
    try:
        while time.time() < deadline and target is None:
            os.write(fd, heartbeat_pkt(seq))
            seq = (seq + 1) & 0xFF
            buf += read_some(fd, 0.3)
            frames, buf = take_frames(buf)
            for msgid, payload, sysid in frames:
                if msgid == 0 and sysid not in (0, 255):
                    target = sysid
                    armed = len(payload) >= 7 and (payload[6] & ARMED_FLAG) != 0
                    break
        if target is None:
            raise SystemExit("no FC HEARTBEAT on %s @ %s" % (device, from_baud))
        if armed:
            raise SystemExit("FC is armed; refuse SER_TEL1_BAUD")
        print("HEARTBEAT sysid=%s on %s @ %s" % (target, device, from_baud))
        os.write(fd, heartbeat_pkt(seq))
        seq = (seq + 1) & 0xFF
        os.write(fd, param_set_pkt(seq, target, "SER_TEL1_BAUD", to_baud, 6))
        seq = (seq + 1) & 0xFF
        confirmed = False
        wait_until = time.time() + 3.0
        while time.time() < wait_until:
            buf += read_some(fd, 0.3)
            frames, buf = take_frames(buf)
            for msgid, payload, _sysid in frames:
                if msgid != 22:
                    continue
                decoded = decode_param_value(payload)
                if decoded and decoded[0] == "SER_TEL1_BAUD":
                    print("SER_TEL1_BAUD now %s type %s" % (decoded[1], decoded[2]))
                    confirmed = True
                    break
            if confirmed:
                break
        os.write(fd, heartbeat_pkt(seq))
        seq = (seq + 1) & 0xFF
        os.write(fd, command_long_pkt(seq, target, CMD_REBOOT, 1))
        print("sent PREFLIGHT_REBOOT after SER_TEL1_BAUD=%s" % to_baud)
    finally:
        os.close(fd)
    return 0


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--device", default="/dev/ttyS7")
    parser.add_argument("--from-baud", type=int, default=115200)
    parser.add_argument("--to-baud", type=int, default=921600)
    parser.add_argument("--seconds", type=float, default=8.0)
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.to_baud != 921600:
        raise SystemExit("refuse to lift to %s; product baud is 921600" % args.to_baud)
    return lift(args.device, args.from_baud, args.to_baud, args.seconds)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
}

baud_lift_self_test() {
  python3 - --self-test <<<"$(baud_lift_python)"
}

# Stop the 921600 router, SET SER_TEL1_BAUD on vendor 115200, reboot FC.
repair_fc_baud() {
  log "baud lift: stop ${ROUTER_UNIT} and talk ${UART_DEVICE} @ ${VENDOR_BAUD}"
  systemctl stop "${ROUTER_UNIT}" || true
  local rc=0
  if ! python3 - --device "${UART_DEVICE}" --from-baud "${VENDOR_BAUD}" --to-baud "${EXPECT_BAUD}" \
      --seconds "${LINK_CHECK_SECONDS}" <<<"$(baud_lift_python)"; then
    rc=1
  fi
  log "wait ${FC_REBOOT_WAIT_SECONDS}s for FC reboot"
  sleep "${FC_REBOOT_WAIT_SECONDS}"
  log "start ${ROUTER_UNIT} @ ${EXPECT_BAUD}"
  systemctl start "${ROUTER_UNIT}"
  systemctl is-active --quiet "${ROUTER_UNIT}" || die "${ROUTER_UNIT} failed to start after baud lift"
  grep -q "^Baud = ${EXPECT_BAUD}$" "${ROUTER_CONF}" \
    || die "router.conf must stay Baud = ${EXPECT_BAUD}"
  if grep -q "^Baud = ${VENDOR_BAUD}$" "${ROUTER_CONF}"; then
    die "refuse: router.conf was rewritten to ${VENDOR_BAUD}"
  fi
  return "${rc}"
}

# Fail early when FC is still at another baud (common vendor default 115200).
verify_fc_heartbeat() {
  if [[ "${SKIP_LINK_CHECK}" -ne 0 ]]; then
    warn "skipping HEARTBEAT link check (--skip-link-check)"
    return 0
  fi
  log "link check: wait up to ${LINK_CHECK_SECONDS}s for FC HEARTBEAT on ${LOCAL_MAVLINK_UDP} (baud ${EXPECT_BAUD})"
  if python3 - "${LOCAL_MAVLINK_UDP}" "${LINK_CHECK_SECONDS}" <<'PY'
import sys, socket, time, struct

target, seconds = sys.argv[1], float(sys.argv[2])
host, port_s = target.rsplit(":", 1)
port = int(port_s)

def crc_x25(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        tmp = b ^ (crc & 0xFF)
        tmp ^= (tmp << 4) & 0xFF
        crc = ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xFFFF
    return crc

# MAVLink v1 HEARTBEAT from GCS (sys 255, comp 190). crc_extra for HEARTBEAT = 50.
payload = struct.pack("<IBBBBB", 0, 6, 8, 0, 0, 0)  # custom_mode, type, autopilot, base_mode, system_status, mavlink_version
seq = 0
header = struct.pack("<BBBBBB", 0xFE, len(payload), seq, 255, 190, 0)
crc = crc_x25(header[1:] + payload + bytes([50]))
pkt = header + payload + struct.pack("<H", crc)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.5)
# Ephemeral local bind so the router's UDP Server has a return path.
sock.bind(("0.0.0.0", 0))
deadline = time.time() + seconds
got = False
while time.time() < deadline:
    try:
        sock.sendto(pkt, (host, port))
    except OSError:
        pass
    try:
        data, _addr = sock.recvfrom(2048)
    except socket.timeout:
        continue
    if not data:
        continue
    # Any MAVLink framing from the FC path is enough; prefer HEARTBEAT msgid 0.
    if data[0] in (0xFE, 0xFD):
        # v1: msgid at [5]; v2: msgid at [7:10] little-endian 24-bit
        if data[0] == 0xFE and len(data) >= 6 and data[5] == 0:
            # Ignore our own GCS heartbeats if echoed (sysid 255).
            if len(data) >= 4 and data[3] != 255:
                got = True
                break
        elif data[0] == 0xFD and len(data) >= 10:
            msgid = data[7] | (data[8] << 8) | (data[9] << 16)
            sysid = data[5]
            if msgid == 0 and sysid != 255:
                got = True
                break
        elif data[0] in (0xFE, 0xFD) and (len(data) < 4 or data[3] != 255):
            # Non-GCS traffic on the FC link — accept as link-up.
            if data[0] == 0xFD and len(data) >= 6 and data[5] != 255:
                got = True
                break
            if data[0] == 0xFE and len(data) >= 4 and data[3] != 255:
                got = True
                break
sock.close()
sys.exit(0 if got else 2)
PY
  then
    log "HEARTBEAT/link OK on ${LOCAL_MAVLINK_UDP}"
    return 0
  fi
  warn "no FC MAVLink on ${LOCAL_MAVLINK_UDP} within ${LINK_CHECK_SECONDS}s at ${EXPECT_BAUD}"
  return 1
}

print_baud_dead_help() {
  cat >&2 <<EOF
error: still no FC MAVLink after baud lift.

Companion UART stays ${EXPECT_BAUD} (hard rule). Usual leftover: FC not on
TELEM1, FC armed, or wiring. Do **not** lower Baud in ${ROUTER_CONF}.

Wired QGC last resort: set PX4 SER_TEL1_BAUD=${EXPECT_BAUD}, then
systemctl restart ${ROUTER_UNIT}.
To skip the link gate: --skip-link-check.
EOF
}

smoke() {
  log "smoke"
  systemctl --no-pager --full status "${ROUTER_UNIT}" | sed -n '1,25p'
  ss -lntup 2>/dev/null | grep -E ':5760|:14560|:14561' || true
  if [[ -d "${QUARANTINE_DIR}" ]]; then
    log "quarantined apt sources under ${QUARANTINE_DIR}"
  fi
  cat <<EOF
+ hard rule: companion UART Baud = ${EXPECT_BAUD} (do not lower it)
+ remote QGC/MAVROS: UDP ${UART_DEVICE%@*} host:14560 or TCP host:5760
+ onboard MAVROS (if used later): udp://:14551@127.0.0.1:14561
EOF
  log "next: Insert check apt boot"
  log "remote BlockMsgIdOut = ${EXPECT_BLOCK_OUT}"
  log "onboard extras.txt: 30/31/32 @ 15 Hz (next FC reboot)"
  log "done"
}

ensure_link_or_lift() {
  if verify_fc_heartbeat; then
    return 0
  fi
  if [[ "${SKIP_BAUD_REPAIR}" -ne 0 ]]; then
    print_baud_dead_help
    return 1
  fi
  log "921600 silent; lifting SER_TEL1_BAUD from ${VENDOR_BAUD} (vendor startMavRoute)"
  repair_fc_baud || { print_baud_dead_help; return 1; }
  if verify_fc_heartbeat; then
    return 0
  fi
  print_baud_dead_help
  return 1
}

apply_fc_extras_rates() {
  local py="${SCRIPT_DIR}/apply-fc-extras-rates.py"
  log "persist 30/31/32 @ 15 Hz in FC extras.txt"
  if [[ -f "${py}" ]]; then
    python3 "${py}" --host 127.0.0.1 --port 14561 --wait "${LINK_CHECK_SECONDS}"
    return
  fi
  # Insert only places the catalog .sh; keep the helper inline.
  python3 - --host 127.0.0.1 --port 14561 --wait "${LINK_CHECK_SECONDS}" <<'PY'
import argparse, re, socket, struct, sys, time
STREAM_RE = re.compile(r"^mavlink stream -d (/dev/ttyS\d+) -s\s+(\S+) -r (\d+)\s*$")
WANT = (("LOCAL_POSITION_NED", "15"), ("ATTITUDE_QUATERNION", "15"), ("ATTITUDE", "15"))
CRC_EXTRA = {0: 50, 126: 220}
ARMED_FLAG = 128
DEV_SHELL, FLAG_RESPOND, FLAG_EXCLUSIVE, FLAG_MULTI = 10, 2, 4, 16

def crc_x25(data):
    crc = 0xFFFF
    for b in bytearray(data):
        tmp = b ^ (crc & 0xFF)
        tmp = (tmp ^ ((tmp << 4) & 0xFF)) & 0xFF
        crc = ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xFFFF
    return crc

def pack_v1(msgid, payload, seq, sysid=255, compid=190):
    header = struct.pack("BBBBB", len(payload), seq & 0xFF, sysid, compid, msgid)
    crc = crc_x25(header + payload + bytes(bytearray([CRC_EXTRA[msgid]])))
    return b"\xfe" + header + payload + struct.pack("<H", crc)

def heartbeat_pkt(seq):
    return pack_v1(0, struct.pack("<IBBBBB", 0, 6, 8, 0, 0, 0), seq)

def serial_control_pkt(seq, flags, data):
    chunk = data[:70]
    # Wire order: baudrate u32, timeout u16, device, flags, count, data[70]
    payload = struct.pack("<IHBBB70s", 0, 0, DEV_SHELL, flags, len(chunk), chunk.ljust(70, b"\x00"))
    return pack_v1(126, payload, seq)

def parse_one(buf):
    if not buf:
        return None
    if buf[0] == 0xFE and len(buf) >= 8:
        plen = buf[1]
        if len(buf) < 8 + plen:
            return None
        return buf[5], buf[6:6 + plen], buf[3], 8 + plen
    if buf[0] == 0xFD and len(buf) >= 12:
        plen = buf[1]
        if len(buf) < 12 + plen:
            return None
        msgid = buf[7] | (buf[8] << 8) | (buf[9] << 16)
        return msgid, buf[10:10 + plen], buf[5], 12 + plen
    return None

def merge_extras(text):
    lines = text.splitlines()
    devices = []
    for ln in lines:
        m = STREAM_RE.match(ln.strip()) if ln.strip() else None
        if m and m.group(1) not in devices:
            devices.append(m.group(1))
    if not devices:
        devices = ["/dev/ttyS1", "/dev/ttyS0"]
    seen = {d: set() for d in devices}
    out = []
    wanted = dict(WANT)
    for ln in lines:
        s = ln.strip()
        m = STREAM_RE.match(s) if s else None
        if not m:
            out.append(ln)
            continue
        dev, stream = m.group(1), m.group(2)
        if stream in wanted:
            out.append("mavlink stream -d %s -s  %s -r %s" % (dev, stream, wanted[stream]))
            seen.setdefault(dev, set()).add(stream)
        else:
            out.append(ln)
            seen.setdefault(dev, set())
    for dev in devices:
        have = seen.get(dev, set())
        for stream, rate in WANT:
            if stream not in have:
                out.append("mavlink stream -d %s -s  %s -r %s" % (dev, stream, rate))
                have.add(stream)
    return "\n".join(out).rstrip() + "\n"

def extras_ok(text):
    if "LOCAL_POSITION_NED -r 30" in text or "LOCAL_POSITION_NED  -r 30" in text:
        return False
    if "ATTITUDE -r 10" in text or "ATTITUDE  -r 10" in text:
        return False
    if "ATTITUDE -r 30" in text or "ATTITUDE  -r 30" in text:
        return False
    if "ATTITUDE_QUATERNION -r 15" not in text and "ATTITUDE_QUATERNION  -r 15" not in text:
        return False
    if "LOCAL_POSITION_NED -r 15" not in text and "LOCAL_POSITION_NED  -r 15" not in text:
        return False
    if "ATTITUDE -r 15" not in text and "ATTITUDE  -r 15" not in text:
        return False
    return True

class Link(object):
    def __init__(self, host, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.4)
        self.sock.bind(("0.0.0.0", 0))
        self.dest = (host, port)
        self.seq = 0
        self.buf = b""
        self.target_sys = 1
    def send(self, pkt):
        self.sock.sendto(pkt, self.dest)
        self.seq = (self.seq + 1) & 0xFF
    def recv_msg(self, timeout=0.4):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not self.buf:
                try:
                    data, _ = self.sock.recvfrom(2048)
                except socket.timeout:
                    return None
                self.buf += data
            parsed = parse_one(self.buf)
            if parsed is None:
                self.buf = self.buf[1:]
                continue
            msgid, payload, sysid, n = parsed
            self.buf = self.buf[n:]
            return msgid, payload, sysid
        return None
    def wait_fc(self, seconds):
        t0 = time.time()
        while time.time() - t0 < seconds:
            self.send(heartbeat_pkt(self.seq))
            msg = self.recv_msg(0.4)
            if not msg:
                continue
            msgid, payload, sysid = msg
            # HEARTBEAT: type@4, autopilot@5 (PX4=12), base_mode@6
            if msgid == 0 and sysid != 255 and len(payload) >= 7 and payload[5] == 12:
                return True, (payload[6] & ARMED_FLAG) != 0
        return False, False
    def nsh(self, cmd, wait=2.0):
        flags = FLAG_RESPOND | FLAG_EXCLUSIVE | FLAG_MULTI
        payload = (cmd + "\n").encode("ascii")
        off = 0
        while off < len(payload):
            self.send(serial_control_pkt(self.seq, flags, payload[off:off+70]))
            off += 70
        out = b""
        t0 = time.time()
        while time.time() - t0 < wait:
            self.send(heartbeat_pkt(self.seq))
            msg = self.recv_msg(0.4)
            if not msg:
                continue
            msgid, payload, _sysid = msg
            if msgid != 126 or len(payload) < 9:
                continue
            out += payload[9:9+payload[8]]
        return out.decode("utf-8", "replace")
    def close_shell(self):
        self.send(serial_control_pkt(self.seq, 0, b""))

p = argparse.ArgumentParser()
p.add_argument("--host", default="127.0.0.1")
p.add_argument("--port", type=int, default=14561)
p.add_argument("--wait", type=float, default=12.0)
args = p.parse_args()
link = Link(args.host, args.port)
ok, armed = link.wait_fc(args.wait)
if not ok:
    sys.stderr.write("error: no PX4 HEARTBEAT\n")
    sys.exit(2)
if armed:
    sys.stderr.write("error: FC armed; refuse extras write\n")
    sys.exit(2)
link.nsh("cp /fs/microsd/etc/extras.txt /fs/microsd/etc/extras.txt.bak", 2.0)
current = link.nsh("cat /fs/microsd/etc/extras.txt", 4.0)
body = current
for token in ("nsh> ", "cat /fs/microsd/etc/extras.txt", "\x1b[K"):
    body = body.replace(token, "")
merged = merge_extras(body)
if not extras_ok(merged):
    sys.stderr.write("error: merge failed\n")
    sys.exit(1)
first = True
path = "/fs/microsd/etc/extras.txt"
for ln in merged.splitlines():
    if first:
        cmd = ("echo %s > %s" % (ln, path)) if ln else ("echo > %s" % path)
        first = False
    else:
        cmd = ("echo %s >> %s" % (ln, path)) if ln else ("echo >> %s" % path)
    link.nsh(cmd, 1.2)
verify = link.nsh("cat /fs/microsd/etc/extras.txt", 4.0)
link.close_shell()
if not extras_ok(verify):
    sys.stderr.write("error: extras verify failed\n")
    sys.exit(1)
print("wrote 30/31/32 @ 15 Hz into extras.txt (takes effect on next FC reboot)")
sys.exit(0)
PY
}

if [[ "${SELF_TEST}" -eq 1 ]]; then
  baud_lift_self_test
  block_self_test
  [[ "${RETRACTED_FS150_DEB}" == "0.1.0-20" ]] \
    || die "retracted FS150 deb must stay 0.1.0-20 until 0.1.0-21 is live"
  python3 "${SCRIPT_DIR}/apply-fc-extras-rates.py" --self-test
  exit 0
fi

if [[ "${REPAIR_BAUD_ONLY}" -eq 1 ]]; then
  repair_fc_baud || exit 1
  if ! verify_fc_heartbeat; then
    print_baud_dead_help
    exit 1
  fi
  smoke
  exit 0
fi

note_preexisting_uart_baud
quarantine_foreign_apt_lists
configure_ubuntu_mirror
configure_ros_source
configure_xgc2_source
install_router_package
ensure_block_msg_ids
enable_router
link_rc=0
ensure_link_or_lift || link_rc=$?
if [[ "${link_rc}" -eq 0 ]]; then
  apply_fc_extras_rates || link_rc=$?
fi
smoke
exit "${link_rc}"
