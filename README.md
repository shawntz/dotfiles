# shawn's (declarative) nix/flakes macos dotfiles 👨🏼‍💻

## info
this `main` branch of my `dotfiles` repo contains my latest attempt at bootstrapping macos with (mostly) declarative configs. here, i use `nix-darwin` and  `nix-flakes`, along with as few instances of `stow` to avoid porting certain configs (like `neovim`) into flakes.

## devices
- mac studio m2 ultra running `macos sequoia 15.2`
- macbook pro m3 max running `macos sequoia 15.2`

## useful commands when running initial setup
- `xcode-select —install`
- `softwareupdate --install-rosetta`
- `chsh -s /run/current-system/sw/bin/fish`
- `eval (ssh-agent -c)`
- `darwin-rebuild switch --flake ~/Nix`
- for lsps (tailwindcss):
  - `sudo chown -R 501:20 "~/.npm"`
  - `npm install -g @tailwindcss/language-server`

## other notes
- download `R` lang directly from CRAN (instead of from Nix/Nix Brew) so that library is exposed for `R.nvim`
- download `R` lang server through CRAN to facilitate autocompletions in nvim:
```r
install.packages("languageserver")
```
