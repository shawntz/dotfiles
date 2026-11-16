import CryptoKit
import Foundation
import ShawnCore

/// A `webapp:` item with its variables expanded and paths resolved for this machine.
struct ResolvedWebApp: Sendable {
    enum Icon: Sendable, Equatable {
        /// The site's own icon, or a letter tile.
        case automatic
        /// A file under the config directory (`display` is the path as written).
        case file(URL, display: String)
        case remote(URL)

        var description: String {
            switch self {
            case .automatic: return "the site's own icon (or a letter tile)"
            case .file(_, let display): return display
            case .remote(let url): return url.absoluteString
            }
        }
    }

    let name: String
    let url: URL
    let bundleURL: URL
    let bundleIdentifier: String
    let userAgent: String?
    let width: Int?
    let height: Int?
    let hosts: [String]
    let icon: Icon

    var executableURL: URL { bundleURL.appendingPathComponent("Contents/MacOS/\(name)") }
    var infoPlistURL: URL { bundleURL.appendingPathComponent("Contents/Info.plist") }
    var iconFileURL: URL { bundleURL.appendingPathComponent("Contents/Resources/\(WebAppInfoPlist.iconFileName).icns") }
}

/// Where the shell binary every web app is a copy of comes from.
enum WebAppShellLocator {
    static let binaryName = "WebAppShell"

    /// The app bundle's helpers first, then the copy `shawn-cli` keeps in `~/.shawn/bin`.
    static func candidates(in environment: SystemEnvironment) -> [URL] {
        var result: [URL] = []
        if let helpers = environment.helpersDirectory { result.append(helpers.appendingPathComponent(binaryName)) }
        result.append(environment.stateDirectory.appendingPathComponent("bin/\(binaryName)"))
        return result
    }

    static func locate(in environment: SystemEnvironment) -> URL? {
        candidates(in: environment).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func missingError(_ context: ActionContext) -> ActionError {
        let searched = candidates(in: context.environment).map { context.display($0) }.joined(separator: " or ")
        return ActionError(
            "WebAppShell, the program inside every web app, is missing (looked for \(searched))",
            hint: "Run the installer app, which carries it, or build it with 'swift build -c release --product WebAppShell' in installer/ and copy .build/release/WebAppShell to ~/.shawn/bin/"
        )
    }
}

enum Digest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The generated bundle's Info.plist: normal app keys plus everything WebAppShell reads.
enum WebAppInfoPlist {
    static let iconFileName = "AppIcon"
    /// Present in every bundle this installer generates.
    static let urlKey = "ShawnWebAppURL"
    /// What the icon was made from as configured: `auto`, `file:<path>#<sha256>` or `url:<address>`; or, when the
    /// site's own icon stands in for that address, why (`IconFallback`): `url-failed:<address>` or `url-unusable:<address>`.
    static let iconKey = "ShawnWebAppIcon"
    /// The artwork actually used (`site:<address>`, `letter`, ...). For people, not for comparisons.
    static let iconOriginKey = "ShawnWebAppIconOrigin"
    static let shellDigestKey = "ShawnWebAppShellSHA256"
    static let informationalKeys: Set<String> = [iconOriginKey]

    static func iconRecord(remote url: URL) -> String { "url:\(url.absoluteString)" }

    /// Why a configured icon address gave no icon, so the site's own icon stands in.
    enum IconFallback: String, CaseIterable, Sendable {
        /// The address could not be downloaded.
        case unreachable = "url-failed"
        /// It downloaded, but is not an image that can be used (an SVG, a web page).
        case unusable = "url-unusable"
    }

    /// Recorded instead of `iconRecord(remote:)` when the address gave no icon, so the next run knows to try again
    /// and can say why, rather than report that the icon changed.
    static func fallbackIconRecord(remote url: URL, _ fallback: IconFallback) -> String {
        "\(fallback.rawValue):\(url.absoluteString)"
    }

    /// Why the bundle `info` describes has a stand-in for the icon at `url`; nil when it does not.
    static func iconFallback(remote url: URL, in info: [String: Any]) -> IconFallback? {
        IconFallback.allCases.first { info[iconKey] as? String == fallbackIconRecord(remote: url, $0) }
    }

    static func make(_ app: ResolvedWebApp, shellDigest: String, iconRecord: String, iconOrigin: String? = nil) -> [String: Any] {
        let host = app.url.host ?? app.url.absoluteString
        var info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": app.name,
            "CFBundleExecutable": app.name,
            "CFBundleIconFile": iconFileName,
            "CFBundleIdentifier": app.bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": app.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": ShawnCore.version,
            "CFBundleVersion": ShawnCore.version,
            "LSMinimumSystemVersion": "27.0",
            // Files the app downloads get the same Gatekeeper check as a browser's downloads.
            "LSFileQuarantineEnabled": true,
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "NSAppTransportSecurity": ["NSAllowsArbitraryLoadsInWebContent": true],
            "NSCameraUsageDescription": "\(app.name) uses the camera when \(host) asks for it, for example in a video call.",
            "NSMicrophoneUsageDescription": "\(app.name) uses the microphone when \(host) asks for it, for example in a call.",
            urlKey: app.url.absoluteString,
            "ShawnWebAppName": app.name,
            "ShawnWebAppHosts": app.hosts,
            iconKey: iconRecord,
            shellDigestKey: shellDigest,
        ]
        if let userAgent = app.userAgent { info["ShawnWebAppUserAgent"] = userAgent }
        if let width = app.width { info["ShawnWebAppWidth"] = width }
        if let height = app.height { info["ShawnWebAppHeight"] = height }
        if let iconOrigin { info[iconOriginKey] = iconOrigin }
        return info
    }

    static func serialize(_ info: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    }

    static func read(bundle: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: bundle.appendingPathComponent("Contents/Info.plist").path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return plist as? [String: Any]
    }

    /// True when the bundle was generated by this installer (so rebuilding it destroys nothing of the user's).
    static func isGenerated(_ info: [String: Any]) -> Bool {
        info[urlKey] is String
    }

    /// The YAML options (or other inputs) whose values differ, in words, e.g. `["url", "icon"]`.
    static func differences(expected: [String: Any], actual: [String: Any]) -> [String] {
        let keys = Set(expected.keys).union(actual.keys).subtracting(informationalKeys)
        var labels: [String] = []
        for key in keys.sorted() {
            let same: Bool
            switch (expected[key], actual[key]) {
            case (nil, nil): same = true
            case (let wanted?, let present?): same = (wanted as AnyObject).isEqual(present)
            default: same = false
            }
            if !same, !labels.contains(label(for: key)) { labels.append(label(for: key)) }
        }
        return labels
    }

    private static func label(for key: String) -> String {
        switch key {
        case urlKey: return "url"
        case "ShawnWebAppName", "CFBundleName", "CFBundleDisplayName", "CFBundleExecutable": return "name"
        case "ShawnWebAppHosts": return "hosts"
        case "ShawnWebAppUserAgent": return "user_agent"
        case "ShawnWebAppWidth": return "width"
        case "ShawnWebAppHeight": return "height"
        case "CFBundleIdentifier": return "bundle_id"
        case iconKey: return "icon"
        case shellDigestKey: return "WebAppShell"
        case "CFBundleShortVersionString", "CFBundleVersion": return "installer version"
        default: return "Info.plist \(key)"
        }
    }
}
