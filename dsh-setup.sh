#!/usr/bin/env bash
# DeepSeek Harness (dsh) one-command installer.
# Termux/Android: boots a proot Debian/Ubuntu, installs Node 24, starts `dsh web` and opens the browser.
# Plain Linux (Debian/Ubuntu and glibc distros): installs Node 24 if missing and starts `dsh web`.
# Usage:
#   bash dsh-setup.sh            normal install + launch
#   bash dsh-setup.sh --check    diagnostics only, changes nothing
# Env overrides:
#   DSH_VERSION         pinned dsh version (default below)
#   DSH_DISTRO          proot distro: debian (default) or ubuntu
#   DEEPSEEK_API_KEY    forwarded into the distro when set
set -uo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.2-rc.1}"
NODE_TARBALL_VERSION="24.22.3"
LOG="${DSH_LOG:-/tmp/dsh-web.log}"

c()   { printf '\033[1;36m[dsh-setup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[dsh-setup] ERROR:\033[0m %s\n' "$*" >&2; }

is_termux() { [ -n "${TERMUX_VERSION:-}" ]; }

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v; v="$(node -v 2>/dev/null | tr -d 'v')"
  [ -n "$v" ] || return 1
  [ "$(printf '24.9.0\n%s\n' "$v" | sort -V | head -n1)" = "24.9.0" ]
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 || return 1
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y "$@" >/dev/null 2>&1
}

install_node_linux() {
  if node_ok; then c "Node $(node -v) already OK"; return 0; fi
  c "Installing Node.js 24 ..."
  apt_install curl ca-certificates xz-utils
  if command -v curl >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    if curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1 \
       && apt-get install -y nodejs >/dev/null 2>&1 && node_ok; then
      c "Node $(node -v) installed via NodeSource"
      return 0
    fi
  fi
  c "NodeSource unavailable, falling back to official tarball ..."
  local arch a dir
  case "$(uname -m)" in
    x86_64)         a=x64 ;;
    aarch64|arm64)  a=arm64 ;;
    *) err "unsupported architecture: $(uname -m)"; return 1 ;;
  esac
  dir="$HOME/.dsh-node"
  mkdir -p "$dir"
  command -v curl >/dev/null 2>&1 || { err "curl is missing and cannot be installed"; return 1; }
  curl -fsSL "https://nodejs.org/dist/v${NODE_TARBALL_VERSION}/node-v${NODE_TARBALL_VERSION}-linux-${a}.tar.xz" \
    -o /tmp/dsh-node.tar.xz || { err "Node download failed"; return 1; }
  if ! tar -xJf /tmp/dsh-node.tar.xz -C "$dir" --strip-components=1 2>/dev/null; then
    python3 - "$dir" <<'PY' || { err "Node extraction failed"; return 1; }
