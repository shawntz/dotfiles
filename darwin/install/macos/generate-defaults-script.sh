#!/usr/bin/env bash
set -euo pipefail

# Generates set-defaults.sh from config.yaml
# This script reads the YAML config and creates the bash defaults script

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
OUTPUT_FILE="${SCRIPT_DIR}/set-defaults.sh"

# Helper to read config values
cfg() {
  yq eval "$1" "$CONFIG_FILE"
}

# Generate the script
cat > "$OUTPUT_FILE" << 'HEADER'
configure_macos_defaults() {
  set -euo pipefail

  # Optional: ask for admin once and keep it alive
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    sudo -v
    while true; do
      sudo -n true
      sleep 60
      kill -0 "$$" 2>/dev/null || exit
    done 2>/dev/null &
  fi

  # Helper to write defaults with nice logging
  w() {
    local domain="$1" key="$2" type="$3" value="$4"
    echo "defaults write ${domain} ${key} -${type} ${value}"
    defaults write "$domain" "$key" "-$type" "$value"
  }

  # Ensure dockutil path
  DOCKUTIL="$(command -v dockutil || true)"
  [ -z "$DOCKUTIL" ] && DOCKUTIL="/opt/homebrew/bin/dockutil"
  [ ! -x "$DOCKUTIL" ] && echo "dockutil not found; brew install dockutil" && return 1

  ##############################################################################
  # Activate settings helper (like nix activation script)
  ##############################################################################
  if [ -x /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings ]; then
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u || true
  fi

  ##############################################################################
  # Application Layer Firewall (alf)
  ##############################################################################
HEADER

# Firewall settings
cat >> "$OUTPUT_FILE" << EOF
  sudo defaults write /Library/Preferences/com.apple.alf allowdownloadsignedenabled -int $(cfg '.firewall.allowdownloadsignedenabled')
  sudo defaults write /Library/Preferences/com.apple.alf allowsignedenabled -int $(cfg '.firewall.allowsignedenabled')
  sudo defaults write /Library/Preferences/com.apple.alf globalstate -int $(cfg '.firewall.globalstate')
  # Reload firewall agent
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate >/dev/null || true

  ##############################################################################
  # Control Center: hide Now Playing
  ##############################################################################
  w com.apple.controlcenter "NSStatusItem Visible NowPlaying" bool $(cfg '.controlcenter.hide_now_playing')

  ##############################################################################
  # Dock
  ##############################################################################
  w com.apple.dock autohide bool $(cfg '.dock.autohide')
  w com.apple.dock autohide-delay float $(cfg '.dock.autohide_delay')
  w com.apple.dock autohide-time-modifier float $(cfg '.dock.autohide_time_modifier')
  w com.apple.dock enable-spring-load-actions-on-all-items bool $(cfg '.dock.enable_spring_load_actions')
  w com.apple.dock appswitcher-all-displays bool $(cfg '.dock.appswitcher_all_displays')
  w com.apple.dock dashboard-in-overlay bool $(cfg '.dock.dashboard_in_overlay')
  w com.apple.dock expose-animation-duration float $(cfg '.dock.expose_animation_duration')
  w com.apple.dock expose-group-apps bool $(cfg '.dock.expose_group_apps')
  w com.apple.dock launchanim bool $(cfg '.dock.launch_animation')
  w com.apple.dock mineffect string "$(cfg '.dock.minimize_effect')"
  w com.apple.dock minimize-to-application bool $(cfg '.dock.minimize_to_application')
  w com.apple.dock mru-spaces bool $(cfg '.dock.mru_spaces')
  w com.apple.dock orientation string "$(cfg '.dock.orientation')"
  w com.apple.dock scroll-to-open bool $(cfg '.dock.scroll_to_open')
  w com.apple.dock show-process-indicators bool $(cfg '.dock.show_process_indicators')
  w com.apple.dock show-recents bool $(cfg '.dock.show_recents')
  w com.apple.dock showhidden bool $(cfg '.dock.show_hidden')
  w com.apple.dock static-only bool $(cfg '.dock.static_only')
  w com.apple.dock tilesize int $(cfg '.dock.tile_size')

  # Dock content
  "\$DOCKUTIL" --remove all --no-restart || true
  killall Dock || true
  sleep 3 # Wait for Dock to restart before adding apps

  "\$DOCKUTIL" --remove "Downloads" --no-restart || true
  "\$DOCKUTIL" --add "\$HOME/Downloads" --view $(cfg '.dock.downloads.view') --sort $(cfg '.dock.downloads.sort') --display $(cfg '.dock.downloads.display') --no-restart || true

  # Curate persistent apps (skips missing apps gracefully)
  add_app() { [ -d "\$1" ] && "\$DOCKUTIL" --add "\$1" --no-restart || true; }
EOF

# Add dock apps from YAML
yq eval '.dock.apps[]' "$CONFIG_FILE" | while IFS= read -r app; do
  echo "  add_app \"$app\"" >> "$OUTPUT_FILE"
done

cat >> "$OUTPUT_FILE" << EOF

  killall Dock || true

  ##############################################################################
  # Finder
  ##############################################################################
  w com.apple.finder AppleShowAllExtensions bool $(cfg '.finder.show_all_extensions')
  w com.apple.finder FXDefaultSearchScope string "$(cfg '.finder.default_search_scope')"
  w com.apple.finder FXEnableExtensionChangeWarning bool $(cfg '.finder.extension_change_warning')
  w com.apple.finder FXPreferredViewStyle string "$(cfg '.finder.preferred_view_style')"
  w com.apple.finder NewWindowTarget string "$(cfg '.finder.new_window_target')"
  w com.apple.finder NewWindowTargetPath string "file://\${HOME}/"
  w com.apple.finder QuitMenuItem bool $(cfg '.finder.quit_menu_item')
  w com.apple.finder ShowExternalHardDrivesOnDesktop bool $(cfg '.finder.show_external_drives')
  w com.apple.finder ShowHardDrivesOnDesktop bool $(cfg '.finder.show_hard_drives')
  w com.apple.finder ShowMountedServersOnDesktop bool $(cfg '.finder.show_mounted_servers')
  w com.apple.finder ShowPathbar bool $(cfg '.finder.show_pathbar')
  w com.apple.finder ShowRemovableMediaOnDesktop bool $(cfg '.finder.show_removable_media')
  w com.apple.finder ShowStatusBar bool $(cfg '.finder.show_statusbar')
  w com.apple.finder _FXShowPosixPathInTitle bool $(cfg '.finder.show_posix_path_in_title')
  w com.apple.finder _FXSortFoldersFirst bool $(cfg '.finder.sort_folders_first')
  w com.apple.finder _FXSortFoldersFirstOnDesktop bool $(cfg '.finder.sort_folders_first_on_desktop')

  killall Finder || true

  ##############################################################################
  # LaunchServices
  ##############################################################################
  w com.apple.LaunchServices LSQuarantine bool $(cfg '.launchservices.disable_quarantine')

  ##############################################################################
  # Login Window
  ##############################################################################
  w com.apple.loginwindow GuestEnabled bool $(cfg '.loginwindow.guest_enabled')
  w com.apple.loginwindow LoginwindowText string "$(cfg '.loginwindow.login_text')"
  w com.apple.loginwindow PowerOffDisabledWhileLoggedIn bool $(cfg '.loginwindow.power_off_disabled_while_logged_in')
  w com.apple.loginwindow RestartDisabled bool $(cfg '.loginwindow.restart_disabled')
  w com.apple.loginwindow RestartDisabledWhileLoggedIn bool $(cfg '.loginwindow.restart_disabled_while_logged_in')
  w com.apple.loginwindow ShutDownDisabled bool $(cfg '.loginwindow.shutdown_disabled')
  w com.apple.loginwindow ShutDownDisabledWhileLoggedIn bool $(cfg '.loginwindow.shutdown_disabled_while_logged_in')
  w com.apple.loginwindow SleepDisabled bool $(cfg '.loginwindow.sleep_disabled')

  ##############################################################################
  # NSGlobalDomain (general UI/input)
  ##############################################################################
  w -g AppleScrollerPagingBehavior bool $(cfg '.global.scroller_paging_behavior')
  w -g AppleShowAllExtensions bool $(cfg '.global.show_all_extensions')
  w -g AppleSpacesSwitchOnActivate bool $(cfg '.global.spaces_switch_on_activate')
  w -g ApplePressAndHoldEnabled bool $(cfg '.global.press_and_hold_enabled')
  w -g InitialKeyRepeat int $(cfg '.global.initial_key_repeat')
  w -g KeyRepeat int $(cfg '.global.key_repeat')
  w -g NSAutomaticCapitalizationEnabled bool $(cfg '.global.automatic_capitalization')
  w -g NSAutomaticInlinePredictionEnabled bool $(cfg '.global.automatic_inline_prediction')
  w -g NSAutomaticDashSubstitutionEnabled bool $(cfg '.global.automatic_dash_substitution')
  w -g NSAutomaticPeriodSubstitutionEnabled bool $(cfg '.global.automatic_period_substitution')
  w -g NSAutomaticQuoteSubstitutionEnabled bool $(cfg '.global.automatic_quote_substitution')
  w -g NSAutomaticSpellingCorrectionEnabled bool $(cfg '.global.automatic_spelling_correction')
  w -g NSAutomaticWindowAnimationsEnabled bool $(cfg '.global.automatic_window_animations')
  w -g NSDocumentSaveNewDocumentsToCloud bool $(cfg '.global.save_documents_to_cloud')
  w -g NSNavPanelExpandedStateForSaveMode bool $(cfg '.global.expand_save_panel')
  w -g NSNavPanelExpandedStateForSaveMode2 bool $(cfg '.global.expand_save_panel')
  w -g NSTableViewDefaultSizeMode int $(cfg '.global.table_view_size_mode')
  w -g NSWindowResizeTime float $(cfg '.global.window_resize_time')
  w -g NSWindowShouldDragOnGesture bool $(cfg '.global.window_drag_on_gesture')
  w -g PMPrintingExpandedStateForPrint bool $(cfg '.global.expand_print_panel')
  w -g PMPrintingExpandedStateForPrint2 bool $(cfg '.global.expand_print_panel')
  w -g com.apple.mouse.tapBehavior int $(cfg '.global.mouse_tap_behavior')
  w -g com.apple.sound.beep.feedback int $(cfg '.global.sound_beep_feedback')
  w -g com.apple.springing.delay float $(cfg '.global.spring_delay')
  w -g com.apple.springing.enabled bool $(cfg '.global.spring_enabled')
  w -g com.apple.swipescrolldirection bool $(cfg '.global.swipe_scroll_direction')
  w -g com.apple.trackpad.enableSecondaryClick bool $(cfg '.global.trackpad_secondary_click')
  w -g com.apple.trackpad.forceClick bool $(cfg '.global.trackpad_force_click')
  w -g com.apple.trackpad.scaling float $(cfg '.global.trackpad_scaling')

  ##############################################################################
  # Screen saver / Screen capture
  ##############################################################################
  w com.apple.screensaver askForPassword int $(cfg '.screensaver.ask_for_password')
  w com.apple.screensaver askForPasswordDelay float $(cfg '.screensaver.ask_for_password_delay')
  SCREENSHOT_LOCATION="$(eval echo $(cfg '.screensaver.screenshot_location'))"
  mkdir -p "\$SCREENSHOT_LOCATION"
  w com.apple.screencapture location string "\$SCREENSHOT_LOCATION"
  w NSGlobalDomain _HIHideMenuBar bool $(cfg '.global.hide_menu_bar')

  killall SystemUIServer || true

  ##############################################################################
  # Spaces
  ##############################################################################
  w com.apple.spaces spans-displays bool $(cfg '.spaces.spans_displays')

  ##############################################################################
  # Trackpad (per-device domains, plus globals handled above)
  ##############################################################################
  # Built-in/USB trackpad
  w com.apple.AppleMultitouchTrackpad ActuationStrength int $(cfg '.trackpad.actuation_strength')
  w com.apple.AppleMultitouchTrackpad Clicking int $(cfg '.trackpad.clicking')
  w com.apple.AppleMultitouchTrackpad Dragging int $(cfg '.trackpad.dragging')
  w com.apple.AppleMultitouchTrackpad FirstClickThreshold int $(cfg '.trackpad.first_click_threshold')
  w com.apple.AppleMultitouchTrackpad SecondClickThreshold int $(cfg '.trackpad.second_click_threshold')
  w com.apple.AppleMultitouchTrackpad TrackpadRightClick int $(cfg '.trackpad.right_click')
  w com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag int $(cfg '.trackpad.three_finger_drag')
  w com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture int $(cfg '.trackpad.three_finger_tap_gesture')

  # Bluetooth trackpad (mirror settings; harmless if absent)
  w com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking int $(cfg '.trackpad.bluetooth_clicking')
  w com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging int $(cfg '.trackpad.bluetooth_dragging')
  w com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadRightClick int $(cfg '.trackpad.bluetooth_right_click')
  w com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag int $(cfg '.trackpad.bluetooth_three_finger_drag')
  w com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerTapGesture int $(cfg '.trackpad.bluetooth_three_finger_tap_gesture')

  ##############################################################################
  # WindowManager (Stage Manager / tiling)
  ##############################################################################
  w com.apple.WindowManager AppWindowGroupingBehavior bool $(cfg '.windowmanager.app_window_grouping')
  w com.apple.WindowManager AutoHide bool $(cfg '.windowmanager.autohide')
  w com.apple.WindowManager EnableTiledWindowMargins bool $(cfg '.windowmanager.enable_tiled_margins')
  w com.apple.WindowManager GloballyEnabled bool $(cfg '.windowmanager.globally_enabled')
  w com.apple.WindowManager EnableStandardClickToShowDesktop bool $(cfg '.windowmanager.standard_click_to_show_desktop')

  # Flush prefs caches and UI
  sudo killall cfprefsd 2>/dev/null
  killall SystemUIServer 2>/dev/null

EOF

# Add spotlight disable if configured
if [ "$(cfg '.spotlight.disable_cmd_space')" = "true" ]; then
  cat >> "$OUTPUT_FILE" << 'SPOTLIGHT'
  # Disable cmd + space => spotlight shortcut
  for id in 64 65; do
    /usr/libexec/PlistBuddy -c "Set :AppleSymbolicHotKeys:$id:enabled false" ~/Library/Preferences/com.apple.symbolichotkeys.plist 2>/dev/null ||
      /usr/libexec/PlistBuddy -c "Add :AppleSymbolicHotKeys:$id:enabled bool false" ~/Library/Preferences/com.apple.symbolichotkeys.plist
  done

  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 '<dict><key>enabled</key><false/></dict>'

SPOTLIGHT
fi

cat >> "$OUTPUT_FILE" << 'FOOTER'
  echo "macOS defaults configured."
}

configure_macos_defaults
FOOTER

chmod +x "$OUTPUT_FILE"
echo "✅ Generated $OUTPUT_FILE from $CONFIG_FILE"
