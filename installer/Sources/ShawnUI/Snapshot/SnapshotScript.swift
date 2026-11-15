import Foundation
import ShawnCore

/// Puts a model into a given screen with a fixed set of events, so snapshots are the same every time.
///
/// Everything is derived from the loaded plan by position (first steps finished, a middle step running,
/// the rest pending), never from particular step ids, so it works with any config.
@MainActor
enum SnapshotScript {
    static let fixedRunStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// "Now" for running screens: 3m 12s into the run.
    static let fixedNow = fixedRunStart.addingTimeInterval(192)

    static func apply(_ state: SnapshotState, to model: InstallerModel) {
        // The run "starts" at fixedRunStart; the screen is looked at 3m 12s later.
        model.now = { fixedRunStart }
        defer { model.now = { fixedNow } }
        switch state {
        case .loading:
            break
        case .configError:
            if model.loadFailure == nil { model.showLoadFailure(sampleFailure) }
        case .welcome:
            break
        case .customize:
            enableFirstOptionalItem(in: model)
            model.showCustomize()
        case .running:
            playRunning(model)
        case .password:
            playRunning(model)
            let request = PasswordRequest(reason: "Installing the package manager writes to /opt and needs administrator rights.",
                                          attempt: 2, lastError: "That password was not accepted.", maxAttempts: SudoSession.maxAttempts)
            model.enqueue(.password(request, PromptGate<String?>()))
        case .question:
            playRunning(model)
            model.enqueue(.question(sampleQuestion, PromptGate<String>()))
        case .attention:
            playRunning(model)
            if let itemID = model.currentItemID {
                model.apply(.attention(itemID: itemID, attention: sampleAttention))
            }
        case .finished:
            playFinished(model, failures: 0, stopped: false)
        case .failed:
            playFinished(model, failures: 2, stopped: false)
        case .stopped:
            playFinished(model, failures: 0, stopped: true)
        case .dryRunFinished:
            model.dryRun = true
            playFinished(model, failures: 0, stopped: false)
        }
    }

    static let sampleFailure = InstallerModel.LoadFailure(
        message: "The config at ~/Developer/dotfiles/installer/config has problems.",
        issues: [
            .error("item 3 (cask): unknown key 'ap'. Did you mean 'app'?", at: SourceRef(file: "steps/04-apps.yaml", line: 18)),
            .error("item 12 (brew): 'brew' needs a value, e.g. 'brew: something'", at: SourceRef(file: "steps/03-packages.yaml", line: 41)),
            .error("item 1: unknown item kind 'cask_app'. Did you mean 'cask'? (known kinds: brew, cask, copy, …)", at: SourceRef(file: "steps/02-dropbox.yaml", line: 7)),
            .warning("mascot 'gunter' has no sprite in fun/sprites/", at: SourceRef(file: "steps/16-dock.yaml")),
        ]
    )

    static let sampleQuestion = Question(
        title: "Sign in to the App Store",
        message: "Open the App Store, sign in with your Apple Account, then come back. App Store apps cannot be installed until you do.",
        options: [
            Question.Option(id: "signed-in", label: "I'm signed in", isDefault: true),
            Question.Option(id: "skip", label: "Skip App Store apps"),
        ],
        url: URL(string: "macappstore://apps.apple.com/app/id937984704")
    )

    static let sampleAttention = Attention(
        title: "Sign in to GitHub",
        message: "Enter this code in the browser window that just opened, then approve the sign-in.",
        code: "LUMP-5PCE",
        url: URL(string: "https://github.com/login/device")
    )

    // MARK: Scripts

    private static func enableFirstOptionalItem(in model: InstallerModel) {
        for step in model.steps where model.isEnabled(step) {
            if let optional = step.items.first(where: { !$0.enabledByDefault }) {
                model.setItem(optional, enabled: true)
                return
            }
        }
    }

    private static func enabledSteps(_ model: InstallerModel) -> [PlannedStep] {
        model.steps.filter { model.isEnabled($0) && model.selectedItemCount(in: $0) > 0 }
    }

    private static func enabledItems(_ model: InstallerModel, in step: PlannedStep) -> [PlannedItem] {
        step.items.filter { model.isEnabled($0) }
    }

