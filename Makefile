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
	.config/omarchy/branding \
	.config/Pinta \
	.config/rstudio \
	.config/swayosd \
	.config/systemd \
	.config/walker \
	.config/sublime-text \
	.local/bin \
	.local/share/applications \
	.local/share/omarchy/logo.svg \
	.local/share/omarchy/logo.txt \
	.local/share/omarchy/bin \
	.local/share/omarchy/default/plymouth

CONFIG_FILES := \
	.zshrc \
	.zprofile \
	.zshenv \
	.gitconfig \
	.gitignore \
	.inputrc \
	.profile \
	.bashrc

.PHONY: help install fresh-install uninstall status backup-packages restore-packages backup-configs setup-keyd link-wallpapers link-scripts link-langs scan-langs

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
	@echo "🔄 Committing and pushing changes..."
	@cd $(SCRIPT_DIR) && \
	git add archlinux/pkglist.txt archlinux/aurlist.txt && \
	if git diff --staged --quiet; then \
		echo "ℹ️  No changes to commit"; \
	else \
		git commit -m "[CI] Update package lists" && \
		git push; \
		echo "✅ Changes committed and pushed"; \
	fi

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

backup-configs: ## Backup configuration files and directories to platform directory
	@if [ "$(PLATFORM)" = "unknown" ]; then \
		echo "❌ Config backup requires a supported platform"; \
		exit 1; \
	fi
	@echo "📁 Backing up configuration files to $(PLATFORM) directory..."
	@mkdir -p $(SCRIPT_DIR)/$(PLATFORM)
	@echo "🔄 Copying CONFIG_DIRS..."
	@for item in $(CONFIG_DIRS); do \
		if [ -d "$(HOME_DIR)/$$item" ] && [ ! -L "$(HOME_DIR)/$$item" ]; then \
			echo "  📂 Copying $$item..."; \
			mkdir -p "$(SCRIPT_DIR)/$(PLATFORM)/$$(dirname $$item)"; \
			cp -r "$(HOME_DIR)/$$item" "$(SCRIPT_DIR)/$(PLATFORM)/$$item"; \
		elif [ -f "$(HOME_DIR)/$$item" ] && [ ! -L "$(HOME_DIR)/$$item" ]; then \
			echo "  📄 Copying $$item..."; \
			mkdir -p "$(SCRIPT_DIR)/$(PLATFORM)/$$(dirname $$item)"; \
			cp "$(HOME_DIR)/$$item" "$(SCRIPT_DIR)/$(PLATFORM)/$$item"; \
		elif [ -L "$(HOME_DIR)/$$item" ]; then \
			echo "  🔗 Skipping $$item (already symlinked to dotfiles)"; \
		else \
			echo "  ⚠️  Skipping $$item (not found)"; \
		fi \
	done
	@echo "📄 Copying CONFIG_FILES..."
	@for file in $(CONFIG_FILES); do \
		if [ -f "$(HOME_DIR)/$$file" ] && [ ! -L "$(HOME_DIR)/$$file" ]; then \
			echo "  📄 Copying $$file..."; \
			mkdir -p "$(SCRIPT_DIR)/$(PLATFORM)/$$(dirname $$file)"; \
			cp "$(HOME_DIR)/$$file" "$(SCRIPT_DIR)/$(PLATFORM)/$$file"; \
		elif [ -L "$(HOME_DIR)/$$file" ]; then \
			echo "  🔗 Skipping $$file (already symlinked to dotfiles)"; \
		else \
			echo "  ⚠️  Skipping $$file (not found)"; \
		fi \
	done
	@echo "✅ Configuration backup complete"
	@echo "🔄 Committing and pushing changes..."
	@cd $(SCRIPT_DIR) && \
	git add $(PLATFORM)/ && \
	if git diff --staged --quiet; then \
		echo "ℹ️  No changes to commit"; \
	else \
		git commit -m "[CI] Update configuration files for $(PLATFORM)" && \
		git push; \
		echo "✅ Changes committed and pushed"; \
	fi

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
	@echo "Special directory symlinks:"
	@if [ -L "$(HOME_DIR)/Pictures/wallpapers" ]; then \
		existing_target=$$(readlink "$(HOME_DIR)/Pictures/wallpapers"); \
		if [ "$$existing_target" = "$(SCRIPT_DIR)/wallpapers" ]; then \
			echo "  ✅ wallpapers -> $(SCRIPT_DIR)/wallpapers"; \
		else \
			echo "  ⚠️  wallpapers -> $$existing_target (should be $(SCRIPT_DIR)/wallpapers)"; \
		fi \
	elif [ -e "$(HOME_DIR)/Pictures/wallpapers" ]; then \
		echo "  ⚠️  wallpapers (exists but not symlinked)"; \
	else \
		echo "  ❌ wallpapers (missing)"; \
	fi
	@if [ -L "$(HOME_DIR)/Scripts" ]; then \
		existing_target=$$(readlink "$(HOME_DIR)/Scripts"); \
		if [ "$$existing_target" = "$(SCRIPT_DIR)/common/scripts" ]; then \
			echo "  ✅ scripts -> $(SCRIPT_DIR)/common/scripts"; \
		else \
			echo "  ⚠️  scripts -> $$existing_target (should be $(SCRIPT_DIR)/common/scripts)"; \
		fi \
	elif [ -e "$(HOME_DIR)/Scripts" ]; then \
		echo "  ⚠️  scripts (exists but not symlinked)"; \
	else \
		echo "  ❌ scripts (missing)"; \
	fi
	@echo ""
	@echo "Language environment directories:"
	@if [ -d "$(HOME_DIR)/Developer/langs" ]; then \
		lang_count=$$(find "$(HOME_DIR)/Developer/langs" -maxdepth 1 -type d | wc -l); \
		lang_count=$$((lang_count - 1)); \
		echo "  📁 Developer/langs/ ($$lang_count directories)"; \
		for pattern in go R .cargo .rustup .npm .yarn .julia .pyenv .rbenv .nvm; do \
			if [ -e "$(HOME_DIR)/Developer/langs/$$pattern" ]; then \
				case "$$pattern" in \
					"go"|"R") \
						if [ -L "$(HOME_DIR)/.$$pattern" ]; then \
							echo "  ✅ $$pattern -> ~/.$$pattern (hidden)"; \
						else \
							echo "  ⚠️  $$pattern (relocated but not symlinked as hidden)"; \
						fi \
						;; \
					*) \
						if [ -L "$(HOME_DIR)/$$pattern" ]; then \
							echo "  ✅ $$pattern -> ~/$$pattern"; \
						else \
							echo "  ⚠️  $$pattern (relocated but not symlinked)"; \
						fi \
						;; \
				esac \
			fi \
		done; \
	else \
		echo "  ❌ Developer/langs/ (missing - run 'make link-langs')"; \
	fi
	@echo ""
	@echo "Environment variables (shell config):"
	@for shell_config in ".zshrc" ".bashrc"; do \
		if [ -f "$(SCRIPT_DIR)/common/$$shell_config" ]; then \
			if grep -q "Developer/langs" "$(SCRIPT_DIR)/common/$$shell_config"; then \
				echo "  ✅ $$shell_config (language env vars configured)"; \
			else \
				echo "  ⚠️  $$shell_config (missing language env vars)"; \
			fi \
		else \
			echo "  ❌ $$shell_config (missing)"; \
		fi \
	done
	@echo ""
	@echo "Home directory cleanliness check:"
	@if ls "$(HOME_DIR)" | grep -E "(Makefile|LICENSE|install\.sh|uninstall\.sh|pkglist\.txt|aurlist\.txt|^archlinux$$|^common$$|^go$$|^R$$|node_modules|vendor)" >/dev/null 2>&1; then \
		echo "  ⚠️  Found dotfiles repo files in home directory:"; \
		ls "$(HOME_DIR)" | grep -E "(Makefile|LICENSE|install\.sh|uninstall\.sh|pkglist\.txt|aurlist\.txt|^archlinux$$|^common$$|^go$$|^R$$|node_modules|vendor)" | sed 's/^/    /'; \
	else \
		echo "  ✅ Home directory is clean (no repo files)"; \
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

