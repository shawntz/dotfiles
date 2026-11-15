import Foundation
import ShawnCore

/// The `webapp` kind: standalone site-specific apps built on the bundled WebAppShell.
public enum WebAppActions {
    /// Every item kind this module provides.
    public static var descriptors: [ActionDescriptor] { descriptors(fetcher: URLSessionFetcher()) }

    /// The same kinds, downloading icons and pages through `fetcher` (tests pass one that never touches the network).
    public static func descriptors(fetcher: any WebAppFetching) -> [ActionDescriptor] {
        [
            ActionDescriptor(
                kind: "webapp",
                summary: "A standalone Mac app for a website: its own window, Dock icon and saved login (built on WebAppShell). "
                    + "Icons you supply go in config/\(WebAppRules.iconFolder)/.",
                example: """
                - webapp: X
                  url: https://x.com
                  hosts: [twitter.com]       # optional: other hosts that stay inside the app
                  icon: \(WebAppRules.iconFolder)/x.png   # optional: png/jpg/icns in config/\(WebAppRules.iconFolder)/, or an https URL
                """,
                make: { parser in WebAppAction(spec: WebAppSpec.parse(parser), fetcher: fetcher) }
            ),
        ]
    }
}

/// One `webapp:` item as written in the YAML. Strings may still contain `{{variables}}`.
struct WebAppSpec: Equatable, Sendable {
    var name: String
    var url: String
    var icon: String?
    var to: String
    var bundleID: String?
    var userAgent: String?
    var width: Int?
    var height: Int?
    var hosts: [String]

    static let sizeRange = 320...10_000
    static let iconExtensions: Set<String> = ["png", "jpg", "jpeg", "icns"]

    static func parse(_ parser: ItemParser) -> WebAppSpec {
        let options = parser.options
        let name = parser.primaryString().trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let problem = WebAppRules.nameProblem(name) { parser.fail(problem) }

        let url = options.requiredString("url").trimmingCharacters(in: .whitespaces)
        if !url.isEmpty, !url.contains("{{"), let problem = WebAppRules.urlProblem(url) { options.error(problem, key: "url") }

        let icon = options.string("icon")?.trimmingCharacters(in: .whitespaces)
        if let icon, let problem = WebAppRules.iconProblem(icon) { options.error(problem, key: "icon") }

        let to = options.string("to", default: "{{applications}}")
        let bundleID = options.string("bundle_id")?.trimmingCharacters(in: .whitespaces)
        if let bundleID, !bundleID.contains("{{"), let problem = WebAppRules.bundleIDProblem(bundleID) {
            options.error(problem, key: "bundle_id")
        }
        if bundleID == nil, !name.isEmpty, WebAppRules.slug(name).isEmpty {
            parser.fail("cannot make a bundle id from the name '\(name)'; add 'bundle_id: \(ShawnCore.bundleIdentifierPrefix).webapp.something'")
        }

        let userAgent = options.string("user_agent")
        let width = size(options, "width")
        let height = size(options, "height")

        var hosts: [String] = []
        for entry in options.stringList("hosts") {
            if entry.contains("{{") {
                hosts.append(entry)
            } else if let host = WebAppRules.normalizedHost(entry) {
                if !hosts.contains(host) { hosts.append(host) }
            } else {
                options.error("'hosts' entries are host names like 'twitter.com', not '\(entry)'", key: "hosts")
            }
        }

        return WebAppSpec(name: name, url: url, icon: icon, to: to, bundleID: bundleID, userAgent: userAgent,
                          width: width, height: height, hosts: hosts)
    }

    private static func size(_ options: MapReader, _ key: String) -> Int? {
        guard let value = options.int(key) else { return nil }
        guard sizeRange.contains(value) else {
            options.error("'\(key)' must be between \(sizeRange.lowerBound) and \(sizeRange.upperBound) points (got \(value))", key: key)
            return nil
        }
        return value
    }

    /// Every string option, for the unknown-variable check.
    var templatedFields: [(field: String, text: String)] {
        var fields: [(String, String)] = [("url", url), ("to", to)]
        if let icon { fields.append(("icon", icon)) }
        if let bundleID { fields.append(("bundle_id", bundleID)) }
        if let userAgent { fields.append(("user_agent", userAgent)) }
        fields += hosts.map { ("hosts", $0) }
        return fields
    }
}

/// Checks shared by YAML parsing and the expanded values at run time.
enum WebAppRules {
    /// Where icons for `icon:` live, relative to the config directory. Any path under it works, but not a
    /// folder named `icons`: the dotfiles repo's .gitignore pattern `Icon?` (matched without regard to case)
    /// hides it, so its images would never reach GitHub or another Mac.
    static let iconFolder = "webapp-icons"

    static func nameProblem(_ name: String) -> String? {
        if name.contains("/") || name.contains(":") {
            return "the app name becomes '<name>.app', so it cannot contain '/' or ':' (got '\(name)')"
        }
        if name.hasPrefix(".") { return "the app name cannot start with '.' (got '\(name)')" }
        if name.count > 100 { return "the app name is too long (\(name.count) characters; keep it under 100)" }
        return nil
    }

    /// The URL as a validated https address, or nil.
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func urlProblem(_ text: String) -> String? {
        if webURL(text) != nil { return nil }
        if let url = URL(string: text), url.scheme?.lowercased() == "http" {
            return "'url' must use https:// (got '\(text)')"
        }
        return "'url' must be a full https:// address such as https://x.com (got '\(text)')"
    }

    static func iconProblem(_ icon: String) -> String? {
        if icon.isEmpty { return "'icon' must not be empty" }
        let lowered = icon.lowercased()
        if lowered.hasPrefix("https://") {
            return webURL(icon) == nil ? "'icon' is not a valid https:// address (got '\(icon)')" : nil
        }
        if lowered.hasPrefix("http://") { return "'icon' must use https:// (got '\(icon)')" }
        if icon.hasPrefix("/") || icon.hasPrefix("~") || icon.split(separator: "/").contains("..") {
            return "'icon' must be a path inside the config directory (like \(iconFolder)/x.png) or an https:// address (got '\(icon)')"
        }
        let pathExtension = (icon as NSString).pathExtension.lowercased()
        if !icon.contains("{{"), !WebAppSpec.iconExtensions.contains(pathExtension) {
            return "'icon' must be a .png, .jpg or .icns file (got '\(icon)')"
        }
        return nil
    }

    static func bundleIDProblem(_ identifier: String) -> String? {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let valid = parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        }
        return valid ? nil : "'bundle_id' must look like com.example.app: letters, digits, '-' and dots (got '\(identifier)')"
    }

    /// `my-app` for "My App!"; the default bundle id is `com.shawnschwartz.webapp.<slug>`.
    /// WebAppShell derives the same id when it runs outside a bundle, so its saved window frame and
    /// settings line up with the generated app's.
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
        return result
    }

    static func defaultBundleID(for name: String) -> String {
        "\(ShawnCore.bundleIdentifierPrefix).webapp.\(slug(name))"
    }

    /// `twitter.com` for "Twitter.com" or "*.twitter.com"; nil when it is not a host name (a URL, say).
    /// The same normalization WebAppShell applies when it reads `ShawnWebAppHosts`.
    static func normalizedHost(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        while host.hasPrefix(".") { host.removeFirst() }
        guard !host.isEmpty, host.count <= 253 else { return nil }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }) else {
                return nil
            }
        }
        return host
    }
}
