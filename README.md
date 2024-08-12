# shawn's dotfiles (for arch linux btw)

## step 0
install `git`
```
sudo pacman -S git --noconfirm
```

## step 0.5
[setup git ssh key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent) if new system

## step 1
clone `dotfiles` to home directory
```
git clone git@github.com:shawntschwartz/dotfiles.git ~/dotfiles
```

## step 2
```
cd ~/dotfiles && mv .extra.template .extra.sh
nvim ~/dotfiles/.extra.sh

# set the following variables within `~/dotfiles/.extra`
GIT_AUTHOR_NAME="Your Name"
GIT_AUTHOR_EMAIL="email@you.com"
GH_USER="nickname"
GPG_KEY="~/.ssh/key.pub"

# then execute `~/dotfiles/.extra` to configure git props
chmod +x ~/dotfiles/.extra.sh && ~/./dotfiles/.extra.sh
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