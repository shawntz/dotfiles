
# 🗂️ Dotfiles (Bare Repo + Omarchy/Arch)

[![Arch Linux](https://img.shields.io/badge/OS-Arch_Linux-1793D1?logo=arch-linux&logoColor=white)](https://archlinux.org)
[![macOS Compatible](https://img.shields.io/badge/OS-macOS-000000?logo=apple&logoColor=white)](https://apple.com/macos)
[![Package Manager](https://img.shields.io/badge/Pacman-Enabled-00457C?logo=arch-linux&logoColor=white)](https://wiki.archlinux.org/title/Pacman)
[![AUR](https://img.shields.io/badge/AUR-yay-1793D1?logo=arch-linux&logoColor=white)](https://aur.archlinux.org)
[![Omarchy](https://img.shields.io/badge/Setup-Omarchy-FF4088?logo=linux&logoColor=white)](https://world.hey.com/dhh/omarchy-is-out-4666dd31)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

These are my personal dotfiles for **Arch Linux with Omarchy + Hyprland**.  
They’re managed with a **bare Git repo** at `~/.dotfiles`, which keeps `$HOME` clean while tracking only the files I choose.  

A small bootstrap lives in `.bootstrap/` with an `install.sh` script and a `Makefile` for backup/restore.

---

## 🚀 First-Time Install

On a new machine, just run:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/shawntz/dotfiles/master/.bootstrap/install.sh)"
```

This will:

1. Install a `config` shim at `~/.local/bin/config`.

2. Clone the bare repo into `~/.dotfiles`.

3. Configure it to hide untracked files.

4. Back up any conflicting files and then check out your tracked dotfiles into `$HOME`.

After this, run all dotfile commands with:

```bash
config status
config add .bashrc
config commit -m "Update bashrc"
config push
```

---

## 🔧 Overriding the Repo URL

By default, `install.sh` has the remote URL baked in (`git@github.com:shawntz/dotfiles.git`).

If you want to clone from a fork, use HTTPS instead of SSH, or test a branch, override it inline:

```bash
REMOTE_URL=https://github.com/{you}/dotfiles.git bash -c "$(wget -qO- https://raw.githubusercontent.com/{you}/dotfiles/master/.bootstrap/install.sh)"
```

---

## 🔍 List available targets

```bash
make -f ~/.bootstrap/Makefile help
```

---

## 📦 Backup

```bash
# export pacman + yay package lists → commit & push
make -f ~/.bootstrap/Makefile backup-packages

# add config dirs/files → commit & push
make -f ~/.bootstrap/Makefile backup-configs
```

---

## 🔄 Restore

```bash
# reinstall pacman + yay packages
make -f ~/.bootstrap/Makefile restore-packages

# checkout tracked dotfiles into $HOME
make -f ~/.bootstrap/Makefile restore-dotfiles
```

---

## 🚀 One-Shot

```bash
# restore packages, then dotfiles
make -f ~/.bootstrap/Makefile bootstrap
```

---

> [!IMPORTANT]
>
> - Any pre-existing files that conflict on first checkout are automatically backed up to a folder like `~/.dotfiles-backup-<timestamp>`.
>
> - Sensitive material (`~/.ssh`, API keys, tokens) should not be committed. **Be sure to store those securely elsewhere.**
>
> - Edit `.bootstrap/Makefile` `CONFIG_DIRS` / `CONFIG_FILES` to match _your_ setup (Hyprland, Waybar, Kitty, Neovim, etc.).
>
> Out-of-the-box, the package backup includes:
>
> - `pkglist.txt` → explicitly installed Pacman packages.
> - `aurlist.txt` → explicitly installed AUR packages (via Yay).

---

## ✅ Quick Reference

```bash
# check repo status
config status

# add + commit + push dotfiles
config add .zshrc .config/hypr/hyprland.conf
config commit -m "Update Hyprland config"
config push

# backup packages & configs
make -f ~/.bootstrap/Makefile backup-packages
make -f ~/.bootstrap/Makefile backup-configs

# restore everything on a new machine
make -f ~/.bootstrap/Makefile bootstrap
```

---

## 📂 Example File Tree

```text
.
├── .bootstrap/
│   ├── Makefile
│   └── install.sh
├── .config/
│   ├── hypr/
│   │   └── hyprland.conf
│   ├── waybar/
│   │   └── config
│   ├── kitty/
│   │   └── kitty.conf
│   ├── nvim/
│   │   └── init.vim
│   └── dunst/
│       └── dunstrc
├── .gitconfig
├── .bashrc
├── pkglist.txt
└── aurlist.txt

