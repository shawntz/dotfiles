#!/usr/bin/env bash

set -euo pipefail

# Dotfiles uninstaller script
# Removes symlinks created by the install script

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

# Remove symlinks for a specific platform
remove_platform_links() {
    local platform="$1"
    local platform_dir="$PLATFORMS_DIR/$platform"
    
    if [[ ! -d "$platform_dir" ]]; then
        echo "❌ Platform directory not found: $platform_dir"
        return 1
    fi
    
    echo "🧹 Removing $platform dotfile symlinks..."
    
    # Find all files in the platform directory and remove corresponding symlinks
    while IFS= read -r -d '' file; do
        # Get relative path from platform directory
        rel_path="${file#$platform_dir/}"
        
        # Skip if it's a directory
        [[ -f "$file" ]] || continue
        
        # Remove symlink in home directory if it exists and points to our dotfiles
        target="$HOME/$rel_path"
        if [[ -L "$target" ]]; then
            link_target=$(readlink "$target")
            if [[ "$link_target" == "$file" ]]; then
                rm "$target"
                echo "✓ Removed: $target"
                
                # Remove empty parent directories
                parent_dir=$(dirname "$target")
                if [[ "$parent_dir" != "$HOME" ]]; then
                    rmdir "$parent_dir" 2>/dev/null || true
                fi
            fi
        fi
    done < <(find "$platform_dir" -type f -print0)
}

# Main uninstallation function
main() {
    local platform="${1:-$(detect_platform)}"
    
    echo "🗑️ Dotfiles Uninstallation"
    echo "Platform: $platform"
    echo "Dotfiles directory: $SCRIPT_DIR"
    echo ""
    
    # Remove platform-specific files first
    if [[ "$platform" != "common" ]]; then
        remove_platform_links "$platform"
    fi
    
    # Remove common files
    if [[ -d "$PLATFORMS_DIR/common" ]]; then
        remove_platform_links "common"
    fi
    
    echo ""
    echo "✅ Uninstallation complete!"
}

# Show help
show_help() {
    cat << EOF
Dotfiles Uninstallation Script

Usage: $0 [PLATFORM]

Available platforms:
  archlinux    - Remove Arch Linux specific symlinks
  darwin       - Remove macOS specific symlinks
  common       - Remove common symlinks only
  
If no platform is specified, it will be auto-detected.

Examples:
  $0              # Auto-detect and remove all symlinks
  $0 archlinux    # Remove Arch Linux symlinks only
  $0 common       # Remove common symlinks only
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