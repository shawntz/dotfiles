#!/usr/bin/env bash

mkdir -p ~/dotfiles/gtk
git clone https://github.com/vinceliuice/WhiteSur-gtk-theme.git ~/dotfiles/gtk/whitesur --depth=1
~/./dotfiles/gtk/whitesur/install.sh -r
~/./dotfiles/gtk/whitesur/install.sh -t all -m -N glassy -s 220 -i arch -HD --normal --round -P bigger
~/./dotfiles/gtk/whitesur/tweaks.sh -e
~/./dotfiles/gtk/whitesur/tweaks.sh -f -r
~/./dotfiles/gtk/whitesur/tweaks.sh -f alt
~/./dotfiles/gtk/whitesur/tweaks.sh -c Dark -d 
