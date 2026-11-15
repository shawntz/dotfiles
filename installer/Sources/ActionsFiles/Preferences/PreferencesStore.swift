import Darwin
import Foundation
import ShawnCore

/// One preferences domain: `com.apple.dock`, `NSGlobalDomain`, or a plist path such as
/// `/Library/Preferences/com.apple.loginwindow`, optionally for this Mac only (`-currentHost`).
struct PreferenceDomain: Equatable, Sendable, CustomStringConvertible {
    static let global = "NSGlobalDomain"

    /// Already expanded: a domain name or an absolute path.
    let name: String
    let currentHost: Bool

    init(_ name: String, currentHost: Bool = false) {
        self.name = PreferenceDomain.normalized(name)
        self.currentHost = currentHost
    }

    /// `-g`, `-globalDomain` and `Apple Global Domain` are all the global domain.
    static func normalized(_ name: String) -> String {
        switch name {
        case "-g", "-globalDomain", "NSGlobalDomain", "Apple Global Domain", ".GlobalPreferences": return global
        default: return name
        }
    }

    var isGlobal: Bool { name == PreferenceDomain.global }
    var isPath: Bool { name.hasPrefix("/") }

    /// `defaults` arguments that go before the verb.
    var hostArguments: [String] { currentHost ? ["-currentHost"] : [] }

    var description: String { currentHost ? "\(name) (this Mac only)" : name }
}

/// One key to write.
struct PreferenceChange: Equatable, Sendable {
    let key: String
    let value: PlistValue
}

/// Reads and writes preferences. Shared by `defaults` and `dock`.
protocol PreferencesStore: Sendable {
    /// Every key in the domain (empty when the domain does not exist yet).
    func read(_ domain: PreferenceDomain) async throws -> [String: PlistValue]
    /// Sets the given keys, leaving every other key in the domain alone.
    func write(_ changes: [PreferenceChange], to domain: PreferenceDomain, asRoot: Bool) async throws
}

enum Preferences {
    /// The store for this run: the real `defaults` tool, or plain plist files inside a sandbox.
    static func store(for context: ActionContext) -> any PreferencesStore {
        if context.environment.isSandbox {
            return PlistFileStore(environment: context.environment, files: context.files)
        }
        return DefaultsCommandStore(commands: context.commands, temporaryDirectory: context.environment.temporaryDirectory)
    }

    /// Keys whose wanted value differs from the current one (compared with their types; see `PlistValue.satisfies`).
    static func differences(current: [String: PlistValue], wanted: [(key: String, value: PlistValue)]) -> [PreferenceChange] {
        wanted.filter { current[$0.key]?.satisfies($0.value) != true }.map { PreferenceChange(key: $0.key, value: $0.value) }
    }
}

// MARK: - Sandbox: plist files

/// Reads and writes `<home>/Library/Preferences/<domain>.plist` directly. Only used in sandboxes, where
/// there is no `cfprefsd` looking after those files, so tests exercise real plists.
struct PlistFileStore: PreferencesStore {
    let environment: SystemEnvironment
    let files: FileOps

    func url(for domain: PreferenceDomain) -> URL {
        if domain.isPath {
            let url = MachinePaths.confined(URL(fileURLWithPath: domain.name), in: environment)
            return url.pathExtension == "plist" ? url : url.appendingPathExtension("plist")
        }
        let base = domain.isGlobal ? ".GlobalPreferences" : domain.name
        let preferences = environment.home.appendingPathComponent("Library/Preferences")
        if domain.currentHost {
            return preferences.appendingPathComponent("ByHost/\(base).\(HostIdentity.uuid).plist")
        }
        return preferences.appendingPathComponent("\(base).plist")
    }

    func read(_ domain: PreferenceDomain) async throws -> [String: PlistValue] {
        let url = url(for: domain)
        guard files.exists(url) else { return [:] }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ActionError("cannot read \(url.path)", hint: "check the file's permissions")
        }
        do {
            return try PlistValue.decodeDictionary(data)
        } catch {
            throw ActionError("\(url.path) is not a valid preferences file", hint: "move it aside and run this step again")
        }
    }

    func write(_ changes: [PreferenceChange], to domain: PreferenceDomain, asRoot: Bool) async throws {
        guard !changes.isEmpty else { return }
        var values = try await read(domain)
        for change in changes { values[change.key] = change.value }
        let data = try PlistValue.encode(values, format: .binary)
        try files.write(data, to: url(for: domain), backup: false)
    }
}

/// The hardware UUID macOS uses in `ByHost` preference file names.
enum HostIdentity {
    static let uuid: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        let status = bytes.withUnsafeMutableBufferPointer { gethostuuid($0.baseAddress!, &wait) }
        guard status == 0 else { return "00000000-0000-0000-0000-000000000000" }
        return NSUUID(uuidBytes: bytes).uuidString
    }()
}

// MARK: - Real Mac: /usr/bin/defaults

