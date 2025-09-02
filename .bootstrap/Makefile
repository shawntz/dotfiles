# ~/.bootstrap/Makefile

SHELL := /bin/bash
HOME_DIR := $(HOME)
DOTFILES_DIR := $(HOME)/.dotfiles
SHIM_PATH := $(HOME)/.local/bin/config
REMOTE_URL ?= git@github.com:shawntz/dotfiles.git

# 'config' wrapper
CONFIG := git --git-dir=$(DOTFILES_DIR) --work-tree=$(HOME)

# back up targets
CONFIG_DIRS := \
  .config/hypr \
  .config/waybar \
  .config/gtk-3.0 \
  .config/gtk-4.0 \
  .config/starship.toml \
  .config/nvim \
	.config/alacritty \
	.config/btop \
	.config/environment.d \
	.config/fastfetch \
	.config/fontconfig \
	.config/lazydocker \
	.config/lazygit \
	.config/libreoffice \
	.config/mise \
	.config/nautilus \
	.config/nvim \
	.config/omarchy \
	.config/Pinta \
	.config/rstudio/rstudio-prefs.json \
	.config/rstudio/config.json \
	.config/rstudio/themes \
	.config/swayosd \
	.config/systemd \
	.config/walker \
	.config/sublime-text \
	Scripts \
	.local/bin \
	.local/share/applications

CONFIG_FILES := \
  .zshrc \
  .zprofile \
  .zshenv \
  .gitconfig \
  .gitignore \
  .inputrc \
  .profile \
  .bashrc

.PHONY: help
help:
	@echo "Targets:"
	@echo "  init-dotfiles     - install shim, clone bare, checkout"
	@echo "  backup-packages   - export pkg lists -> commit/push"
	@echo "  restore-packages  - install from pkglist.txt + aurlist.txt"
	@echo "  backup-configs    - add config dirs/files -> commit/push"
	@echo "  restore-dotfiles  - checkout tracked files from bare"
	@echo "  bootstrap         - restore packages, then dotfiles"

# --- bootstrap bare setup (can be used after install.sh too) ---

.PHONY: install-config-shim
install-config-shim:
	@mkdir -p "$(HOME)/.local/bin"
	@printf '%s\n' '#!/usr/bin/env bash' \
		'DOTFILES_DIR="${DOTFILES_DIR:-$$HOME/.dotfiles}"' \
		'exec /usr/bin/git --git-dir="$$DOTFILES_DIR" --work-tree="$$HOME" "$$@"' \
		> "$(SHIM_PATH)"
	@chmod +x "$(SHIM_PATH)"
	@grep -q '\.local/bin' "$(HOME)/.bash_profile" 2>/dev/null || \
		echo 'export PATH="$$HOME/.local/bin:$$PATH"' >> "$(HOME)/.bash_profile"
	@echo "✅ config shim: $(SHIM_PATH)"

.PHONY: clone-bare
clone-bare:
	@if [ -d "$(DOTFILES_DIR)" ]; then \
		echo "⚠️  $(DOTFILES_DIR) already exists, skipping clone."; \
	else \
		echo "📥 Cloning bare repo from $(REMOTE_URL)"; \
		git clone --bare "$(REMOTE_URL)" "$(DOTFILES_DIR)"; \
	fi

.PHONY: init-dotfiles
init-dotfiles: install-config-shim clone-bare
	@echo "⚙️  Configure bare repo defaults"
	$(CONFIG) config status.showUntrackedFiles no || true
	@echo "📥 Checkout"
	-$(CONFIG) checkout || true
	@echo "🎉 Dotfiles initialized."

# --- packages ---

.PHONY: backup-packages
backup-packages:
	@echo "📦 Exporting package lists..."
	pacman -Qqe > $(HOME_DIR)/pkglist.txt
	@if command -v yay >/dev/null 2>&1; then yay -Qm > $(HOME_DIR)/aurlist.txt; else echo "⚠️  yay not found; skipping aurlist.txt"; fi
	@echo "📝 Commit & push"
	$(CONFIG) add pkglist.txt aurlist.txt 2>/dev/null || true
	$(CONFIG) commit -m "Update package lists [auto]" || echo "No package list changes"
	$(CONFIG) push
	@echo "✅ Done."

.PHONY: restore-packages
restore-packages:
	@echo "📥 Restoring pacman packages..."
	@if [ -f $(HOME_DIR)/pkglist.txt ]; then \
		sudo pacman -S --needed - < $(HOME_DIR)/pkglist.txt; \
	else echo "❌ pkglist.txt not found"; fi
	@echo "📥 Restoring AUR packages..."
	@if command -v yay >/dev/null 2>&1 && [ -f $(HOME_DIR)/aurlist.txt ]; then \
		awk '{print $$1}' $(HOME_DIR)/aurlist.txt | yay -S --needed -; \
	else echo "⚠️  yay or aurlist.txt missing; skipping AUR restore"; fi
	@echo "🎉 Packages restored."

# --- dotfiles/configs content ---

.PHONY: backup-configs
backup-configs:
	@echo "🗂  Adding config dirs/files…"
	@set -e; for p in $(CONFIG_DIRS) $(CONFIG_FILES); do \
		if [ -e "$(HOME_DIR)/$$p" ]; then \
			echo "  + $$p"; \
			$(CONFIG) add "$$p"; \
		else \
			echo "  - $$p (missing)"; \
		fi; \
	done
	@echo "📝 Commit & push"
	$(CONFIG) commit -m "Backup configs [auto]" || echo "No config changes"
	$(CONFIG) push
	@echo "✅ Configs backed up."

.PHONY: restore-dotfiles
restore-dotfiles:
	@echo "📥 Checking out tracked dotfiles"
	$(CONFIG) checkout
	@echo "🎉 Dotfiles restored."

# --- one-shot setup ---

.PHONY: bootstrap
bootstrap: restore-packages restore-dotfiles
	@echo "🚀 Bootstrap complete."

