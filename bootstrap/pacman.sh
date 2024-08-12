#!/usr/bin/env bash

sudo -v  # ask for sudo password upfront

##### fully upgrade system #####
pacman -Syu

##### yay #####
pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si

##### install helper #####
install_if_missing() {
    package_name="$1"
    
    if command -v yay > /dev/null; then
        package_manager="yay"
    else
        package_manager="pacman"
    fi

    if ! $package_manager -Qi "$package_name" > /dev/null; then
        sudo $package_manager -S "$package_name" -y
    else
        echo "'$package_name' is already installed... skipping!"
    fi
}

##### gnome extensions #####
install_if_missing gnome-tweaks
install_if_missing gnome-shell-extension-caffeine
install_if_missing gnome-shell-extension-blur-my-shell
install_if_missing whitesur-gtk-theme-git

##### system #####
install_if_missing bluez
install_if_missing bluez-utils
systemctl start bluetooth.service
systemctl enable bluetooth.service

install_if_missing docker
install_if_missing firefox
install_if_missing i3-wm
install_if_missing kitty
install_if_missing neovim
install_if_missing picom
install_if_missing r
install_if_missing rofi
install_if_missing tmux
install_if_missing ttf-meslo-nerd
install_if_missing zsh
install_if_missing zsh-syntax-highlighting
install_if_missing zsh-autosuggestions

##### shell tools #####
install_if_missing neofetch     # sysinfo panel
install_if_missing usbutils     # fix camera drivers on framework 13
install_if_missing fprintd      # fix fingerprint reader on framework 13
install_if_missing eza          # better ls
install_if_missing fd           # better find
install_if_missing fzf          # fuzzy finder
install_if_missing imagemagick  # image manipulation
install_if_missing lazygit      # git ui
install_if_missing pandoc-cli   # converting between file formats
install_if_missing polybar      # status bar
install_if_missing rclone       # sync files to cloud
install_if_missing ripgrep      # fast recursive grep
install_if_missing starship     # cross-shell prompt
install_if_missing stow         # installation manager for dotfiles
install_if_missing trash-cli    # trashcan interface
install_if_missing tree         # nested dir listings
install_if_missing wget         # retrieve files from the web
install_if_missing yazi         # fast terminal file manager
install_if_missing zoxide       # better cd

##### apps #####
install_if_missing dropbox
install_if_missing google-chrome
install_if_missing notion-app-electron
install_if_missing positron-ide-devel-bin
install_if_missing rstudio-desktop-bin
install_if_missing slack-desktop
install_if_missing todoist-appimage
install_if_missing visual-studio-code-bin
install_if_missing zoom