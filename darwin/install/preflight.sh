#!/usr/bin/env/zsh

set -euo pipefail

### ── helpers ────────────────────────────────────────────────────────────────
msg()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || return 1; }

maximize() { 
  screen_info=$(swift -e 'import AppKit; let f=NSScreen.main!.visibleFrame; print(Int(f.origin.x), Int(f.origin.y), Int(f.size.width), Int(f.size.height))')
  X=$(echo $screen_info | cut -d' ' -f1)
  Y=$(echo $screen_info | cut -d' ' -f2)  
  W=$(echo $screen_info | cut -d' ' -f3)
  H=$(echo $screen_info | cut -d' ' -f4)
  osascript -e "tell application \"Terminal\" to set bounds of front window to {0, 0, $(($X+$W)), $(($Y+$H))}"
}

maximize

drawlsp() { /opt/homebrew/bin/chafa --scale 0.66 $DOTFILES_ROOT/misc/lsp.png }

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
}

# Resolve repo root relative to this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
DOTFILES_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

### ── Install Xcode Command Line Tools ───────────────────────────────────────
msg "Checking for Xcode Command Line Tools…"
if ! xcode-select -p >/dev/null 2>&1; then
  msg "Installing Xcode Command Line Tools (you may see a GUI popup)…"
  xcode-select --install || true
  # Wait until installed
  until xcode-select -p >/dev/null 2>&1; do
    sleep 20
  done
  msg "Xcode Command Line Tools installed."
else
  msg "Xcode Command Line Tools already installed."
fi

### ── Homebrew (for gh & gum) ────────────────────────────────────────────────
if command -v brew >/dev/null 2>&1; then
  msg "Homebrew already installed (prefix: $(brew --prefix)). Skipping install."
  # Make sure this shell has brew’s env (idempotent)
  eval "$($(command -v /opt/homebrew/bin/brew) shellenv)"
else
  msg "Installing Homebrew…"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add brew to PATH for this script run
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"    # Apple Silicon default
  elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"       # Intel default
  else
    # Fallback: search common prefixes
    BREW_BIN="$(/usr/bin/find /opt/homebrew /usr/local -type f -name brew 2>/dev/null | head -n1)"
    if [[ -n "$BREW_BIN" ]]; then
      eval "$("$BREW_BIN" shellenv)"
    else
      echo "⚠️  Homebrew install finished but 'brew' not found on PATH." >&2
      echo "    Try opening a new shell or source brew’s shellenv manually." >&2
      exit 1
    fi
  fi
fi

### ── Install gum & gh ───────────────────────────────────────────────────────
msg "Ensuring gum and gh + some other fun goodies are installed…"
brew install charmbracelet/tap/gum gh lolcat figlet chafa >/dev/null

### ── Interactive prompts with gum ───────────────────────────────────────────
msg "Git config identity info…"

USER_NAME="$(gum input --placeholder 'Full Name (e.g., Shawn T. Schwartz)' --prompt '> Name: ' )"
USER_EMAIL="$(gum input --placeholder 'Email (e.g., you@example.com)' --prompt '> Email: ' )"
USER_SITE="$(gum input --placeholder 'Website (e.g., https://example.com)' --prompt '> Website: ' )"

gum confirm "Use these?  Name: $USER_NAME  Email: $USER_EMAIL  Site:  $USER_SITE" || {
  echo "Cancelled."; exit 1;
}

### ────────────────────────────────────────────────────────────────────────────
### Find stow packages: immediate subdirs, excluding ignored names (portable)
### ────────────────────────────────────────────────────────────────────────────

# Ensure stow
command -v stow >/dev/null 2>&1 || brew install stow

find . -name .DS_Store -type f -print -delete

# Resolve script dir
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  __SCRIPT_FILE="${BASH_SOURCE[0]}"
elif (unsetopt 2>/dev/null | grep -q '^shwordsplit$') 2>/dev/null; then
  # crude zsh detection path; use %N
  __SCRIPT_FILE="${(%):-%N}"
else
  __SCRIPT_FILE="$0"