setup-apple-emoji: ## Setup Apple emoji font support (Arch Linux only)
	@if [ "$(PLATFORM)" != "archlinux" ]; then \
		echo "❌ Apple emoji setup only supported on Arch Linux"; \
		exit 1; \
	fi
	@echo "😀 Setting up Apple emoji font support..."
	@if ! pacman -Qi ttf-apple-emoji >/dev/null 2>&1; then \
		echo "❌ ttf-apple-emoji package not installed. Install with: yay -S ttf-apple-emoji"; \
		exit 1; \
	fi
	@echo "🔗 Enabling Apple emoji fontconfig system-wide..."
	@sudo ln -sf /usr/share/fontconfig/conf.avail/75-apple-color-emoji.conf /etc/fonts/conf.d/75-apple-color-emoji.conf
	@echo "🔄 Rebuilding font cache..."
	@fc-cache -f
	@echo "🧪 Testing emoji support..."
	@echo "Testing: 😀 🎉 ❤️ 👍"
	@fc-match emoji
	@echo "✅ Apple emoji setup complete! Restart applications to see changes."

link-wallpapers: ## Create symlink for wallpapers directory
	@echo "🖼️  Linking wallpapers directory..."
	@mkdir -p "$(HOME_DIR)/Pictures"
	@if [ -L "$(HOME_DIR)/Pictures/wallpapers" ]; then \
		existing_target=$$(readlink "$(HOME_DIR)/Pictures/wallpapers"); \
		if [ "$$existing_target" = "$(SCRIPT_DIR)/wallpapers" ]; then \
			echo "✅ $(HOME_DIR)/Pictures/wallpapers -> $(SCRIPT_DIR)/wallpapers (already linked correctly)"; \
		else \
			echo "🔄 $(HOME_DIR)/Pictures/wallpapers -> $(SCRIPT_DIR)/wallpapers (updating from $$existing_target)"; \
			rm -f "$(HOME_DIR)/Pictures/wallpapers"; \
			ln -sf "$(SCRIPT_DIR)/wallpapers" "$(HOME_DIR)/Pictures/wallpapers"; \
		fi \
	elif [ -e "$(HOME_DIR)/Pictures/wallpapers" ]; then \
		echo "⚠️  $(HOME_DIR)/Pictures/wallpapers (exists but not symlinked - backing up to .bak)"; \
		mv "$(HOME_DIR)/Pictures/wallpapers" "$(HOME_DIR)/Pictures/wallpapers.bak"; \
		ln -sf "$(SCRIPT_DIR)/wallpapers" "$(HOME_DIR)/Pictures/wallpapers"; \
		echo "✅ $(HOME_DIR)/Pictures/wallpapers -> $(SCRIPT_DIR)/wallpapers (created, original backed up)"; \
	else \
		ln -sf "$(SCRIPT_DIR)/wallpapers" "$(HOME_DIR)/Pictures/wallpapers"; \
		echo "✅ $(HOME_DIR)/Pictures/wallpapers -> $(SCRIPT_DIR)/wallpapers (created)"; \
	fi

