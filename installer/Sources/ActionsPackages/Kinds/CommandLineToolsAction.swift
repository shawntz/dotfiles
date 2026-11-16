import Foundation
import ShawnCore

/// `- xcode-clt: install` installs the Xcode Command Line Tools.
///
/// Installed headlessly the way Homebrew's install.sh does it (placeholder file → `softwareupdate -l` →
/// `softwareupdate -i <label>`), with Apple's install dialog as the fallback. Never runs `/usr/bin/git`,
/// `clang` or `python3`: before the tools exist those shims pop up that very dialog.
struct CommandLineToolsAction: Action {
    let system: MacSystem

    var title: String { "Xcode Command Line Tools" }
    var subtitle: String? { "softwareupdate, headless" }
    var sudo: SudoNeed { .always }

    static let dialogProcessName = "Install Command Line Developer Tools"

    static func parse(_ parser: ItemParser, system: MacSystem) -> CommandLineToolsAction {
        requireInstallValue(parser)
        return CommandLineToolsAction(system: system)
    }

    // MARK: Check

    func isInstalled(_ context: ActionContext) async -> Bool {
        let bin = system.commandLineTools.appendingPathComponent("usr/bin")
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: bin.appendingPathComponent("git").path),
              fileManager.isExecutableFile(atPath: bin.appendingPathComponent("clang").path) else { return false }
        return await context.commands.succeeds(system.pkgutil, ["--pkg-info=\(system.cltReceipt)"], timeout: 30)
    }

    func check(_ context: ActionContext) async -> CheckResult {
        await isInstalled(context) ? .satisfied("installed") : .needed(nil)
    }

    // MARK: Run

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        if !context.dryRun, await isInstalled(context) { return .done("already installed") }
        if let refusal = Common.sandboxRefusal("installing the Command Line Tools", context, system: system) { return refusal }

        let label = try await installHeadlessly(context)
        if context.dryRun {
            try await selectCommandLineTools(context)
            return .done(nil)
        }
        if await isInstalled(context) {
            try await selectCommandLineTools(context)
            return .done(label.map { "installed \($0)" } ?? "installed")
        }
        return try await installWithDialog(context)
    }

    /// The softwareupdate route. Returns the label it installed (or tried to); nil when none was offered.
    private func installHeadlessly(_ context: ActionContext) async throws -> String? {
        let placeholder = system.cltPlaceholder.path
        try await context.runChecked(Command(system.touch, [placeholder]).asRoot())
        do {
            let label = try await findLabel(context)
            if let label {
                let install = Command(system.softwareupdate, ["-i", label, "--verbose"]).asRoot().timeout(system.timing.cltInstallTimeout)
                // Any failure here (including a timeout) leaves the dialog as the way forward, so it is not fatal.
                do {
                    let result = try await context.run(install)
                    if !result.succeeded {
                        context.warn("softwareupdate could not install \(label): \(result.tail(3))")
                    }
                } catch let error as CommandError where error.isTimeout && !Task.isCancelled {
                    context.warn("softwareupdate did not finish within \(Common.duration(system.timing.cltInstallTimeout)) installing \(label), so it was stopped.")
                } catch {
                    if Common.isStop(error) { throw error }
                    context.warn("softwareupdate could not install \(label): \(Common.describe(error))")
                }
            } else {
                context.warn("softwareupdate does not offer the Command Line Tools right now.")
            }
            await removePlaceholder(context)
            return label
        } catch {
            await removePlaceholder(context)
            throw error
        }
    }

    private func removePlaceholder(_ context: ActionContext) async {
        let command = Command(system.rm, ["-f", system.cltPlaceholder.path]).asRoot()
        await Common.uncancellable {
            do {
                let result = try await context.run(command)
                if !result.succeeded { context.warn("Could not remove \(system.cltPlaceholder.path): \(result.tail(2))") }
            } catch {
                context.warn("Could not remove \(system.cltPlaceholder.path): \(Common.describe(error))")
            }
        }
    }

    /// Lists available updates (retrying while softwareupdated is busy) and picks the newest non-beta Command Line Tools.
    private func findLabel(_ context: ActionContext) async throws -> String? {
        if context.dryRun {
            try await context.run(Command(system.softwareupdate, ["-l"]))
            return "Command Line Tools for Xcode (newest offered)"
        }
        let attempts = max(1, system.timing.softwareUpdateAttempts)
        for attempt in 1...attempts {
            // The exit status is not trustworthy here: a busy scan can fail yet still print the cached list.
            do {
                let result = try await context.run(Command(system.softwareupdate, ["-l"]).timeout(10 * 60))
                if let label = CommandLineToolsLabel.pick(from: result.stdout + "\n" + result.stderr) {
                    context.info("Picked \(label)")
                    return label
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                context.warn("softwareupdate -l did not work: \(Common.describe(error))")
            }
            if attempt < attempts {
                context.info("No Command Line Tools in the list yet; asking again (\(attempt + 1) of \(attempts)).")
                try await Common.pause(system.timing.softwareUpdateRetryDelay * Double(attempt))
            }
        }
        return nil
    }

    /// Points the developer directory at the Command Line Tools, unless a full Xcode is already selected.
    private func selectCommandLineTools(_ context: ActionContext) async throws {
        if let selected = await context.capture(system.xcodeSelect, ["-p"]), Common.isFullXcode(selected) {
            context.info("Keeping the selected Xcode (\(selected)).")
            return
        }
        try await context.runChecked(Command(system.xcodeSelect, ["--switch", system.commandLineTools.path]).asRoot())
    }

    /// Apple's own dialog: start it, then wait for the tools to appear (or for the dialog to be closed).
    private func installWithDialog(_ context: ActionContext) async throws -> ActionOutcome {
        context.info("Falling back to Apple's installer dialog.")
        let start = try await context.run(Command(system.xcodeSelect, ["--install"]))
        let followUpTitle = "Install the Xcode Command Line Tools"
        guard start.succeeded else {
            // Nothing was opened (typically "already installed", when an earlier install stopped half-way and
            // left files behind), so there is no dialog to wait for.
            let said = start.tail(2).split(separator: "\n").joined(separator: " ")
            context.warn("xcode-select --install: \(said)")
            context.followUp(followUpTitle, detail: "'xcode-select --install' said: \(said). If it says they are already installed, "
                + "an earlier install stopped half-way: remove \(system.commandLineTools.path) (sudo rm -rf), "
                + "run 'xcode-select --install' in Terminal, click Install, then run the installer again.")
            return .needsAttention("xcode-select --install did not start Apple's installer: \(said)")
        }
        context.attention(Attention(
            title: "Install the Command Line Tools",
            message: "Click Install in the dialog macOS just opened, and agree to the license. This step carries on by itself once they are installed."
        ))
        defer { context.attention(nil) }

        enum Ending { case closed, neverAppeared, timedOut }
        let timing = system.timing
        let deadline = Date().addingTimeInterval(timing.cltDialogTimeout)
        let appearanceDeadline = Date().addingTimeInterval(timing.cltDialogAppearanceTimeout)
        var sawDialog = false
        var pollsWithoutDialog = 0
        let ending: Ending
        while true {
            if await isInstalled(context) {
                try await selectCommandLineTools(context)
                return .done("installed with Apple's installer")
            }
            let dialogOpen = await context.commands.succeeds(system.pgrep, ["-x", Self.dialogProcessName], timeout: 10)
            if dialogOpen {
                sawDialog = true
                pollsWithoutDialog = 0
            } else if sawDialog {
                pollsWithoutDialog += 1
            }
            // Two polls in a row without the dialog (it may vanish just before the files land): it was closed.
            if pollsWithoutDialog >= 2 {
                ending = .closed
                break
            }
            let now = Date()
            if now >= deadline {
                ending = .timedOut
                break
            }
            if !sawDialog && now >= appearanceDeadline {
                ending = .neverAppeared
                break
            }
            try await Common.pause(timing.cltDialogPollInterval)
        }

        context.followUp(followUpTitle, detail: "Run 'xcode-select --install' in Terminal, click Install, then run the installer again.")
        switch ending {
        case .closed: return .needsAttention("the installer dialog was closed before the Command Line Tools were installed")
        case .neverAppeared: return .needsAttention("Apple's installer dialog did not appear")
        case .timedOut: return .needsAttention("the Command Line Tools did not finish installing in time")
        }
    }
}

