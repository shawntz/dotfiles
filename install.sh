#!/bin/zsh

build_xcode() {
  if ! xcode-select --print-path &> /dev/null; then
    xcode-select --install &> /dev/null

    until xcode-select --print-path &> /dev/null; do
      sleep 5
    done

    sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer

    sudo xcodebuild -license
  fi
}

install_mac_app_store_apps() {
  mas install 1606145041  # sleeve
  mas install 1545870783  # system color picker
  mas install 497799835   # xcode
}

config_git() {
  cp ~/dotfiles/git/.extra.template .extra.sh
  nvim .extra.sh
}

generate_ssh_key() {
  local email="$1"
  local key_path="$2"

  if [[ -z "$email" ]]; then
    read -rp "enter your email for the ssh key: " email
  fi

  if [[ -z "$email" ]]; then
    echo "error: no email provided... exiting."
    return 1
  fi

  if [[ -z "$key_path" ]]; then
    read -rp "enter the path where the ssh key should be saved (default: ~/.ssh/id_ed25519): " key_path
    key_path="${key_path:-~/.ssh/id_ed25519}"
  fi

  ssh-keygen -t ed25519 -C "$email" -f "$key_path"
  echo "[INFO] - ssh key generated at $key_path with email: $email"

  echo "[INFO] - starting the ssh-agent in the background..."
  eval "$(ssh-agent -s)"

  echo "[INFO] - adding ssh private key to the ssh-agent and storing passphrase in the mac keychain..."
  ssh-add --apple-use-keychain "$key_path"

  pub_key_content=$(cat "${key_path}.pub")
  echo "$pub_key_content" | pbcopy
  echo "[INFO] - public key copied to clipboard! please add to github!"
}

get_obsidian_vault() {
  git clone git@github.com:shawntschwartz/obsidian.git ~/documents/notes
}

config_crons() {
  crontab ~/dotfiles/crontab/crontab
}

create_dirs() {
  ./finder/finder
}

install_brew() {
  ./brew/brew
}

config_macos() {
  ./macos/macos
}

stow_dotfiles() {
  ./stow/stow
}

confirm_reboot() {
  echo "[IMPORTANT] - it's now time to reboot... press <return> to continue or ctrl+c to cancel."
  read -r
  sudo reboot
}

printf "🔑  generating ssh key...\n"
generate_ssh_key

printf "🐙  configuring git...\n"
config_git

printf "🗄  creating directories and configuring finder...\n"
create_dirs

printf "🛠  installing xcode command line tools...\n"
build_xcode

printf "🍺  brewing packages...\n"
install_brew

printf "⏰  configuring cron jobs...\n"
config_crons

printf "🛍️  shopping the mac app store...\n"
install_mac_app_store_apps

printf "🛠  setting xcode path...\n"
sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer

printf "💻  setting up macos...\n"
config_macos

printf "😇  stowing dotfiles...\n"
stow_dotfiles

printf "💎  getting obsidian vault...\n"
get_obsidian_vault

printf "✨  order up, your mac is ready!!\n"
confirm_reboot

