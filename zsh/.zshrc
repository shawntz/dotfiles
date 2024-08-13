source_if_exists () {
    if test -r "$1"; then
        source "$1"
    fi
}

source_if_exists /home/$USER/zsh/history.zsh
source_if_exists /home/$USER/zsh/aliases.zsh

precmd() {
    source /home/$USER/zsh/aliases.zsh
}

eval "$(zoxide init zsh)"
eval "$(fzf --zsh)"
eval "$(starship init zsh)"

xset r rate 200 100

neofetch

# https://juliu.is/a-simple-tmux/
# tat: tmux attach
function tat {
  name=$(basename `pwd` | sed -e 's/\.//g')

  if tmux ls 2>&1 | grep "$name"; then
    tmux attach -t "$name"
  elif [ -f .envrc ]; then
    direnv exec / tmux new-session -s "$name"
  else
    tmux new-session -s "$name"
  fi
}

# todo: source zsh plugins based on pacman install location
