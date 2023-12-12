# shawn's dotfiles

## setup steps (for a fresh macos install)👨🏼‍💻

1. `mkdir -p ~/Developer/repos`
2. [setup git ssh key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)
3. setup git config name/email params
    > git config --global user.name "John Doe"
    
    > git config --global user.email johndoe@example.com
5. `git clone git@github.com:ShawnTylerSchwartz/dotfiles.git ~/Developer/repos/dotfiles`
6. `cd ~/Developer/repos/dotfiles && chmod +x brew/install.sh && ./brew/install.sh`
7. `chmod +x install/install-deps.sh && ./install/install-deps.sh`
8. configure gpg signing key with git
9. `chmod +x install/bootstrap.sh && ./install/bootstrap.sh`
10. `chmod +x iterm/install.sh && ./iterm/install.sh`
11. manually load in [iterm/iterm.json](iterm/iterm.json) config file into `iTerm.app`
12. `chmod +x vscode/config.sh && ./vscode/config.sh`
13. `chmod +x install/macos.sh && ./install/macos.sh`
14. restart computer and enjoy 😎

## other apps to install (not from package managers)

- [x] [Mango MRI viewer](https://mangoviewer.com/downloads/mango_mac.zip)
- [x] [MATLAB](https://www.mathworks.com/downloads/web_downloads/)
- [x] [Cisco AnyConnect VPN client](https://uit.stanford.edu/sites/default/files/installers/anyconnect/mac/InstallAnyConnect4.10.pkg)
- [x] [Apple Xcode (not through app store)](https://developer.apple.com/download/all/)
- [x] [Apple SF Symbols](https://developer.apple.com/sf-symbols/)
- [x] [Things 3](https://culturedcode.com/things/mac/appstore/)
- [x] [Onigiri - Minimal Timer](https://apps.apple.com/us/app/onigiri-minimal-timer/id1639917298?mt=12)

## thanks to...

* [@mathiasbynens](https://github.com/mathiasbynens/dotfiles)
* [@andrew8088](https://github.com/andrew8088/dotfiles)
* [@narze](https://github.com/narze/dotfiles)
* [@dhanishgajjar](https://github.com/dhanishgajjar/vscode-icons)
* [@jasonlong](https://github.com/jasonlong/iterm2-icons)
* [8K wallpaper](https://www.wallpaperflare.com/untitled-night-mountains-landscape-dark-minimal-4k-8k-wallpaper-saazn/download)
