#!/usr/bin/env bash
set -euo pipefail

# ── small helpers ────────────────────────────────────────────────────────────
msg()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# ── flags ────────────────────────────────────────────────────────────────────
YES=0         # -y to auto-confirm
TARGET_OS=""  # --darwin or --linux (future-proof)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1; shift ;;
    --darwin|--mac|--macos) TARGET_OS="Darwin"; shift ;;
    --linux) TARGET_OS="Linux"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -y, --yes        Run non-interactively (assume "yes")
      --darwin     Force macOS path
      --linux      Force Linux path (if/when you add it)
  -h, --help       Show this help
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── detect OS ────────────────────────────────────────────────────────────────
UNAME="${TARGET_OS:-$(uname -s)}"

# ── confirmation (gum if present; else read -p) ──────────────────────────────
confirm() {
  local prompt="$1"
  if (( YES )); then return 0; fi
  if need gum; then
    gum confirm --default=true "$prompt"
  else
    read -r -p "$prompt [Y/n] " ans
    [[ -z "${ans:-}" || "${ans:-}" =~ ^[Yy]$ ]]
  fi
}

# ── sudo keepalive (only when needed by child scripts) ───────────────────────
ensure_sudo_keepalive() {
  # Call this *before* invoking scripts that need sudo.
  if [[ $EUID -ne 0 ]]; then
    sudo -p "[admin password for setup] " -v
    # keep sudo alive while the parent script runs
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
  fi
}

# ── runners ──────────────────────────────────────────────────────────────────
run_darwin() {
  local DARWIN_MAIN="$REPO_ROOT/darwin/install.sh"
  [[ -f "$DARWIN_MAIN" ]] || { echo "Missing: $DARWIN_MAIN" >&2; exit 1; }

  msg "macOS (darwin) setup selected."

  ensure_sudo_keepalive

  bash "$DARWIN_MAIN"
}

# run_linux() {
#   local LINUX_MAIN="$REPO_ROOT/linux/install.sh"
#   if [[ -f "$LINUX_MAIN" ]]; then
#     msg "Linux setup selected."
#     bash "$LINUX_MAIN"
#   } else
#     echo "Linux installer not found at $LINUX_MAIN" >&2
#     exit 1
#   fi
# }

# ── main ─────────────────────────────────────────────────────────────────────
case "$UNAME" in
  Darwin)
    if confirm "Run the macOS (darwin) setup now?"; then
      run_darwin
    else
      msg "Skipped macOS setup."
    fi
    ;;
  Linux)
    if confirm "Run the Linux setup now?"; then
      run_linux
    else
      msg "Skipped Linux setup."
    fi
    ;;
  *)
    echo "Unsupported OS: $UNAME" >&2
    exit 1
    ;;
esac

msg "All done."
