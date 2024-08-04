#!/usr/bin/env bash

brew update

brew install cmake
brew install cmatrix
brew install cowsay
brew install eza
brew install fd
brew install ffmpeg
brew install fileicon
brew install folderify
brew install fzf
brew install gcc
brew install gh
brew install gnupg
brew install imagemagick
brew install istat-menus
brew install jsonpp
brew install lazygit
brew install neovim
brew install node
brew install pandoc
brew install php
brew install pinentry-mac
brew install rclone
brew install ripgrep
brew install tmux
brew install trash
brew install tree
brew install tree-sitter
brew install webp
brew install wget
brew install yarn
brew install z
brew install zoxide

brew install --cask alacritty
brew install --cask aldente
brew install --cask alfred
brew install --cask bartender
brew install --cask bibdesk
brew install --cask caffeine
brew install --cask dropbox
brew install --cask evernote
brew install --cask google-chrome
brew install --cask google-drive
brew install --cask hazeover
brew install --cask istat-menus
brew install --cask keycastr
brew install --cask kindle
brew install --cask macdown
brew install --cask mactex
brew install --cask microsoft-auto-update
brew install --cask microsoft-office
brew install --cask microsoft-remote-desktop
brew install --cask middleclick
brew install --cask min
brew install --cask notion
brew install --cask postman
brew install --cask psychopy
brew install --cask rectangle
brew install --cask slack
brew install --cask todoist
brew install --cask visual-studio-code
brew install --cask xquartz
brew install --cask zoom

brew tap homebrew/cask-fonts
brew install font-tex-gyre-pagella
brew install font-tex-gyre-termes
brew install font-meslo-lg-nerd-font

# powerlevel10k term config
brew install powerlevel10k
brew install zsh-autosuggestions
brew install zsh-syntax-highlighting

# start background services
brew services start php

# Remove outdated versions from the cellar.
brew cleanup
