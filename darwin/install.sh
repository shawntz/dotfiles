#!/usr/bin/env bash
set -euo pipefail

msg()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || return 1; }

# Ask for admin password up-front, then keep sudo alive while the script runs
if [[ $EUID -ne 0 ]]; then
  sudo -p "[admin password for setup] " -v
  # Keep-alive: update existing `sudo` time stamp until script finishes
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done 2>/dev/null &
fi

./install/preflight.sh
./install/tooling.sh
./install/webapps.sh
./install/macos/set-defaults.sh
