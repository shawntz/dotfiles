#!/usr/bin/env bash
echo "[INFO] - stowing dotfiles..."
stow . -v
echo "[INFO] - finished stowing dotfiles!"

echo "[INFO] - making dirs..."
mkdir ~/Pictures/screenshots
mkdir -p ~/Developer/repos
echo "[INFO] - finished configuring home directory!"

