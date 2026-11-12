#!/usr/bin/env bash
# DeepSeek Harness launcher for Android (Termux + proot Debian/Ubuntu)
#
# Usage (inside Termux):
#   bash dsh-android.sh          # install what's missing, start server, open browser
#   bash dsh-android.sh stop     # stop the server
#   bash dsh-android.sh logs     # show server log
#
# Advanced (already inside a Debian/Ubuntu shell):
#   bash dsh-android.sh --inside-setup && bash dsh-android.sh --inside-serve
#
# Env overrides: DISTRO=debian|ubuntu  NODE_MAJOR=22  MIN_NODE_MAJOR=20
#                PKG_NAME=@deepseek-ai/dsh  WAIT_SECS=180

set -euo pipefail

DISTRO="${DISTRO:-debian}"
NODE_MAJOR="${NODE_MAJOR:-22}"
MIN_NODE_MAJOR="${MIN_NODE_MAJOR:-20}"
PKG_NAME="${PKG_NAME:-@deepseek-ai/dsh}"
WAIT_SECS="${WAIT_SECS:-180}"

HOST_LOG="${HOME}/dsh-server.log"
HOST_PID="${HOME}/dsh-server.pid"

log()  { printf '\033[1;36m[dsh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dsh] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[dsh] %s\033[0m\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Inside the Debian/Ubuntu guest
# ----------------------------------------------------------------------------
inner_setup() {
  [ "$(id -u)" -eq 0 ] || die "Run as root inside the distro."
  export DEBIAN_FRONTEND=noninteractive

  local need_apt=0 c
  for c in curl git make g++ python3 xz; do
    command -v "$c" >/dev/null 2>&1 || need_apt=1
  done
  [ -f /etc/ssl/certs/ca-certificates.crt ] || need_apt=1
  if [ "$need_apt" = 1 ]; then
    log "Installing base packages..."
    apt-get update
    apt-get install -y --no-install-recommends \
      curl ca-certificates git build-essential python3 xz-utils gnupg
  fi

  local node_major=0
  if command -v node >/dev/null 2>&1; then
    node_major="$(node -p 'process.versions.node.split(".")[0]')"
  fi
  if [ "$node_major" -lt "$MIN_NODE_MAJOR" ]; then
    log "Installing Node.js ${NODE_MAJOR}.x (found: ${node_major})..."
    local tmp
    tmp="$(mktemp)"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$tmp"
    bash "$tmp"
    rm -f "$tmp"
    apt-get install -y nodejs
  else
    log "Node.js $(node -v) OK"
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    log "Installing pnpm..."
    if ! { corepack enable && corepack prepare pnpm@latest --activate; } >/dev/null 2>&1; then
      npm install -g pnpm
    fi
  fi
  log "pnpm $(pnpm -v) OK"
}

inner_serve() {
  export HOME=/root
  cd /root
  log "Starting DeepSeek Harness (${PKG_NAME})..."
  exec npx -y "$PKG_NAME" web --no-open
}

# ----------------------------------------------------------------------------
# Termux host side
# ----------------------------------------------------------------------------
find_url() {
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$HOST_LOG" 2>/dev/null \
    | grep -oE 'https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):[0-9]+[^[:space:]]*' \
    | head -1 \
    | sed -e 's#//0\.0\.0\.0#//localhost#' -e 's#//\[::1\]#//localhost#' -e 's#//\[::\]#//localhost#' \
    || true
}

server_alive() {
  [ -f "$HOST_PID" ] && kill -0 "$(cat "$HOST_PID")" 2>/dev/null
}

open_url() {
  local url="$1"
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$url" || true
  elif command -v am >/dev/null 2>&1; then
    am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1 || true
  else
    warn "Can't auto-open a browser. Open this manually: $url"
  fi
}

host_stop() {
  if server_alive; then
    kill "$(cat "$HOST_PID")" 2>/dev/null || true
  fi
  pkill -f "$PKG_NAME" 2>/dev/null || true
  rm -f "$HOST_PID"
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock || true
  log "Stopped."
}

host_main() {
  command -v pkg >/dev/null 2>&1 || die "This must run inside Termux. (Already in Debian/Ubuntu? Use --inside-setup / --inside-serve.)"

  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) warn "Unusual CPU architecture: $(uname -m). Continuing anyway." ;;
  esac

  # 1) Termux packages
  local missing=()
  for p in proot-distro termux-api curl; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  # termux-api package provides termux-open-url etc.
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing Termux packages: ${missing[*]}"
    pkg update -y
    pkg install -y "${missing[@]}"
  fi

  # 2) Distro
  local rootfs="${PREFIX}/var/lib/proot-distro/installed-rootfs/${DISTRO}"
  if [ ! -d "$rootfs" ]; then
    log "Installing ${DISTRO} (one-time, a few hundred MB)..."
    proot-distro install "$DISTRO"
  fi

  # 3) Keep CPU awake so Android doesn't kill the server
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true

  # 4) Setup inside distro (idempotent)
  local self
  self="$(readlink -f "$0")"
  cp "$self" "${rootfs}/root/dsh.sh"
  proot-distro login "$DISTRO" -- bash /root/dsh.sh --inside-setup

  # 5) Start server (if not already running)
  if server_alive; then
    log "Server already running (pid $(cat "$HOST_PID"))."
  else
    : > "$HOST_LOG"
    nohup proot-distro login "$DISTRO" -- bash /root/dsh.sh --inside-serve \
      >"$HOST_LOG" 2>&1 &
    echo $! > "$HOST_PID"
  fi

  # 6) Wait for the URL to show up in the log
  log "Waiting for the server (first run downloads the package, can take a while)..."
  local url="" i=0
  while [ "$i" -lt "$WAIT_SECS" ]; do
    url="$(find_url)"
    [ -n "$url" ] && break
    if ! server_alive; then
      warn "Server exited early. Last log lines:"
      tail -n 25 "$HOST_LOG" >&2 || true
      exit 1
    fi
    sleep 1
    i=$((i + 1))
  done

  if [ -z "$url" ]; then
    warn "Server is running but no URL was found in the log within ${WAIT_SECS}s."
    warn "Check: tail -n 40 $HOST_LOG"
    exit 1
  fi

  log "Ready: $url"
  open_url "$url"
  log "Stop with: bash $(basename "$self") stop"
}

# ----------------------------------------------------------------------------
case "${1:-}" in
  --inside-setup) inner_setup ;;
  --inside-serve) inner_serve ;;
  stop)           host_stop ;;
  logs)           tail -n 60 "$HOST_LOG" ;;
  ""|start)       host_main ;;
  *)              die "Unknown option: $1" ;;
esac
