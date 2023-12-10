#!/usr/bin/env bash

xcode-select --install

mkdir ~/Developer

brew update

brew install cmake
brew install cmatrix
brew install cowsay
brew install exa
brew install ffmpeg
brew install gcc
brew install gnupg
brew install imagemagick
brew install istat-menus
brew install jsonpp
brew install neovim
brew install node
brew install pandoc
brew install rclone
brew install tmux
brew install trash
brew install tree
brew install tree-sitter
brew install webp
brew install wget
brew install yarn
brew install z

# brew install powerlevel10k
# echo "source $(brew --prefix)/share/powerlevel10k/powerlevel10k.zsh-theme" >>~/.zshrc
# brew install zsh-syntax-highlighting

brew install --cask adobe-creative-cloud
brew install --cask alfred
brew install --cask caffeine
brew install --cask dropbox
brew install --cask firefox
brew install --cask font-tex-gyre-pagella
brew install --cask font-tex-gyre-termes
brew install --cask google-chrome
brew install --cask hazeover
brew install --cask iterm2
brew install --cask keycastr
brew install --cask kindle
brew install --cask mactex
brew install --cask microsoft-office
brew install --cask microsoft-remote-desktop
brew install --cask middleclick
brew install --cask min
brew install --cask notion
brew install --cask obsidian
brew install --cask psychopy
brew install --cask r
brew install --cask rectangle
brew install --cask rstudio
brew install --cask slack
brew install --cask spotify
brew install --cask visual-studio-code
brew install --cask xquartz
brew install --cask zoom
brew install --cask zotero

# Remove outdated versions from the cellar.
brew cleanup
