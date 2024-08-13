#!/usr/bin/env bash

mkdir -p ~/dotfiles/icons
git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git ~/dotfiles/icons/whitesur --depth=1
~/./dotfiles/icons/whitesur/install.sh -r
~/./dotfiles/icons/whitesur/install.sh -a -b
