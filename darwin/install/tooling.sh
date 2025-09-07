#!/usr/bin/env bash
set -euo pipefail

msg()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || return 1; }

### ────────────────────────────────────────────────────────────────────────────
### Rosetta 2 (for Apple Silicon Macs)
### ────────────────────────────────────────────────────────────────────────────
if [[ "$(uname -m)" == "arm64" ]]; then
  msg "Checking for Rosetta 2…"
  if /usr/bin/pgrep oahd >/dev/null 2>&1; then
    msg "Rosetta 2 already installed."
  else
    msg "Installing Rosetta 2 (requires admin password)…"
    softwareupdate --install-rosetta --agree-to-license
  fi
else
  msg "Not an Apple Silicon Mac — Rosetta not required."
fi

### ────────────────────────────────────────────────────────────────────────────
### Homebrew desired behavior (autoUpdate/upgrade/cleanup)
### ────────────────────────────────────────────────────────────────────────────
# Make brew available in this shell
if [[ -d /opt/homebrew/bin ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -d /usr/local/bin ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

msg "Updating Homebrew and adding taps…"
brew update
brew tap charmbracelet/tap >/dev/null || true
brew tap nikitabobko/tap >/dev/null || true
brew tap FelixKratz/formulae >/dev/null || true

msg "Configuring Homebrew autoupdate + cleanup (runs in background)…"
brew install aom glib
brew autoupdate stop >/dev/null 2>&1 || true
brew autoupdate start --upgrade --cleanup --immediate >/dev/null 2>&1 || true
brew cleanup -s >/dev/null || true

### ────────────────────────────────────────────────────────────────────────────
### Brew formulae
### ────────────────────────────────────────────────────────────────────────────
FORMULAE=(
  jupyterlab macos-trash dockutil bat deno docker eza aria2
  fastfetch fd feh ffmpeg freetype fzf gcc git git-lfs htop imagemagick
  jq lazygit lazydocker neovim pandoc rclone ripgrep shfmt starship stow 
  tlrc tree tree-sitter wget yarn zoxide mise qpdf sketchybar tailscale xcodes
  zsh-autosuggestions zsh-syntax-highlighting zsh-completions
)

msg "Installing brew formulae…"
for f in "${FORMULAE[@]}"; do
  if brew list --formula --cask | grep -q "^${f}\$"; then
    echo "• $f (already installed)"
  else
    echo "• $f"
    if ! brew install "$f" >/dev/null 2>&1; then
      echo "  ⚠️  Could not install $f (skipping)"; continue;
    fi
  fi
done

mkdir -p ~/Developer/Xcode
xcodes list                   # see available versions
xcodes install 16.4           # example; will prompt for Apple ID + 2FA
sudo xcodes select 16.4       # set active developer dir

### ────────────────────────────────────────────────────────────────────────────
### mise setup: languages & defaults
### ────────────────────────────────────────────────────────────────────────────
if need mise; then
  msg "Configuring mise and language plugins…"

  MISE_DIR="${HOME}/.config/mise"
  mkdir -p "$MISE_DIR"

  mise plugin add nodejs    >/dev/null 2>&1 || true
  mise plugin add python    >/dev/null 2>&1 || true
  mise plugin add ruby      >/dev/null 2>&1 || true
  mise plugin add rust      >/dev/null 2>&1 || true
  mise plugin add java      >/dev/null 2>&1 || true
  mise plugin add lua       >/dev/null 2>&1 || true
  mise plugin add r         >/dev/null 2>&1 || true  # community plugin for R

  mise use -g nodejs@lts    >/dev/null 2>&1 || true
  mise use -g python@latest >/dev/null 2>&1 || true
  mise use -g ruby@latest   >/dev/null 2>&1 || true
  mise use -g rust@latest   >/dev/null 2>&1 || true
  mise use -g java@temurin-21 >/dev/null 2>&1 || true
  mise use -g lua@latest    >/dev/null 2>&1 || true
  mise use -g r@latest      >/dev/null 2>&1 || true

  mise install -y || true

  # Ruby on Rails after Ruby exists
  if need ruby && ! gem list -i rails >/dev/null 2>&1; then
    msg "Installing Rails (gem)…"
    gem install rails --no-document || true
  fi
else
  msg "mise not installed; skipping language setup."
fi

### ────────────────────────────────────────────────────────────────────────────
### Brew casks (GUI apps/nerd fonts)
### ────────────────────────────────────────────────────────────────────────────
CASKS=(
  1password beeper claude claude-code docker font-sketchybar-app-font google-chrome
  notion raycast rstudio sf-symbols via gimp github inkscape positron skim google-drive
  microsoft-word microsoft-powerpoint microsoft-excel cursor chatgpt localsend typora
  shortcat whatsapp messenger basecamp figma slack zoom ghostty nikitabobko/tap/aerospace
)

msg "Installing brew casks…"
for c in "${CASKS[@]}"; do
  if brew list --cask | grep -q "^${c##*/}\$"; then
    echo "• $c (already installed)"
  else
    echo "• $c"
    brew install --cask "$c" || echo "  ⚠️  Could not install $c (skipping)"
  fi
done

# ==> Caveats
# Claude Code's auto-updater installs updates to `~/.local/bin/claude` and
# not to Homebrew's location. It is recommended to disable the auto-updater
# with either `DISABLE_AUTOUPDATER=1` or
# `claude config set -g autoUpdates false` and use
# `brew upgrade --cask claude-code`.
claude config set -g autoUpdates false
brew upgrade --cask claude-code

brew search '/font-.*-nerd-font/' | awk '{ print $1 }' | xargs -I{} brew install --cask {} || true

### ────────────────────────────────────────────────────────────────────────────
### Neovim bootstrap (LazyVim + custom overlay)
### ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

msg() { printf "\033[1;32m==>\033[0m %s\n" "$*"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DOTFILES_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Stow package + repo paths
STOW_DIR="$DOTFILES_ROOT/darwin"
PKG="nvim"
PKG_DIR="$STOW_DIR/$PKG/.config/nvim"     # <- this mirrors ~/.config/nvim
TARGET_DIR="${HOME}/.config/nvim"         # <- will be a symlink after stow

# Ensure package directory exists
mkdir -p "$PKG_DIR"

# If package dir is empty (first time), seed it with LazyVim starter
if [[ -z "$(ls -A "$PKG_DIR" 2>/dev/null || true)" ]]; then
  msg "Bootstrapping Neovim package with LazyVim starter…"
  tmpdir="$(mktemp -d)"
  git clone --depth=1 https://github.com/LazyVim/starter "$tmpdir/starter"
  # move contents into the repo package dir
  rsync -a --exclude=".git" "$tmpdir/starter/" "$PKG_DIR/"
  rm -rf "$tmpdir"
else
  msg "Neovim package already has content (skipping clone)."
fi

OPTIONS_LUA="$PKG_DIR/lua/config/options.lua"
mkdir -p "$(dirname "$OPTIONS_LUA")"
if ! grep -q 'vim\.opt\.relativenumber\s*=\s*true' "${OPTIONS_LUA}" 2>/dev/null; then
  echo 'vim.opt.relativenumber = true' >> "${OPTIONS_LUA}"
fi

# Stow the package into $HOME
msg "Stowing Neovim package → ${TARGET_DIR}"
if ! command -v stow &>/dev/null; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    command -v brew &>/dev/null || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install stow
  else
    echo "Please install GNU stow."; exit 1
  fi
fi

# Restow will replace existing correct links if needed
stow -d "$STOW_DIR" -t "$HOME" -Rv "$PKG"

if [[ -L "$TARGET_DIR" ]]; then
  msg "✅ Neovim is now managed by Stow at ${TARGET_DIR} → ${PKG_DIR}"
else
  msg "⚠️ ${TARGET_DIR} is not a symlink. If you had a preexisting folder, consider:"
  echo "   stow -d \"$STOW_DIR\" -t \"$HOME\" --adopt -Rv $PKG"
fi

### ────────────────────────────────────────────────────────────────────────────
### Final homebrew touches
### ────────────────────────────────────────────────────────────────────────────
msg "Final brew maintenance…"
brew upgrade >/dev/null || true
brew cleanup -s >/dev/null || true

msg "All set ✅"
echo "• Homebrew autoupdate is running in the background (upgrade + cleanup)."
echo "• To manage languages, see:  ~/.config/mise  and  mise --help"