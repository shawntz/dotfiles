#!/usr/bin/env bash

sudo -v  # ask for sudo password upfront

##### yay #####
pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si

##### gnome extensions #####
pacman -S gnome-shell-extension-caffeine

##### system #####
pacman -S docker
pacman -S i3-wm
pacman -S kitty
pacman -S neovim
pacman -S picom
pacman -S rofi
pacman -S tmux
pacman -S ttf-meslo-nerd
pacman -S zsh
pacman -S zsh-syntax-highlighting
pacman -S zsh-autosuggestions

##### shell tools #####
pacman -S neofetch     # sysinfo panel
pacman -S usbutils     # fix camera drivers on framework 13
pacman -S fprintd      # fix fingerprint reader on framework 13
pacman -S eza          # better ls
pacman -S fd           # better find
pacman -S fzf          # fuzzy finder
pacman -S imagemagick  # image manipulation
pacman -S lazygit      # git ui
pacman -S pandoc-cli   # converting between file formats
pacman -S polybar      # status bar
pacman -S rclone       # sync files to cloud
pacman -S ripgrep      # fast recursive grep
pacman -S starship     # cross-shell prompt
pacman -S stow         # installation manager for dotfiles
pacman -S trash-cli    # trashcan interface
pacman -S tree         # nested dir listings
pacman -S wget         # retrieve files from the web
pacman -S yazi         # fast terminal file manager
pacman -S zoxide       # better cd

##### apps #####
yay -S dropbox
yay -S google-chrome
yay -S notion-app-electron
yay -S slack-desktop
yay -S todoist-appimage
yay -S visual-studio-code-bin
yay -S zoom