#!/usr/bin/env bash

fileicon set "/Applications/iTerm.app" $HOME/.init/iTerm2-nord-chevron.icns

cp $HOME/.init/*.ttf /Library/Fonts/

# Install Oh My Zsh
curl -fsSL --output omz_installer.sh \
https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh

# Execute script
zsh omz_installer.sh
rm omz_installer.sh

rm ~/.zshrc
mv ~/.zshrc.pre-oh-my-zsh ~/.zshrc

echo 'export ZSH="$HOME/.oh-my-zsh"' >>~/.zshrc

# Install Powerlevel10k for Oh My Zsh
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git $ZSH_CUSTOM/themes/powerlevel10k
echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >>~/.zshrc

# Load in p10k config file
# p10k configure
echo 'POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true' >>! ~/.zshrc

# Install zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-autosuggestions \
${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

# Install zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# Activate plugins
echo "plugins=(git zsh-syntax-highlighting zsh-autosuggestions)" >>~/.zshrc

# Activate oh-my-zsh
echo "source $ZSH/oh-my-zsh.sh" >>~/.zshrc

# Restart
source ~/.zshrc
