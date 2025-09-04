# All the default Omarchy aliases and functions
# (don't mess with these directly, just overwrite them here!)
source ~/.local/share/omarchy/default/bash/rc

# Add your own exports, aliases, and functions here.
#
# Make an alias for invoking commands you use constantly
# alias p='python'
#
alias backup='make -f ~/.bootstrap/Makefile backup-packages backup-configs'

# fzf shortcuts for file operations
alias fe='nvim $(fzf)'              # Edit selected file with neovim
alias fv='bat $(fzf)'               # View selected file with bat
alias fc='cp $(fzf) .'              # Copy selected file to current directory
alias fr='rm -i $(fzf)'             # Remove selected file with confirmation

# Multi-purpose fzf function
fdo() {
  local file=$(fzf --preview 'bat --style=numbers --color=always {}')
  if [[ -n "$file" ]]; then
    case "$1" in
      edit|e) nvim "$file" ;;
      view|v) bat "$file" ;;
      copy|c) cp "$file" "${2:-.}" ;;
      *) echo "Usage: fdo [edit|view|copy] [destination]" ;;
    esac
  fi
}

# Use VSCode instead of neovim as your default editor
# export EDITOR="code"
#
# Set a custom prompt with the directory revealed (alternatively use https://starship.rs)
# PS1="\W \[\e]0;\w\a\]$PS1"

. "$HOME/.local/share/../bin/env"
. "$HOME/.cargo/env"
