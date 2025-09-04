#!/usr/bin/make -f

# Enhanced Dotfiles Makefile
# Combines symlink management with package backup functionality

SHELL := /bin/bash
SCRIPT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
HOME_DIR := $(HOME)

# Detect the current platform
PLATFORM := $(shell \
	if [[ "$$OSTYPE" == "linux-gnu"* ]]; then \
		if command -v pacman &> /dev/null; then \
			echo "archlinux"; \
		else \
			echo "linux"; \
		fi \
	elif [[ "$$OSTYPE" == "darwin"* ]]; then \
		echo "darwin"; \
	else \
		echo "unknown"; \
	fi \
)

# Configuration directories and files to backup
CONFIG_DIRS := \
	.config/hypr \
	.config/waybar \
	.config/gtk-3.0 \
	.config/gtk-4.0 \
	.config/starship \
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
	.config/omarchy \
	.config/Pinta \
	.config/rstudio \
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

.PHONY: help install fresh-install uninstall status backup-packages restore-packages setup-keyd

# Default target
help: ## Show this help message
	@echo "Enhanced Dotfiles Management"
	@echo ""
	@echo "Detected platform: $(PLATFORM)"
	@echo "Dotfiles directory: $(SCRIPT_DIR)"
	@echo ""
	@echo "Core targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# === CORE INSTALLATION TARGETS ===

install: ## Install dotfiles for detected platform using install.sh
	@echo "Installing dotfiles for platform: $(PLATFORM)"
	@$(SCRIPT_DIR)/install.sh $(PLATFORM)

fresh-install: ## Simulate fresh install with safety checks - skips existing good symlinks
	@echo "🔍 Running fresh install simulation with safety checks for platform: $(PLATFORM)"
	@echo "This will verify all dotfiles and create missing symlinks without overwriting good ones."
	@echo ""
	@$(MAKE) --no-print-directory _fresh-install-common
	@if [ "$(PLATFORM)" != "common" ] && [ -d "$(SCRIPT_DIR)/$(PLATFORM)" ]; then \
		$(MAKE) --no-print-directory _fresh-install-platform PLATFORM_TARGET=$(PLATFORM); \
	fi
	@$(MAKE) --no-print-directory _fresh-install-local-share
	@echo ""
	@echo "✅ Fresh install simulation complete!"