link-scripts: ## Create symlink for scripts directory
	@echo "📜 Linking scripts directory..."
	@if [ -L "$(HOME_DIR)/Scripts" ]; then \
		existing_target=$$(readlink "$(HOME_DIR)/Scripts"); \
		if [ "$$existing_target" = "$(SCRIPT_DIR)/common/scripts" ]; then \
			echo "✅ $(HOME_DIR)/Scripts -> $(SCRIPT_DIR)/common/scripts (already linked correctly)"; \
		else \
			echo "🔄 $(HOME_DIR)/Scripts -> $(SCRIPT_DIR)/common/scripts (updating from $$existing_target)"; \
			rm -f "$(HOME_DIR)/Scripts"; \
			ln -sf "$(SCRIPT_DIR)/common/scripts" "$(HOME_DIR)/Scripts"; \
		fi \
	elif [ -e "$(HOME_DIR)/Scripts" ]; then \
		echo "⚠️  $(HOME_DIR)/Scripts (exists but not symlinked - backing up to .bak)"; \
		mv "$(HOME_DIR)/Scripts" "$(HOME_DIR)/Scripts.bak"; \
		ln -sf "$(SCRIPT_DIR)/common/scripts" "$(HOME_DIR)/Scripts"; \
		echo "✅ $(HOME_DIR)/Scripts -> $(SCRIPT_DIR)/common/scripts (created, original backed up)"; \
	else \
		ln -sf "$(SCRIPT_DIR)/common/scripts" "$(HOME_DIR)/Scripts"; \
		echo "✅ $(HOME_DIR)/Scripts -> $(SCRIPT_DIR)/common/scripts (created)"; \
	fi

# Language environment directories to detect and relocate
# Note: Some directories (like 'go' and 'R') will be hidden with dots when symlinked
LANG_PATTERNS := go R .cargo .rustup .npm .yarn .gradle .m2 .julia .pyenv .rbenv .nvm .conda .miniconda3 .anaconda3 .poetry .pipenv .deno .bun node_modules .local/share/pnpm .cache/pip .gem .rvm .ghc .stack .cabal .opam .mix .hex _build .nuget .dotnet .composer vendor

# Function to convert directory names to hidden versions for symlinking
define make_hidden
$(if $(filter go R node_modules vendor,$(1)),.$(1),$(1))
endef

