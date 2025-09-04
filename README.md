
# 🗂️ Dotfiles (Bare Repo + Omarchy/Arch)

[![Arch Linux](https://img.shields.io/badge/OS-Arch_Linux-1793D1?logo=arch-linux&logoColor=white)](https://archlinux.org)
[![macOS Compatible](https://img.shields.io/badge/OS-macOS-000000?logo=apple&logoColor=white)](https://apple.com/macos)
[![Package Manager](https://img.shields.io/badge/Pacman-Enabled-00457C?logo=arch-linux&logoColor=white)](https://wiki.archlinux.org/title/Pacman)
[![AUR](https://img.shields.io/badge/AUR-yay-1793D1?logo=arch-linux&logoColor=white)](https://aur.archlinux.org)
[![Omarchy](https://img.shields.io/badge/Setup-Omarchy-FF4088?logo=linux&logoColor=white)](https://world.hey.com/dhh/omarchy-is-out-4666dd31)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

These are my personal dotfiles for **Arch Linux with Omarchy + Hyprland**.  
They include an `install.sh` script and a `Makefile` for comprehensive dotfiles management including symlink creation, package backup/restore, and system configuration.

---

## 🚀 First-Time Install

On a new machine, run:

```bash
git clone https://github.com/shawntz/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
make bootstrap
```

This will:

1. Install packages from backup lists (if on Arch Linux)
2. Create symlinks for all configuration files and directories  
3. Handle conflicts by backing up existing files

After installation, manage dotfiles with standard git commands in the dotfiles directory.

---

## 🔍 Available Commands

Run `make help` to see all available targets:

```
Enhanced Dotfiles Management

Detected platform: archlinux
Dotfiles directory: /home/sts/Developer/dotfiles

Core targets:
  help                 Show this help message
  install              Install dotfiles for detected platform using install.sh
  fresh-install        Simulate fresh install with safety checks - skips existing good symlinks
  uninstall            Remove all dotfiles symlinks using uninstall.sh
  status               Show current symlink status with detailed checking
  archlinux            Force install Arch Linux dotfiles
  darwin               Force install macOS dotfiles  
  common               Install only common dotfiles
  backup-packages      Export and backup package lists to platform directory
  restore-packages     Install packages from backup lists in platform directory
  backup-configs       Backup configuration files and directories to platform directory
  fix-local-share      Fix .local/share directory symlinking for current platform
  list-platforms       List available platforms
  bootstrap            Complete setup: restore packages, then fresh-install dotfiles
  validate             Validate all symlinks and report issues
  doctor               Run comprehensive health check
  clean                Alias for uninstall
  setup-keyd           Setup keyd keyboard remapping service (Arch Linux only)
  setup-apple-emoji    Setup Apple emoji font support (Arch Linux only)
  link-wallpapers      Create symlink for wallpapers directory
  link-scripts         Create symlink for scripts directory
  link-langs           Automatically detect and link language directories to Developer/langs
  scan-langs           Scan for language directories without moving them
```

---

> [!IMPORTANT]
>
> - Any pre-existing files that conflict during installation are automatically backed up with `.bak` extension.
>
> - Sensitive material (`~/.ssh`, API keys, tokens) should not be committed. **Be sure to store those securely elsewhere.**
>
> - Edit `CONFIG_DIRS` / `CONFIG_FILES` in the Makefile to match _your_ setup (Hyprland, Waybar, Alacritty, Neovim, etc.).
>
> Out-of-the-box, the package backup includes:
>
> - `pkglist.txt` → explicitly installed Pacman packages.
> - `aurlist.txt` → explicitly installed AUR packages (via Yay).

---

## ✅ Quick Reference

```bash
# Check symlink status
make status

# Install/update dotfiles with safety checks  
make fresh-install

# Backup packages & configs
make backup-packages
make backup-configs

# Complete setup on a new machine
make bootstrap

# Validate installation
make validate

# Run health check
make doctor

# Special directory management
make link-wallpapers     # Link ~/Pictures/wallpapers to dotfiles/wallpapers
make link-scripts        # Link ~/Scripts to dotfiles/common/scripts
make scan-langs          # Preview language directories that can be moved
make link-langs          # Move & hide language dirs in ~/Developer/langs/
```

---

## 📂 Example File Tree

```text
.
├── Makefile
├── install.sh
├── common/
│   ├── .config/
│   │   └── nvim/
│   │       └── init.lua
│   ├── .gitconfig
│   ├── .zshrc
│   └── .profile
├── archlinux/
│   ├── .config/
│   │   ├── hypr/
│   │   │   └── hyprland.conf
│   │   ├── waybar/
│   │   │   └── config
│   │   └── alacritty/
│   │       └── alacritty.yml
│   ├── .bashrc
│   ├── pkglist.txt
│   └── aurlist.txt
└── darwin/
    ├── .config/
    │   └── sketchybar/
    │       └── sketchybarrc
    └── .zshrc

