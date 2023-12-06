#!/usr/bin/env bash

# Install Oh My Zsh
curl -fsSL --output omz_installer.sh
https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh

# Execute script
zsh omz_installer.sh

# Install Powerlevel10k for Oh My Zsh
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git $ZSH_CUSTOM/themes/powerlevel10k
echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >>~/.zshrc

# Load in p10k config file
p10k configure

# Install zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-autosuggestions \
${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

# Install zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# Activate plugins
echo "plugins=(git zsh-syntax-highlighting zsh-autosuggestions)" >>~/.zshrc

# Restart
source ~/.zshrc