import Foundation
import ShawnCore
import ShawnFun

/// Turns engine events into terminal output.
///
/// On a terminal: step headings with the step's mascot and a quip, a live "working on…" line that is
/// rewritten in place, progress bars that overwrite themselves. Anywhere else (a pipe, a log file):
/// one plain line per event, no cursor movement, no color unless forced.
final class InstallRenderer: @unchecked Sendable {
    private let plan: InstallPlan
    private let fun: FunConfig
    private let terminal: Terminal
    private let out: any OutputSink
    private let desktop: (any DesktopActions)?
    private let style: Style
    private let lock = NSLock()
    private let seed: Int

    private let itemTitles: [String: String]
    private let enabledSteps: [String]
    private let enabledItems: Set<String>
    /// Items that reached a final status, so a stopped step can say what never got its turn.
    private var finishedItems: Set<String> = []
    private var transientShown = false
    /// The "→ title" line currently on the live line, kept until the item finishes or prints something.
    private var runningLine: String?
    private var shownAttention: Set<String> = []

    /// `desktop` (open URLs, copy codes) is only passed for interactive runs on a real Mac.
    init(plan: InstallPlan, selection: Selection, fun: FunConfig, terminal: Terminal, out: any OutputSink,
         desktop: (any DesktopActions)?, seed: Int = Int.random(in: 0..<10_000)) {
        self.plan = plan
        self.fun = fun
        self.terminal = terminal
        self.out = out
        self.desktop = desktop
        self.style = terminal.style
        self.seed = seed
        var titles: [String: String] = [:]
        for item in plan.allItems { titles[item.id] = item.title }
        itemTitles = titles
        enabledSteps = plan.steps.filter { selection.isEnabled(step: $0) }.map(\.id)
        enabledItems = Set(selection.enabledItems(in: plan).map(\.id))
    }

    private var live: Bool { terminal.stdoutIsTTY }

    func handle(_ event: InstallEvent) {
        lock.withLock { render(event) }
    }

    // MARK: Output primitives

    private func permanent(_ text: String) {
        if transientShown {
            out.write("\r\u{1B}[2K")
            transientShown = false
        }
        out.write(text + "\n")
    }

    /// Output is about to appear under the running item: keep its "→ title" line instead of overwriting it.
    private func keepRunningLine() {
        guard let line = runningLine else { return }
        runningLine = nil
        permanent(line)
    }

    private func transient(_ text: String) {
        guard live else { return }
        let fitted = TextWidth.of(text) > terminal.width - 1 ? TextWidth.truncate(ANSIText.strip(text), to: terminal.width - 1) : text
        out.write("\r\u{1B}[2K" + fitted)
        transientShown = true
    }

    private func title(_ itemID: String) -> String {
        itemTitles[itemID] ?? itemID
    }

    // MARK: Events

    private func render(_ event: InstallEvent) {
        switch event {
        case .runStarted(let total):
            let steps = enabledSteps.count
            permanent(style.heading("▶ \(total) item\(total == 1 ? "" : "s") in \(steps) step\(steps == 1 ? "" : "s")"))

        case .stepStatus(let stepID, let status):
            guard let step = plan.step(stepID) else { return }
            switch status {
            case .running:
                stepHeading(step)
            case .stopped:
                stepStopped(step)
            case .pending, .disabled, .done, .finishedWithFailures:
                return
            }

        case .itemStatus(let itemID, let status):
            itemLine(itemID, status)

        case .log(let line):
            logLine(line)

        case .attention(let itemID, let attention):
            guard let attention else { return }
            keepRunningLine()
            attentionBox(attention)
            if let desktop, !shownAttention.contains(itemID + attention.title) {
                shownAttention.insert(itemID + attention.title)
                if let code = attention.code { desktop.copy(code) }
                if let url = attention.url { desktop.open(url) }
            }

        case .followUp:
            // Collected by the engine into the summary's checklist.
            break

        case .runFinished(let summary):
            finished(summary)
        }
    }

    private func stepHeading(_ step: PlannedStep) {
        let position = (enabledSteps.firstIndex(of: step.id) ?? 0) + 1
        let counter = "[\(position)/\(max(1, enabledSteps.count))]"
        permanent("")
        if live, let sprite = fun.sprite(step.config.mascot), !sprite.frames.isEmpty {
            var said = step.config.title
            if let subtitle = step.config.subtitle { said += ": \(subtitle)" }
            said += "\n" + fun.line(for: .working, stepID: step.id, seed: seed + position)
            for line in Painter.speaking(sprite, says: said, style: style, width: terminal.width) { permanent(line) }
            permanent(style.muted("  \(counter) \(step.config.title)"))
        } else {
            var heading = "== \(counter) \(step.config.title)"
            if let subtitle = step.config.subtitle { heading += " · \(subtitle)" }
            permanent(style.heading(heading + " =="))
        }
    }

    /// The run was stopped inside this step: say how much of it never ran (a re-run picks it up).
    private func stepStopped(_ step: PlannedStep) {
        let notRun = step.items.filter { enabledItems.contains($0.id) && !finishedItems.contains($0.id) }.count
        let rest = notRun == 0 ? "" : ": \(notRun) item\(notRun == 1 ? "" : "s") did not get \(notRun == 1 ? "its" : "their") turn"
        permanent("  " + style.warn("■") + style.muted(" \(step.config.title) stopped\(rest)"))
    }

