# Customized from andrew8088's dotfiles on github

source_if_exists () {
    if test -r "$1"; then
        source "$1"
    fi
}

source_if_exists $HOME/.env.sh
source_if_exists $DOTFILES/zsh/history.zsh
source_if_exists $DOTFILES/zsh/git.zsh
source_if_exists $DOTFILES/zsh/aliases.zsh
source_if_exists $DOTFILES/zsh/gpgclient.zsh

precmd() {
    source $DOTFILES/zsh/aliases.zsh
}
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
plugins=(git zsh-syntax-highlighting zsh-autosuggestions)
source /Users/shawn/.oh-my-zsh/oh-my-zsh.sh
