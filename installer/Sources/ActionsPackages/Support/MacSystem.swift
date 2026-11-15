import Foundation

/// The macOS tools and system locations the package kinds use that live outside `SystemEnvironment`
/// (which only describes the user's own directories). Tests point these at shims and sandbox paths.
struct MacSystem: Sendable {
    /// How long things wait and how often they poll. Tests shrink these to milliseconds.
    struct Timing: Sendable {
        /// `softwareupdate -l` sometimes comes back empty while softwareupdated is busy.
        var softwareUpdateAttempts = 3
        var softwareUpdateRetryDelay: TimeInterval = 15
        /// Generous bound on `softwareupdate -i` (about 500 MB plus a two-minute install).
        var cltInstallTimeout: TimeInterval = 60 * 60
        /// Apple's "Install Command Line Developer Tools" dialog.
        var cltDialogPollInterval: TimeInterval = 10
        var cltDialogTimeout: TimeInterval = 45 * 60
        /// Xcode: how often `xcode: finish` looks for the app.
        var xcodePollInterval: TimeInterval = 30
        /// How long the App Store sign-in question waits for an answer before App Store apps are skipped
        /// for the run: an unattended install must not stop at step 1 because nobody is at the Mac.
        var appStoreQuestionTimeout: TimeInterval = 10 * 60
        /// Bound on one `mas install`/`mas get` of an ordinary app. mas can hang (mas-cli #1222), and it waits
        /// silently while the App Store wants a password or Touch ID that nobody gives.
        var masInstallTimeout: TimeInterval = 30 * 60
        /// Bound on the background Xcode download (about 3 GB; four hours is roughly 200 KB/s). Killing mas does
        /// not stop the App Store's own download, and `xcode: finish` keeps looking for Xcode.app afterward.
        var xcodeDownloadTimeout: TimeInterval = 4 * 60 * 60
        /// If Apple's installer dialog has not shown up this long after `xcode-select --install`, it is not coming.
        var cltDialogAppearanceTimeout: TimeInterval = 2 * 60
    }

    var softwareupdate = "/usr/sbin/softwareupdate"
    var xcodeSelect = "/usr/bin/xcode-select"
    var pkgutil = "/usr/sbin/pkgutil"
    var spctl = "/usr/sbin/spctl"
    var installer = "/usr/sbin/installer"
    var codesign = "/usr/bin/codesign"
    var curl = "/usr/bin/curl"
    var hdiutil = "/usr/bin/hdiutil"
    var ditto = "/usr/bin/ditto"
    var open = "/usr/bin/open"
    var pgrep = "/usr/bin/pgrep"
    var touch = "/usr/bin/touch"
    var rm = "/bin/rm"
    var bash = "/bin/bash"
    var zsh = "/bin/zsh"
    var sh = "/bin/sh"

    var commandLineTools = URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
    /// While this file exists, `softwareupdate -l` lists the Command Line Tools (Homebrew's install.sh does the same).
    var cltPlaceholder = URL(fileURLWithPath: "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress")
    var cltReceipt = "com.apple.pkg.CLTools_Executables"
    var rosettaRuntime = URL(fileURLWithPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")

    var homebrewPackageURL = URL(string: "https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg")!
    var homebrewScriptURL = URL(string: "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")!

    var timing = Timing()
    /// True while these tools and locations are the real machine's. Sandbox runs then leave them alone
    /// (see `Common.sandboxRefusal`); tests that point everything at fakes set this to false.
    var isRealMachine = true

    static let standard = MacSystem()
}
