printf '\33c\e[3J'  # hide 'last login' message

source_if_exists () {
    if test -r "$1"; then
        source "$1"
    fi
}

<<<<<<< HEAD
source_if_exists $HOME/.env
source_if_exists $HOME/.zsh/util.zsh
source_if_exists $HOME/.zsh/history.zsh
source_if_exists $HOME/.zsh/aliases.zsh
source_if_exists $HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source_if_exists $HOME/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
=======
source_if_exists /home/$USER/zsh/util.zsh
source_if_exists /home/$USER/zsh/history.zsh
source_if_exists /home/$USER/zsh/aliases.zsh
source_if_exists /home/$USER/zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source_if_exists /home/$USER/zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
>>>>>>> 4c744880 (:sparkles: update zsh config)

precmd() {
    source $HOME/.zsh/aliases.zsh
    source $HOME/dotfiles/zsh/zshmusic/zshmusic.zsh
}

# brew
PATH=$PATH:/opt/homebrew/bin

# zoxide
eval "$(zoxide init zsh)"

# fzf
eval "$(fzf --zsh)"

# starship
eval "$(starship init zsh)"

neofetch

