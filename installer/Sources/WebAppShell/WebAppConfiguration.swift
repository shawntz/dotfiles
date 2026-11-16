import Foundation

/// Info.plist keys the installer writes into every generated web app.
///
/// Outside an `.app` bundle (running the bare binary during development) the same values come from
/// environment variables: `ShawnWebAppUserAgent` → `SHAWN_WEBAPP_USER_AGENT`, and so on.
enum WebAppInfoKey: String, CaseIterable {
    case url = "ShawnWebAppURL"
    case name = "ShawnWebAppName"
    case hosts = "ShawnWebAppHosts"
    case userAgent = "ShawnWebAppUserAgent"
    case width = "ShawnWebAppWidth"
    case height = "ShawnWebAppHeight"

    var environmentName: String {
        switch self {
        case .url: return "SHAWN_WEBAPP_URL"
        case .name: return "SHAWN_WEBAPP_NAME"
        case .hosts: return "SHAWN_WEBAPP_HOSTS"
        case .userAgent: return "SHAWN_WEBAPP_USER_AGENT"
        case .width: return "SHAWN_WEBAPP_WIDTH"
        case .height: return "SHAWN_WEBAPP_HEIGHT"
        }
    }
}

struct WebAppConfigurationError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

/// Everything one web app knows about itself.
struct WebAppConfiguration: Equatable {
    enum Source: String {
        case bundle
        case environment
    }

    static let defaultWidth = 1200
    static let defaultHeight = 800
    static let sizeRange = 320...10_000
    /// Same prefix the installer uses for `bundle_id:`'s default.
    static let bundleIdentifierPrefix = "com.shawnschwartz.webapp."

    var source: Source
    var url: URL
    var name: String
    /// Extra hosts (and their subdomains) that stay in the app besides the URL's own site.
    var hosts: [String]
    /// Replaces the whole user agent; nil means WebKit's own plus a Safari suffix.
    var userAgent: String?
    var width: Int
    var height: Int
    var bundleIdentifier: String

    var policy: SitePolicy { SitePolicy(homeURL: url, extraHosts: hosts) }
    var site: String { policy.homeSite }
    /// The window remembers its frame under this name.
    var frameAutosaveName: String { bundleIdentifier }

    // MARK: Loading

    /// The running executable's configuration: its bundle's Info.plist inside an `.app`, the environment otherwise.
    static func current(bundle: Bundle = .main,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> WebAppConfiguration {
        if bundle.bundleURL.pathExtension.lowercased() == "app" {
            let info = bundle.infoDictionary ?? [:]
            return try parse(info, source: .bundle, bundleIdentifier: bundle.bundleIdentifier,
                             fallbackName: info["CFBundleName"] as? String)
        }
        var values: [String: Any] = [:]
        for key in WebAppInfoKey.allCases {
            if let value = environment[key.environmentName] { values[key.rawValue] = value }
        }
        return try parse(values, source: .environment, bundleIdentifier: nil, fallbackName: nil)
    }

    /// Validates raw values (Info.plist types, or strings from the environment).
    static func parse(_ values: [String: Any], source: Source, bundleIdentifier: String?,
                      fallbackName: String?) throws -> WebAppConfiguration {
        let origin = source == .bundle ? "this app's Info.plist" : "the environment"
        func label(_ key: WebAppInfoKey) -> String { source == .bundle ? key.rawValue : key.environmentName }

        guard let rawURL = (values[WebAppInfoKey.url.rawValue] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            throw WebAppConfigurationError(message: "\(label(.url)) is missing from \(origin); it names the site this app opens")
        }
        let url = try validatedURL(rawURL, key: label(.url))

        let name = nonEmptyString(values[WebAppInfoKey.name.rawValue]) ?? nonEmptyString(fallbackName) ?? (url.host ?? rawURL)
        let hosts = try parseHosts(values[WebAppInfoKey.hosts.rawValue], key: label(.hosts))
        let userAgent = nonEmptyString(values[WebAppInfoKey.userAgent.rawValue])
        let width = try parseSize(values[WebAppInfoKey.width.rawValue], key: label(.width)) ?? defaultWidth
        let height = try parseSize(values[WebAppInfoKey.height.rawValue], key: label(.height)) ?? defaultHeight

        let identifier = nonEmptyString(bundleIdentifier) ?? bundleIdentifierPrefix + slug(name)
        return WebAppConfiguration(source: source, url: url, name: name, hosts: hosts, userAgent: userAgent,
                                   width: width, height: height, bundleIdentifier: identifier)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func validatedURL(_ text: String, key: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw WebAppConfigurationError(message: "\(key) is not a valid web address: \(text)")
        }
        // Plain http only for a server on this Mac (local development); everything else must be encrypted.
        guard scheme == "https" || (scheme == "http" && SitePolicy.isLoopback(host)) else {
            throw WebAppConfigurationError(message: "\(key) must be an https:// address (got \(text))")
        }
        return url
    }

    private static func parseHosts(_ value: Any?, key: String) throws -> [String] {
        let entries: [String]
        switch value {
        case nil:
            entries = []
        case let list as [Any]:
            entries = try list.map { element in
                guard let text = element as? String else {
                    throw WebAppConfigurationError(message: "\(key) must be a list of host names")
                }
                return text
            }
        case let text as String:
            entries = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        default:
            throw WebAppConfigurationError(message: "\(key) must be a list of host names")
        }

        var hosts: [String] = []
        for entry in entries {
            guard let host = SitePolicy.normalizedHostPattern(entry) else {
                throw WebAppConfigurationError(message: "\(key) entry '\(entry)' is not a host name (expected something like 'twitter.com')")
            }
            if !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    private static func parseSize(_ value: Any?, key: String) throws -> Int? {
        guard let value else { return nil }
        let number: Int?
        switch value {
        case let integer as Int: number = integer
        case let text as String: number = Int(text.trimmingCharacters(in: .whitespaces))
        default: number = nil
        }
        guard let number else {
            throw WebAppConfigurationError(message: "\(key) must be a whole number of points")
        }
        guard sizeRange.contains(number) else {
            throw WebAppConfigurationError(message: "\(key) must be between \(sizeRange.lowerBound) and \(sizeRange.upperBound) (got \(number))")
        }
        return number
    }

    /// `my-app` for "My App!". Matches the installer's default bundle id suffix.
    static func slug(_ name: String) -> String {
        var result = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty, !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "app" : result
    }

    // MARK: Reporting

    /// What `--print-config` prints.
    var report: [String: Any] {
        [
            "source": source.rawValue,
            "url": url.absoluteString,
            "name": name,
            "site": site,
            "hosts": hosts,
            "userAgent": userAgent.map { $0 as Any } ?? NSNull(),
            "width": width,
            "height": height,
            "bundleIdentifier": bundleIdentifier,
            "frameAutosaveName": frameAutosaveName,
        ]
    }
}
