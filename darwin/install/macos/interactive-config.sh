#!/usr/bin/env bash
set -euo pipefail

# Interactive macOS Configuration Manager
# Uses gum for TUI and yq for YAML parsing

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
APPLY_SCRIPT="${SCRIPT_DIR}/set-defaults.sh"

# Debug mode - uncomment to enable debugging
# set -x
# DEBUG=true

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check dependencies
check_deps() {
  local missing=()
  command -v gum >/dev/null 2>&1 || missing+=("gum")
  command -v yq >/dev/null 2>&1 || missing+=("yq")

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
    echo "Install with: brew install ${missing[*]}"
    exit 1
  fi
}

# Read a value from config.yaml
read_config() {
  local key="$1"
  yq eval "$key" "$CONFIG_FILE"
}

# Write a value to config.yaml
write_config() {
  local key="$1"
  local value="$2"
  yq eval -i "$key = $value" "$CONFIG_FILE"
}

# Main menu
main_menu() {
  gum style \
    --foreground 212 --border-foreground 212 --border double \
    --align center --width 60 --margin "1 2" --padding "1 4" \
    'macOS System Configuration' 'Interactive Settings Manager'

  local choice
  choice=$(gum choose \
    "🎨 Dock Settings" \
    "📁 Finder Settings" \
    "⌨️  Keyboard & Input" \
    "🖱️  Mouse & Trackpad" \
    "🖥️  Display & Window Manager" \
    "🔒 Security & Privacy" \
    "📸 Screen Saver & Capture" \
    "🪟  Spaces & Mission Control" \
    "👁️  View Current Config" \
    "💾 Apply Settings" \
    "❌ Exit")

  case "$choice" in
    "🎨 Dock Settings") configure_dock ;;
    "📁 Finder Settings") configure_finder ;;
    "⌨️  Keyboard & Input") configure_keyboard ;;
    "🖱️  Mouse & Trackpad") configure_trackpad ;;
    "🖥️  Display & Window Manager") configure_windowmanager ;;
    "🔒 Security & Privacy") configure_security ;;
    "📸 Screen Saver & Capture") configure_screensaver ;;
    "🪟  Spaces & Mission Control") configure_spaces ;;
    "👁️  View Current Config") view_config ;;
    "💾 Apply Settings") apply_settings ;;
    "❌ Exit") exit 0 ;;
  esac
}

# Discover all installed applications
discover_applications() {
  local apps=()

  # Scan /Applications
  while IFS= read -r -d '' app; do
    apps+=("$app")
  done < <(find /Applications -maxdepth 1 -name "*.app" -print0 2>/dev/null | sort -z)

  # Scan /System/Applications
  while IFS= read -r -d '' app; do
    apps+=("$app")
  done < <(find /System/Applications -maxdepth 1 -name "*.app" -print0 2>/dev/null | sort -z)

  # Scan ~/Applications
  if [ -d "$HOME/Applications" ]; then
    while IFS= read -r -d '' app; do
      apps+=("$app")
    done < <(find "$HOME/Applications" -maxdepth 2 -name "*.app" -print0 2>/dev/null | sort -z)
  fi

  # Print unique apps
  printf '%s\n' "${apps[@]}" | sort -u
}