fi
__SCRIPT_DIR="$(cd -- "$(dirname -- "$__SCRIPT_FILE")" && pwd)"

: "${DARWIN_DIR:=$(cd "$__SCRIPT_DIR/.." && pwd)}"
: "${TARGET:=$HOME}"

_ignore="install packages icns macos"
PACKAGES=()
for d in "$DARWIN_DIR"/*/; do
  [ -d "$d" ] || continue
  bname="$(basename "$d")"
  skip=false
  for ig in $_ignore; do
    if [ "$bname" = "$ig" ]; then skip=true; break; fi
  done
  $skip && continue
  PACKAGES+=("$bname")
done

# Sort the list (portable)
if [ "${#PACKAGES[@]}" -gt 0 ]; then
  IFS=$'\n' PACKAGES=($(printf '%s\n' "${PACKAGES[@]}" | sort)) ; unset IFS
  echo "Stowing: ${PACKAGES[*]}"
  stow -d "$DARWIN_DIR" -t "$TARGET" -Rv "${PACKAGES[@]}" --ignore='(^|/)\.DS_Store$'
else
  echo "Stowing: (none found)"
fi

if [ -x "$DARWIN_DIR/install/macos/set-defaults.sh" ]; then
  "$DARWIN_DIR/install/macos/set-defaults.sh"
fi

echo "✅ Done."
echo "Unstow a package:  stow -d \"$DARWIN_DIR\" -t \"$TARGET\" -D <pkg>"

### ── Persist env vars to Zsh ────────────────────────────────────────────────
ZSHRC="${HOME}/.zshrc"
BLOCK_BEGIN="# >>> dotfiles bootstrap (env) >>>"
BLOCK_END="# <<< dotfiles bootstrap (env) <<<"

msg "Writing env vars to ${ZSHRC}…"
mkdir -p "$(dirname "$ZSHRC")"
# Remove old block if present
if grep -q "$BLOCK_BEGIN" "$ZSHRC" 2>/dev/null; then
  perl -0777 -pe "s/${BLOCK_BEGIN}.*?${BLOCK_END}\n?//s" -i "$ZSHRC"
fi
cat >> "$ZSHRC" <<EOF
${BLOCK_BEGIN}
# Exported by dotfiles installer
export USER_NAME="${USER_NAME}"
export USER_EMAIL="${USER_EMAIL}"
export USER_SITE="${USER_SITE}"
${BLOCK_END}
EOF

# Apply to current shell session for immediate use
export USER_NAME USER_EMAIL USER_SITE

### ── Configure Git identity (user.name / user.email) ────────────────────────
msg "Configuring Git identity…"
rm -f ~/.gitconfig
cp $DOTFILES_ROOT/base/.gitconfig ~/.gitconfig
git config --global user.name  "$USER_NAME"
git config --global user.email "$USER_EMAIL"

### ── SSH keys (auth & signing) ──────────────────────────────────────────────
SSH_DIR="${HOME}/.ssh"
AUTH_KEY="${SSH_DIR}/id_ed25519"
SIGN_KEY="${SSH_DIR}/id_ed25519_signing"

msg "Ensuring SSH directory exists…"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "${AUTH_KEY}" ]]; then
  msg "Generating SSH auth key (ed25519)…"
  ssh-keygen -t ed25519 -N "" -f "${AUTH_KEY}" -C "${USER_EMAIL}"
fi

if [[ ! -f "${SIGN_KEY}" ]]; then
  msg "Generating SSH signing key (ed25519)…"
  ssh-keygen -t ed25519 -N "" -f "${SIGN_KEY}" -C "${USER_EMAIL} (signing)"
fi

# macOS keychain integration
msg "Adding keys to ssh-agent (with Keychain)…"
eval "$(ssh-agent -s)" >/dev/null
ssh-add --apple-use-keychain "${AUTH_KEY}" >/dev/null
ssh-add --apple-use-keychain "${SIGN_KEY}" >/dev/null

# SSH config
SSH_CONFIG="${SSH_DIR}/config"
if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
  msg "Updating ${SSH_CONFIG}…"
  {
    echo "Host github.com"
    echo "  AddKeysToAgent yes"
    echo "  UseKeychain yes"
    echo "  IdentityFile ${AUTH_KEY}"
    echo "  IdentityFile ${SIGN_KEY}"
  } >> "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
fi

### ── gh auth login (SSH protocol) ───────────────────────────────────────────
msg "Authenticating with GitHub CLI in the browser..."

# Required scopes for SSH key management
NEED_SCOPES=("admin:public_key" "admin:ssh_signing_key")

# If a token is exported, gh will use it (and scopes may be wrong)
if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
  msg "⚠️  GH_TOKEN/GITHUB_TOKEN is set. This can cause 404/scope errors."
  msg "    Unset it for this step so gh can do OAuth with proper scopes."
  msg "    Example:  env -u GH_TOKEN -u GITHUB_TOKEN <your-install-cmd>"
fi

# Ensure we are logged in to the correct host
if ! gh auth status -h github.com >/dev/null 2>&1; then
  msg "Logging into GitHub with required scopes…"
  gh auth login -h github.com --git-protocol ssh --web -s "$(IFS=,; echo "${NEED_SCOPES[*]}")"
else
  msg "Refreshing GitHub scopes…"
  gh auth refresh -h github.com $(printf ' -s %q' "${NEED_SCOPES[@]}")
fi

# Verify API access
if ! gh api -H "Accept: application/vnd.github+json" /user >/dev/null 2>&1; then
  msg "⚠️  GitHub API access failed. You may need to refresh scopes:"
  msg "    gh auth refresh -h github.com -s ${NEED_SCOPES[*]}"
fi

### ── Upload keys to GitHub (auth + signing) ─────────────────────────────────
HOSTNAME_LABEL="$(scutil --computer-name 2>/dev/null || echo "macOS")"

PUB_KEY_CONTENT="$(cat "${AUTH_KEY}.pub")"
KEY_TITLE="${HOSTNAME_LABEL} auth key $(date +%Y-%m-%d)"

# Add (or skip if already uploaded) the auth key
msg "Uploading SSH AUTH key to GitHub if not already present..."
if gh api /user/keys?per_page=100 | grep -qF "$(echo "$PUB_KEY_CONTENT" | cut -d' ' -f2)"; then
  msg "SSH auth key already present on GitHub. Skipping upload."
else
  gh api -X POST /user/keys \
    -H "Accept: application/vnd.github+json" \
    -f title="$KEY_TITLE" \
    -f key="$PUB_KEY_CONTENT"
  msg "SSH auth key uploaded successfully."
fi

# Add the signing key
msg "Uploading SSH SIGNING key to GitHub if not already present..."
SIGN_PUB_KEY_CONTENT="$(cat "${SIGN_KEY}.pub")"
SIGN_KEY_TITLE="${HOSTNAME_LABEL} signing key $(date +%Y-%m-%d)"

if gh api /user/ssh_signing_keys?per_page=100 | grep -qF "$(echo "$SIGN_PUB_KEY_CONTENT" | cut -d' ' -f2)"; then
  msg "SSH signing key already present on GitHub. Skipping upload."
else
  gh api -X POST /user/ssh_signing_keys \
    -H "Accept: application/vnd.github+json" \
    -f title="$SIGN_KEY_TITLE" \
    -f key="$SIGN_PUB_KEY_CONTENT"
  msg "SSH signing key uploaded successfully."
fi

### ── Enable SSH commit signing in Git ───────────────────────────────────────
msg "Enabling SSH commit signing…"
git config --global gpg.format ssh
git config --global user.signingkey "${SIGN_KEY}.pub"
git config --global commit.gpgsign true

### ── Success & quick tests ──────────────────────────────────────────────────
msg "Done! Quick checks:"
echo "  • Env vars now in ~/.zshrc (reload with:  source ~/.zshrc )"
echo "  • Test GitHub SSH:     ssh -T git@github.com"
echo "  • Test signing (optional in a repo):"
echo "      git commit --allow-empty -m 'test: signed commit'"
echo "      git log --show-signature -1"


