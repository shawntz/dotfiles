# macOS Configuration System

An interactive configuration management system for macOS defaults, allowing you to customize and sync your Mac settings across machines.

## Features

- **Interactive TUI**: Beautiful terminal UI using `gum` for easy configuration
- **YAML-based Config**: All settings stored in `config.yaml` for easy editing and version control
- **Auto-generated Scripts**: `set-defaults.sh` is automatically generated from your config
- **Categories**: Organized settings for Dock, Finder, Keyboard, Trackpad, Security, and more

## Quick Start

### Interactive Mode (Recommended)

```bash
mac-sync -i
# or
mac-sync --interactive
```

This launches an interactive TUI where you can:
- Configure all macOS settings through menus
- View current configuration
- Apply settings to your system

### Non-Interactive Mode

```bash
mac-sync
```

This will:
1. Generate `set-defaults.sh` from `config.yaml`
2. Apply all settings to your system

## Configuration File

All settings are stored in `config.yaml`. You can either:

1. **Use the interactive TUI**: `mac-sync -i` and navigate through the menus
2. **Edit YAML directly**: Open `config.yaml` and modify values

Example `config.yaml` structure:

```yaml
dock:
  autohide: false
  tile_size: 72
  orientation: "bottom"
  apps:
    - "/Applications/Google Chrome.app"
    - "/Applications/Slack.app"
    # ...

finder:
  show_all_extensions: true
  preferred_view_style: "clmv"  # Column view
  show_pathbar: true

global:
  key_repeat: 1  # Fastest
  initial_key_repeat: 10
  automatic_spelling_correction: false
  # ...
```

## Setting Categories

### 🎨 Dock Settings
- **Interactive App Selection**: Browse all installed apps from /Applications, /System/Applications, and ~/Applications
  - Use SPACE to toggle app selection (checkbox style)
  - Apps from your current config are pre-selected
  - Includes Chrome Apps and other user-installed applications
- **App Reordering**: Drag-and-drop style ordering using interactive selection
  - Choose to reorder or preserve existing order
  - New apps are added at the end by default
  - Order is saved and retained across updates
- Autohide behavior
- Icon size (16-128 pixels)
- Position (left/bottom/right)
- Minimize effect (genie/suck/scale)
- Show recent applications
- Downloads folder display

### 📁 Finder Settings
- File extensions visibility
- Default view style
- Path bar and status bar
- Desktop icon display
- Search scope

### ⌨️ Keyboard & Input
- Key repeat speed
- Initial key repeat delay
- Auto-correct features
- Smart quotes and dashes

### 🖱️ Mouse & Trackpad
- Tap to click
- Tracking speed
- Natural scrolling
- Three-finger drag
- Force click

### 🖥️ Display & Window Manager
- Stage Manager
- Menu bar auto-hide
- Window animations
- Window margins

### 🔒 Security & Privacy
- Application firewall
- Quarantine warnings
- Screensaver password
- Password delay

### 📸 Screen Saver & Capture
- Screenshot save location
- Screensaver settings

### 🪟 Spaces & Mission Control
- Automatically rearrange spaces
- Separate spaces per display
- Group windows by app

## Managing Dock Applications

One of the most powerful features is the interactive Dock app manager. Here's how it works:

### Selecting Apps

1. Run `mac-sync -i`
2. Choose "🎨 Dock Settings"
3. Choose "📱 Manage Dock Applications"
4. You'll see a searchable list of ALL installed applications:
   - /Applications (system-wide apps)
   - /System/Applications (macOS default apps)
   - ~/Applications (user-installed apps, including Chrome Apps)
5. Use **SPACE** to toggle selection (like checkboxes)
   - Apps from your current config.yaml are pre-selected with checkmarks
   - Type to search/filter apps
   - Navigate with arrow keys
6. Press **ENTER** to confirm selection

### Ordering Apps

After selecting apps, you'll be asked if you want to reorder them:

**Option 1: Reorder** (choose "Yes")
- Select apps one-by-one in your desired dock order
- Position 1 = leftmost app in dock
- Use search to quickly find apps
- Any unselected apps are added at the end

