#!/usr/bin/env bash

##### fully upgrade system #####
sudo apt update && sudo apt upgrade -y && sudo snap refresh

##### install helper #####
install_if_missing() {
  package_name="$1"
  package_manager="apt"

  # install package
  if ! $package_manager -Qi "$package_name" > /dev/null; then
    sudo $package_manager install "$package_name" -y
  else
    echo "'$package_name' is already installed... skipping!"
  fi
}

##### gnome extensions #####
install_if_missing gnome-tweaks
install_if_missing gnome-shell-extensions

##### system #####
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

install_if_missing bat
install_if_missing feh
install_if_missing gdebi
install_if_missing kitty
install_if_missing lua
install_if_missing luarocks
install_if_missing neovim
install_if_missing r-base
install_if_missing r-base-dev
install_if_missing rofi
install_if_missing rustc
install_if_missing tmux
install_if_missing zsh

##### shell tools #####
install_if_missing neofetch     # sysinfo panel
install_if_missing eza          # better ls
install_if_missing fd           # better find
#install_if_missing flatpak	# application manager
install_if_missing fzf          # fuzzy finder
install_if_missing imagemagick  # image manipulation
install_if_missing pandoc       # converting between file formats
install_if_missing polybar      # status bar
install_if_missing rclone       # sync files to cloud
install_if_missing ripgrep      # fast recursive grep
install_if_missing stow         # installation manager for dotfiles
install_if_missing trash-cli    # trashcan interface
install_if_missing tree         # nested dir listings
install_if_missing wget         # retrieve files from the web
install_if_missing yazi         # fast terminal file manager
install_if_missing zoxide       # better cd

# build lazygit from source
LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
tar xf lazygit.tar.gz lazygit
sudo install lazygit /usr/local/bin

# build starship from source
curl -sS https://starship.rs/install.sh | sh

# build yazi from source
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup update
git clone https://github.com/sxyazi/yazi.git
cd yazi
cargo build --release --locked
./target/release/yazi

# add flathub repo
#flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# reboot system
#reboot

#flatpak install flathub sh.cider.Cider

##### apps #####

sudo snap install code --classic
sudo snap install jupyterlab-desktop --classic
sudo snap install node --classic
sudo snap install postman
sudo snap install slack
sudo snap install todoist

# 1password
curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

 echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main' | sudo tee /etc/apt/sources.list.d/1password.list
 
sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/

curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol

sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22

curl -sS https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
 
sudo apt update && sudo apt install 1password

##### set default shell #####
zsh
zsh-newuser-install -f
chsh -l
chsh -s /usr/bin/zsh

git clone https://github.com/zsh-users/zsh-autosuggestions ~/dotfiles/zsh/zsh/zsh-autosuggestions
rm -rf ~/dotfiles/zsh/zsh/zsh-autosuggestions/.git
rm -rf ~/dotfiles/zsh/zsh/zsh-autosuggestions/.github
rm -rf ~/dotfiles/zsh/zsh/zsh-autosuggestions/.gitignore

git clone https://github.com/zsh-users/zsh-syntax-highlighting ~/dotfiles/zsh/zsh/zsh-syntax-highlighting
rm -rf ~/dotfiles/zsh/zsh/zsh-syntax-highlighting/.git
rm -rf ~/dotfiles/zsh/zsh/zsh-syntax-highlighting/.github
rm -rf ~/dotfiles/zsh/zsh/zsh-syntax-highlighting/.gitignore

