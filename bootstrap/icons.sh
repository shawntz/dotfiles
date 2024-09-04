#!/usr/bin/env bash

mkdir -p ~/dotfiles/icons

git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git ~/dotfiles/icons/whitesur --depth=1
rm -rf ~/dotfiles/icons/whitesur/.git
rm -rf ~/dotfiles/icons/whitesur/.github
rm -rf ~/dotfiles/icons/whitesur/.gitignore

#~/./dotfiles/icons/whitesur/install.sh -a -b
mkdir -p ~/.icons
mkdir -p ~/.icons/whitesur
cp ~/dotfiles/icons/whitesur/ ~/.icons/whitesur/
