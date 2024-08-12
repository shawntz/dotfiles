#!/usr/bin/env bash

sudo -v  # ask for sudo password upfront

##### fully upgrade system #####
pacman -Syu

##### yay #####
pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si

##### install helper #####
install_if_missing() {
    package_name="$1"
    package_manager="$2"

    # validate package manager input as either pacman or yay
    if [[ "$package_manager" != "pacman" && "$package_manager" != "yay" ]]; then
        echo "invalid package manager specified; please use 'pacman' or 'yay'"
        return 1
    fi

    # verify the package manager is installed
    if ! command -v $package_manager > /dev/null; then
        echo "'$package_manager' is not installed!"
        return 1
    fi

    # install package
    if ! $package_manager -Qi "$package_name" > /dev/null; then
        yes | $package_manager -S "$package_name"
    else
        echo "'$package_name' is already installed... skipping!"
    fi
}

##### gnome extensions #####
install_if_missing gnome-tweaks pacman
install_if_missing gnome-shell-extension-caffeine pacman
install_if_missing gnome-shell-extension-blur-my-shell yay
install_if_missing whitesur-gtk-theme yay

##### system #####
install_if_missing bluez pacman
install_if_missing bluez-utils pacman
systemctl start bluetooth.service
systemctl enable bluetooth.service

install_if_missing docker pacman
install_if_missing firefox pacman
install_if_missing i3-wm pacman
install_if_missing kitty pacman
install_if_missing neovim pacman
install_if_missing picom pacman
install_if_missing r pacman
install_if_missing rofi pacman
install_if_missing tmux pacman
install_if_missing ttf-meslo-nerd pacman
install_if_missing zsh pacman
install_if_missing zsh-syntax-highlighting pacman
install_if_missing zsh-autosuggestions pacman

##### shell tools #####
install_if_missing neofetch pacman     # sysinfo panel
install_if_missing usbutils pacman     # fix camera drivers on framework 13
install_if_missing fprintd pacman      # fix fingerprint reader on framework 13
install_if_missing eza pacman          # better ls
install_if_missing fd pacman           # better find
install_if_missing fzf pacman          # fuzzy finder
install_if_missing imagemagick pacman  # image manipulation
install_if_missing lazygit pacman      # git ui
install_if_missing pandoc-cli pacman   # converting between file formats
install_if_missing polybar pacman      # status bar
install_if_missing rclone pacman       # sync files to cloud
install_if_missing ripgrep pacman      # fast recursive grep
install_if_missing starship pacman     # cross-shell prompt
install_if_missing stow pacman         # installation manager for dotfiles
install_if_missing trash-cli pacman    # trashcan interface
install_if_missing tree pacman         # nested dir listings
install_if_missing wget pacman         # retrieve files from the web
install_if_missing yazi pacman         # fast terminal file manager
install_if_missing zoxide pacman       # better cd

##### apps #####
install_if_missing 1password yay
install_if_missing dropbox yay
install_if_missing google-chrome yay
install_if_missing notion-app-electron yay
install_if_missing positron-ide-devel-bin yay
install_if_missing rstudio-desktop-bin yay
install_if_missing slack-desktop yay
install_if_missing todoist-appimage yay
install_if_missing visual-studio-code-bin yay
install_if_missing zoom yay