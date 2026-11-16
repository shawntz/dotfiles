/// Shared constants for the installer, the `shawn` CLI and the web-app shell.
public enum ShawnCore {
    /// Version of the app and CLI. Bump this (and only this) when cutting a release.
    public static let version = "1.0.0"
    /// Highest config `schema:` this build understands.
    public static let schemaVersion = 1
    /// Reverse-DNS prefix for everything the installer creates (app bundle id, web apps, launch agents).
    public static let bundleIdentifierPrefix = "com.shawnschwartz"
}
