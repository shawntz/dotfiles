# Customized from andrew8088's dotfiles on github

# ALIASES ---------------------------------------------------------------------
alias v='nvim -w ~/.vimlog "$@"'
alias vi='nvim -w ~/.vimlog "$@"'
alias vim='nvim -w ~/.vimlog "$@"'

alias ta='tmux attach -t'

alias vsc="code -g ."

alias cd='z'

alias hg='history | grep'

alias ls='eza --color=always --sort=newest --long --no-filesize --no-user --icons=always --no-permissions'
alias c='clear'
alias s='source ~/.zshrc'
alias jj='pbpaste | jsonpp | pbcopy'
alias rm=trash
alias trim="awk '{\$1=\$1;print}'"

# GIT ALIASES -----------------------------------------------------------------
alias g='lazygit'
alias gss='git status'
alias gc='git commit -S -m'
#alias gco='git checkout'
alias ga='git add'
#alias gb='git branch'
#alias gba='git branch --all'
#alias gbd='git branch -D'
#alias gcp='git cherry-pick'
alias gd='git diff -w'
#alias gds='git diff -w --staged'
#alias grs='git restore --staged'
#alias gst='git rev-parse --git-dir > /dev/null 2>&1 && git status || exa'
#alias gu='git reset --soft HEAD~1'
#alias gpr='git remote prune origin'
#alias ff='gpr && git pull --ff-only'
#alias grd='git fetch origin && git rebase origin/master'
#alias gbb='git-switchbranch'
#alias gbf='git branch | head -1 | xargs' # top branch
#alias gl=pretty_git_log
#alias gla=pretty_git_log_all
#alias git-current-branch="git branch | grep \* | cut -d ' ' -f2"
#alias grc='git rebase --continue'
#alias gra='git rebase --abort'
#alias gec='git status | grep "both modified:" | cut -d ":" -f 2 | trim | xargs nvim -'
#alias gcan='gc --amend --no-edit'

alias gp="git push"
alias gpl="git pull"

#alias gbdd='git-branch-utils -d'
#alias gbuu='git-branch-utils -u'
#alias gbrr='git-branch-utils -r -b develop'
#alias gg='git branch | fzf | xargs git checkout'
#alias gup='git branch --set-upstream-to=origin/$(git-current-branch) $(git-current-branch)'

#alias gnext='git log --ancestry-path --format=%H ${commit}..master | tail -1 | xargs git checkout'
#alias gprev='git checkout HEAD^'

# FUNCTIONS -------------------------------------------------------------------
function take {
    mkdir -p $1
    cd $1
}

extract-audio-and-video () {
    ffmpeg -i "$1" -c:a copy obs-audio.aac
    ffmpeg -i "$1" -c:v copy obs-video.mp4
}

hs () {
 curl https://httpstat.us/$1
}

copy-line () {
  rg --line-number "${1:-.}" | sk --delimiter ':' --preview 'bat --color=always --highlight-line {2} {1}' | awk -F ':' '{print $3}' | sed 's/^\s+//' | pbcopy
}

open-at-line () {
  vim $(rg --line-number "${1:-.}" | sk --delimiter ':' --preview 'bat --color=always --highlight-line {2} {1}' | awk -F ':' '{print "+"$2" "$1}')
}
