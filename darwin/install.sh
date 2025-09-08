#!/usr/bin/env bash
set -euo pipefail

# --- robust script dir (works with set -u, and if BASH_SOURCE is missing) ---
SCRIPT_FILE="${BASH_SOURCE[0]-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_FILE")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

# helpers (if not already defined)
msg()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

# Ask for admin password up-front, then keep sudo alive while the script runs
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  sudo -p "[admin password for setup] " -v || true
  while true; do
    sudo -n true || true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done 2>/dev/null &
fi

# --- run the darwin-local install pieces, anchored to SCRIPT_DIR -------------
bash "$SCRIPT_DIR/install/preflight.sh"

drawlsp
lspquote 1


bash "$SCRIPT_DIR/install/tooling.sh"

drawlsp
lspquote 2


bash "$SCRIPT_DIR/install/webapps.sh"

drawlsp
lspquote 3


bash "$SCRIPT_DIR/install/macos/set-defaults.sh"

drawlsp
lspquote 4


bash "$SCRIPT_DIR/install/activate.sh"

drawlsp
lspquote 5


bash "$SCRIPT_DIR/install/services.sh"

drawlsp
lspquote 6


bash "$SCRIPT_DIR/install/sync.sh"

drawlsp
lspquote 7


bash "$SCRIPT_DIR/install/reboot.sh"

