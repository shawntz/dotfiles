# shawn's dotfiles (for arch linux btw)

## step 0
install `git`
```
sudo pacman -S git -y
```

## step 0.5
clone `dotfiles` to home directory
```
git clone git@github.com:shawntschwartz/dotfiles.git ~/
```

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
```
chmod +x ~/dotfiles/bootstrap/setdirs.sh && ~/./dotfiles/bootstrap/setdirs.sh
```

## step 4
execute `bootstrap/display.sh`
```
chmod +x ~/dotfiles/bootstrap/display.sh && ~/./dotfiles/bootstrap/display.sh
```

## step 5
`reboot` system
```
reboot
```

## step 6
execute `bootstrap/pacman.sh`
```
chmod +x ~/dotfiles/bootstrap/pacman.sh && ~/./dotfiles/bootstrap/pacman.sh
```

## step 7
set `zsh` as default shell
```
zsh
```

## step 8
`stow` dotfiles