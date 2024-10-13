OS = $(shell uname)

FEDORA_PACKAGES = git kitty alacritty bat zsh neovim curl R feh fzf lua python3 python3-pip pipx tmux neofetch eza fd-find ImageMagick pandoc rclone ripgrep stow trash-cli tree make wget zoxide jupyterlab gimp

# stow dirs
STOW_DIR = $(HOME)/dotfiles/_configs
CONFIG_TARGET_DIR = $(HOME)/.config
KEYD_TARGET_DIR = /etc/keyd
WALLPAPERS_TARGET_DIR = $(HOME)/pictures
ZSH_TARGET_DIR = $(HOME)

step-a: configure-git rename-dirs install-packages
step-b: install-from-source setup-keyd stow-dot-configs stow-others
step-c: enable-zsh

configure-git:
	@echo "configuring git..."
	cp .gitconfig.template .gitconf.sh
	nano .gitconf.sh
	bash .gitconf.sh

stow-dot-configs:
	@echo "stowing .config files..."
	@for dir in $(STOW_DIR)/*; do \
		if [ "$$(basename $$dir)" != "keyd" ] && [ "$$(basename $$dir)" != "zsh" ] && [ "$$(basename $$dir)" != "wallpapers" ]; then \
			stow -v -d $(STOW_DIR) -t $(CONFIG_TARGET_DIR) $$(basename $$dir); \
		fi; \
	done

stow-others:
	@echo "stowing other files..."
	sudo stow -v -d $(STOW_DIR) -t $(KEYD_TARGET_DIR) keyd
	stow -v -d $(STOW_DIR) -t $(WALLPAPERS_TARGET_DIR) wallpapers
	stow -v -d $(STOW_DIR) -t $(ZSH_TARGET_DIR) zsh

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
	$(MAKE) fix-zoxide-binary
	@echo "after this next step finishes, run `make install-from-source`"
	$(MAKE) install-rustup

install-macos-packages:
	@echo "installing packages for macos..."
	brew install $(MACOS_PACKAGES)

install-rustup:
	@echo "setting up rustup (for cargo)..."
	bash _scripts/rust
	source $(HOME)/.bashrc

install-from-source:
	@echo "installing cli tools and apps from source..."
	bash _scripts/bob
	bash _scripts/starship
	bash _scripts/lazygit
	bash _scripts/yazi
	bash _scripts/1password
	bash _scripts/via
	bash _scripts/docker
	@echo "done installing packages from source!"

fix-zoxide-binary:
	@echo "fixing zoxide binary location..."
	sudo mv /usr/bin/zoxide /usr/local/bin/

setup-keyd:
	@echo "setting up keyd manager in systemctl..."
	bash _scripts/keyd

enable-zsh:
	@echo "enabling zsh and ohmyzsh..."
	_scripts/zsh

# if needed, clean up symlinks or dirs
clean:
	@echo "cleaning up symlinks..."
	stow -D _configs
