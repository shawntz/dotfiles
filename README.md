# 🗂️ dotfiles (omarchy/arch + macos)

[![Arch Linux](https://img.shields.io/badge/Arch-Linux-1793D1?logo=arch-linux&logoColor=white)](https://archlinux.org)
[![Omarchy](https://img.shields.io/badge/Omarchy-FF4088?logo=linux&logoColor=white)](https://learn.omacom.io/2/the-omarchy-manual)
[![Hyprland](https://img.shields.io/badge/Hyprland-01A7D6?logo=hyprland&logoColor=white)](https://hypr.land/)
[![Package Manager](https://img.shields.io/badge/pacman-00457C?logo=arch-linux&logoColor=white)](https://wiki.archlinux.org/title/Pacman)
[![AUR](https://img.shields.io/badge/AUR-yay-1793D1?logo=arch-linux&logoColor=white)](https://aur.archlinux.org)
[![macOS](https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white)](https://apple.com/macos)
[![homebrew](https://img.shields.io/badge/homebrew-513D23?logo=homebrew&logoColor=white)](https://brew.sh)
[![GNU Stow](https://img.shields.io/badge/GNU_Stow-blue?logo=gnu&logoColor=white)](https://www.gnu.org/software/stow/)
[![License: MIT](https://img.shields.io/badge/License-MIT-darkgreen.svg)](LICENSE)

These are my personal dotfiles for **Arch Linux with Omarchy + Hyprland**.  
Now using **GNU Stow** for robust symlink management that eliminates circular symlink issues and provides a cleaner, more maintainable setup.

---

## 🚀 First-Time Setup

### Prerequisites

Install stow and clone the repository:

```bash
# On Arch Linux
sudo pacman -S stow

# On macOS  
brew install stow

# Clone dotfiles
git clone https://github.com/shawntz/dotfiles.git ~/Developer/dotfiles
cd ~/Developer/dotfiles
```

### Installation

```bash
# Install dotfiles for your platform (auto-detected)
make install

# Or install for specific platform
make archlinux  # For Arch Linux
make darwin     # For macOS
make base       # Base files only
```

### Full Bootstrap (New Machine)

```bash
# Complete setup: packages + dotfiles
make bootstrap
```

This will:

1. Install packages from backup lists (if on Arch Linux)
2. Create symlinks for all configuration files using stow
3. Handle conflicts automatically

---

## 🔧 Available Commands

Run `make help` to see all available targets:

### Core Commands

```bash
make install          # Install dotfiles for detected platform
make uninstall        # Remove all symlinks  
make restow           # Re-create symlinks (useful after adding files)
make status           # Show current installation status
make doctor           # Run comprehensive health check
make preview          # Preview what stow would do (dry run)
```

### Package Management

```bash
make backup-packages   # Export package lists (Arch Linux only)
make restore-packages  # Install packages from lists (Arch Linux only)
```

### Conflict Resolution

```bash
make adopt            # Adopt existing files into dotfiles (use with caution)
```

### Platform-Specific

```bash
make archlinux        # Force install Arch Linux dotfiles
make darwin           # Force install macOS dotfiles
make base             # Install base dotfiles only
```

### Utilities

```bash
make list-packages    # List available stow packages
make clean            # Alias for uninstall
```

---

## 📁 Directory Structure

The repository is organized as **stow packages**:

```text
dotfiles/
├── Makefile                    # Simplified stow-based automation
├── base/                       # Common files for all platforms
│   ├── .gitconfig
│   ├── .zshrc
│   ├── .bashrc
│   ├── .profile
│   ├── .gitignore
│   └── scripts/
│       ├── auto-mount-cloud.sh
│       └── open-url.sh
├── archlinux/                  # Arch Linux specific files
│   ├── .config/
│   │   ├── hypr/
│   │   │   ├── hyprland.conf
│   │   │   ├── bindings.conf
│   │   │   └── ...
│   │   ├── waybar/
│   │   ├── alacritty/
│   │   ├── nvim/
│   │   └── ...
│   ├── .local/
│   │   ├── bin/
│   │   └── share/
│   │       └── applications/
│   └── packages/               # Package lists
│       ├── pkglist.txt
│       └── aurlist.txt
├── darwin/                     # macOS specific files
│   ├── .config/
│   └── ...
├── wallpapers/                 # Wallpaper collection
└── misc/                       # Miscellaneous files
```

---

## ✅ Quick Reference

### Daily Usage

```bash
# Check status
make status

# Install/update dotfiles
make install

# Preview changes before applying
make preview

# Reinstall symlinks after adding files
make restow
```

### Package Management (Arch Linux)

```bash
# Backup current packages
make backup-packages

# Restore packages on new machine
make restore-packages
```

### Troubleshooting

```bash
# Run health check
make doctor

# If you have conflicts with existing files
make adopt

# Remove all symlinks and start over
make uninstall
make install
```

---

## 🔄 Migration from Old Setup

If you're upgrading from the previous custom symlink system:

1. **Backup your current setup** (automatic in migration)
2. **Install stow**: `sudo pacman -S stow` or `brew install stow`  
3. **Run the new install**: `make install`
4. **Verify everything works**: `make status` and `make doctor`

The new system:
- ✅ **Eliminates circular symlink issues**
- ✅ **Simplified maintenance** 
- ✅ **Better conflict detection**
- ✅ **Standard tool** (GNU Stow)
- ✅ **Dry-run capabilities**

---

## 🚨 Important Notes

> [!IMPORTANT]
>
> - **Conflicts**: Existing files that conflict are handled by stow's `--adopt` feature
> - **Sensitive files**: Never commit SSH keys, API tokens, or other secrets
> - **Platform detection**: Automatically detects Arch Linux vs macOS vs other Linux
> - **Package lists**: Automatically maintained in `archlinux/packages/`

### What Changed

- ❌ **Removed**: Complex custom symlink logic that caused circular references
- ❌ **Removed**: The `backup-configs` target (caused the circular symlink issues)
- ✅ **Added**: GNU Stow for reliable symlink management
- ✅ **Added**: Better conflict detection and resolution
- ✅ **Added**: Dry-run capabilities with `make preview`
- ✅ **Added**: Simplified directory structure

---

## 🛠️ Customization

To customize for your setup:

1. **Add files**: Place them in the appropriate stow package (`base/`, `archlinux/`, `darwin/`)
2. **Platform-specific**: Use the platform directories for OS-specific configurations
3. **Common files**: Use `base/` for files shared across all platforms
4. **Re-stow**: Run `make restow` after adding new files

The stow-based approach makes customization much more predictable and maintainable.
