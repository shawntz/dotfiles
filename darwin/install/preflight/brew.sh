#!/bin/zsh

# Install build tools
if ! command -v brew >/dev/null 2>&1; then \
    echo "Installing Homebrew..."; \
	/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
fi

# Configure homebrew
echo "Configuring shell environment for Homebrew..."
echo 'eval "$$($(HOMEBREW_PREFIX)/bin/brew shellenv)"' >> $(HOME)/.zprofile
eval "$$($(HOMEBREW_PREFIX)/bin/brew shellenv)"
echo "Homebrew setup complete!"
echo "Homebrew installed at: $(HOMEBREW_PREFIX)"

# Refresh all repos
brew update && brew upgrade