import sys, tarfile
t = tarfile.open('/tmp/dsh-node.tar.xz')
t.extractall(sys.argv[1], filter='data')
PY
    mv "$dir"/node-v${NODE_TARBALL_VERSION}-linux-${a}/* "$dir/" 2>/dev/null || true
  fi
  export PATH="$dir/bin:$PATH"
  node_ok || { err "Node installation failed"; return 1; }
  grep -qs "\.dsh-node/bin" "$HOME/.bashrc" 2>/dev/null \
    || echo 'export PATH="$HOME/.dsh-node/bin:$PATH"' >> "$HOME/.bashrc"
  c "Node $(node -v) installed (tarball, persisted in ~/.bashrc)"
}

open_browser() {
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$1" 2>/dev/null && return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 && return 0
  fi
  c "Open this URL in your browser: $1"
  return 0
}

start_server() {
  : > "$LOG"
  c "Starting dsh web (version $DSH_VERSION), first run downloads packages ..."
  npx -y "@deepseek-ai/dsh@${DSH_VERSION}" web >"$LOG" 2>&1 &
  local pid=$! url="" i
  trap 'kill "$pid" 2>/dev/null; exit 0' INT TERM
  for i in $(seq 1 180); do
    url="$(grep -oE 'http://127\.0\.0\.1:[0-9]+/\?token=[^[:space:]]+' "$LOG" 2>/dev/null | head -n1)"
    [ -n "$url" ] && break
    if ! kill -0 "$pid" 2>/dev/null; then
      err "server exited early; last log lines:"
      tail -n 20 "$LOG" >&2
      exit 1
    fi
    sleep 1
  done
  if [ -n "$url" ]; then
    c "Web UI is ready: $url"
    open_browser "$url"
  else
    err "could not detect the URL; check $LOG"
  fi
  wait "$pid"
}

inner_main() {
  c "guest environment: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  apt_install curl ca-certificates xz-utils procps
  install_node_linux || exit 1
  if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
    c "NOTE: DEEPSEEK_API_KEY is not set. The UI will boot, but to chat, run:"
    c "  proot-distro login ${DSH_DISTRO:-debian} --shared-tmp"
    c "  export DEEPSEEK_API_KEY=your_key && npx -y @deepseek-ai/dsh@${DSH_VERSION} web"
  fi
  start_server
}

termux_main() {
  local distro="${DSH_DISTRO:-debian}"
  c "Termux detected — preparing proot $distro (first run downloads ~50 MB) ..."
  command -v proot-distro >/dev/null 2>&1 || pkg install -y proot-distro
  proot-distro install "$distro" >/dev/null 2>&1 || true
  proot-distro login "$distro" -- /bin/true >/dev/null 2>&1 \
    || { err "could not install the $distro proot distro"; exit 1; }
  termux-wake-lock 2>/dev/null || true

  local inner="$PREFIX/tmp/dsh-inner.sh"
  {
    echo 'set -uo pipefail'
    echo "DSH_VERSION=\"${DSH_VERSION}\""
    echo "DSH_DISTRO=\"${distro}\""
    echo "LOG=\"${LOG}\""
    declare -f c err node_ok apt_install install_node_linux open_browser start_server inner_main
    echo 'inner_main'
  } > "$inner"

  local -a env_cmd=()
  [ -n "${DEEPSEEK_API_KEY:-}" ] && env_cmd=(/usr/bin/env "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY")

  proot-distro login "$distro" --shared-tmp -- "${env_cmd[@]}" /bin/bash /tmp/dsh-inner.sh \
    > "$PREFIX/tmp/dsh-inner.out" 2>&1 &
  local pid=$! url="" i
  trap 'kill "$pid" 2>/dev/null; exit 0' INT TERM
  c "Waiting for the server (progress: cat $PREFIX/tmp/dsh-inner.out) ..."
  for i in $(seq 1 240); do
    url="$(grep -oE 'http://127\.0\.0\.1:[0-9]+/\?token=[^[:space:]]+' "$PREFIX/tmp/dsh-web.log" 2>/dev/null | head -n1)"
    [ -n "$url" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 2
  done
  if [ -n "$url" ]; then
    c "Web UI is ready: $url"
    termux-open-url "$url" 2>/dev/null || c "Open this URL in your browser: $url"
  else
    err "URL not detected. Check: cat $PREFIX/tmp/dsh-inner.out $PREFIX/tmp/dsh-web.log"
  fi
  wait "$pid"
}

check_mode() {
  c "diagnostics"
  if is_termux; then c "environment   : Termux ${TERMUX_VERSION}"; else c "environment   : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"; fi
  c "architecture  : $(uname -m)"
  if node_ok; then c "node          : $(node -v) (OK)"; else c "node          : missing or < 24.9 (will be installed)"; fi
  if command -v proot-distro >/dev/null 2>&1; then c "proot-distro  : installed"; else c "proot-distro  : missing (will be installed on Termux)"; fi
  c "dsh version   : $DSH_VERSION"
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then c "api key       : set"; else c "api key       : NOT set (needed to chat)"; fi
}

main() {
  case "${1:-}" in
    --check) check_mode; return 0 ;;
    -h|--help)
      printf 'Usage: bash dsh-setup.sh [--check]\n'; return 0 ;;
  esac
  if is_termux; then
    termux_main
  else
    c "Native Linux detected (Alpine/musl is not supported; Debian/Ubuntu recommended)."
    apt_install curl ca-certificates xz-utils || true
    install_node_linux || exit 1
    start_server
  fi
}

if [ -z "${DSH_SETUP_NO_EXEC:-}" ]; then
  main "$@"
fi