    private func itemLine(_ itemID: String, _ status: ItemStatus) {
        let name = title(itemID)
        // A finished item's status line takes the place of its "→ title" line.
        if status.isFinished {
            runningLine = nil
            if status != .disabled { finishedItems.insert(itemID) }
        }
        switch status {
        case .pending, .disabled:
            return
        case .checking:
            transient("  " + style.muted("⋯ checking \(name)"))
        case .running:
            if live {
                runningLine = "  " + style.accent("→") + " \(name)"
                transient(runningLine ?? "")
            } else {
                permanent("  → \(name)")
            }
        case .done(let message):
            permanent("  " + style.ok("✓") + " \(name)" + suffix(message))
        case .alreadyDone(let reason):
            // A check that only answers "already done" has nothing to add to the line.
            let why = reason.flatMap { $0.isEmpty || $0 == "already done" ? nil : " (\($0))" } ?? ""
            permanent("  " + style.muted("· \(name): already done" + why))
        case .skipped(let reason):
            permanent("  " + style.muted("↷ \(name): skipped (\(reason))"))
        case .needsAttention(let message):
            permanent("  " + style.warn("!") + " \(name)" + Self.detail(message, after: name, style.warn))
        case .failed(let message):
            permanent("  " + style.bad("✗") + " \(name): " + style.bad(message))
        case .cancelled:
            // Interrupted by the stop, not failed: the next run does it.
            permanent("  " + style.warn("■") + " \(name): " + style.muted("stopped before it finished"))
        }
    }

    private func suffix(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return style.muted(": \(message)")
    }

    /// ": message", or nothing when the message only repeats the name ("Log out and back in").
    private static func detail(_ message: String, after name: String, _ paint: (String) -> String) -> String {
        message == name ? "" : ": " + paint(message)
    }

    private func logLine(_ line: LogLine) {
        // The engine also logs failures as "✗ title: message"; the item line already says that.
        if line.style == .error, let itemID = line.itemID, line.text.hasPrefix("✗ \(title(itemID)):") { return }
        keepRunningLine()
        if line.isProgress {
            transient("    " + style.muted(line.text))
            return
        }
        let text = line.text
        switch line.style {
        case .command:
            permanent("    " + style.fg(Palette.sky, text))
        case .stdout, .stderr:
            permanent("    " + style.muted("│ " + text))
        case .info:
            permanent(line.itemID == nil ? style.accent("✦ ") + text : "    " + style.muted(text))
        case .success:
            permanent("    " + style.ok(text))
        case .warning:
            permanent("    " + style.warn("! " + text))
        case .error:
            permanent("    " + style.bad("✗ " + text))
        }
    }

    /// A box that stands out in the log: title in the top border, then the message, code and URL.
    private func attentionBox(_ attention: Attention) {
        var body = [attention.message]
        if let code = attention.code { body.append("code: \(code)" + (desktop != nil ? " (copied to the clipboard)" : "")) }
        if let url = attention.url { body.append(url.absoluteString) }
        let title = TextWidth.truncate(attention.title, to: max(10, terminal.width - 12))
        let inner = min(max(TextWidth.of(title) + 2, body.map(TextWidth.of).max() ?? 0), max(20, terminal.width - 8))
        let rows = body.flatMap { TextWidth.wrap($0, width: inner) }
        let dashes = max(1, inner - TextWidth.of(title) - 1)
        permanent("")
        permanent("  " + style.warn("╭─ ") + style.bold(title) + style.warn(" " + String(repeating: "─", count: dashes) + "╮"))
        for row in rows {
            permanent("  " + style.warn("│ ") + style.bold(TextWidth.pad(row, to: inner)) + style.warn(" │"))
        }
        permanent("  " + style.warn("╰" + String(repeating: "─", count: inner + 2) + "╯"))
    }

    private func finished(_ summary: InstallSummary) {
        permanent("")
        permanent(style.heading("== Summary" + (summary.wasDryRun ? " (dry run: nothing was changed)" : "") + " =="))
        var counts = ["\(summary.done) done", "\(summary.alreadyDone) already done"]
        if summary.skipped > 0 { counts.append("\(summary.skipped) skipped") }
        if summary.needsAttention > 0 { counts.append("\(summary.needsAttention) need\(summary.needsAttention == 1 ? "s" : "") you") }
        counts.append("\(summary.failures.count) failed")
        permanent("  " + counts.joined(separator: " · ") + style.muted("  (\(Self.duration(summary.duration)))"))
        if summary.wasCancelled { permanent("  " + style.warn("Canceled before the end. Run it again to pick up where it stopped.")) }
        if !summary.failures.isEmpty {
            permanent("")
            permanent(style.bad("Failed:"))
            for failure in summary.failures {
                permanent("  " + style.bad("✗") + " \(failure.title): \(failure.message)")
            }
            permanent(style.muted("  Fix what the messages say, then run it again: finished items are skipped."))
        }
        if !summary.followUps.isEmpty {
            permanent("")
            permanent(style.heading("Things only you can do:"))
            for followUp in summary.followUps {
                permanent("  ☐ \(followUp.title)" + (followUp.url.map { style.muted("  \($0.absoluteString)") } ?? ""))
                if let detail = followUp.detail { permanent("    " + style.muted(detail)) }
            }
        }
        if let log = summary.logFile {
            permanent("")
            permanent(style.muted("Log: \(log.path)"))
        }
        let moment: Moment = summary.wasCancelled ? .cancelled : summary.wasDryRun ? .dryRun : summary.failures.isEmpty ? .finished : .finishedWithFailures
        permanent("")
        if live, summary.succeeded, let sprite = fun.sprite(fun.speaker), !sprite.frames.isEmpty {
            for line in Painter.speaking(sprite, says: fun.line(for: moment, seed: seed), style: style, width: terminal.width) { permanent(line) }
        } else {
            permanent(style.fg(Palette.star, "\"\(fun.line(for: moment, seed: seed))\""))
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}
