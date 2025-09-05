#!/usr/bin/make -f

# Simplified Dotfiles Makefile using GNU Stow
# Eliminates circular symlink issues and complex custom logic

SHELL := /bin/bash
DOTFILES_DIR := $(shell pwd)
STOW := stow

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

.PHONY: help install uninstall restow adopt status clean doctor backup-packages restore-packages preview list-packages bootstrap base archlinux darwin rstudio

# Default target
help: ## Show this help message
	@echo "Simplified Dotfiles Management using GNU Stow"
	@echo ""
	@echo "Detected platform: $(PLATFORM)"
	@echo "Dotfiles directory: $(DOTFILES_DIR)"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# === CORE INSTALLATION TARGETS ===

install: ## Install dotfiles for detected platform
	@echo "🔧 Installing dotfiles for platform: $(PLATFORM)"
	@echo "📂 Using stow to create symlinks..."
	@$(STOW) --target=$(HOME) base
	@if [ "$(PLATFORM)" != "unknown" ] && [ -d "$(PLATFORM)" ]; then \
		$(STOW) --target=$(HOME) $(PLATFORM); \
		echo "✅ Installed base and $(PLATFORM) configurations"; \
	else \
		echo "✅ Installed base configuration only"; \
	fi

adopt: ## Adopt existing files into dotfiles (use with caution)
	@echo "🔄 Adopting existing files into dotfiles..."
	@echo "⚠️  This will move existing files into the dotfiles directory"
	@$(STOW) --target=$(HOME) --adopt base
	@if [ "$(PLATFORM)" != "unknown" ] && [ -d "$(PLATFORM)" ]; then \
		$(STOW) --target=$(HOME) --adopt $(PLATFORM); \
	fi
	@echo "✅ Files adopted - check git status for changes"

uninstall: ## Remove all dotfiles symlinks
	@echo "🗑️ Uninstalling dotfiles..."
	@$(STOW) --target=$(HOME) --delete base || true
	@if [ "$(PLATFORM)" != "unknown" ] && [ -d "$(PLATFORM)" ]; then \
		$(STOW) --target=$(HOME) --delete $(PLATFORM) || true; \
	fi
	@echo "✅ Dotfiles uninstalled"

restow: ## Restow (useful after adding new files)
	@echo "🔄 Restowing dotfiles..."
	@$(MAKE) --no-print-directory uninstall
	@$(MAKE) --no-print-directory install

status: ## Show current symlink status
	@echo "🔍 Dotfiles Status Report"
	@echo "Platform: $(PLATFORM)"
	@echo "Dotfiles directory: $(DOTFILES_DIR)"
	@echo ""
	@echo "Checking stow packages:"
	@echo "  📦 base package:"
	@if [ -d "base" ]; then \
		echo "    ✅ base/ directory exists"; \
		file_count=$$(find base -type f | wc -l); \
		echo "    📄 $$file_count files"; \
	else \
		echo "    ❌ base/ directory missing"; \
	fi
	@echo "  📦 $(PLATFORM) package:"
	@if [ -d "$(PLATFORM)" ]; then \
		echo "    ✅ $(PLATFORM)/ directory exists"; \
		file_count=$$(find $(PLATFORM) -type f | wc -l); \
		echo "    📄 $$file_count files"; \
	else \
		echo "    ❌ $(PLATFORM)/ directory missing"; \
	fi

# === PLATFORM-SPECIFIC TARGETS ===

archlinux: ## Force install Arch Linux dotfiles
	@echo "🐧 Installing Arch Linux dotfiles..."
	@$(STOW) --target=$(HOME) base
	@$(STOW) --target=$(HOME) archlinux
	@echo "✅ Arch Linux dotfiles installed"

darwin: ## Force install macOS dotfiles
	@echo "🍎 Installing macOS dotfiles..."
	@$(STOW) --target=$(HOME) base
	@$(STOW) --target=$(HOME) darwin
	@echo "✅ macOS dotfiles installed"

base: ## Install only base dotfiles
	@echo "📦 Installing base dotfiles..."
	@$(STOW) --target=$(HOME) base
	@echo "✅ Base dotfiles installed"

# === PACKAGE MANAGEMENT TARGETS ===

backup-packages: ## Export and backup package lists to platform directory
	@if [ "$(PLATFORM)" != "archlinux" ]; then \
		echo "❌ Package backup only supported on Arch Linux"; \
		exit 1; \
	fi
	@echo "📦 Exporting package lists..."
	@mkdir -p $(PLATFORM)/packages
	@pacman -Qqe > $(PLATFORM)/packages/pkglist.txt
	@if command -v yay >/dev/null 2>&1; then \
		yay -Qm > $(PLATFORM)/packages/aurlist.txt; \
		echo "✅ Exported pacman packages -> $(PLATFORM)/packages/pkglist.txt"; \
		echo "✅ Exported AUR packages -> $(PLATFORM)/packages/aurlist.txt"; \
	else \
		echo "✅ Exported pacman packages -> $(PLATFORM)/packages/pkglist.txt"; \
		echo "⚠️  yay not found; skipping aurlist.txt"; \
	fi