_fresh-install-common: ## Internal: Process common directory with safety checks
	@if [ -d "$(SCRIPT_DIR)/common" ]; then \
		echo "📂 Processing common files..."; \
		find "$(SCRIPT_DIR)/common" -type f | while read -r file; do \
			rel_path=$${file#$(SCRIPT_DIR)/common/}; \
			target="$(HOME_DIR)/$$rel_path"; \
			$(MAKE) --no-print-directory _check-and-link SRC="$$file" DST="$$target"; \
		done; \
	fi

_fresh-install-platform: ## Internal: Process platform-specific directory with safety checks
	@if [ -d "$(SCRIPT_DIR)/$(PLATFORM_TARGET)" ]; then \
		echo "📂 Processing $(PLATFORM_TARGET) files..."; \
		find "$(SCRIPT_DIR)/$(PLATFORM_TARGET)" -type f | while read -r file; do \
			rel_path=$${file#$(SCRIPT_DIR)/$(PLATFORM_TARGET)/}; \
			target="$(HOME_DIR)/$$rel_path"; \
			$(MAKE) --no-print-directory _check-and-link SRC="$$file" DST="$$target"; \
		done; \
	fi

_fresh-install-local-share: ## Internal: Process .local/share files with safety checks
	@if [ -d "$(SCRIPT_DIR)/$(PLATFORM)/.local/share" ]; then \
		echo "📂 Processing .local/share files for $(PLATFORM)..."; \
		find "$(SCRIPT_DIR)/$(PLATFORM)/.local/share" -type f | while read -r file; do \
			rel_path=$${file#$(SCRIPT_DIR)/$(PLATFORM)/.local/share/}; \
			target="$(HOME_DIR)/.local/share/$$rel_path"; \
			$(MAKE) --no-print-directory _check-and-link SRC="$$file" DST="$$target"; \
		done; \
	fi

_check-and-link: ## Internal: Safety check and create symlink if needed
	@target_dir=$$(dirname "$(DST)"); \
	if [ ! -d "$$target_dir" ]; then \
		echo "📁 Creating directory: $$target_dir"; \
		mkdir -p "$$target_dir"; \
	fi; \
	if [ -L "$(DST)" ]; then \
		existing_target=$$(readlink "$(DST)"); \
		if [ "$$existing_target" = "$(SRC)" ]; then \
			echo "✅ $(DST) -> $(SRC) (already linked correctly)"; \
		else \
			echo "🔄 $(DST) -> $(SRC) (updating from $$existing_target)"; \
			rm -f "$(DST)"; \
			ln -sf "$(SRC)" "$(DST)"; \
		fi \
	elif [ -f "$(DST)" ] || [ -d "$(DST)" ]; then \
		echo "⚠️  $(DST) (exists but not symlinked - backing up to .bak)"; \
		mv "$(DST)" "$(DST).bak"; \
		ln -sf "$(SRC)" "$(DST)"; \
		echo "✅ $(DST) -> $(SRC) (created, original backed up)"; \
	else \
		ln -sf "$(SRC)" "$(DST)"; \
		echo "✅ $(DST) -> $(SRC) (created)"; \
	fi

uninstall: ## Remove all dotfiles symlinks using uninstall.sh
	@echo "Uninstalling dotfiles..."
	@$(SCRIPT_DIR)/uninstall.sh

status: ## Show current symlink status with detailed checking
	@echo "Dotfiles Status Report"
	@echo "Platform: $(PLATFORM)"
	@echo "Dotfiles directory: $(SCRIPT_DIR)"
	@echo ""
	@echo "Checking common symlinks..."
	@if [ -d "$(SCRIPT_DIR)/common" ]; then \
		find "$(SCRIPT_DIR)/common" -type f | while read -r file; do \
			rel_path=$${file#$(SCRIPT_DIR)/common/}; \
			target="$(HOME_DIR)/$$rel_path"; \
			if [ -L "$$target" ]; then \
				existing_target=$$(readlink "$$target"); \
				if [ "$$existing_target" = "$$file" ]; then \
					echo "✅ $$target -> $$existing_target"; \
				else \
					echo "⚠️  $$target -> $$existing_target (should be $$file)"; \
				fi \
			elif [ -f "$$target" ] || [ -d "$$target" ]; then \
				echo "⚠️  $$target (exists but not symlinked)"; \
			else \
				echo "❌ $$target (missing)"; \
			fi \
		done; \
	fi
	@echo ""
	@echo "Checking $(PLATFORM) symlinks..."
	@if [ -d "$(SCRIPT_DIR)/$(PLATFORM)" ] && [ "$(PLATFORM)" != "common" ]; then \
		find "$(SCRIPT_DIR)/$(PLATFORM)" -type f | while read -r file; do \
			rel_path=$${file#$(SCRIPT_DIR)/$(PLATFORM)/}; \
			target="$(HOME_DIR)/$$rel_path"; \
			if [ -L "$$target" ]; then \
				existing_target=$$(readlink "$$target"); \
				if [ "$$existing_target" = "$$file" ]; then \
					echo "✅ $$target -> $$existing_target"; \
				else \
					echo "⚠️  $$target -> $$existing_target (should be $$file)"; \
				fi \
			elif [ -f "$$target" ] || [ -d "$$target" ]; then \
				echo "⚠️  $$target (exists but not symlinked)"; \
			else \
				echo "❌ $$target (missing)"; \
			fi \
		done; \
	fi

# === PLATFORM-SPECIFIC TARGETS ===

archlinux: ## Force install Arch Linux dotfiles
	@echo "Installing Arch Linux dotfiles..."
	@$(SCRIPT_DIR)/install.sh archlinux

darwin: ## Force install macOS dotfiles  
	@echo "Installing macOS dotfiles..."
	@$(SCRIPT_DIR)/install.sh darwin

common: ## Install only common dotfiles
	@echo "Installing common dotfiles..."
	@$(SCRIPT_DIR)/install.sh common

# === PACKAGE MANAGEMENT TARGETS ===

backup-packages: ## Export and backup package lists to platform directory
	@if [ "$(PLATFORM)" != "archlinux" ]; then \
		echo "❌ Package backup only supported on Arch Linux"; \
		exit 1; \
	fi
	@echo "📦 Exporting package lists..."
	@pacman -Qqe > $(SCRIPT_DIR)/archlinux/pkglist.txt
	@if command -v yay >/dev/null 2>&1; then \
		yay -Qm > $(SCRIPT_DIR)/archlinux/aurlist.txt; \
		echo "✅ Exported pacman packages -> archlinux/pkglist.txt"; \
		echo "✅ Exported AUR packages -> archlinux/aurlist.txt"; \
	else \
		echo "✅ Exported pacman packages -> archlinux/pkglist.txt"; \
		echo "⚠️  yay not found; skipping aurlist.txt"; \
	fi
	@echo "📝 Package lists saved to platform directory"

restore-packages: ## Install packages from backup lists in platform directory
	@if [ "$(PLATFORM)" != "archlinux" ]; then \
		echo "❌ Package restore only supported on Arch Linux"; \
		exit 1; \
	fi
	@echo "📥 Restoring pacman packages..."
	@if [ -f $(SCRIPT_DIR)/archlinux/pkglist.txt ]; then \
		sudo pacman -S --needed - < $(SCRIPT_DIR)/archlinux/pkglist.txt; \
	else \
		echo "❌ archlinux/pkglist.txt not found"; \
	fi
	@echo "📥 Restoring AUR packages..."
	@if command -v yay >/dev/null 2>&1 && [ -f $(SCRIPT_DIR)/archlinux/aurlist.txt ]; then \
		awk '{print $$1}' $(SCRIPT_DIR)/archlinux/aurlist.txt | yay -S --needed -; \
	else \
		echo "⚠️  yay or archlinux/aurlist.txt missing; skipping AUR restore"; \
	fi
	@echo "✅ Packages restored."

# === DEVELOPMENT/MAINTENANCE TARGETS ===

fix-local-share: ## Fix .local/share directory symlinking for current platform
	@echo "🔧 Fixing .local/share directory symlinks for $(PLATFORM)..."
	@if [ -d "$(SCRIPT_DIR)/$(PLATFORM)/.local/share" ]; then \
		find "$(SCRIPT_DIR)/$(PLATFORM)/.local/share" -type f | while read -r file; do \
			rel_path=$${file#$(SCRIPT_DIR)/$(PLATFORM)/.local/share/}; \
			src_file="$$file"; \
			target_file="$(HOME_DIR)/.local/share/$$rel_path"; \
			echo "Creating symlink: $$target_file -> $$src_file"; \
			mkdir -p "$$(dirname "$$target_file")"; \
			if [ -e "$$target_file" ] || [ -L "$$target_file" ]; then \
				rm -rf "$$target_file"; \
			fi; \
			ln -sf "$$src_file" "$$target_file"; \
			echo "✅ Linked: $$target_file -> $$src_file"; \
		done; \
	else \
		echo "❌ No .local/share directory found for platform $(PLATFORM)"; \
	fi

list-platforms: ## List available platforms
	@echo "Available platforms:"
	@for dir in archlinux darwin common; do \
		if [ -d "$(SCRIPT_DIR)/$$dir" ]; then \
			echo "  ✅ $$dir/"; \
		else \
			echo "  ❌ $$dir/ (missing)"; \
		fi \
	done

bootstrap: ## Complete setup: restore packages, then fresh-install dotfiles
	@echo "🚀 Starting bootstrap process..."
	@if [ "$(PLATFORM)" = "archlinux" ] && [ -f "$(SCRIPT_DIR)/archlinux/pkglist.txt" ]; then \
		$(MAKE) --no-print-directory restore-packages; \
	else \
		echo "⚠️  Skipping package restore (not Arch Linux or no package lists found)"; \
	fi
	@$(MAKE) --no-print-directory fresh-install
	@echo "🎉 Bootstrap complete!"

# === VALIDATION TARGETS ===

validate: ## Validate all symlinks and report issues
	@echo "🔍 Validating dotfiles installation..."
	@$(MAKE) --no-print-directory status | grep -E '(⚠️|❌)' || echo "✅ All symlinks are healthy!"

doctor: ## Run comprehensive health check
	@echo "🏥 Running dotfiles health check..."
	@echo ""
	@echo "Platform detection:"
	@echo "  Current platform: $(PLATFORM)"
	@echo ""
	@echo "Available platform directories:"
	@for dir in archlinux darwin common; do \
		if [ -d "$(SCRIPT_DIR)/$$dir" ]; then \
			echo "  ✅ $$dir/"; \
		else \
			echo "  ❌ $$dir/ (missing)"; \
		fi \
	done
	@echo ""
	@echo "Package manager availability:"
	@if command -v pacman >/dev/null 2>&1; then echo "  ✅ pacman"; else echo "  ❌ pacman"; fi
	@if command -v yay >/dev/null 2>&1; then echo "  ✅ yay"; else echo "  ❌ yay"; fi
	@if command -v brew >/dev/null 2>&1; then echo "  ✅ brew"; else echo "  ❌ brew"; fi
	@echo ""
	@echo "Package lists:"
	@if [ -f "$(SCRIPT_DIR)/archlinux/pkglist.txt" ]; then \
		echo "  ✅ archlinux/pkglist.txt"; \
	else \
		echo "  ❌ archlinux/pkglist.txt (missing)"; \
	fi
	@if [ -f "$(SCRIPT_DIR)/archlinux/aurlist.txt" ]; then \
		echo "  ✅ archlinux/aurlist.txt"; \
	else \
		echo "  ❌ archlinux/aurlist.txt (missing)"; \
	fi
	@echo ""
	@$(MAKE) --no-print-directory validate

clean: uninstall ## Alias for uninstall

# === SYSTEM CONFIGURATION TARGETS ===

setup-keyd: ## Setup keyd keyboard remapping service (Arch Linux only)
	@if [ "$(PLATFORM)" != "archlinux" ]; then \
		echo "❌ keyd setup only supported on Arch Linux"; \
		exit 1; \
	fi
	@echo "🔧 Setting up keyd keyboard remapping..."
	@if [ ! -f "$(SCRIPT_DIR)/archlinux/.config/keyd/default.conf" ]; then \
		echo "❌ keyd configuration file not found: $(SCRIPT_DIR)/archlinux/.config/keyd/default.conf"; \
		exit 1; \
	fi
	@echo "📁 Creating /etc/keyd directory..."
	@sudo mkdir -p /etc/keyd
	@echo "🔗 Creating symlink /etc/keyd/default.conf -> $(SCRIPT_DIR)/archlinux/.config/keyd/default.conf"
	@sudo ln -sf "$(SCRIPT_DIR)/archlinux/.config/keyd/default.conf" /etc/keyd/default.conf
	@echo "🔄 Enabling keyd service..."
	@sudo systemctl enable keyd
	@echo "▶️  Starting keyd service..."
	@sudo systemctl start keyd
	@echo "✅ keyd setup complete! Check status with: systemctl status keyd"