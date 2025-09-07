#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Fake Test Installer for dotfiles (no system changes)
# - Uses a sandbox HOME
# - Shims privileged / destructive commands
# ─────────────────────────────────────────────────────────────────────────────

REPO_GH="shawntz/dotfiles"
BRANCH="${BRANCH:-master}"
KEEP=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -b|--branch) BRANCH="${2:-master}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--keep] [-v] [--branch BRANCH]
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { printf "\033[1m➡ %s\033[0m\n" "$*"; }
say() { printf "   %s\n" "$*"; }

# 1) Sandbox
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-fake.XXXXXX")"
export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

# log file inside sandbox
LOGFILE="$SANDBOX/fake-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

log "Sandbox HOME: $HOME"
say  "Logfile      : $LOGFILE"

# 2) Shim bin for no-op system commands
SHIMBIN="$SANDBOX/shim-bin"
mkdir -p "$SHIMBIN"
PATH="$SHIMBIN:$PATH"
export PATH

shim() {
  local name="$1" body="$2"
  printf '%s\n' "#!/usr/bin/env bash" > "$SHIMBIN/$name"
  printf '%s\n' "set -euo pipefail" >> "$SHIMBIN/$name"
  printf '%s\n' "$body" >> "$SHIMBIN/$name"
  chmod +x "$SHIMBIN/$name"
}

# --- function overrides (survive PATH changes; bash prefers functions) -----
# Make VERBOSE visible for logs if you want
export VERBOSE="${VERBOSE:-0}"

sudo() {
  # log, then always succeed; never execute a subcommand
  if [[ "${VERBOSE}" -eq 1 ]]; then
    printf "[func:sudo] %q" sudo; for a in "$@"; do printf " %q" "$a"; done; printf "\n" >&2
  else
    printf "[func:sudo] %s\n" "$*" >&2
  fi
  # swallow common flags so callers don't error
  while (($#)); do
    case "$1" in
      -v|-n|-k|-E|-H|-S|-A|--) shift ;;
      -p|-u) shift 2 || true ;;
      *) break ;;
    esac
  done
  return 0
}
export -f sudo

gh() {
  if [[ "${VERBOSE}" -eq 1 ]]; then
    printf "[func:gh] %q" gh; for a in "$@"; do printf " %q" "$a"; done; printf "\n" >&2
  else
    printf "[func:gh] %s\n" "$*" >&2
  fi

  local sub="${1:-}"; shift || true
  case "$sub" in
    auth)
      local cmd="${1:-}"; shift || true
      case "$cmd" in
        status)
          cat <<'OUT'
github.com
  ✓ Logged in to github.com as fake-user (oauth_token)
  ✓ Git operations for github.com configured to use ssh protocol.
  ✓ Token: *******************
OUT
          return 0
          ;;
        login|logout|refresh|token|switch|setup-git|setup-ssh)
          return 0
          ;;
      esac
      return 0
      ;;
    pr)
      local cmd="${1:-}"; shift || true
      case "$cmd" in
        create)
          echo "https://github.com/fake-org/fake-repo/pull/123"
          return 0
          ;;
        view|status|list) return 0 ;;
      esac
      return 0
      ;;
    repo)
      local cmd="${1:-}"; shift || true
      case "$cmd" in
        view)
          # minimal JSON when asked
          if printf "%s " "$@" | grep -q -- "--json"; then
            echo '{"defaultBranchRef":{"name":"main"}}'
          fi
          return 0
          ;;
      esac
      return 0
      ;;
    config|"ssh-key") return 0 ;;
  esac
  return 0
}
export -f gh

emit_log='
if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  printf "[shim:%s] %q" "$(basename "$0")" "$0"; for a in "$@"; do printf " %q" "$a"; done; printf "\n" >&2
else
  printf "[shim:%s] %s\n" "$(basename "$0")" "$*" >&2
fi
'

# sudo: don’t elevate; just run subcommand (or succeed for -v/-n)
# VERBOSE is already exported in your script; keep using it
shim sudo '
# log
if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  printf "[shim:%s] %q" "$(basename "$0")" "$0"; for a in "$@"; do printf " %q" "$a"; done; printf "\n" >&2
else
  printf "[shim:%s] %s\n" "$(basename "$0")" "$*" >&2
fi

# In fake mode, never execute the subcommand. Just succeed.
# Swallow common flags (with or without args) so callers don’t choke.
# Handle: -v -n -k -E -H -S -A -p <prompt> -u <user> -- <cmd> …
while (($#)); do
  case "$1" in
    -v|-n|-k|-E|-H|-S|-A|--) shift ;;
    -p|-u) shift 2 || true ;;   # eat flag + its arg if present
    *) break ;;                 # stop at first non-flag; ignore the rest
  esac
done
exit 0
'

