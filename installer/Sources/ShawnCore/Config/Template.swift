import Foundation

/// `{{name}}` substitution used throughout the YAML config.
///
/// Built-in variables come from the machine (`home`, `user`, `hostname`, ...);
/// the rest come from `vars:` in `installer.yaml` and from the answers to its
/// `ask:` questions. Unknown variables are left untouched so they are easy to
/// spot, and `unknownVariables(in:)` lets the validator flag them.
public struct TemplateVars: Equatable, Sendable {
    public private(set) var values: [String: String]
    /// Variables that exist but have no value yet: questions from `ask:` that are not answered on this Mac.
    /// `unknownVariables(in:)` does not report them and `expand` leaves them as written.
    public private(set) var pending: Set<String>

    /// Names the installer fills in itself. A question may not use one of them.
    public static let builtinNames: Set<String> = [
        "home", "user", "hostname", "arch", "brew_prefix", "applications", "state_dir", "config_dir", "shawn_bin",
    ]

    public init(_ values: [String: String] = [:], pending: Set<String> = []) {
        self.values = values
        self.pending = pending.subtracting(values.keys)
    }

    public subscript(name: String) -> String? {
        get { values[name] }
        set {
            values[name] = newValue
            if newValue != nil { pending.remove(name) }
        }
    }

    public func merging(_ other: [String: String]) -> TemplateVars {
        TemplateVars(values.merging(other) { _, new in new }, pending: pending)
    }

    /// Replaces every `{{name}}` whose name is known.
    public func expand(_ text: String) -> String {
        guard text.contains("{{") else { return text }
        var result = ""
        var remainder = Substring(text)
        while let open = remainder.range(of: "{{") {
            result += remainder[remainder.startIndex..<open.lowerBound]
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                result += remainder[open.lowerBound...]
                return result
            }
            let name = afterOpen[afterOpen.startIndex..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values[name] {
                result += value
            } else {
                result += remainder[open.lowerBound..<close.upperBound]
            }
            remainder = afterOpen[close.upperBound...]
        }
        result += remainder
        return result
    }

    /// Names referenced as `{{name}}` in `text` that have no value and are not pending.
    public func unknownVariables(in text: String) -> [String] {
        Self.names(in: text).filter { values[$0] == nil && !pending.contains($0) }
    }

    /// Names referenced as `{{name}}` in `text` that are pending (asked, not answered yet).
    public func pendingVariables(in text: String) -> [String] {
        Self.names(in: text).filter { values[$0] == nil && pending.contains($0) }
    }

    /// Every name referenced as `{{name}}` in `text`, in order of first mention.
    public static func names(in text: String) -> [String] {
        var names: [String] = []
        var remainder = Substring(text)
        while let open = remainder.range(of: "{{") {
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { break }
            let name = afterOpen[afterOpen.startIndex..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !names.contains(name) { names.append(name) }
            remainder = afterOpen[close.upperBound...]
        }
        return names
    }

    /// True for a name a question can use: a letter or `_` first, then letters, digits, `_` or `-`.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil
    }
}

public enum PathExpansion {
    /// Expands a leading `~` against `home`. Other paths are returned unchanged.
    public static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }

    /// Shortens a path under `home` to `~/...` for display.
    public static func abbreviate(_ path: String, home: URL) -> String {
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
