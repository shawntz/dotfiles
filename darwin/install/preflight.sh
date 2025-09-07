#!/usr/bin/env bash
set -euo pipefail

### ── helpers ────────────────────────────────────────────────────────────────
msg()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || return 1; }

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
msg "Ensuring gum and gh are installed…"
brew install charmbracelet/tap/gum gh >/dev/null

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
msg "Authenticating gh with SSH (will open a browser)…"
# If already logged in, this will be a no-op
if ! gh auth status >/dev/null 2>&1; then
  gh auth login --hostname github.com --git-protocol ssh --web
fi

### ── Upload keys to GitHub (auth + signing) ─────────────────────────────────
HOSTNAME_LABEL="$(scutil --computer-name 2>/dev/null || echo "macOS")"

# Add (or skip if already uploaded) the auth key
msg "Uploading SSH AUTH key to GitHub (if not already present)…"
if ! gh ssh-key list | grep -q "$(cat "${AUTH_KEY}.pub" | awk '{print $2}')" ; then
  gh ssh-key add "${AUTH_KEY}.pub" -t "${HOSTNAME_LABEL} auth key"
fi

gh auth refresh -h github.com -s admin:ssh_signing_key

# Add (or skip) the signing key
msg "Uploading SSH SIGNING key to GitHub (if not already present)…"
if gh ssh-key add --help 2>&1 | grep -q -- '--type'; then
  if ! gh ssh-key list --type signing 2>/dev/null | grep -q "$(cat "${SIGN_KEY}.pub" | awk '{print $2}')" ; then
    gh ssh-key add "${SIGN_KEY}.pub" --type signing -t "${HOSTNAME_LABEL} signing key"
  fi
else
  msg "Your gh version may not support '--type signing'. You can still add the signing key manually in GitHub Settings → SSH and GPG keys → New SSH key (type: Signing)."
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

