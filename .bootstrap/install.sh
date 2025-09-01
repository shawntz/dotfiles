#!/usr/bin/env bash
set -euo pipefail

# --- config ---
REMOTE_URL="${REMOTE_URL:-git@github.com:shawntz/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
SHIM_PATH="${SHIM_PATH:-$HOME/.local/bin/config}"
MAKEFILE_PATH="${MAKEFILE_PATH:-$HOME/.bootstrap/Makefile}"
BACKUP_DIR="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"

echo "==> installing 'config' shim to $SHIM_PATH"
mkdir -p "$(dirname "$SHIM_PATH")"
cat >"$SHIM_PATH" <<'EOF'
#!/usr/bin/env bash
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
exec /usr/bin/git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" "$@"
EOF
chmod +x "$SHIM_PATH"

# ensure ~/.local/bin on PATH for bash
if ! grep -q '\.local/bin' "$HOME/.bash_profile" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >>"$HOME/.bash_profile"
fi
export PATH="$HOME/.local/bin:$PATH"

# clone bare repo if needed
if [[ ! -d "$DOTFILES_DIR" ]]; then
  echo "==> cloning bare repo from $REMOTE_URL into $DOTFILES_DIR"
  git clone --bare "$REMOTE_URL" "$DOTFILES_DIR"
else
  echo "==> bare repo already exists at $DOTFILES_DIR (skipping clone)"
fi

echo "==> configuring 'config' defaults"
config config status.showUntrackedFiles no || true

# pre-backup any tracked paths that already exist in $HOME
echo "==> pre-checking for conflicts and backing up to $BACKUP_DIR (if any)"
mkdir -p "$BACKUP_DIR"
# list tracked files in repo (HEAD must exist)
tracked_files=$(config ls-tree -r --name-only HEAD || true)
if [[ -n "${tracked_files}" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ -e "$HOME/$p" && ! -L "$HOME/$p" ]]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$p")"
      echo "   backing up ~/$p -> $BACKUP_DIR/$p"
      mv "$HOME/$p" "$BACKUP_DIR/$p"
    fi
  done <<<"$tracked_files"
fi

echo "==> checking out dotfiles into \$HOME"
if ! config checkout; then
  echo "!! checkout reported conflicts; forcing checkout after backup"
  config checkout -f
fi

echo "==> success. Make targets live at $MAKEFILE_PATH"
echo "   Try: make -f $MAKEFILE_PATH bootstrap"
