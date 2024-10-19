printf '\33c\e[3J'  # hide 'last login' message

source_if_exists () {
    if test -r "$1"; then
        source "$1"
    fi
}

source_if_exists $HOME/.env
source_if_exists $HOME/.zsh/util.zsh
source_if_exists $HOME/.zsh/history.zsh
source_if_exists $HOME/.zsh/aliases.zsh
source_if_exists $HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source_if_exists $HOME/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

precmd() {
    source $HOME/.zsh/aliases.zsh
}

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS-specific settings
    PATH=$PATH:/opt/homebrew/bin
    eval "$(zoxide init zsh)"
    eval "$(fzf --zsh)"
    eval "$(starship init zsh)"

elif [[ "$(uname)" == "Linux" ]]; then
    # Linux-specific settings
    export PATH="/usr/local/bin:$PATH"
    [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
    eval "$(starship init zsh)"
    # Created by `pipx` on 2024-09-04 16:11:33
    export PATH="$PATH:/home/shawn/.local/bin"
    source $HOME/.cargo/env
    export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"
    export RIG_PLATFORM="ubuntu-22.04"
    eval "$(zoxide init zsh)"

else
    echo "Unknown OS"
fi

neofetch
