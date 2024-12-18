#!/usr/bin/env bash
trash ~/.config/{karabiner,neofetch,nvim,rstudio,tmux,yazi}

echo "[INFO] - stowing dotfiles..."
stow . -v
echo "[INFO] - finished stowing dotfiles!"

echo "[INFO] - making dirs..."
mkdir ~/Pictures/screenshots
mkdir -p ~/Developer/repos
echo "[INFO] - finished configuring home directory!"

