#!/bin/zsh

if [[ ! -d "$HOME/.config/nvim" ]]; then
  git clone https://github.com/LazyVim/starter ~/.config/nvim
  cp -R ~/.local/share/dotfiles/darwin/install/config/nvim/* ~/.config/nvim/
  rm -rf ~/.config/nvim/.git
  echo "vim.opt.relativenumber = true" >>~/.config/nvim/lua/config/options.lua
fi