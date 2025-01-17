{ pkgs, username, ... }:

###########################
### macOS System Config ###
###########################

{
  system = {
    stateVersion = 5;

    # activationScripts are executed every time you boot the system or run `nixos-rebuild` / `darwin-rebuild`.
    activationScripts.postUserActivation.text = ''
      # activateSettings -u will reload the settings from the database and apply them to the current session,
      # so we do not need to logout and login again to make the changes take effect.
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    '';

    defaults = {
      alf = {
        allowdownloadsignedenabled = 1;  # Default is 0
        allowsignedenabled = 1;  # Default is true
        globalstate = 0;  # 0 = disabled 1 = enabled 2 = blocks all connections except for essential services
      };

      controlcenter = {
	    NowPlaying = true;  # Default is null
      };

      dock = {
        autohide = true;  # Default is false
        autohide-delay = 0.0;  # Default is (0.24).
        autohide-time-modifier = 0.0;  # Default is (1.0).
        enable-spring-load-actions-on-all-items = true;  # Default is false.
        appswitcher-all-displays = true;  # Default is false.
        dashboard-in-overlay = true;  # Default is false.
        expose-animation-duration = 0.0;  # Default is (1.0).
        expose-group-apps = true;  # Default is false.
        launchanim = false;  # Default is true.
        mineffect = "suck";  # Type: null or one of “genie” (default), “suck”, “scale”
        minimize-to-application = true;  # Default is false.
        mru-spaces = false;  # Auto rearrange spaces based on (m)ost (r)ecent (u)se. Default is true.
        orientation = "bottom";  # Type: null or one of “bottom” (default), “left”, “right”

        # Persistent applications in the dock.
        # Type: null or (list of (path or string))
        persistent-apps = [
          "/Applications/Beeper.app"
          "/Applications/HEY.app"
          "/Applications/Basecamp 3.app"
          "${pkgs.google-chrome}/Applications/Google Chrome.app"
          "${pkgs.slack}/Applications/Slack.app"
          "/Applications/Ghostty.app"
          "/Applications/Xcode.app"
          "/Applications/ChatGPT.app"
          "/System/Applications/Music.app"
          "/System/Applications/System Settings.app"
        ];

        # Persistent folders in the dock.
        # Type: null or (list of (path or string))
        persistent-others = [
          "/Users/${username}/Downloads/"
        ];

        scroll-to-open = true;  # Defualt is false.
        show-process-indicators = true;  # Default is true.
        show-recents = false;  # Default is true.
        showhidden = true;  # Default is false.
        slow-motion-allowed = false;  # Default is false.
        static-only = false;  # Default is false.
        tilesize = 64;  # Default is (64).

        # Hot corner actions. Valid values include:
        #
        # 1: Disabled
        # 2: Mission Control
        # 3: Application Windows
        # 4: Desktop
        # 5: Start Screen Saver
        # 6: Disable Screen Saver
        # 7: Dashboard
        # 10: Put Display to Sleep
        # 11: Launchpad
        # 12: Notification Center
        # 13: Lock Screen
        # 14: Quick Note
        #
        # Type: null or (positive integer, meaning >0)

        wvous-bl-corner = 1;  # bottom left corner
        wvous-br-corner = 1;  # bottom right corner
        wvous-tl-corner = 1;  # top left corner
        wvous-tr-corner = 1;  # top right corner
      };

      finder = {
        AppleShowAllExtensions = true;  # Default is false.
        FXDefaultSearchScope = "SCcf";  # Use “SCcf” to default to current folder. The default is unset (“This Mac”).
        FXEnableExtensionChangeWarning = false;  # Default is true.
        FXPreferredViewStyle = "clmv";  # “icnv” = Icon (default), “Nlsv” = List, “clmv” = Column, “Flwv” = Gallery.

        # Change the default folder shown in Finder windows.
        # “Other” corresponds to the value of NewWindowTargetPath. The default is unset (“Recents”).
        # Type: null or one of “Computer”, “OS volume”, “Home”, “Desktop”, “Documents”, “Recents”, “iCloud Drive”, “Other”
        NewWindowTarget = "Home";

        QuitMenuItem = true;  # Default is false.
        ShowExternalHardDrivesOnDesktop = true;  # Default is true.
        ShowHardDrivesOnDesktop = true;  # Default is false.
        ShowMountedServersOnDesktop = true;  # Default is false.
        ShowPathbar = true;  # Default is false.
        ShowRemovableMediaOnDesktop = true;  # Default is true.
        ShowStatusBar = true;  # Defualt is false.
        _FXShowPosixPathInTitle = false;  # Default is false.
        _FXSortFoldersFirst = true;  # Default is false.
        _FXSortFoldersFirstOnDesktop = true;  # Default is false.
      };

      LaunchServices = {
	    LSQuarantine = false;  # Default is true.
      };

      loginwindow = {
        GuestEnabled = true;  # Default is true.
        LoginwindowText = "if found, contact s@shawnts.com";  # Default is “\\U03bb”.
        PowerOffDisabledWhileLoggedIn = false;  # Default is false.
        RestartDisabled = false;  # Default is false.
        RestartDisabledWhileLoggedIn = false;  # Default is false.
        ShutDownDisabled = false;  # Default is false.
        ShutDownDisabledWhileLoggedIn = false;  # Default is false.
        SleepDisabled = false;  # Default is false.
        autoLoginUser = "On";  # Default is "Off".
      };

      NSGlobalDomain = {
        AppleScrollerPagingBehavior = true;  # Default is false.
        AppleShowAllExtensions = true;  # Default is false.
        AppleSpacesSwitchOnActivate = false;  # Default is true.
        InitialKeyRepeat = 10;
        KeyRepeat = 1;
        NSAutomaticCapitalizationEnabled = false;  # Default is true.
        NSAutomaticInlinePredictionEnabled = false;  # Default is true.
        NSAutomaticDashSubstitutionEnabled = true;  # Default is true.
        NSAutomaticPeriodSubstitutionEnabled = true;  # Default is true.
        NSAutomaticQuoteSubstitutionEnabled = false;  # Default is true.
        NSAutomaticSpellingCorrectionEnabled = false;  # Default is true.
        NSAutomaticWindowAnimationsEnabled = false;  # Default is true.
        NSDocumentSaveNewDocumentsToCloud = true;  # Default is true.
        NSNavPanelExpandedStateForSaveMode = true;  # Default is false.
        NSNavPanelExpandedStateForSaveMode2 = true;  # Default is false.
        NSTableViewDefaultSizeMode = 3;  # Size of finder sidebar icons: 1 (small), 2 (medium) or 3 (large) (default).
        NSWindowResizeTime = 1.0;  # Default is (0.2).
        NSWindowShouldDragOnGesture = true;  # Default is false.
        PMPrintingExpandedStateForPrint = true;  # Default is false.
        PMPrintingExpandedStateForPrint2 = true;  # Default is false.
        "com.apple.mouse.tapBehavior" = 1;  # Mode 1 enables tap to click.
        "com.apple.sound.beep.feedback" = 1;  # Defaults to 1 (feedback sound when changing system volume).
        "com.apple.springing.delay" = 0.0;  # Default is (1.0).
        "com.apple.springing.enabled" = false;
        "com.apple.swipescrolldirection" = true;  # Default is true.
        "com.apple.trackpad.enableSecondaryClick" = true;  # Default is true.
        "com.apple.trackpad.forceClick" = true;
        "com.apple.trackpad.scaling" = 3.0;  # Configures the trackpad tracking speed (0 to 3). The default is “1”.
      };

      screensaver = {
        askForPassword = true;  # Default is false.
        askForPasswordDelay = 5;  # Number of seconds for screen saver / password grace period.
      };

	  screencapture.location = "~/Pictures/screenshots";

      spaces = {
        # false = each physical display has a separate space (Mac default)
        # true = one space spans across all physical displays
        spans-displays = false;
      };

      trackpad = {
        ActuationStrength = 0;  # 0 to enable Silent Clicking, 1 to disable. The default is 1.
        Clicking = true;  # Whether to enable trackpad tap to click. The default is false.
        Dragging = true;  # Whether to enable tap-to-drag. The default is false.
        FirstClickThreshold = 2;  # For normal click: 0 for light clicking, 1 for medium, 2 for firm. The default is 1.
        SecondClickThreshold = 2;  # For force touch: 0 for light clicking, 1 for medium, 2 for firm. The default is 1.
        TrackpadRightClick = true;  # Whether to enable trackpad right click. The default is false.
        TrackpadThreeFingerDrag = true;  # Whether to enable three finger drag. The default is false.
        TrackpadThreeFingerTapGesture = 2;  # 0 to disable three finger tap, 2 to trigger Look up & data detectors. The default is 2.
      };

      WindowManager = {
        AppWindowGroupingBehavior = true;  # false means “One at a time” true means “All at once”
        AutoHide = true;  # Auto hide stage strip showing recent apps. Default is false.
        EnableTiledWindowMargins = true;  # Enable Window Margins. The default is true.
      };

      universalaccess = {
        closeViewScrollWheelToggle = true;  # Use scroll gesture with the Ctrl (^) modifier key to zoom. The default is false.
        closeViewZoomFollowsFocus = true;  # Without setting closeViewScrollWheelToggle this has no effect. The default is false.
        mouseDriverCursorSize = 1.5;  # Set the size of cursor. 1 for normal, 4 for maximum. The default is 1.
      };
    };
  };

  # Add ability to used TouchID for sudo authentication
  security.pam.enableSudoTouchIdAuth = true;
}
