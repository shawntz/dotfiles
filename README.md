# shawn's dotfiles (for arch linux btw)

## step 1
[setup git ssh key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent) if new system

## step 2
```
cp .extra.template ~/.extra
nvim ~/.extra

# set the following variables within ~/.extra
GIT_AUTHOR_NAME="Your Name"
GIT_AUTHOR_EMAIL="email@you.com"
GH_USER="nickname"
GPG_KEY="~/.ssh/key.pub"
```

## step 3
execute `bootstrap/setdirs.sh`

## step 4
execute `bootstrap/display.sh`

## step 5
`reboot`

## step 6
execute `bootstrap/pacman.sh`

## step 7
`zsh`

## step 8
`stow` dotfiles