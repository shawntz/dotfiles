# ── dotfiles (macOS / darwin) zshrc ──────────────────────────────────────────
source ~/.zsh/rc

export PATH="$HOME/.local/bin:$PATH"
export GOOGLE_APPLICATION_CREDENTIALS="/Users/shawn.schwartz/Developer/Projects/clementime/psych-10-admin-bots-5ce7b8d04264.json"

# Set locale for R and other applications
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8

# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/opt/homebrew/Caskroom/miniconda/base/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/opt/homebrew/Caskroom/miniconda/base/etc/profile.d/conda.sh" ]; then
        . "/opt/homebrew/Caskroom/miniconda/base/etc/profile.d/conda.sh"
    else
        export PATH="/opt/homebrew/Caskroom/miniconda/base/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<

