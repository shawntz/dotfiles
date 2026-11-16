import Foundation
import ShawnCore

/// Octal permission strings as written in the YAML (`mode: "0600"`).
enum FileMode {
    /// Parses `"0600"`, `"600"` or `"0o755"`. Returns nil for anything that is not an octal mode.
    static func parse(_ text: String) -> Int? {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("0o") || digits.hasPrefix("0O") { digits = digits.dropFirst(2) }
        guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ ("0"..."7").contains($0) }),
              let value = Int(digits, radix: 8), value <= 0o7777 else { return nil }
        return value
    }

    /// `0o600` → `"0600"`.
    static func describe(_ mode: Int) -> String {
        let octal = String(mode, radix: 8)
        return String(repeating: "0", count: max(0, 4 - octal.count)) + octal
    }
}

extension MapReader {
    /// An optional octal `mode:` option. YAML may have typed it as a number (`mode: 0600`); the raw text is what counts.
    func fileMode(_ key: String) -> Int? {
        guard let text = string(key) else { return nil }
        guard let mode = FileMode.parse(text) else {
            error("'\(key)' must be an octal permission string such as \"0644\" (got '\(text)')", key: key)
            return nil
        }
        return mode
    }
}

/// Locations outside the home folder.
enum MachinePaths {
    /// The directory that stands for `/`: the real root, or the sandbox's root so a sandboxed run
    /// never reads or writes system locations. `SystemEnvironment.sandbox` puts `Applications` directly under its root.
    static func systemRoot(_ environment: SystemEnvironment) -> URL {
        environment.isSandbox ? environment.applicationsDirectory.deletingLastPathComponent() : URL(fileURLWithPath: "/")
    }

    /// An absolute system path such as `/System/Applications`, re-rooted inside a sandbox.
    static func system(_ absolutePath: String, in environment: SystemEnvironment) -> URL {
        guard environment.isSandbox else { return URL(fileURLWithPath: absolutePath) }
        let relative = absolutePath.drop(while: { $0 == "/" })
        return systemRoot(environment).appendingPathComponent(String(relative))
    }

    /// Keeps a path that is already inside the sandbox; re-roots any other absolute path into it.
    static func confined(_ url: URL, in environment: SystemEnvironment) -> URL {
        guard environment.isSandbox else { return url }
        let root = systemRoot(environment).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root || path.hasPrefix(root + "/") { return url }
        return system(path, in: environment)
    }
}

/// `counted(1, "app")` → `1 app`, `counted(2, "app")` → `2 apps`.
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

enum Naming {
    /// `Google Chrome` → `google-chrome`.
    static func slug(_ text: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                if pendingDash && !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return result
    }

    /// The bare name of an app given as a name or a path: `/Applications/Herdr.app` → `Herdr`.
    static func appName(_ text: String) -> String {
        let last = (text as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// True when `text` names a path rather than an app or URL.
    static func looksLikePath(_ text: String) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~")
    }

    /// True for `https://…`, `x-apple.systempreferences:…`, `macappstore://…`.
    static func looksLikeURL(_ text: String) -> Bool {
        guard !looksLikePath(text), let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[text.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }
}

enum Validation {
    /// Unknown-variable messages for each named field that has text.
    static func unknownVariables(_ context: ValidationContext, _ fields: [(name: String, text: String?)]) -> [String] {
        fields.flatMap { field -> [String] in
            guard let text = field.text else { return [] }
            return context.unknownVariableMessages(in: text, field: field.name)
        }
    }
}

extension ActionContext {
    /// Short outcome text for one file change: "created ~/.zshrc", "updated ~/.zshrc (old copy: …)".
    func describe(_ change: FileChange, _ url: URL) -> String {
        let what = display(url)
        switch change {
        case .unchanged: return "\(what) already up to date"
        case .created: return dryRun ? "would create \(what)" : "created \(what)"
        case .replaced(let backup):
            if dryRun { return "would update \(what)" }
            guard let backup else { return "updated \(what)" }
            return "updated \(what) (old copy: \(display(backup)))"
        }
    }

    /// Turns any error from a file operation into an `ActionError` that says what to do next.
    /// A `FileOps` refusal with its own hint keeps that hint. The permissions hint is for every other error.
    func fileError(_ error: Error, doing what: String) -> ActionError {
        if let error = error as? FileOpsError, let hint = error.hint {
            return ActionError("could not \(what): \(error.message)", hint: hint)
        }
        return ActionError("could not \(what): \(InstallEngine.describe(error))",
                           hint: "check the permissions of the folders involved, then run this step again")
    }
}

/// Quotes a scalar for a small hand-written YAML file when plain style would be ambiguous.
enum YAMLText {
    static func scalar(_ text: String) -> String {
        let special = CharacterSet(charactersIn: ":#'\"{}[],&*!|>%@`")
        let needsQuotes = text.isEmpty || text.unicodeScalars.contains(where: special.contains)
            || text.first == " " || text.last == " " || text.first == "-" || text.first == "?"
        guard needsQuotes else { return text }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