restore-packages: ## Install packages from backup lists in platform directory
	@if [ "$(PLATFORM)" != "archlinux" ]; then \
		echo "❌ Package restore only supported on Arch Linux"; \
		exit 1; \
	fi
	@echo "📥 Restoring pacman packages..."
	@if [ -f $(PLATFORM)/packages/pkglist.txt ]; then \
		sudo pacman -S --needed - < $(PLATFORM)/packages/pkglist.txt; \
	else \
		echo "❌ $(PLATFORM)/packages/pkglist.txt not found"; \
	fi
	@echo "📥 Restoring AUR packages..."
	@if command -v yay >/dev/null 2>&1 && [ -f $(PLATFORM)/packages/aurlist.txt ]; then \
		awk '{print $$1}' $(PLATFORM)/packages/aurlist.txt | yay -S --needed -; \
	else \
		echo "⚠️  yay or $(PLATFORM)/packages/aurlist.txt missing; skipping AUR restore"; \
	fi
	@echo "✅ Packages restored."

# === UTILITY TARGETS ===

clean: uninstall ## Alias for uninstall

doctor: ## Run comprehensive health check
	@echo "🏥 Running dotfiles health check..."
	@echo ""
	@echo "Platform detection:"
	@echo "  Current platform: $(PLATFORM)"
	@echo ""
	@echo "Available stow packages:"
	@for dir in base archlinux darwin; do \
		if [ -d "$$dir" ]; then \
			file_count=$$(find $$dir -type f 2>/dev/null | wc -l); \
			echo "  ✅ $$dir/ ($$file_count files)"; \
		else \
			echo "  ❌ $$dir/ (missing)"; \
		fi \
	done
	@echo ""
	@echo "Stow availability:"
	@if command -v stow >/dev/null 2>&1; then \
		echo "  ✅ stow ($$(stow --version | head -1))"; \
	else \
		echo "  ❌ stow (missing - install with your package manager)"; \
	fi
	@echo ""
	@echo "Package manager availability:"
	@if command -v pacman >/dev/null 2>&1; then echo "  ✅ pacman"; else echo "  ❌ pacman"; fi
	@if command -v yay >/dev/null 2>&1; then echo "  ✅ yay"; else echo "  ❌ yay"; fi
	@if command -v brew >/dev/null 2>&1; then echo "  ✅ brew"; else echo "  ❌ brew"; fi

preview: ## Preview what stow would do (dry run)
	@echo "🔍 Previewing stow operations (dry run)..."
	@echo "Base package:"
	@$(STOW) --target=$(HOME) --no base || echo "  (no changes needed)"
	@if [ "$(PLATFORM)" != "unknown" ] && [ -d "$(PLATFORM)" ]; then \
		echo "$(PLATFORM) package:"; \
		$(STOW) --target=$(HOME) --no $(PLATFORM) || echo "  (no changes needed)"; \
	fi

list-packages: ## List available stow packages
	@echo "Available stow packages:"
	@for dir in */; do \
		if [ -d "$$dir" ] && [ "$${dir%/}" != ".git" ] && [ "$${dir%/}" != "wallpapers" ] && [ "$${dir%/}" != "misc" ]; then \
			file_count=$$(find "$$dir" -type f 2>/dev/null | wc -l); \
			echo "  📦 $${dir%/}/ ($$file_count files)"; \
		fi \
	done

bootstrap: ## Complete setup: restore packages, then install dotfiles
	@echo "🚀 Starting bootstrap process..."
	@if [ "$(PLATFORM)" = "archlinux" ] && [ -f "$(PLATFORM)/packages/pkglist.txt" ]; then \
		$(MAKE) --no-print-directory restore-packages; \
	else \
		echo "⚠️  Skipping package restore (not Arch Linux or no package lists found)"; \
	fi
	@$(MAKE) --no-print-directory install
	@echo "🎉 Bootstrap complete!"

rstudio: ## Install RStudio Desktop from AUR (binary package)
	@echo "📦 Installing RStudio Desktop from AUR..."
	@echo "📥 Cloning rstudio-desktop-bin from AUR..."
	@if [ -d "../rstudio-desktop-bin" ]; then \
		echo "⚠️  Removing existing rstudio-desktop-bin directory..."; \
		rm -rf ../rstudio-desktop-bin; \
	fi
	@cd .. && git clone https://aur.archlinux.org/rstudio-desktop-bin.git
	@echo "🏗️  Building package with makepkg..."
	@cd ../rstudio-desktop-bin && makepkg -s
	@echo "📦 Installing built package..."
	@cd ../rstudio-desktop-bin && sudo pacman -U rstudio-desktop-bin-*.pkg.tar.zst
	@echo "🔧 Installing required dependency..."
	@sudo pacman -S --needed --noconfirm openssl-1.1
	@echo "✅ RStudio installation complete!"