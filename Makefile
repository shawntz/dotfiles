OS = $(shell uname)

FEDORA_PACKAGES = git kitty alacritty bat zsh neovim curl R feh fzf lua python3 python3-pip pipx tmux neofetch eza fd-find ImageMagick pandoc rclone ripgrep stow trash-cli tree make wget zoxide jupyterlab gimp

all: configure-git rename-dirs install-packages stow enable-zsh

configure-git:
  cp .gitconfig.template .gitconf.sh
  nano .gitconf.sh
  bash .gitconf.sh

stow:
  @echo "stowing .configs..."
  stow -t $(HOME) _configs

rename-dirs:
  @echo "renaming user dirs..."
  bash _scripts/dirs

install-packages:
  @echo "installing packages..."
  @if [ "$(OS)" = "Linux" ]; then \
    if [ -f /etc/debian_version ]; then \
      $(MAKE) install-ubuntu-packages; \
    elif [ -f /etc/redhat-release ]; then \
      $(MAKE) install-fedora-packages; \
    fi; \
    elif [ "$(OS)" = "Darwin" ]; then \
      $(MAKE) install-macos-packages; \
    fi

install-ubuntu-packages:
  @echo "installing packages for ubuntu..."
  sudo apt update && sudo apt install -y $(UBUNTU_PACKAGES)

install-fedora-packages:
  @echo "installing packages for fedora..."
  sudo dnf install -y $(FEDORA_PACKAGES)
  $(MAKE) install-from-source

install-macos-packages:
  @echo "installing packages for macos..."
  brew install $(MACOS_PACKAGES)

install-from-source:
  @echo "installing cli tools and apps from source..."
  bash _scripts/bob
  bash _scripts/starship
  bash _scripts/lazygit
  bash _scripts/yazi
  bash _scripts/1password
  bash _scripts/via
  bash _scripts/docker

enable-zsh:
  @echo "enabling zsh and ohmyzsh..."
  rm ~/.bash_history ~/.bash_logout ~/.bashrc
  sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)"
  rm .zshrc
  mv .zshrc.pre-oh-my-zsh .zshrc
  source ~/.zshrc
  zsh
  chsh -s /usr/bin/zsh
  rm ~/.bash_history ~/.bash_logout ~/.bashrc

# if needed, clean up symlinks or dirs
clean:
  @echo "cleaning up symlinks..."
  stow -D common
  stow -D os/$(OS)
