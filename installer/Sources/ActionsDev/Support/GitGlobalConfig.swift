import Foundation
import ShawnCore

/// The global git config as `git config --global` sees it: the files it reads and writes, every
/// entry in the order git reads them, and writes that never drop a value someone else put there.
struct GitGlobalConfig: Sendable {
    struct Entry: Equatable, Sendable {
        /// As `git config --list` prints it: section and variable lower-cased, subsection as written.
        let key: String
        /// nil for a bare `key` line, which git reads as boolean true.
        let value: String?
    }

    /// In the order git reads them; for a single-valued key the last one wins.
    let entries: [Entry]

    // MARK: Files

    /// The files `git config --global` reads, in reading order.
    static func files(_ environment: SystemEnvironment) -> [URL] {
        if let explicit = explicitFile(environment) { return [explicit] }
        return [xdgFile(environment), environment.home.appendingPathComponent(".gitconfig")]
    }

    /// The file `git config --global` writes: `~/.gitconfig`, or the XDG one when only that exists.
    static func writeTarget(_ environment: SystemEnvironment, files: FileOps) -> URL {
        if let explicit = explicitFile(environment) { return explicit }
        let home = environment.home.appendingPathComponent(".gitconfig")
        let xdg = xdgFile(environment)
        return !files.exists(home) && files.exists(xdg) ? xdg : home
    }

    /// `GIT_CONFIG_GLOBAL` on a real Mac. Sandboxes remove it from git's environment (`GitTool.isolationVariables`).
    private static func explicitFile(_ environment: SystemEnvironment) -> URL? {
        guard !environment.isSandbox, let path = environment.baseEnvironment["GIT_CONFIG_GLOBAL"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: PathExpansion.expandTilde(path, home: environment.home))
    }

    private static func xdgFile(_ environment: SystemEnvironment) -> URL {
        if !environment.isSandbox, let base = environment.baseEnvironment["XDG_CONFIG_HOME"], base.hasPrefix("/") {
            return URL(fileURLWithPath: base).appendingPathComponent("git/config")
        }
        return environment.home.appendingPathComponent(".config/git/config")
    }

    // MARK: Reading

    /// Every global entry. A Mac without a global config yet has none (git itself calls that an error).
    static func read(git: String, context: ActionContext) async throws -> GitGlobalConfig {
        guard files(context.environment).contains(where: { context.files.exists($0) }) else { return GitGlobalConfig(entries: []) }
        // --list on --global does not follow includes, so the entries are exactly what the files say.
        let list = GitTool.command(git, ["config", "--global", "-z", "--list"], environment: context.environment).timeout(30).readOnly()
        let result = try await context.commands.run(list)
        guard result.succeeded else {
            throw ActionError("git cannot read the global git config: \(result.tail(2))",
                              hint: "Fix the line git names (or move that file aside), then run this again")
        }
        return GitGlobalConfig(entries: parse(result.stdout))
    }

    /// `git config -z --list`: `key\nvalue`, or a bare `key`, per entry, each ended by NUL.
    static func parse(_ output: String) -> [Entry] {
        output.split(separator: "\0").map { record in
            guard let newline = record.firstIndex(of: "\n") else { return Entry(key: String(record), value: nil) }
            return Entry(key: String(record[..<newline]), value: String(record[record.index(after: newline)...]))
        }
    }

    /// Every value of `key`, in reading order.
    func values(_ key: String) -> [String?] {
        let wanted = Self.normalize(key)
        return entries.filter { $0.key == wanted }.map(\.value)
    }

    // MARK: Keys

    struct KeyParts: Equatable {
        let section: String
        let subsection: String?
        let variable: String
    }