# defaults / softwareupdate / xcode-select / killall / scutil / launchctl / spctl
for cmd in defaults softwareupdate xcode-select killall scutil launchctl spctl pmset; do
  shim "$cmd" "$emit_log"$'\n''exit 0'
done

# system utilities that may write: chflags chown chmod ditto plutil
for cmd in chflags chown chmod ditto plutil csrutil; do
  shim "$cmd" "$emit_log"$'\n''exit 0'
done

# GUI / app helpers that we don’t want to mutate real system
# Replace the previous generic gh shim with this:
shim gh '
# verbose log (optional)
if [[ "${VERBOSE:-0}" -eq 1 ]]; then
  printf "[shim:%s] %q" "$(basename "$0")" "$0"; for a in "$@"; do printf " %q" "$a"; done; printf "\n" >&2
else
  printf "[shim:%s] %s\n" "$(basename "$0")" "$*" >&2
fi

sub="${1:-}"; shift || true
case "$sub" in
  auth)
    cmd="${1:-}"; shift || true
    case "$cmd" in
      status)
        # Imitate gh’s output & exit code for "logged in"
        cat <<EOF
github.com
  ✓ Logged in to github.com as fake-user (oauth_token)
  ✓ Git operations for github.com configured to use ssh protocol.
  ✓ Token: *******************
EOF
        exit 0
        ;;
      login|logout|refresh|token|switch)
        # Always succeed
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  pr)
    cmd="${1:-}"; shift || true
    case "$cmd" in
      create)
        # Print a plausible PR URL to stdout so scripts can capture it
        echo "https://github.com/fake-org/fake-repo/pull/123"
        exit 0
        ;;
      view|status|list)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  repo)
    cmd="${1:-}"; shift || true
    case "$cmd" in
      view)
        # If scripts ask for JSON, give them something minimal but valid
        if printf "%s " "$@" | grep -q -- "--json"; then
          echo '\''{"defaultBranchRef":{"name":"main"}}'\''
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  config)
    # e.g., gh config set git_protocol ssh
    exit 0
    ;;
  "ssh-key")
    # e.g., gh ssh-key add …
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

for cmd in dockutil mas xcodes nativefier gum osascript; do
  shim "$cmd" "$emit_log"$'\n''# mimic success with benign outputs where helpful
case "$(basename "$0")" in
  brew|mas|xcodes|nativefier|gum) : ;;
esac
exit 0'
done

# Homebrew shim: pretend installed; provide shellenv; succeed on installs
shim brew "
$emit_log
case \"\${1:-}\" in
  shellenv)
    # Minimal plausible env so child scripts proceed
    cat <<'ENV'
HOMEBREW_PREFIX=/opt/homebrew
HOMEBREW_CELLAR=/opt/homebrew/Cellar
HOMEBREW_REPOSITORY=/opt/homebrew
PATH=\"/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH\"
export HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY PATH
ENV
    ;;
  --prefix) echo /opt/homebrew ;;
  list) exit 0 ;;
  install|tap|update|upgrade|cleanup|bundle) exit 0 ;;
  *) exit 0 ;;
esac
"

# 3) Ensure real stow & git exist
command -v /opt/homebrew/bin/stow >/dev/null 2>&1 || { echo "Please install GNU stow (brew install stow)"; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "Please install git"; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "Please install rsync"; exit 1; }

# 4) Materialize repo (use existing cwd if inside it, else clone to sandbox)
if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
   git -C . remote -v | grep -q "$REPO_GH"; then
  REPO_DIR="$(pwd)"
  say "Using existing repo: $REPO_DIR"
else
  REPO_DIR="$SANDBOX/repo"
  log "Cloning $REPO_GH@$BRANCH → $REPO_DIR"
  git clone --depth=1 -b "$BRANCH" "https://github.com/${REPO_GH}.git" "$REPO_DIR"
fi

cd "$REPO_DIR"

# 5) Make sure root install script exists; if not, fall back to darwin
ROOT_INSTALL="./install.sh"
DARWIN_INSTALL="./darwin/install.sh"
if [[ -f "$ROOT_INSTALL" ]]; then
  log "Running repo root installer (fake test)…"
  # Avoid interactive prompts
  VERBOSE="$VERBOSE" bash "$ROOT_INSTALL" -y || true
elif [[ -f "$DARWIN_INSTALL" ]]; then
  log "Running darwin installer (fake test)…"
  VERBOSE="$VERBOSE" bash "$DARWIN_INSTALL" || true
else
  echo "No installer found at root or darwin paths." >&2
  exit 1
fi

log "Fake test complete."
say "Sandbox: $SANDBOX"
if [[ "$KEEP" -eq 0 ]]; then
  say "Cleaning up sandbox…"
  rm -rf "$SANDBOX"
  say "Done."
else
  say "Keeping sandbox for inspection (use --keep to keep)."
fi
