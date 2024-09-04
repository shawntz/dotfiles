if type git > /dev/null; then
    git clone https://github.com/shawntschwartz/dotfiles ~/dotfiles
    chmod +x ~/dotfiles
    cd ~/dotfiles
    ./install
else
    curl -LO https://github.com/shawntschwartz/dotfiles/archive/ubuntu.zip
    unzip dotfiles-ubuntu.zip
    rm -rf dotfiles-ubuntu.zip
    mv dotfiles-ubuntu ~/dotfiles
    chmod +x ~/dotfiles
    cd ~/dotfiles
    ./install
fi