    /// Finishes one item with a varied outcome and a little output, the way the engine reports it (a dry
    /// run only narrates the command). Returns the item's final status.
    @discardableResult
    private static func finish(_ item: PlannedItem, index: Int, failing: Bool, needsYou: Bool = false,
                               model: InstallerModel) -> ItemStatus {
        let name = slug(item.title)
        let status: ItemStatus
        model.apply(.itemStatus(itemID: item.id, status: .checking))
        if !failing, !needsYou, index % 4 == 2 {
            status = .alreadyDone("already installed")
            model.apply(.itemStatus(itemID: item.id, status: status))
            return status
        }
        model.apply(.itemStatus(itemID: item.id, status: .running))
        if model.runIsDryRun {
            model.apply(.log(LogLine("[dry-run] $ install \(name)", style: .command, itemID: item.id)))
        } else {
            model.apply(.log(LogLine("$ install \(name)", style: .command, itemID: item.id)))
            model.apply(.log(LogLine("==> Fetching \(name)", style: .stdout, itemID: item.id)))
        }
        if failing {
            let message = "install \(name) failed (exit 1): Error: the download was interrupted (curl: (56) Recv failure: Connection reset by peer)"
            model.apply(.log(LogLine("curl: (56) Recv failure: Connection reset by peer", style: .stderr, itemID: item.id)))
            model.apply(.log(LogLine("✗ \(item.title): \(message)", style: .error, itemID: item.id)))
            status = .failed(message)
        } else if needsYou {
            status = .needsAttention("finish it by hand")
        } else {
            if !model.runIsDryRun { model.apply(.log(LogLine("==> Installed \(name)", style: .stdout, itemID: item.id))) }
            status = .done(nil)
        }
        model.apply(.itemStatus(itemID: item.id, status: status))
        return status
    }

    /// STOP lands while `item` runs: the model's own STOP, then exactly the events InstallEngine sends for an
    /// item interrupted mid-command (`.cancelled`, then the step `.stopped`).
    private static func interrupt(_ item: PlannedItem, in step: PlannedStep, model: InstallerModel) {
        let name = slug(item.title)
        model.apply(.itemStatus(itemID: item.id, status: .checking))
        model.apply(.itemStatus(itemID: item.id, status: .running))
        model.apply(.log(LogLine("$ install \(name)", style: .command, itemID: item.id)))
        model.apply(.log(LogLine("==> Fetching \(name)", style: .stdout, itemID: item.id)))
        model.stop()
        model.apply(.attention(itemID: item.id, attention: nil))
        model.apply(.itemStatus(itemID: item.id, status: .cancelled))
        model.apply(.stepStatus(stepID: step.id, status: .stopped))
    }

    /// About 40% through: earlier steps finished (one item failed), the middle step mid-item with live output.
    static func playRunning(_ model: InstallerModel) {
        let steps = enabledSteps(model)
        guard !steps.isEmpty else { return }
        model.apply(.runStarted(totalItems: model.enabledItemCount))
        model.apply(.log(LogLine("Asked for administrator rights once for the whole run.", style: .info)))

        let currentIndex = min(steps.count - 1, max(1, steps.count * 2 / 5))
        for (stepIndex, step) in steps.enumerated() where stepIndex < currentIndex {
            model.apply(.stepStatus(stepID: step.id, status: .running))
            var failures = 0
            for (index, item) in enabledItems(model, in: step).enumerated() {
                let failing = stepIndex == currentIndex - 1 && index == enabledItems(model, in: step).count - 1 && stepIndex > 0
                finish(item, index: index, failing: failing, model: model)
                if failing { failures += 1 }
            }
            model.apply(.stepStatus(stepID: step.id, status: failures == 0 ? .done : .finishedWithFailures(failures)))
        }

        let current = steps[currentIndex]
        model.apply(.stepStatus(stepID: current.id, status: .running))
        let items = enabledItems(model, in: current)
        let runningIndex = min(items.count - 1, items.count / 2)
        for (index, item) in items.enumerated() where index < runningIndex {
            finish(item, index: index, failing: false, model: model)
        }
        let item = items[runningIndex]
        model.apply(.itemStatus(itemID: item.id, status: .checking))
        model.apply(.itemStatus(itemID: item.id, status: .running))
        let name = slug(item.title)
        let lines: [LogLine] = [
            LogLine("$ install \(name)", style: .command, itemID: item.id),
            LogLine("==> Fetching downloads for: \(name)", style: .stdout, itemID: item.id),
            LogLine("==> Downloading https://ghcr.io/v2/homebrew/core/\(name)/manifests/2.4.1", style: .stdout, itemID: item.id),
            LogLine("Warning: \(name) 2.4.0 is already installed but outdated; upgrading.", style: .stderr, itemID: item.id),
            LogLine("==> Pouring \(name)--2.4.1.arm64_tahoe.bottle.tar.gz", style: .stdout, itemID: item.id),
            LogLine(String(repeating: "#", count: 21) + String(repeating: " ", count: 19) + "  52.4%", style: .stdout, itemID: item.id, isProgress: true),
        ]
        model.apply(lines.map { InstallEvent.log($0) })
        // Show the step's own line rather than the reaction to the earlier failure.
        model.advanceQuip()
    }

