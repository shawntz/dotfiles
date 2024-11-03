OS = $(shell uname)

FEDORA_PACKAGES = git kitty alacritty bat zsh neovim curl R feh fzf lua python3 python3-pip pipx tmux neofetch eza fd-find ImageMagick pandoc rclone ripgrep stow trash-cli tree make wget zoxide jupyterlab gimp

# stow dirs
DOTS_DIR = $(HOME)/.dotfiles
STOW_DIR = $(DOTS_DIR)/config
CONFIG_TARGET_DIR = $(HOME)/.config
# HAMMERSPOON_TARGET_DIR = $(HOME)/.hammerspoon
KEYD_TARGET_DIR = /etc/keyd
WALLPAPERS_TARGET_DIR = $(HOME)/Pictures/wallpapers
ZSH_TARGET_DIR = $(HOME)

config: configure-git rename-dirs install-packages
install: install-packages
stow: stow-dot-configs
zsh: enable-zsh

config-mac:
	@echo "configuring macos preferences..."
	bash macos/defaults

configure-git:
	@echo "configuring git..."
	cp .gitconfig.template .gitconf.sh
	nano .gitconf.sh
	bash .gitconf.sh

rename-dirs:
	@echo "renaming user dirs..."
	@if [ "$(OS)" = "Darwin" ]; then \
		bash scripts/finder; \
	else \
		bash scripts/dirs; \
	fi; \

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
	fi; \

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
	/opt/homebrew/bin/brew bundle

install-rustup:
	@echo "setting up rustup (for cargo)..."
	bash scripts/rust
	source $(HOME)/.bashrc

install-from-source:
	@echo "installing cli tools and apps from source..."
	bash scripts/bob
	bash scripts/starship
	bash scripts/lazygit
	bash scripts/yazi
	bash scripts/1password
	bash scripts/via
	bash scripts/docker
	@echo "done installing packages from source!"

stow-dot-configs:
	@echo "stowing .config files..."
	mkdir -p ~/.config
	@if [ "$(OS)" = "Darwin" ]; then \
		STOW_CMD="/opt/homebrew/bin/stow"; \
		mkdir -p $(WALLPAPERS_TARGET_DIR); \
		$$STOW_CMD -v -d $(DOTS_DIR) -t $(WALLPAPERS_TARGET_DIR) wallpapers; \
		$$STOW_CMD -v -d $(STOW_DIR) -t $(ZSH_TARGET_DIR) zsh; \
		mkdir -p ~/.config/karabiner; \
		$$STOW_CMD -v -d $(STOW_DIR) -t $(CONFIG_TARGET_DIR)/karabiner karabiner; \
		$$STOW_CMD -v -d $(STOW_DIR) -t $(ZSH_TARGET_DIR) zsh; \
	else \
		STOW_CMD="stow"; \
	fi; \
	for dir in $(STOW_DIR)/*; do \
		if [ "$$(basename $$dir)" != "keyd" ] && [ "$$(basename $$dir)" != "zsh" ] && [ "$$(basename $$dir)" != "karabiner" ] && [ "$$(basename $$dir)" != "hammerspoon" ] && [ "$$(basename $$dir)" != "aerospace" ] && [ "$$(basename $$dir)" != "wallpapers" ]; then \
			$$STOW_CMD -v -d $(STOW_DIR) -t $(CONFIG_TARGET_DIR) $$(basename $$dir); \
		fi; \
	done
	@if [ "$(OS)" != "Darwin" ]; then \
		sudo $$STOW_CMD -v -d $(STOW_DIR) -t $(KEYD_TARGET_DIR) keyd; \
		sudo keyd reload; \
	fi; \

stow-mac-dot-configs:
	@echo "stowing macos specific configs..."
	# mkdir -p ~/.config/aerospace
	# /opt/homebrew/bin/stow -v -d $(STOW_DIR) -t $(CONFIG_TARGET_DIR)/aerospace aerospace
	# mkdir -p ~/.hammerspoon
	# /opt/homebrew/bin/stow -v -d $(STOW_DIR) -t $(HAMMERSPOON_TARGET_DIR) hammerspoon
	mkdir -p ~/.config/karabiner
	/opt/homebrew/bin/stow -v -d $(STOW_DIR) -t $(CONFIG_TARGET_DIR)/karabiner karabiner
	/opt/homebrew/bin/stow -v -d $(STOW_DIR) -t $(ZSH_TARGET_DIR) zsh

fix-zoxide-binary:
	@echo "fixing zoxide binary location..."
	sudo mv /usr/bin/zoxide /usr/local/bin/

setup-keyd:
	@echo "setting up keyd manager in systemctl..."
	bash scripts/keyd

enable-zsh:
	@echo "enabling zsh and ohmyzsh..."
	scripts/zsh

install-transfuse:
	@echo "installing transfuse kde plasma backup script..."
	scripts/transfuse

install-cronjobs:
	@echo "installing cron jobs with crontab..."
	sudo crontab -u shawn $(DOTS_DIR)/cronfile

# backup-kde-appearance:
# 	@echo "backing up kde plasma appearance..."
# 	crontab/kdebkup.sh

# if needed, clean up symlinks or dirs
clean:
	@echo "cleaning up symlinks..."
	stow -D config
