#!/usr/bin/env bash
set -euo pipefail

# --- robust script dir (works with set -u, and if BASH_SOURCE is missing) ---
SCRIPT_FILE="${BASH_SOURCE[0]-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_FILE")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

# helpers (if not already defined)
msg()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

drawlsp() { /opt/homebrew/bin/chafa --scale 0.66 "$DOTFILES_ROOT/misc/lsp.png"; sleep 2; }

# from https://adventuretime.fandom.com/wiki/Lumpy_Space_Princess/Quotes
lspquote() {
  local quotes=(
    "WHATEVERS 2009!"
    "I said, 'Lump off,' Mom!"
    "The guys who use the antidote up here are notorious for being... smooth posers."
    "Buuuuumps!"
    "Oh, my Glob. What the stuff are you doing?"
    "Well, if you want these lumps, you gotta put a ring on it. WHERE'S MY RING?"
    "MAH BEANS!"
  )

  local idx
  if [[ -n "$1" ]]; then
    # Clamp to valid range (1..N)
    if (( $1 >= 1 && $1 <= ${#quotes[@]} )); then
      idx=$(( $1 - 1 ))   # convert to 0-based
    else
      echo "⚠️ Invalid index. Pick between 1 and ${#quotes[@]}."
      return 1
    fi
  else
    idx=$(( RANDOM % ${#quotes[@]} ))
  fi

  echo "${quotes[$idx]}" | /opt/homebrew/bin/figlet | /opt/homebrew/bin/lolcat

  sleep 5
}

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

drawlsp
lspquote 7


bash "$SCRIPT_DIR/install/reboot.sh"