    /// A whole run, ended by `.runFinished`: a real run, or a dry run when `model.dryRun` is on. With `stopped`,
    /// STOP lands halfway through, while an item runs, and the steps after it are never reached.
    static func playFinished(_ model: InstallerModel, failures: Int, stopped: Bool) {
        let steps = enabledSteps(model)
        model.apply(.runStarted(totalItems: model.enabledItemCount))
        let dryRun = model.runIsDryRun
        if dryRun { model.apply(.log(LogLine("Dry run: nothing on this Mac will be changed.", style: .info))) }
        var summary = InstallSummary()
        summary.wasDryRun = dryRun
        let allItems = steps.flatMap { enabledItems(model, in: $0) }
        let stopIndex = stopped ? allItems.count / 2 : allItems.count
        var failingIndices = Set<Int>()
        if failures > 0 {
            for index in stride(from: 1, to: allItems.count, by: max(1, allItems.count / failures)) where failingIndices.count < failures {
                failingIndices.insert(index)
            }
        }
        // A couple of items a person has to finish by hand, as a real run of a full config has.
        let attentionIndices = Set([allItems.count / 3 + 1, allItems.count * 2 / 3 + 1]).subtracting(failingIndices)

        var position = 0
        run: for step in steps {
            model.apply(.stepStatus(stepID: step.id, status: .running))
            var stepFailures = 0
            for item in enabledItems(model, in: step) {
                if position == stopIndex {
                    interrupt(item, in: step, model: model)
                    break run
                }
                let status = finish(item, index: position, failing: failingIndices.contains(position),
                                    needsYou: attentionIndices.contains(position), model: model)
                switch status {
                case .done: summary.done += 1
                case .alreadyDone: summary.alreadyDone += 1
                case .needsAttention: summary.needsAttention += 1
                case .failed(let message):
                    stepFailures += 1
                    summary.failures.append(InstallSummary.Failure(itemID: item.id, title: item.title, message: message))
                default: break
                }
                position += 1
            }
            model.apply(.stepStatus(stepID: step.id, status: stepFailures == 0 ? .done : .finishedWithFailures(stepFailures)))
        }

        let followUps = [
            FollowUp(id: "snapshot-accessibility", title: "Allow Accessibility for Hammerspoon",
                     detail: "System Settings → Privacy & Security → Accessibility → turn on Hammerspoon.",
                     url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")),
            FollowUp(id: "snapshot-logout", title: "Log out and back in", detail: "Key repeat settings apply after you log in again."),
            FollowUp(id: "snapshot-dropbox", title: "Sign in to Dropbox", detail: "Dropbox is running; sign in from its menu bar icon.",
                     url: URL(string: "https://www.dropbox.com/login")),
        ]
        for followUp in followUps { model.apply(.followUp(followUp)) }
        summary.followUps = followUps
        summary.wasCancelled = stopped
        summary.duration = 4 * 60 + 12
        // The engine writes no log file for a dry run.
        summary.logFile = dryRun ? nil : model.environment.logsDirectory.appendingPathComponent("install-20261114-221530.log")
        model.apply(.runFinished(summary))
    }

    private static func slug(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }
}