/// Picks a label from `softwareupdate -l` output.
///
///     * Label: Command Line Tools for Xcode 27.2-27.2
///     	Title: Command Line Tools for Xcode 27.2, Version: 27.2, Size: 521120KiB, Recommended: YES,
///
/// Homebrew sorts the labels with `sort -V | tail -1`, which prefers "27.3 beta 2" over "27.2"; this
/// prefers releases, newest `Version:` first, and only falls back to a beta when nothing else is offered.
enum CommandLineToolsLabel {
    struct Candidate: Equatable {
        let label: String
        let version: [Int]
        let isBeta: Bool
    }

    static func pick(from output: String) -> String? {
        candidates(in: output).sorted { left, right in
            if left.isBeta != right.isBeta { return !left.isBeta }
            return compare(left.version, right.version) == .orderedDescending
        }.first?.label
    }

    static func candidates(in output: String) -> [Candidate] {
        var result: [Candidate] = []
        var pending: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let label = labelValue(line) {
                if let pending { result.append(candidate(pending, title: nil)) }
                pending = label.hasPrefix("Command Line Tools") ? label : nil
            } else if let label = pending, line.hasPrefix("Title:") {
                result.append(candidate(label, title: line))
                pending = nil
            }
        }
        if let pending { result.append(candidate(pending, title: nil)) }
        return result
    }

    /// `Command Line Tools for Xcode 27.2-27.2` from `* Label: …` (recommended) or `- Label: …`.
    private static func labelValue(_ line: String) -> String? {
        guard let first = line.first, first == "*" || first == "-" else { return nil }
        let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("Label:") else { return nil }
        let value = rest.dropFirst("Label:".count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func candidate(_ label: String, title: String?) -> Candidate {
        var versionText: String?
        if let title, let range = title.range(of: "Version:") {
            versionText = title[range.upperBound...].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        // Labels end in "-<version>" when there is no Title line to read it from.
        if versionText == nil, let dash = label.lastIndex(of: "-") {
            versionText = String(label[label.index(after: dash)...])
        }
        let lowered = label.lowercased()
        let isBeta = lowered.contains("beta") || lowered.contains("seed") || lowered.contains("release candidate")
        return Candidate(label: label, version: numericVersion(versionText ?? ""), isBeta: isBeta)
    }

    static func numericVersion(_ text: String) -> [Int] {
        text.split(separator: ".").map { component in Int(component.prefix { $0.isNumber }) ?? 0 }
    }

    static func compare(_ left: [Int], _ right: [Int]) -> ComparisonResult {
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// `xcode-clt`, `homebrew` and `rosetta` all take the value `install`.
func requireInstallValue(_ parser: ItemParser) {
    let value = parser.item.value.string
    if value != "install" {
        parser.fail("'\(parser.item.kind)' takes the value 'install' (e.g. '- \(parser.item.kind): install')")
    }
}
