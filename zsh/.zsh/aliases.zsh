#!/bin/zsh

# ALIASES ---------------------------------------------------------------------
## neovim *********************************************************************
alias vi='fd --type f --hidden --exclude .git | fzf-tmux -m --preview="bat --color=always {}" -p | xargs nvim'
alias v='nvim -w ~/.vimlog "$@"'
alias vim='nvim -w ~/.vimlog "$@"'

## navigation *****************************************************************
alias cl='clear'
alias cd='z'
alias cdi='zi'
alias b='cd ..'
alias bb='cd ../..'
alias bbb='cd ../../..'
alias bbbb='cd ../../../..'
alias ls='eza --all --color=always --sort=name --long --no-user --icons=always --no-permissions'
alias home="cd ~"
alias dots="cd ~/dotfiles"
alias dotfiles="cd ~/dotfiles"
alias dev="cd ~/code"
alias oss="cd ~/code/oss"
alias anl="cd ~/code/anl"
alias desk="cd ~/desktop"
alias docs="cd ~/documents"
alias dl="cd ~/downloads"
alias md="mkdir"
alias t="touch"
alias x="exit"
alias kk='killall kitty'
alias o="open ."
alias restart="sudo reboot"
alias bye="sudo shutdown -r now"
alias get="curl -O -L"
alias ssh="kitty +kitten ssh"

## tools **********************************************************************
alias c="code -g ."
alias s='source ~/.zshrc'
alias trim="awk '{\$1=\$1;print}'"
alias g='lazygit'
alias f='yazi'
alias stfu="osascript -e 'set volume output muted true'"
alias afk="/System/Library/CoreServices/Menu\ Extras/User.menu/Contents/Resources/CGSession -suspend"
alias chromekill="ps ux | grep '[C]hrome Helper --type=renderer' | grep -v extension-process | tr -s ' ' | cut -d ' ' -f2 | xargs kill"
alias rm_ds="find . -name '*.DS_Store' -type f -ls -delete"

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

# some helpful utils from @gretzky
# https://github.com/gretzky/dotfiles/blob/main/zsh/.aliases

# use gitignore.io cmd line tool
gi() {
  curl -L -s https://www.gitignore.io/api/$@
}

# create a remote repo
create-repo() {
  # Get user input
  echo "Enter name for new repo"
  read REPONAME
  echo "Do you want to make it private? (y/n)"
  read -r -n PRIVATE_ANSWER

  if [[ "$PRIVATE_ANSWER" =~ ^[Yy]$ ]]; then
    PRIVATE_TF=true
  else
    PRIVATE_TF=false
  fi

  # Curl some json to the github API oh damn we so fancy
  curl -u shawntschwartz https://api.github.com/user/repos -d "{\"name\": \"$REPONAME\", \"private\": $PRIVATE_TF}" >/dev/null

  # first commit
  git init 1>/dev/null
  gi macos,visualstudiocode >>.gitignore 1>/dev/null
  print_in_green ".gitignore added"
  git add . 1>/dev/null
  git commit -S -m "initial commit" 1>/dev/null
  print_in_green "initial commit"
  git remote add origin https://github.com/shawntschwartz/$REPONAME.git 1>/dev/null
  git push -u origin master --force 1>/dev/null

  sleep 0.5
  print_in_green "\nRepo created"
  print_in_cyan "You can view your new repo at https://github.com/gretzky/$REPONAME.git"
}

# change dir
up() {
  local cdir="$(pwd)"
  if [[ "${1}" == "" ]]; then
    cdir="$(dirname) "${cdir}")"
  elif ! [[ "${1}" =~ ^[0-9]+$ ]]; then
    echo "🛂  Arg must be a number"
  elif ! [[ "${1}" -gt "0" ]]; then
    echo "a POSITIVE number"
  else
    for i in {1..${1}}; do
      local ncdir="$(dirname "${cdir}")"
      if [[ "${cdir}" == "${ncdir}" ]]; then
        break
      else
        cdir="${ncdir}"
      fi
    done
  fi
  cd "${cdir}"
}

# emptytrash() {
#   echo "🗑  Emptying trashes..."
#   sudo rm -rfv /Volumes/*/.Trashes 1>/dev/null
#   rm -rfv ~/.Trash/* 1>/dev/null
#   sudo rm -v /private/var/vm/sleepimage 1>/dev/null
# }

rename-branch() {
  current_name=$1
  new_name=$2

  # rename the branch
  git branch -m $current_name $new_name

  # delete the old branch from remote and push the new name
  git push origin :$current_name $new_name

  # reset the upstream branch for the new_name local branch
  git push origin -u $new_name
}

# animated gifs from any video
# https://gist.github.com/SlexAxton/4989674
gifify() {
  if [[ -n "$1" ]]; then
    if [[ $2 == '--good' ]]; then
      ffmpeg -i "$1" -r 10 -vcodec png out-static-%05d.png
      time convert -verbose +dither -layers Optimize -resize 900x900\> out-static*.png GIF:- | gifsicle --colors 128 --delay=5 --loop --optimize=3 --multifile - >"$1.gif"
      rm out-static*.png
    else
      ffmpeg -i "$1" -s 600x400 -pix_fmt rgb24 -r 10 -f gif - | gifsicle --optimize=3 --delay=3 >"$1.gif"
    fi
  else
    echo "✋  proper usage: gifify <input_movie.mov>. You DO need to include extension."
  fi
}

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

bindkey '^I^I' autosuggest-accept  # tab tab
