bash -c "$(cat <<'INSTALL_DSH'
#!/usr/bin/env bash
set -Eeuo pipefail

C_RESET='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'

info()  { printf "${C_CYAN}[INFO]${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"; }
fail()  { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; exit 1; }

[ -n "${TERMUX_VERSION:-}" ] || fail "Run this inside Termux. Use the F-Droid build."
command -v pkg >/dev/null 2>&1 || fail "pkg not found. Use Termux from F-Droid."

SDK="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
if [ "${SDK:-0}" -lt 30 ]; then
  warn "Android API ${SDK:-0} detected. Android 11 / API 30 or newer is recommended."
fi

info "Updating Termux packages..."
pkg update -y
pkg upgrade -y

info "Installing system dependencies..."
pkg install -y nodejs-lts git curl wget build-essential clang cmake ninja python pkg-config binutils libvips libandroid-spawn proot which termux-tools || {
  warn "nodejs-lts was not available. Falling back to nodejs..."
  pkg install -y nodejs git curl wget build-essential clang cmake ninja python pkg-config binutils libvips libandroid-spawn proot which termux-tools
}

command -v node >/dev/null 2>&1 || fail "Node.js installation failed."
command -v npm  >/dev/null 2>&1 || fail "npm installation failed."

info "Configuring npm..."
npm config set fund false
npm config set audit false
npm config set ignore-scripts false

if ! curl -sSf --max-time 10 https://registry.npmjs.org/ >/dev/null 2>&1; then
  warn "npm registry is slow or unreachable. Switching to npmmirror."
  npm config set registry https://registry.npmmirror.com
fi

ARCH="$(uname -m)"
TARGET=""
case "$ARCH" in
  aarch64) TARGET="aarch64-linux-android30" ;;
  armv7l|armv8l) TARGET="armv7a-linux-androideabi30" ;;
  x86_64) TARGET="x86_64-linux-android30" ;;
  i686) TARGET="i686-linux-android30" ;;
  *) warn "Unknown architecture: $ARCH. Continuing without custom compiler target." ;;
esac

if [ -n "$TARGET" ]; then
  export CFLAGS="-target $TARGET ${CFLAGS:-}"
  export CXXFLAGS="-target $TARGET ${CXXFLAGS:-}"
fi
export SHARP_FORCE_GLOBAL_LIBVIPS=1
export GYP_DEFINES="android_ndk_path="

patch_node_gyp() {
  local gypdir
  gypdir="$(npm root -g)/npm/node_modules/node-gyp"
  if [ -f "$gypdir/lib/create-config-gypi.js" ]; then
    if ! grep -q 'process.platform === "android" ? "linux"' "$gypdir/lib/create-config-gypi.js"; then
      cp "$gypdir/lib/create-config-gypi.js" "$gypdir/lib/create-config-gypi.js.bak.$$" 2>/dev/null || true
      sed -i 's/OS: process.platform/OS: process.platform === "android" ? "linux" : process.platform/' \
        "$gypdir/lib/create-config-gypi.js" 2>/dev/null || true
    fi
  fi
}
patch_node_gyp

install_dsh() {
  npm install -g @deepseek-ai/dsh --foreground-scripts
}

info "Installing @deepseek-ai/dsh..."
if ! install_dsh; then
  warn "First install attempt failed. Applying node-gyp compatibility patch and retrying..."
  patch_node_gyp
  install_dsh || fail "dsh installation failed after retry."
fi
ok "dsh installed."

DSH_ROOT="$(npm root -g)/@deepseek-ai/dsh"
[ -d "$DSH_ROOT" ] || fail "Cannot find dsh install directory: $DSH_ROOT"

info "Patching dsh launcher for Termux..."
DSH_BIN="$(command -v dsh 2>/dev/null || true)"
if [ -n "$DSH_BIN" ]; then
  REAL_BIN="$(readlink -f "$DSH_BIN" 2>/dev/null || echo "$DSH_BIN")"
  if [ -f "$REAL_BIN" ] && head -n1 "$REAL_BIN" | grep -q '^#!'; then
    if ! head -n1 "$REAL_BIN" | grep -q -- '--expose-internals'; then
      cp "$REAL_BIN" "$REAL_BIN.bak.$$" 2>/dev/null || true
      sed -i '1s|^#!.*|#!/usr/bin/env -S node --expose-internals|' "$REAL_BIN" 2>/dev/null || true
    fi
  fi
fi

info "Applying best-effort hardlink compatibility patch..."
find "$DSH_ROOT" -type f \( -name '*.js' -o -name '*.cjs' -o -name '*.mjs' \) -print0 2>/dev/null | while IFS= read -r -d '' f; do
  if grep -qE '\b(fs\.)?link\(' "$f" 2>/dev/null; then
    cp "$f" "$f.bak.$$" 2>/dev/null || true
    sed -i -E 's/\bfs\.link\(/fs.rename(/g; s/([^.[:alnum:]_])link\(/\1rename(/g' "$f" 2>/dev/null || true
  fi
done || true

if ! NODE_PATH="$(npm root -g)" node -e "require('sharp')" >/dev/null 2>&1; then
  warn "sharp native binding check failed. Trying WASM fallback..."
  npm install -g @img/sharp-wasm32 >/dev/null 2>&1 || warn "WASM fallback install failed. Continuing."
fi

dsh --version >/dev/null 2>&1 || fail "dsh is installed but not runnable. Re-run this installer or check logs."
ok "dsh version: $(dsh --version 2>/dev/null || echo unknown)"

command -v termux-open-url >/dev/null 2>&1 || pkg install -y termux-tools >/dev/null 2>&1 || true

info "Starting DeepSeek Harness web UI..."
info "Opening http://127.0.0.1:3080 in your browser..."
( sleep 3; termux-open-url http://127.0.0.1:3080 >/dev/null 2>&1 || true ) &
info "Press Ctrl+C to stop."
exec dsh web
INSTALL_DSH
)"
