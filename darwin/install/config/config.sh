#!/bin/zsh

# Copy over configs
mkdir -p ~/.config
cp -R ~/.local/share/dotfiles/darwin/install/config/* ~/.config/
cp ~/.local/share/dotfiles/default/zshrc ~/.zshrc