/// Goes through `/usr/bin/defaults`, so `cfprefsd` stays in charge, every change is logged, and dry runs only echo.
///
/// Reads use `defaults export <domain> -` (a property list, so types are exact). Plain values are written with
/// typed flags (`-bool`, `-int`, `-string`), and reals as a property-list value (`'<real>0.15</real>'`): `-float`
/// keeps only single precision, so 0.15 would read back as 0.15000000596046448. Arrays and dictionaries cannot be
/// expressed exactly on the command line, so the domain is exported, changed and handed back with `defaults import <domain> -`.
struct DefaultsCommandStore: PreferencesStore {
    let commands: CommandRunner
    let executable: String
    let temporaryDirectory: URL

    init(commands: CommandRunner, executable: String = "/usr/bin/defaults", temporaryDirectory: URL) {
        self.commands = commands
        self.executable = executable
        self.temporaryDirectory = temporaryDirectory
    }

    func read(_ domain: PreferenceDomain) async throws -> [String: PlistValue] {
        let command = Command(executable, domain.hostArguments + ["export", domain.name, "-"]).readOnly().timeout(30)
        let result: CommandResult
        do {
            result = try await commands.run(command)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ActionError("could not read the \(domain) preferences: \(InstallEngine.describe(error))")
        }
        guard result.succeeded else {
            throw ActionError("could not read the \(domain) preferences: \(result.tail())",
                              hint: "try 'defaults export \(domain.name) -' in Terminal to see what is wrong")
        }
        do {
            return try PlistValue.decodeDictionary(Data(result.stdout.utf8))
        } catch {
            throw ActionError("'defaults export \(domain.name)' did not return a property list")
        }
    }

    func write(_ changes: [PreferenceChange], to domain: PreferenceDomain, asRoot: Bool) async throws {
        guard !changes.isEmpty else { return }
        let typedWrites = changes.compactMap { Self.writeArguments($0, domain: domain) }
        guard typedWrites.count == changes.count else {
            try await importChanges(changes, into: domain, asRoot: asRoot)
            return
        }
        for arguments in typedWrites {
            try await commands.runChecked(Command(executable, arguments).asRoot(asRoot))
        }
    }

    /// `[-currentHost] write <domain> <key> -<type> <value>` (a real: `<key> '<real>…</real>'`), or nil for values
    /// that cannot be written exactly on the command line.
    static func writeArguments(_ change: PreferenceChange, domain: PreferenceDomain) -> [String]? {
        let typed: [String]
        switch change.value {
        case .bool(let flag): typed = ["-bool", flag ? "true" : "false"]
        case .int(let number): typed = ["-int", String(number)]
        case .real(let number): typed = ["<real>\(PlistValue.format(number))</real>"]
        case .string(let text): typed = ["-string", text]
        default: return nil
        }
        return domain.hostArguments + ["write", domain.name, change.key] + typed
    }

    private func importChanges(_ changes: [PreferenceChange], into domain: PreferenceDomain, asRoot: Bool) async throws {
        let keys = changes.map(\.key).joined(separator: ", ")
        let label = "defaults \((domain.hostArguments + ["import", domain.name, "-"]).joined(separator: " "))   # sets \(keys)"
        let importCommand = Command(executable, domain.hostArguments + ["import", domain.name, "-"]).asRoot(asRoot).labeled(label)
        if commands.dryRun {
            try await commands.runChecked(importCommand)
            return
        }
        var values = try await exportBinary(domain)
        for change in changes { values[change.key] = change.value }
        let data = try PlistValue.encode(values, format: .binary)
        try await commands.runChecked(importCommand.input(data))
    }

    /// The whole domain, exported in binary form so dates and data keep full precision when it is imported back.
    private func exportBinary(_ domain: PreferenceDomain) async throws -> [String: PlistValue] {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let file = temporaryDirectory.appendingPathComponent("shawn-prefs-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let command = Command(executable, domain.hostArguments + ["export", domain.name, file.path]).readOnly().timeout(30)
        let result = try await commands.run(command)
        guard result.succeeded, let data = FileManager.default.contents(atPath: file.path) else {
            throw ActionError("could not read the \(domain) preferences before changing them: \(result.tail())")
        }
        return try PlistValue.decodeDictionary(data)
    }
}

// MARK: - Restarting apps

/// Restarts processes (`killall Dock`) so they pick up new preferences. Skipped inside a sandbox: those
/// processes belong to the real Mac.
struct ProcessRestarter {
    var executable = "/usr/bin/killall"

    func restart(_ names: [String], context: ActionContext) async {
        guard !names.isEmpty else { return }
        if context.environment.isSandbox {
            context.info("sandbox: not restarting \(names.joined(separator: ", "))")
            return
        }
        await restart(names, commands: context.commands, warn: context.warn)
    }

    func restart(_ names: [String], commands: CommandRunner, warn: (String) -> Void) async {
        for name in names {
            do {
                let result = try await commands.run(Command(executable, [name]))
                if !result.succeeded {
                    warn("could not restart \(name) (\(result.tail(1).isEmpty ? "it is not running" : result.tail(1))); the change applies the next time it starts or after logging out")
                }
            } catch {
                warn("could not restart \(name): \(InstallEngine.describe(error))")
            }
        }
    }
}
