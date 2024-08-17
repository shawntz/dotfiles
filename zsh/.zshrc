source_if_exists () {
    if test -r "$1"; then
        source "$1"
    fi
}

source_if_exists /home/$USER/zsh/util.zsh
source_if_exists /home/$USER/zsh/history.zsh
source_if_exists /home/$USER/zsh/aliases.zsh
source_if_exists /home/$USER/zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source_if_exists /home/$USER/zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

precmd() {
    source /home/$USER/zsh/aliases.zsh
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