# Configure dock apps
configure_dock_apps() {
  gum style --foreground 212 "📱 Dock Applications"

  # Discover all apps
  gum style --foreground 214 "Discovering installed applications..."
  local all_apps
  all_apps=$(discover_applications)

  if [ -z "$all_apps" ]; then
    gum style --foreground 196 "❌ No applications found!"
    sleep 2
    return
  fi

  # Get currently configured apps from config.yaml
  local current_apps
  current_apps=$(yq eval '.dock.apps[]' "$CONFIG_FILE" 2>/dev/null)

  # Create temp file for selection
  local tmp_apps="/tmp/dock_apps_$$"
  echo "$all_apps" > "$tmp_apps"

  # Build selected list (apps that are in current config) as an array
  local selected_args=()
  if [ -n "$current_apps" ]; then
    while IFS= read -r app; do
      # Expand tilde for comparison
      local expanded_app
      expanded_app=$(eval echo "$app")
      if echo "$all_apps" | grep -qxF "$expanded_app"; then
        selected_args+=("--selected=$expanded_app")
      fi
    done <<< "$current_apps"
  fi

  gum style --foreground 212 "Select apps for Dock (use SPACE to toggle, ENTER to confirm):"

  # Use gum filter with multi-select
  local selected_apps
  if [ ${#selected_args[@]} -gt 0 ]; then
    selected_apps=$(cat "$tmp_apps" | gum filter --no-limit "${selected_args[@]}")
  else
    selected_apps=$(cat "$tmp_apps" | gum filter --no-limit)
  fi

  rm -f "$tmp_apps"

  if [ -z "$selected_apps" ]; then
    gum style --foreground 196 "No apps selected. Keeping current configuration."
    sleep 2
    return
  fi

  # Now let user reorder the apps
  echo ""
  gum style --foreground 212 "🔀 App Ordering"

  local save_success=false

  if gum confirm "Do you want to manually reorder all apps? (No = preserve existing order, add new apps at end)"; then
    # Manual reordering
    if reorder_dock_apps "$selected_apps"; then
      save_success=true
    else
      gum style --foreground 196 "Reordering cancelled or failed."
      sleep 2
    fi
  else
    # Keep selection but don't reorder - use current config order for existing apps,
    # append new ones at the end
    if save_dock_apps_preserve_order "$selected_apps"; then
      save_success=true
    else
      gum style --foreground 196 "Save cancelled or failed."
      sleep 2
    fi
  fi

  # Show summary if save was successful
  if [ "$save_success" = true ]; then
    echo ""
    gum style --foreground 212 "📋 Summary"
    local saved_count
    saved_count=$(yq eval '.dock.apps | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
    gum style --foreground 214 "Total apps in Dock: $saved_count"
    gum style --foreground 214 "Config saved to: ${CONFIG_FILE/#$HOME/~}"
    echo ""
    gum style --foreground 214 "Press ENTER to continue..."
    read -r
  fi
}

# Reorder dock apps interactively
reorder_dock_apps() {
  local selected_apps="$1"
  local ordered_apps=()
  local remaining_apps="$selected_apps"

  local count
  count=$(echo "$selected_apps" | wc -l | tr -d ' ')

  gum style --foreground 214 "Select apps in your desired dock order (${count} total)."
  gum style --foreground 214 "Press ESC or ENTER on empty to finish ordering."

  for i in $(seq 1 "$count"); do
    if [ -z "$remaining_apps" ]; then
      break
    fi

    local choice
    choice=$(echo "$remaining_apps" | gum filter --placeholder "Position ${i}: Select app" || echo "")

    if [ -z "$choice" ]; then
      # User pressed ESC or selected nothing - add remaining apps at end
      gum style --foreground 214 "Adding remaining apps at the end..."
      break
    fi

    ordered_apps+=("$choice")
    remaining_apps=$(echo "$remaining_apps" | grep -v -F "$choice")
  done

  # Add any remaining apps that weren't explicitly ordered
  while IFS= read -r app; do
    if [ -n "$app" ]; then
      ordered_apps+=("$app")
    fi
  done <<< "$remaining_apps"

  # Verify we have apps to save
  if [ ${#ordered_apps[@]} -eq 0 ]; then
    gum style --foreground 196 "❌ No apps were ordered. Aborting."
    sleep 2
    return 1
  fi

  # Save to config
  gum style --foreground 214 "Saving ${#ordered_apps[@]} apps to config..."
  save_dock_apps_to_config "${ordered_apps[@]}"

  if [ $? -eq 0 ]; then
    gum style --foreground 212 "✅ Successfully saved ${#ordered_apps[@]} apps!"

    # Show saved apps for verification
    if [ "${DEBUG:-}" = "true" ]; then
      echo "Saved apps:"
      yq eval '.dock.apps[]' "$CONFIG_FILE"
    fi
  else
    gum style --foreground 196 "❌ Failed to save apps to config."
    return 1
  fi

  return 0
}

# Save dock apps preserving existing order
save_dock_apps_preserve_order() {
  local selected_apps="$1"
  local ordered_apps=()

  # First, add apps that were already in config in their existing order
  local current_apps
  current_apps=$(yq eval '.dock.apps[]' "$CONFIG_FILE" 2>/dev/null)

  if [ -n "$current_apps" ]; then
    while IFS= read -r app; do
      local expanded_app
      expanded_app=$(eval echo "$app")
      # If this app is in the selected list, add it
      if echo "$selected_apps" | grep -qxF "$expanded_app"; then
        ordered_apps+=("$expanded_app")
      fi
    done <<< "$current_apps"
  fi

  # Then, add any newly selected apps that weren't in the config
  while IFS= read -r app; do
    if [ -n "$app" ]; then
      # Check if already added
      local already_added=false
      for existing in "${ordered_apps[@]}"; do
        if [ "$existing" = "$app" ]; then
          already_added=true
          break
        fi
      done

      if [ "$already_added" = false ]; then
        ordered_apps+=("$app")
      fi
    fi
  done <<< "$selected_apps"

  # Verify we have apps to save
  if [ ${#ordered_apps[@]} -eq 0 ]; then
    gum style --foreground 196 "❌ No apps selected. Keeping current configuration."
    sleep 2
    return 1
  fi

  # Save to config
  gum style --foreground 214 "Saving ${#ordered_apps[@]} apps (preserving order)..."
  save_dock_apps_to_config "${ordered_apps[@]}"

  if [ $? -eq 0 ]; then
    gum style --foreground 212 "✅ Successfully saved ${#ordered_apps[@]} apps!"

    # Show saved apps for verification
    if [ "${DEBUG:-}" = "true" ]; then
      echo "Saved apps:"
      yq eval '.dock.apps[]' "$CONFIG_FILE"
    fi
  else
    gum style --foreground 196 "❌ Failed to save apps to config."
    return 1
  fi

  return 0
}

# Save dock apps array to config.yaml
save_dock_apps_to_config() {
  local apps=("$@")

  if [ ${#apps[@]} -eq 0 ]; then
    echo "Error: No apps provided to save" >&2
    return 1
  fi

  # Clear existing apps
  if ! yq eval -i 'del(.dock.apps)' "$CONFIG_FILE" 2>/dev/null; then
    echo "Error: Failed to clear existing apps from config" >&2
    return 1
  fi

  # Add each app
  for app in "${apps[@]}"; do
    # Replace $HOME with ~ for cleaner config
    local app_path="${app/#$HOME/~}"
    if ! yq eval -i ".dock.apps += [\"$app_path\"]" "$CONFIG_FILE" 2>/dev/null; then
      echo "Error: Failed to add app to config: $app_path" >&2
      return 1
    fi
  done

  return 0
}

# Dock configuration menu
configure_dock() {
  gum style --foreground 212 "🎨 Dock Configuration"

  local choice
  choice=$(gum choose \
    "📱 Manage Dock Applications" \
    "⚙️  Dock Appearance Settings" \
    "◀️  Back to Main Menu")

  case "$choice" in
    "📱 Manage Dock Applications") configure_dock_apps; configure_dock ;;
    "⚙️  Dock Appearance Settings") configure_dock_appearance ;;
    "◀️  Back to Main Menu") main_menu ;;
  esac
}

# Dock appearance configuration
configure_dock_appearance() {
  gum style --foreground 212 "⚙️  Dock Appearance"

  local autohide=$(read_config '.dock.autohide')
  local size=$(read_config '.dock.tile_size')
  local position=$(read_config '.dock.orientation')
  local minimize=$(read_config '.dock.minimize_effect')
  local show_recents=$(read_config '.dock.show_recents')

  # Autohide
  if gum confirm "Enable Dock autohide? (current: $autohide)"; then
    write_config '.dock.autohide' 'true'
  else
    write_config '.dock.autohide' 'false'
  fi

  # Tile size
  local new_size
  new_size=$(gum input --placeholder "Dock icon size (16-128, current: $size)" --value "$size")
  write_config '.dock.tile_size' "$new_size"

  # Position
  local new_position
  new_position=$(gum choose --header "Dock position (current: $position)" "left" "bottom" "right")
  write_config '.dock.orientation' "\"$new_position\""

  # Minimize effect
  local new_effect
  new_effect=$(gum choose --header "Minimize effect (current: $minimize)" "genie" "suck" "scale")
  write_config '.dock.minimize_effect' "\"$new_effect\""

  # Show recents
  if gum confirm "Show recent applications? (current: $show_recents)"; then
    write_config '.dock.show_recents' 'true'
  else
    write_config '.dock.show_recents' 'false'
  fi

  gum style --foreground 212 "✅ Dock appearance settings updated!"
  sleep 1
  configure_dock
}

# Finder configuration
configure_finder() {
  gum style --foreground 212 "📁 Finder Configuration"

  local show_extensions=$(read_config '.finder.show_all_extensions')
  local view_style=$(read_config '.finder.preferred_view_style')
  local show_pathbar=$(read_config '.finder.show_pathbar')
  local show_statusbar=$(read_config '.finder.show_statusbar')

  # Show all file extensions
  if gum confirm "Show all file extensions? (current: $show_extensions)"; then
    write_config '.finder.show_all_extensions' 'true'
  else
    write_config '.finder.show_all_extensions' 'false'
  fi

  # View style
  local new_view
  new_view=$(gum choose --header "Default view style (current: $view_style)" \
    "icnv (Icon)" \
    "clmv (Column)" \
    "Nlsv (List)" \
    "glyv (Gallery)")
  new_view="${new_view%% *}"  # Extract code
  write_config '.finder.preferred_view_style' "\"$new_view\""

  # Show path bar
  if gum confirm "Show path bar? (current: $show_pathbar)"; then
    write_config '.finder.show_pathbar' 'true'
  else
    write_config '.finder.show_pathbar' 'false'
  fi

  # Show status bar
  if gum confirm "Show status bar? (current: $show_statusbar)"; then
    write_config '.finder.show_statusbar' 'true'
  else
    write_config '.finder.show_statusbar' 'false'
  fi

  # Folders first
  if gum confirm "Sort folders first?"; then
    write_config '.finder.sort_folders_first' 'true'
    write_config '.finder.sort_folders_first_on_desktop' 'true'
  else
    write_config '.finder.sort_folders_first' 'false'
    write_config '.finder.sort_folders_first_on_desktop' 'false'
  fi

  gum style --foreground 212 "✅ Finder settings updated!"
  sleep 1
  main_menu
}

# Keyboard & Input configuration
configure_keyboard() {
  gum style --foreground 212 "⌨️  Keyboard & Input Configuration"

  local key_repeat=$(read_config '.global.key_repeat')
  local initial_repeat=$(read_config '.global.initial_key_repeat')
  local autocorrect=$(read_config '.global.automatic_spelling_correction')
  local autocap=$(read_config '.global.automatic_capitalization')

  # Key repeat
  local new_repeat
  new_repeat=$(gum input --placeholder "Key repeat speed (1=fastest, 2=default, current: $key_repeat)" --value "$key_repeat")
  write_config '.global.key_repeat' "$new_repeat"

  # Initial key repeat
  local new_initial
  new_initial=$(gum input --placeholder "Initial key repeat (10-2, lower=faster, current: $initial_repeat)" --value "$initial_repeat")
  write_config '.global.initial_key_repeat' "$new_initial"

  # Auto-correct
  if gum confirm "Enable automatic spelling correction? (current: $autocorrect)"; then
    write_config '.global.automatic_spelling_correction' 'true'
  else
    write_config '.global.automatic_spelling_correction' 'false'
  fi

  # Auto-capitalize
  if gum confirm "Enable automatic capitalization? (current: $autocap)"; then
    write_config '.global.automatic_capitalization' 'true'
  else
    write_config '.global.automatic_capitalization' 'false'
  fi

  # Smart quotes
  if gum confirm "Enable smart quotes?"; then
    write_config '.global.automatic_quote_substitution' 'true'
  else
    write_config '.global.automatic_quote_substitution' 'false'
  fi

  # Smart dashes
  if gum confirm "Enable smart dashes?"; then
    write_config '.global.automatic_dash_substitution' 'true'
  else
    write_config '.global.automatic_dash_substitution' 'false'
  fi

  gum style --foreground 212 "✅ Keyboard settings updated!"
  sleep 1
  main_menu
}

# Trackpad configuration
configure_trackpad() {
  gum style --foreground 212 "🖱️  Mouse & Trackpad Configuration"

  local tap_to_click=$(read_config '.global.mouse_tap_behavior')
  local tracking_speed=$(read_config '.global.trackpad_scaling')
  local natural_scroll=$(read_config '.global.swipe_scroll_direction')
  local three_finger_drag=$(read_config '.trackpad.three_finger_drag')

  # Tap to click
  if gum confirm "Enable tap to click? (current: $tap_to_click)"; then
    write_config '.global.mouse_tap_behavior' '1'
    write_config '.trackpad.clicking' '1'
  else
    write_config '.global.mouse_tap_behavior' '0'
    write_config '.trackpad.clicking' '0'
  fi

  # Tracking speed
  local new_speed
  new_speed=$(gum input --placeholder "Tracking speed (0.0-3.0, current: $tracking_speed)" --value "$tracking_speed")
  write_config '.global.trackpad_scaling' "$new_speed"

  # Natural scrolling
  if gum confirm "Enable natural (reversed) scrolling? (current: $natural_scroll)"; then
    write_config '.global.swipe_scroll_direction' 'true'
  else
    write_config '.global.swipe_scroll_direction' 'false'
  fi

  # Three finger drag
  if gum confirm "Enable three finger drag? (current: $three_finger_drag)"; then
    write_config '.trackpad.three_finger_drag' '1'
    write_config '.trackpad.bluetooth_three_finger_drag' '1'
  else
    write_config '.trackpad.three_finger_drag' '0'
    write_config '.trackpad.bluetooth_three_finger_drag' '0'
  fi

  gum style --foreground 212 "✅ Trackpad settings updated!"
  sleep 1
  main_menu
}

# Window Manager configuration
configure_windowmanager() {
  gum style --foreground 212 "🖥️  Display & Window Manager Configuration"

  local stage_manager=$(read_config '.windowmanager.globally_enabled')
  local hide_menu_bar=$(read_config '.global.hide_menu_bar')
  local window_animations=$(read_config '.global.automatic_window_animations')

  # Stage Manager
  if gum confirm "Enable Stage Manager globally? (current: $stage_manager)"; then
    write_config '.windowmanager.globally_enabled' 'true'
  else
    write_config '.windowmanager.globally_enabled' 'false'
  fi

  # Auto-hide menu bar
  if gum confirm "Auto-hide menu bar? (current: $hide_menu_bar)"; then
    write_config '.global.hide_menu_bar' 'true'
  else
    write_config '.global.hide_menu_bar' 'false'
  fi

  # Window animations
  if gum confirm "Enable window animations? (current: $window_animations)"; then
    write_config '.global.automatic_window_animations' 'true'
  else
    write_config '.global.automatic_window_animations' 'false'
  fi

  gum style --foreground 212 "✅ Window Manager settings updated!"
  sleep 1
  main_menu
}

# Security & Privacy configuration
configure_security() {
  gum style --foreground 212 "🔒 Security & Privacy Configuration"

  local firewall=$(read_config '.firewall.globalstate')
  local quarantine=$(read_config '.launchservices.disable_quarantine')
  local screensaver_password=$(read_config '.screensaver.ask_for_password')
  local password_delay=$(read_config '.screensaver.ask_for_password_delay')

  # Firewall
  local firewall_choice
  firewall_choice=$(gum choose --header "Firewall state (current: $firewall)" \
    "0 (Off)" \
    "1 (On for specific services)" \
    "2 (On for all services)")
  firewall_choice="${firewall_choice%% *}"
  write_config '.firewall.globalstate' "$firewall_choice"

  # Quarantine warning
  if gum confirm "Disable quarantine warning for downloaded apps? (current: $quarantine)"; then
    write_config '.launchservices.disable_quarantine' 'true'
  else
    write_config '.launchservices.disable_quarantine' 'false'
  fi

  # Screensaver password
  if gum confirm "Require password after screensaver? (current: $screensaver_password)"; then
    write_config '.screensaver.ask_for_password' '1'
  else
    write_config '.screensaver.ask_for_password' '0'
  fi

  # Password delay
  if [ "$screensaver_password" = "1" ]; then
    local new_delay
    new_delay=$(gum input --placeholder "Password delay in seconds (current: $password_delay)" --value "$password_delay")
    write_config '.screensaver.ask_for_password_delay' "$new_delay"
  fi

  gum style --foreground 212 "✅ Security settings updated!"
  sleep 1
  main_menu
}

# Screen Saver & Capture configuration
configure_screensaver() {
  gum style --foreground 212 "📸 Screen Saver & Capture Configuration"

  local screenshot_location=$(read_config '.screensaver.screenshot_location')

  # Screenshot location
  local new_location
  new_location=$(gum input --placeholder "Screenshot save location" --value "$screenshot_location")
  write_config '.screensaver.screenshot_location' "\"$new_location\""

  gum style --foreground 212 "✅ Screen capture settings updated!"
  sleep 1
  main_menu
}

# Spaces configuration
configure_spaces() {
  gum style --foreground 212 "🪟  Spaces & Mission Control Configuration"

  local mru_spaces=$(read_config '.dock.mru_spaces')
  local spans_displays=$(read_config '.spaces.spans_displays')
  local group_apps=$(read_config '.dock.expose_group_apps')

  # Automatically rearrange spaces
  if gum confirm "Automatically rearrange spaces based on recent use? (current: $mru_spaces)"; then
    write_config '.dock.mru_spaces' 'true'
  else
    write_config '.dock.mru_spaces' 'false'
  fi

  # Displays have separate spaces
  if gum confirm "Displays have separate Spaces? (current: $([[ "$spans_displays" == "false" ]] && echo "yes" || echo "no"))"; then
    write_config '.spaces.spans_displays' 'false'
  else
    write_config '.spaces.spans_displays' 'true'
  fi

  # Group windows by application
  if gum confirm "Group windows by application in Mission Control? (current: $group_apps)"; then
    write_config '.dock.expose_group_apps' 'true'
  else
    write_config '.dock.expose_group_apps' 'false'
  fi

  gum style --foreground 212 "✅ Spaces settings updated!"
  sleep 1
  main_menu
}

# View current configuration
view_config() {
  gum style --foreground 212 "👁️  Current Configuration"
  gum pager < "$CONFIG_FILE"
  main_menu
}

# Apply settings to the system
apply_settings() {
  gum style --foreground 212 "💾 Apply Settings to System"

  if ! gum confirm "This will apply all settings from config.yaml to your system. Continue?"; then
    main_menu
    return
  fi

  gum spin --spinner dot --title "Generating set-defaults.sh from config.yaml..." -- \
    bash "${SCRIPT_DIR}/generate-defaults-script.sh"

  if gum confirm "Settings script generated. Apply now?"; then
    gum style --foreground 212 "Applying settings..."
    bash "$APPLY_SCRIPT"
    gum style --foreground 212 "✅ Settings applied! Some changes may require logout/restart."
  fi

  main_menu
}

# Main execution
check_deps

while true; do
  main_menu
done
