import Foundation
import ShawnCore

/// Small helpers shared by several kinds.
enum Common {
    /// Runs clean-up work to completion even when the item has been canceled: a canceled task
    /// cannot start new processes, and a mounted disk image must still be detached.
    static func uncancellable<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task { await work() }.value
    }

    /// Sleeps, but wakes up (by throwing) as soon as the run is canceled.
    static func pause(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// What a finished item reports; a dry run did not really do it, so it says nothing.
    static func done(_ message: String, _ context: ActionContext) -> ActionOutcome {
        .done(context.dryRun ? nil : message)
    }

    /// A sandbox run (tests, the app's `--sandbox` mode) must not change the real Mac outside the sandbox:
    /// installers, softwareupdate, xcode-select and the App Store all act system-wide. Returns the outcome
    /// to report instead, or nil when going ahead is fine.
    static func sandboxRefusal(_ what: String, _ context: ActionContext, system: MacSystem) -> ActionOutcome? {
        guard context.environment.isSandbox, !context.dryRun, system.isRealMachine else { return nil }
        context.warn("Sandbox run: not \(what), because that would change this Mac outside the sandbox.")
        return .skipped("sandbox run: not \(what)")
    }

    /// `Dropbox` → `Dropbox.app`.
    static func appBundleName(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? name : name + ".app"
    }

    /// `Dropbox.app` → `Dropbox`.
    static func appDisplayName(_ bundleName: String) -> String {
        bundleName.lowercased().hasSuffix(".app") ? String(bundleName.dropLast(4)) : bundleName
    }

    /// The first non-empty line of a script, marked when more follows.
    static func firstLine(of script: String) -> String {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        return lines.count > 1 ? first + " …" : first
    }

    /// Validation messages for every `{{name}}` without a value in the given fields.
    static func unknownVariables(_ context: ValidationContext, _ fields: [(field: String, text: String?)]) -> [String] {
        fields.flatMap { field, text in text.map { context.unknownVariableMessages(in: $0, field: field) } ?? [] }
    }

    /// The "what happened" part of any error, for log lines and follow-ups.
    static func describe(_ error: Error) -> String {
        InstallEngine.describe(error)
    }

    /// True when the run was stopped: the error is (or was caused by) cancellation, so it must be passed on
    /// rather than turned into a follow-up.
    static func isStop(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    /// "45 seconds", "10 minutes", "4 hours": how long something waits, for messages.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 2 * 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600)) hours" }
        if seconds >= 120 { return "\(Int((seconds / 60).rounded())) minutes" }
        let whole = Int(seconds.rounded())
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }

    /// True for the developer directory of a full Xcode that is really there (`…/Name.app/Contents/Developer`
    /// with an executable xcodebuild), as opposed to the Command Line Tools or a selection that has gone stale.
    static func isFullXcode(_ developerDirectory: String) -> Bool {
        developerDirectory.hasSuffix(".app/Contents/Developer")
            && FileManager.default.isExecutableFile(atPath: developerDirectory + "/usr/bin/xcodebuild")
    }

    /// A fresh private directory under the environment's temporary directory. Callers remove it when done.
    /// Never called in a dry run.
    static func makeScratchDirectory(_ context: ActionContext, prefix: String) throws -> URL {
        let directory = context.environment.temporaryDirectory
            .appendingPathComponent("shawn-\(prefix)-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Removes the installer's own scratch files; a failure is reported, never fatal.
    static func removeScratch(_ url: URL, _ context: ActionContext) {
        guard context.files.exists(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            context.warn("Could not remove the temporary \(context.display(url)): \(error.localizedDescription)")
        }
    }

    /// Opens an app or URL without stealing focus. Failure is only a warning: nothing depends on it.
    static func open(_ arguments: [String], _ context: ActionContext, system: MacSystem) async throws {
        let result = try await context.run(Command(system.open, arguments))
        if !result.succeeded {
            context.warn("Could not open \(arguments.last ?? ""): \(result.tail())")
        }
    }

    /// The `CFBundleShortVersionString` of an app bundle, if it can be read.
    static func bundleVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return object["CFBundleShortVersionString"] as? String
    }
}
