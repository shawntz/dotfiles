configure_macos_defaults() {
  set -euo pipefail

  # Optional: ask for admin once and keep it alive
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    sudo -v
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
  fi

  # Helper to write defaults with nice logging
  w() { local domain="$1" key="$2" type="$3" value="$4"; echo "defaults write ${domain} ${key} -${type} ${value}"; defaults write "$domain" "$key" "-$type" "$value"; }

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
  #  allowdownloadsignedenabled=1, allowsignedenabled=1, globalstate=0 (off)
  ##############################################################################
  sudo defaults write /Library/Preferences/com.apple.alf allowdownloadsignedenabled -int 1
  sudo defaults write /Library/Preferences/com.apple.alf allowsignedenabled        -int 1
  sudo defaults write /Library/Preferences/com.apple.alf globalstate               -int 0
  # Reload firewall agent
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate >/dev/null || true

  ##############################################################################
  # Control Center: hide Now Playing (Best-effort key)
  ##############################################################################
  # Many macOS versions use this visibility key; harmless if it changes.
  w com.apple.controlcenter "NSStatusItem Visible NowPlaying" bool false

  ##############################################################################
  # Dock
  ##############################################################################
  w com.apple.dock autohide                  bool  false
  w com.apple.dock autohide-delay            float 0.0
  w com.apple.dock autohide-time-modifier    float 0.0
  w com.apple.dock enable-spring-load-actions-on-all-items bool true
  w com.apple.dock appswitcher-all-displays  bool  true
  w com.apple.dock dashboard-in-overlay      bool  true
  w com.apple.dock expose-animation-duration float 0.0
  w com.apple.dock expose-group-apps         bool  true
  w com.apple.dock launchanim                bool  false
  w com.apple.dock mineffect                 string "suck"
  w com.apple.dock minimize-to-application   bool  false
  w com.apple.dock mru-spaces                bool  false
  w com.apple.dock orientation               string "bottom"
  w com.apple.dock scroll-to-open            bool  true
  w com.apple.dock show-process-indicators   bool  true
  w com.apple.dock show-recents              bool  false
  w com.apple.dock showhidden                bool  true
  w com.apple.dock static-only               bool  false
  w com.apple.dock tilesize                  int   64

  # Dock content
  "$DOCKUTIL" --remove all --no-restart || true
  killall Dock || true
  
  "$DOCKUTIL" --remove "Downloads" --no-restart || true
  "$DOCKUTIL" --add "$HOME/Downloads" --view fan --sort dateadded --display folder --no-restart || true
  
  # Curate persistent apps (skips missing apps gracefully)
  add_app() { [ -d "$1" ] && "$DOCKUTIL" --add "$1" --no-restart || true; }
  add_app "/System/Applications/Calendar.app"
  add_app "/Applications/Google Chrome.app"
  add_app "/Applications/Ghostty.app"
  add_app "/Applications/Xcode.app"
  add_app "/Applications/Visual Studio Code.app"
  add_app "/Applications/RStudio.app"
  add_app "/System/Applications/Music.app"
  add_app "/Applications/Slack.app"
  add_app "/System/Applications/Messages.app"

  killall Dock || true

  ##############################################################################
  # Finder
  ##############################################################################
  w com.apple.finder AppleShowAllExtensions        bool   true
  w com.apple.finder FXDefaultSearchScope          string "SCcf"     # current folder
  w com.apple.finder FXEnableExtensionChangeWarning bool  false
  w com.apple.finder FXPreferredViewStyle          string "clmv"     # Column view
  # New window target: Home (PfHm) and explicit path
  w com.apple.finder NewWindowTarget               string "PfHm"
  w com.apple.finder NewWindowTargetPath           string "file://${HOME}/"
  w com.apple.finder QuitMenuItem                  bool   true
  w com.apple.finder ShowExternalHardDrivesOnDesktop bool true
  w com.apple.finder ShowHardDrivesOnDesktop       bool   true
  w com.apple.finder ShowMountedServersOnDesktop   bool   true
  w com.apple.finder ShowPathbar                   bool   true
  w com.apple.finder ShowRemovableMediaOnDesktop   bool   true
  w com.apple.finder ShowStatusBar                 bool   true
  w com.apple.finder _FXShowPosixPathInTitle       bool   false
  w com.apple.finder _FXSortFoldersFirst           bool   true
  w com.apple.finder _FXSortFoldersFirstOnDesktop  bool   true

  killall Finder || true

  ##############################################################################
  # LaunchServices
  ##############################################################################
  w com.apple.LaunchServices LSQuarantine bool false

  ##############################################################################
  # Login Window
  ##############################################################################
  w com.apple.loginwindow GuestEnabled                   bool  true
  w com.apple.loginwindow LoginwindowText                string "if found, contact s@shawnts.com"
  w com.apple.loginwindow PowerOffDisabledWhileLoggedIn  bool  false
  w com.apple.loginwindow RestartDisabled                bool  false
  w com.apple.loginwindow RestartDisabledWhileLoggedIn   bool  false
  w com.apple.loginwindow ShutDownDisabled               bool  false
  w com.apple.loginwindow ShutDownDisabledWhileLoggedIn  bool  false
  w com.apple.loginwindow SleepDisabled                  bool  false
  # Note: autoLoginUser requires secure additional steps; left as-is in nix but usually avoided.

  ##############################################################################
  # NSGlobalDomain (general UI/input)
  ##############################################################################
  w -g AppleScrollerPagingBehavior           bool  true
  w -g AppleShowAllExtensions                bool  true
  w -g AppleSpacesSwitchOnActivate           bool  false
  w -g ApplePressAndHoldEnabled 			 bool  false
  w -g InitialKeyRepeat                      int   10
  w -g KeyRepeat                             int   1
  w -g NSAutomaticCapitalizationEnabled      bool  false
  w -g NSAutomaticInlinePredictionEnabled    bool  false
  w -g NSAutomaticDashSubstitutionEnabled    bool  true
  w -g NSAutomaticPeriodSubstitutionEnabled  bool  true
  w -g NSAutomaticQuoteSubstitutionEnabled   bool  false
  w -g NSAutomaticSpellingCorrectionEnabled  bool  false
  w -g NSAutomaticWindowAnimationsEnabled    bool  false
  w -g NSDocumentSaveNewDocumentsToCloud     bool  true
  w -g NSNavPanelExpandedStateForSaveMode    bool  true
  w -g NSNavPanelExpandedStateForSaveMode2   bool  true
  w -g NSTableViewDefaultSizeMode            int   3
  w -g NSWindowResizeTime                    float 1.0
  w -g NSWindowShouldDragOnGesture           bool  true
  w -g PMPrintingExpandedStateForPrint       bool  true
  w -g PMPrintingExpandedStateForPrint2      bool  true
  w -g com.apple.mouse.tapBehavior           int   1
  w -g com.apple.sound.beep.feedback         int   1
  w -g com.apple.springing.delay             float 0.0
  w -g com.apple.springing.enabled           bool  false
  w -g com.apple.swipescrolldirection        bool  true
  w -g com.apple.trackpad.enableSecondaryClick bool true
  w -g com.apple.trackpad.forceClick         bool  true
  w -g com.apple.trackpad.scaling            float 3.0

  ##############################################################################
  # Screen saver / Screen capture
  ##############################################################################
  w com.apple.screensaver askForPassword      int   1
  w com.apple.screensaver askForPasswordDelay float 5
  w com.apple.screencapture location          string "$HOME/Pictures/screenshots"
  w NSGlobalDomain _HIHideMenuBar 			  bool  true

  killall SystemUIServer || true

  ##############################################################################
  # Spaces
  ##############################################################################
  w com.apple.spaces spans-displays bool false

  ##############################################################################
  # Trackpad (per-device domains, plus globals handled above)
  ##############################################################################
  # Built-in/USB trackpad
  w com.apple.AppleMultitouchTrackpad ActuationStrength      int 0
  w com.apple.AppleMultitouchTrackpad Clicking               int 1
  w com.apple.AppleMultitouchTrackpad Dragging               int 1
  w com.apple.AppleMultitouchTrackpad FirstClickThreshold    int 2
  w com.apple.AppleMultitouchTrackpad SecondClickThreshold   int 2
  w com.apple.AppleMultitouchTrackpad TrackpadRightClick     int 1
  w com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag int 1
  w com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture int 2

  # Bluetooth trackpad (mirror settings; harmless if absent)
  w com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking             int 1
  w com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging             int 1
  w com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadRightClick   int 1
  w com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag int 1
  w com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerTapGesture int 2

  ##############################################################################
  # WindowManager (Stage Manager / tiling)
  ##############################################################################
  w com.apple.WindowManager AppWindowGroupingBehavior bool true
  w com.apple.WindowManager AutoHide                  bool true
  w com.apple.WindowManager EnableTiledWindowMargins  bool false
  w com.apple.WindowManager GloballyEnabled   		  bool false
  w com.apple.WindowManager EnableStandardClickToShowDesktop  bool  false

  killall WindowManager

  # Flush prefs caches and UI
  sudo killall cfprefsd 2>/dev/null
  killall SystemUIServer 2>/dev/null

  # Disable cmd + space => spotlight shortcut
  for id in 64 65; do
    /usr/libexec/PlistBuddy -c "Set :AppleSymbolicHotKeys:$id:enabled false" ~/Library/Preferences/com.apple.symbolichotkeys.plist 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :AppleSymbolicHotKeys:$id:enabled bool false" ~/Library/Preferences/com.apple.symbolichotkeys.plist
  done
  
  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 '<dict><key>enabled</key><false/></dict>'
  
  killall Dock; killall SystemUIServer

  echo "macOS defaults configured."
}

configure_macos_defaults