import Foundation

/// `{{name}}` substitution used throughout the YAML config.
///
/// Built-in variables come from the machine (`home`, `user`, `hostname`, ...);
/// the rest come from `vars:` in `installer.yaml`. Unknown variables are left
/// untouched so they are easy to spot, and `unknownVariables(in:)` lets the
/// validator flag them.
public struct TemplateVars: Equatable, Sendable {
    public private(set) var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(name: String) -> String? {
        get { values[name] }
        set { values[name] = newValue }
    }

    public func merging(_ other: [String: String]) -> TemplateVars {
        TemplateVars(values.merging(other) { _, new in new })
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

    /// Names referenced as `{{name}}` in `text` that have no value.
    public func unknownVariables(in text: String) -> [String] {
        var unknown: [String] = []
        var remainder = Substring(text)
        while let open = remainder.range(of: "{{") {
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { break }
            let name = afterOpen[afterOpen.startIndex..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if values[name] == nil, !unknown.contains(name) { unknown.append(name) }
            remainder = afterOpen[close.upperBound...]
        }
        return unknown
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
