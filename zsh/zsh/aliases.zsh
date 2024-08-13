# ALIASES ---------------------------------------------------------------------
alias v='nvim -w ~/.vimlog "$@"'
alias vi='nvim -w ~/.vimlog "$@"'
alias vim='nvim -w ~/.vimlog "$@"'
alias vsc="code -g ."
alias cd='z'
alias b='cd ..'
alias bb='cd ../..'
alias bbb='cd ../../..'
alias bbbb='cd ../../../..'
alias hg='history | grep'
alias ls='eza --all --color=always --sort=name --long --no-user --icons=always --no-permissions'
alias c='clear'
alias s='source ~/.zshrc'
alias jj='pbpaste | jsonpp | pbcopy'
alias trim="awk '{\$1=\$1;print}'"
alias g='lazygit'

# FUNCTIONS -------------------------------------------------------------------
function cs () {
  z $1
  eza --all --color=always --sort=name --no-filesize --no-user --icons=always --no-permissions
}

function take {
    mkdir -p $1
    cd $1
}

hs () {
 curl https://httpstat.us/$1
}

copy-line () {
  rg --line-number "${1:-.}" | sk --delimiter ':' --preview 'bat --color=always --highlight-line {2} {1}' | awk -F ':' '{print $3}' | sed 's/^\s+//' | pbcopy
}

open-at-line () {
  nvim $(rg --line-number "${1:-.}" | sk --delimiter ':' --preview 'bat --color=always --highlight-line {2} {1}' | awk -F ':' '{print "+"$2" "$1}')
}