**Option 2: Preserve Order** (choose "No")
- Keeps existing apps in their current order
- New apps are added at the end
- Perfect for just adding one or two new apps

### Smart Order Retention

The system intelligently preserves your preferences:
- ✅ Existing app order is maintained when you select "Preserve Order"
- ✅ New apps are appended to the end
- ✅ Removed apps are simply excluded
- ✅ Your order is saved in config.yaml and syncs across machines

### Example Workflow

```bash
# Initial setup - choose all your apps and order them
mac-sync -i  # → Dock Settings → Manage Applications → Select all → Reorder

# Later, just add one new app (Figma)
mac-sync -i  # → Dock Settings → Manage Applications
             # → SPACE on "Figma.app" → ENTER → Preserve Order? Yes
             # Figma is added at the end, everything else stays in place!

# Reorder everything from scratch
mac-sync -i  # → Dock Settings → Manage Applications
             # → ENTER → Reorder? Yes → Select in new order
```

## Workflow

### First Time Setup

1. Install dependencies (already in Brewfile):
   ```bash
   brew install gum yq dockutil
   ```

2. Review and customize `config.yaml`:
   ```bash
   mac-sync -i
   # Navigate to "👁️ View Current Config"
   ```

3. Make your changes through the TUI or edit `config.yaml` directly

4. Apply settings:
   ```bash
   mac-sync
   ```

### Daily Usage

When you want to adjust settings:

```bash
# Quick interactive tweaks
mac-sync -i

# Or edit config.yaml directly, then apply
vim darwin/install/macos/config.yaml
mac-sync
```

### Syncing Across Machines

Since `config.yaml` is in your dotfiles repo:

1. On Machine A: Configure your settings with `mac-sync -i`
2. Commit and push `config.yaml` to your repo
3. On Machine B: Pull the repo and run `mac-sync`
4. All settings are now synced!

## Files

- `config.yaml` - Your configuration (edit this!)
- `interactive-config.sh` - Interactive TUI application
- `generate-defaults-script.sh` - Generates `set-defaults.sh` from YAML
- `set-defaults.sh` - Auto-generated, applies settings (don't edit directly)

## Tips

- **Start with interactive mode** to explore available settings
- **Use Dock App Manager for visual selection** instead of manually editing the YAML apps array
  - Search is fuzzy - type "chr" to find "Chrome"
  - SPACE toggles, arrow keys navigate, ENTER confirms
  - Pre-selected apps show with checkmarks
- **Commit config.yaml** to your repo to track changes
- **Some changes require logout/restart** to take full effect
- **Review generated set-defaults.sh** to see exactly what will change
- **Use non-interactive mode in scripts** for automation
- **Preserve order when adding single apps** - only use "Reorder" when you want to reorganize everything

## Advanced Usage

### Custom Repository Path

```bash
mac-sync /path/to/custom/dotfiles
mac-sync /path/to/custom/dotfiles --interactive
```

### Programmatic Changes

```bash
# Edit specific values with yq
yq eval -i '.dock.tile_size = 48' config.yaml
yq eval -i '.dock.autohide = true' config.yaml

# Apply changes
mac-sync
```

### Integration with Brewfile Sync

```bash
# Update both Homebrew and macOS settings
brewfile-sync && mac-sync
```

## Troubleshooting

**Settings not applying?**
- Some settings require killing the relevant process (Dock, Finder, etc.)
- Some settings require logout/restart
- Run `killall Dock` or `killall Finder` manually if needed

**Interactive mode not working?**
- Ensure `gum` is installed: `brew install gum`
- Ensure `yq` is installed: `brew install yq`

**Want to reset to defaults?**
- Edit `config.yaml` to restore default values
- Or delete `config.yaml` and it will be regenerated with defaults on next run

## Integration

This system is integrated with your dotfiles workflow:

- `mac-sync` function is defined in `darwin/zsh/.zsh/functions`
- Config and scripts are in `darwin/install/macos/`
- `yq` and `gum` are in your `Brewfile`
- Everything is version controlled and portable

Enjoy your customized macOS experience! 🎉
