if type git > /dev/null; then
    sudo xcodebuild -license
    git clone https://github.com/shawntschwartz/dotfiles ~/dotfiles
    chmod +x ~/dotfiles
    cd ~/dotfiles
    ./install
else
    sudo xcodebuild -license
    curl -LO https://github.com/shawntschwartz/dotfiles/archive/macos.zip
    unzip dotfiles-macos.zip
    rm -rf dotfiles-macos.zip
    mv dotfiles-macos ~/dotfiles
    chmod +x ~/dotfiles
    cd ~/dotfiles
    ./install
fi
