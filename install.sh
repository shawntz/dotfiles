#!/usr/bin/env bash

set -euo pipefail

# Dotfiles installer script
# Supports multiple platforms with platform-specific configurations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORMS_DIR="$SCRIPT_DIR/platforms"

# Detect platform
detect_platform() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v pacman &> /dev/null; then
            echo "archlinux"
        else
            echo "linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "darwin"
    else
        echo "unknown"
    fi
}

# Create symlink safely
create_symlink() {
    local src="$1"
    local dst="$2"
    
    # Create parent directory if it doesn't exist
    mkdir -p "$(dirname "$dst")"
    
    # Remove existing file/symlink if it exists
    if [[ -e "$dst" || -L "$dst" ]]; then
        rm -rf "$dst"
    fi
    
    # Create the symlink
    ln -sf "$src" "$dst"
    echo "✓ Linked: $dst -> $src"
}

# Install dotfiles for a specific platform
install_platform() {
    local platform="$1"
    local platform_dir="$PLATFORMS_DIR/$platform"
    
    if [[ ! -d "$platform_dir" ]]; then
        echo "❌ Platform directory not found: $platform_dir"
        return 1
    fi
    
    echo "📦 Installing $platform dotfiles..."
    
    # Find all files in the platform directory and create symlinks
    while IFS= read -r -d '' file; do
        # Get relative path from platform directory
        rel_path="${file#$platform_dir/}"
        
        # Skip if it's a directory
        [[ -f "$file" ]] || continue
        
        # Create symlink in home directory
        target="$HOME/$rel_path"
        create_symlink "$file" "$target"
    done < <(find "$platform_dir" -type f -print0)
}

# Main installation function
main() {
    local platform="${1:-$(detect_platform)}"
    
    echo "🚀 Dotfiles Installation"
    echo "Platform: $platform"
    echo "Dotfiles directory: $SCRIPT_DIR"
    echo ""
    
    # Install common files first
    if [[ -d "$PLATFORMS_DIR/common" ]]; then
        install_platform "common"
    fi
    
    # Install platform-specific files
    if [[ "$platform" != "common" ]]; then
        install_platform "$platform"
    fi
    
    echo ""
    echo "✅ Installation complete!"
    
    # Platform-specific post-install steps
    case "$platform" in
        "archlinux")
            echo ""
            echo "📝 Arch Linux specific notes:"
            echo "- Run 'source ~/.bashrc' to reload shell configuration"
            echo "- Consider running package installation: sudo pacman -S --needed - < pkglist.txt"
            ;;
        "darwin")
            echo ""
            echo "📝 macOS specific notes:"
            echo "- Run 'source ~/.zshrc' to reload shell configuration"
            ;;
    esac
}

# Show help
show_help() {
    cat << EOF
Dotfiles Installation Script

Usage: $0 [PLATFORM]

Available platforms:
  archlinux    - Arch Linux specific configuration
  darwin       - macOS specific configuration  
  common       - Common configuration (installed automatically)
  
If no platform is specified, it will be auto-detected.

Examples:
  $0              # Auto-detect and install
  $0 archlinux    # Force Arch Linux installation
  $0 darwin       # Force macOS installation
EOF
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac