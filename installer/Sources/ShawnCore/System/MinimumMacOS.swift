import Foundation

/// The oldest macOS that the app, `shawn` and the generated web apps run on.
///
/// Two files state the same version and cannot read this one: `Package.swift` (`platforms`) and
/// `Resources/Info.plist` (`LSMinimumSystemVersion`). Change all three together. `MinimumMacOSTests`
/// fails when they disagree.
public enum MinimumMacOS {
    public static let major = 27

    /// The value an Info.plist takes for `LSMinimumSystemVersion`: "27.0".
    public static let infoPlistValue = "\(major).0"

    /// Whether a Mac running `version` is new enough.
    public static func allows(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= major
    }

    /// "26.7.2", or "26.7" when the patch number is 0.
    public static func describe(_ version: OperatingSystemVersion) -> String {
        let short = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? short : "\(short).\(version.patchVersion)"
    }
}