    /// `section[.subsection].variable`; the subsection may itself contain dots.
    static func parts(_ key: String) -> KeyParts? {
        guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: ".") else { return nil }
        let section = String(key[..<firstDot])
        let variable = String(key[key.index(after: lastDot)...])
        let subsection = firstDot == lastDot ? nil : String(key[key.index(after: firstDot)..<lastDot])
        return KeyParts(section: section, subsection: subsection, variable: variable)
    }

    /// The spelling `git config --list` uses: section and variable names are case-insensitive, subsections are not.
    static func normalize(_ key: String) -> String {
        guard let parts = parts(key) else { return key.lowercased() }
        return ([parts.section.lowercased()] + (parts.subsection.map { [$0] } ?? []) + [parts.variable.lowercased()])
            .joined(separator: ".")
    }

    /// `include.path` and `includeIf.<condition>.path`.
    static func isInclude(_ key: String) -> Bool {
        guard let parts = parts(key), parts.variable.lowercased() == "path" else { return false }
        switch parts.section.lowercased() {
        case "include": return parts.subsection == nil
        case "includeif": return parts.subsection != nil
        default: return false
        }
    }

    /// Keys git reads as a list rather than "last one wins", so setting one means adding to it.
    static func isList(_ key: String) -> Bool {
        guard let parts = parts(key) else { return false }
        switch (parts.section.lowercased(), parts.variable.lowercased()) {
        case ("url", "insteadof"), ("url", "pushinsteadof"), ("remote", "fetch"), ("remote", "push"):
            return parts.subsection != nil
        case ("safe", "directory"), ("credential", "helper"), ("http", "extraheader"):
            return true
        default:
            return false
        }
    }

    // MARK: Includes

    /// True when an include of `path` under `key` is present and nothing but other includes follows it,
    /// so the included file overrides every setting in the global config.
    func includeIsLast(_ key: String, path: String, home: URL) -> Bool {
        let wanted = Self.normalize(key)
        guard let index = entries.lastIndex(where: { $0.key == wanted && Self.samePath($0.value, path, home: home) }) else { return false }
        return entries[(index + 1)...].allSatisfy { Self.isInclude($0.key) }
    }

    /// The ways `path` is already spelled under `key` (`~/x` and `/Users/me/x` are the same file).
    func spellings(of path: String, under key: String, home: URL) -> [String] {
        var seen = Set<String>()
        return values(key).compactMap { $0 }.filter { Self.samePath($0, path, home: home) && seen.insert($0).inserted }
    }

    private static func samePath(_ value: String?, _ path: String, home: URL) -> Bool {
        guard let value else { return false }
        return PathExpansion.expandTilde(value, home: home) == PathExpansion.expandTilde(path, home: home)
    }

    // MARK: Writing

    /// Makes `key` read as `value` without losing anything: a key with one value is overwritten (the old
    /// value is logged first), and a key that already has several gets `value` added after them, because
    /// git reads the last one and `--replace-all` would delete the rest.
    static func set(_ key: String, to value: String, current: [String?], git: String, context: ActionContext) async throws {
        var arguments = ["config", "--global"]
        switch current.count {
        case 0:
            break
        case 1:
            context.info("\(key) was \(shown(current[0])); setting it to \(value)")
        default:
            context.info("\(key) has \(current.count) values (\(current.map(shown).joined(separator: ", "))); "
                + "adding \(value) after them so git uses it, and keeping the others")
            arguments.append("--add")
        }
        try await context.commands.runChecked(GitTool.command(git, arguments + [key, value], environment: context.environment).timeout(30))
    }

    /// Adds `value` to a list-valued key. Nothing already there is removed.
    static func add(_ key: String, _ value: String, git: String, context: ActionContext) async throws {
        try await context.commands.runChecked(
            GitTool.command(git, ["config", "--global", "--add", key, value], environment: context.environment).timeout(30)
        )
    }

    /// Puts an include at the very end of the global config so the included file overrides everything
    /// above it. `git config --add` cannot do that (it files the entry under an existing `[include]`
    /// section, wherever that is), so an earlier include of the same file is removed with git (which
    /// matches that exact entry and nothing else) and a new section is appended to the file git writes.
    static func moveIncludeToEnd(_ key: String, path: String, earlier spellings: [String], git: String, context: ActionContext) async throws {
        for spelling in spellings {
            let unset = GitTool.command(git, ["config", "--global", "--fixed-value", "--unset-all", key, spelling],
                                        environment: context.environment).timeout(30)
            let result = try await context.commands.run(unset)
            // Exit 5 means no match: that include is in a file `--global` does not write. The new one still comes last.
            guard result.succeeded || result.exitCode == 5 else {
                throw ActionError("Could not take the earlier \(key) \(spelling) out of the global git config: \(result.tail(3))",
                                  hint: "Run `git config --global --list --show-origin` to see where it is, then run this again")
            }
        }
        // git writes through a symlinked config file (stow-style dotfiles), so the append does too.
        let file = writeTarget(context.environment, files: context.files).followingLinks()
        var data = FileManager.default.contents(atPath: file.path) ?? Data()
        if let last = data.last, last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
        data.append(Data(section(for: key, value: path).utf8))
        try context.files.write(data, to: file)
    }

    /// One `key = value` in its own section, written the way git writes it.
    static func section(for key: String, value: String) -> String {
        guard let parts = parts(key) else { return "" }
        let header = parts.subsection.map { "[\(parts.section) \"\(escapedSubsection($0))\"]" } ?? "[\(parts.section)]"
        return "\(header)\n\t\(parts.variable) = \(quoted(value))\n"
    }

    /// git's rules for writing a value (config.c `write_pair`).
    static func quoted(_ value: String) -> String {
        let scalars = value.unicodeScalars
        let needsQuotes = scalars.first == " " || scalars.last == " " || scalars.contains { $0 == ";" || $0 == "#" || $0 == "\r" }
        var text = ""
        for scalar in scalars {
            switch scalar {
            case "\n": text += "\\n"
            case "\t": text += "\\t"
            case "\"", "\\": text += "\\" + String(scalar)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return needsQuotes ? "\"\(text)\"" : text
    }

    private static func escapedSubsection(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            if scalar == "\"" || scalar == "\\" { escaped += "\\" }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }

    private static func shown(_ value: String?) -> String {
        value ?? "true (written without a value)"
    }
}
