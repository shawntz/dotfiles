if type git > /dev/null; then
    git clone https://github.com/shawntschwartz/dotfiles ~/dotfiles
    chmod +x ~/dotfiles
    cd ~/dotfiles
    ./install.sh
fi
