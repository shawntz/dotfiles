/// Shared constants for the installer, the `shawn` CLI and the web-app shell.
public enum ShawnCore {
    /// The app's name: its bundle is `Dotfiles.app`, and its menus say "Quit Dotfiles". `scripts/common.sh`
    /// (`APP_NAME`) and `Resources/Info.plist` state it too, and `AppNameTests` fails when they disagree.
    /// What the app sets up is named by the config (`name:` in installer.yaml), not by this.
    public static let appName = "Dotfiles"
    /// Version of the app and CLI. Bump this (and only this) when cutting a release.
    public static let version = "1.0.1"
    /// Highest config `schema:` this build understands.
    public static let schemaVersion = 1
    /// Reverse-DNS prefix for everything the installer creates (app bundle id, web apps, launch agents).
    public static let bundleIdentifierPrefix = "com.shawnschwartz"
}