link-langs: ## Automatically detect and link language directories to Developer/langs
	@echo "🔍 Detecting language environment directories..."
	@mkdir -p "$(HOME_DIR)/Developer/langs"
	@found_dirs=0; \
	for pattern in $(LANG_PATTERNS); do \
		if [ -e "$(HOME_DIR)/$$pattern" ] && [ ! -L "$(HOME_DIR)/$$pattern" ]; then \
			found_dirs=$$((found_dirs + 1)); \
			echo "📁 Found: $$pattern"; \
			target_dir="$(HOME_DIR)/Developer/langs/$$pattern"; \
			mkdir -p "$$(dirname "$$target_dir")"; \
			echo "🚀 Moving $(HOME_DIR)/$$pattern -> $$target_dir"; \
			mv "$(HOME_DIR)/$$pattern" "$$target_dir"; \
			case "$$pattern" in \
				"go"|"R"|"node_modules"|"vendor") \
					hidden_name=".$$pattern"; \
					echo "🔗 Linking $$target_dir -> $(HOME_DIR)/$$hidden_name (hidden)"; \
					ln -sf "$$target_dir" "$(HOME_DIR)/$$hidden_name"; \
					echo "✅ $$pattern relocated and linked as $$hidden_name"; \
					;; \
				*) \
					echo "🔗 Linking $$target_dir -> $(HOME_DIR)/$$pattern"; \
					ln -sf "$$target_dir" "$(HOME_DIR)/$$pattern"; \
					echo "✅ $$pattern relocated and linked"; \
					;; \
			esac \
		elif [ -L "$(HOME_DIR)/$$pattern" ]; then \
			existing_target=$$(readlink "$(HOME_DIR)/$$pattern"); \
			expected_target="$(HOME_DIR)/Developer/langs/$$pattern"; \
			if [ "$$existing_target" = "$$expected_target" ]; then \
				echo "✅ $$pattern (already linked correctly)"; \
			else \
				echo "⚠️  $$pattern (linked to $$existing_target, expected $$expected_target)"; \
			fi \
		elif [ -L "$(HOME_DIR)/.$$pattern" ] && echo "go R node_modules vendor" | grep -q "$$pattern"; then \
			existing_target=$$(readlink "$(HOME_DIR)/.$$pattern"); \
			expected_target="$(HOME_DIR)/Developer/langs/$$pattern"; \
			if [ "$$existing_target" = "$$expected_target" ]; then \
				echo "✅ .$$pattern (already linked correctly, hidden)"; \
			else \
				echo "⚠️  .$$pattern (linked to $$existing_target, expected $$expected_target)"; \
			fi \
		fi \
	done; \
	if [ $$found_dirs -eq 0 ]; then \
		echo "ℹ️  No language directories found to relocate"; \
	else \
		echo "🎉 Relocated $$found_dirs language directories to Developer/langs/"; \
	fi; \
	echo "⚙️  Updating shell environment variables..."; \
	for shell_config in ".zshrc" ".bashrc"; do \
		if [ -f "$(SCRIPT_DIR)/common/$$shell_config" ]; then \
			if ! grep -q "Developer/langs" "$(SCRIPT_DIR)/common/$$shell_config"; then \
				echo "" >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo "# Language environment directories relocated to Developer/langs" >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export GOPATH="$$HOME/.go"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export CARGO_HOME="$$HOME/Developer/langs/.cargo"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export RUSTUP_HOME="$$HOME/Developer/langs/.rustup"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export NPM_CONFIG_CACHE="$$HOME/Developer/langs/.npm"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export R_LIBS_USER="$$HOME/.R"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export JULIA_DEPOT_PATH="$$HOME/Developer/langs/.julia"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export PYENV_ROOT="$$HOME/Developer/langs/.pyenv"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export RBENV_ROOT="$$HOME/Developer/langs/.rbenv"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export NVM_DIR="$$HOME/Developer/langs/.nvm"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export POETRY_HOME="$$HOME/Developer/langs/.poetry"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export DENO_INSTALL="$$HOME/Developer/langs/.deno"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export BUN_INSTALL="$$HOME/Developer/langs/.bun"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export GEM_HOME="$$HOME/Developer/langs/.gem"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo 'export STACK_ROOT="$$HOME/Developer/langs/.stack"' >> "$(SCRIPT_DIR)/common/$$shell_config"; \
				echo "✅ Added environment variables to $$shell_config"; \
			else \
				echo "✅ Environment variables already present in $$shell_config"; \
			fi \
		fi \
	done

scan-langs: ## Scan for language directories without moving them
	@echo "🔍 Scanning for language environment directories..."
	@found_dirs=0; \
	for pattern in $(LANG_PATTERNS); do \
		if [ -e "$(HOME_DIR)/$$pattern" ]; then \
			found_dirs=$$((found_dirs + 1)); \
			if [ -L "$(HOME_DIR)/$$pattern" ]; then \
				existing_target=$$(readlink "$(HOME_DIR)/$$pattern"); \
				echo "🔗 $$pattern -> $$existing_target (symlinked)"; \
			else \
				size=$$(du -sh "$(HOME_DIR)/$$pattern" 2>/dev/null | cut -f1 || echo "?"); \
				echo "📁 $$pattern ($$size, not symlinked)"; \
			fi \
		fi \
	done; \
	if [ $$found_dirs -eq 0 ]; then \
		echo "ℹ️  No language directories found"; \
	else \
		echo "📊 Found $$found_dirs language directories total"; \
	fi
