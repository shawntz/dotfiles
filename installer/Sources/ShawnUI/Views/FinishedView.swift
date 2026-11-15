import AppKit
import ShawnCore
import SwiftUI

struct FinishedView: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        let summary = model.summary ?? InstallSummary()
        let outcome = model.outcome ?? .success
        let isDryRun = model.runIsDryRun
        // The line-up celebrates a Mac that is set up; a dry run has only shown what would happen.
        let celebrates = outcome == .success && !isDryRun && !model.lineup.isEmpty
        VStack(spacing: Theme.Space.l) {
            HeaderBlock(model: model, compact: true)
            ResultBanner(model: model, summary: summary, outcome: outcome)

            if celebrates {
                Celebration(model: model)
            }

            HStack(alignment: .top, spacing: Theme.Space.l) {
                Group {
                    if model.showsLogOnFinishedScreen {
                        LogPanel(model: model)
                    } else {
                        VStack(spacing: Theme.Space.l) {
                            let failures = model.failures
                            if !failures.isEmpty {
                                FailuresPanel(failures: failures)
                            }
                            FollowUpsPanel(model: model)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if !celebrates {
                        MascotCard(sprite: model.speaker, speaker: model.speaker?.name, quip: model.quip, spriteSize: 88)
                            .padding(.top, Theme.Space.xs)
                    }
                    TerminalPanel(title: "STEPS", padding: Theme.Space.s + 2) {
                        HuggingScrollView {
                            StepStatusRows(model: model)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 340)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)

            BottomBar {
                LogFileLine(model: model, url: summary.logFile)
                Spacer(minLength: Theme.Space.s)
                Button(model.showsLogOnFinishedScreen ? "Summary" : "View log") { model.showsLogOnFinishedScreen.toggle() }
                    .buttonStyle(.terminal(.secondary))
                    .keyboardShortcut("l", modifiers: .command)
                    .help(model.showsLogOnFinishedScreen ? "Back to the failures and follow-ups (⌘L)"
                                                         : "Read and copy this run's log (⌘L)")
                if isDryRun {
                    // Back to START rather than straight into the install: the person sees DRY RUN switched
                    // off and the selection before anything changes. The plan is reused, not fetched again.
                    Button("Run for real…") { model.setUpRealRun() }
                        .buttonStyle(.terminal(outcome == .success ? .primary : .secondary))
                        .help("Back to the start screen with DRY RUN off and the same selection. Nothing changes until you press START.")
                }
                switch outcome {
                case .failures:
                    Button(isDryRun ? "Dry run again" : "Retry failed") { model.start() }
                        .buttonStyle(.terminal(.primary))
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!model.canStart)
                        .help(isDryRun ? "Run the same dry run again (⌘R)" : "Run the same selection again; finished items are skipped (⌘R)")
                case .stopped:
                    Button(isDryRun ? "Dry run again" : "Resume") { model.start() }
                        .buttonStyle(.terminal(.primary))
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!model.canStart)
                        .help(isDryRun ? "Run the same dry run again (⌘R)" : "Run the same selection again; finished items are skipped (⌘R)")
                case .success:
                    EmptyView()
                }
                let quitIsTheNextStep = outcome == .success && !isDryRun
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.terminal(quitIsTheNextStep ? .primary : .secondary))
                    .keyboardShortcut(quitIsTheNextStep ? .defaultAction : nil)
            }
        }
    }
}

/// Everyone on stage at the same pixel scale, with the speaker's last word underneath.
private struct Celebration: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            CharacterLineup(sprites: model.lineup, cellHeight: 64)
            HStack(spacing: Theme.Space.s) {
                TypewriterText(text: "\"\(model.quip)\"")
                    .foregroundStyle(palette.text.color)
                if let name = model.speaker?.name {
                    Text(name)
                        .foregroundStyle(palette.pink.color)
                }
            }
            .font(Theme.mono(Theme.Size.body))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The big result line and the counts.
private struct ResultBanner: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    let summary: InstallSummary
    let outcome: InstallerModel.Outcome

    var body: some View {
        VStack(spacing: Theme.Space.s + 2) {
            HStack(spacing: Theme.Space.m) {
                Text(title)
                    .font(Theme.mono(Theme.Size.display, .heavy))
                    .tracking(3)
                    .foregroundStyle(palette.color(tone))
                    .glow(palette.color(tone), radius: 12, strength: 0.7, palette: palette)
                if model.runIsDryRun {
                    Chip(text: "DRY RUN", tone: .yellow)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: Theme.Space.s) {
                stat("✓", summary.done, "done", .mint)
                stat("=", summary.alreadyDone, "already done", .dim)
                stat("»", summary.skipped, "skipped", .dim)
                stat("!", summary.needsAttention, "need you", .yellow)
                stat("✗", model.failures.count, "failed", .red)
                if outcome == .stopped {
                    // What the STOP left undone: the interrupted item and everything after it.
                    stat("■", model.unfinishedItemCount, "left", .pink)
                }
                Text("in \(Format.duration(summary.duration))")
                    .font(Theme.mono(Theme.Size.small))
                    .foregroundStyle(palette.dim.color)
                    .padding(.leading, Theme.Space.xs)
            }
            if let advice {
                Text(advice)
                    .font(Theme.mono(Theme.Size.small))
                    .foregroundStyle(palette.dim.color)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private var advice: String? {
        if model.runIsDryRun {
            // Nothing was done, so there is nothing for a second dry run to skip.
            switch outcome {
            case .success: return "Nothing on this Mac was changed. The log shows what each item would do; RUN FOR REAL… goes back to START with DRY RUN off."
            case .failures: return "Nothing was changed. Fix what you can and DRY RUN AGAIN, or RUN FOR REAL… to go back to START with DRY RUN off."
            case .stopped: return "Nothing was changed. DRY RUN AGAIN starts it over; RUN FOR REAL… goes back to START with DRY RUN off."
            }
        }
        switch outcome {
        case .success: return nil
        case .failures: return "Fix what you can, then RETRY FAILED. It runs the same selection again and skips everything that worked."
        case .stopped: return "RESUME runs the same selection again and skips everything that is already done."
        }
    }

    private var title: String {
        switch outcome {
        case .success: return model.runIsDryRun ? "★ DRY RUN COMPLETE ★" : "★ ALL DONE ★"
        case .failures(let count): return count == 1 ? "DONE, BUT 1 THING FAILED" : "DONE, BUT \(count) THINGS FAILED"
        case .stopped: return "STOPPED"
        }
    }

    private var tone: Tone {
        switch outcome {
        case .success: return .yellow
        case .failures: return .red
        case .stopped: return .pink
        }
    }

    private func stat(_ glyph: String, _ count: Int, _ label: String, _ tone: Tone) -> some View {
        HStack(spacing: 5) {
            Text(glyph).fontWeight(.bold).foregroundStyle(palette.color(count == 0 ? .faint : tone))
            Text("\(count)").fontWeight(.bold).foregroundStyle(count == 0 ? palette.faint.color : palette.text.color)
            Text(label).foregroundStyle(count == 0 ? palette.faint.color : palette.dim.color)
        }
        .font(Theme.mono(Theme.Size.small))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.color(count == 0 ? .faint : tone).opacity(0.45), lineWidth: 1))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }
}

private struct FailuresPanel: View {
    @Environment(\.palette) private var palette
    let failures: [(item: PlannedItem, message: String)]

    var body: some View {
        TerminalPanel(title: "FAILED (\(failures.count))", tint: .red) {
            HuggingScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text("✗").fontWeight(.bold).foregroundStyle(palette.red.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.item.title)
                                    .font(Theme.mono(Theme.Size.body, .semibold))
                                    .foregroundStyle(palette.text.color)
                                Text(failure.message)
                                    .foregroundStyle(palette.dim.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(Theme.mono(Theme.Size.small))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct FollowUpsPanel: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        TerminalPanel(title: "ONLY YOU CAN DO THESE (\(model.followUps.count))", tint: model.followUps.isEmpty ? .dim : .yellow) {
            if model.followUps.isEmpty {
                Text("Nothing left for you to do.")
                    .font(Theme.mono(Theme.Size.small))
                    .foregroundStyle(palette.dim.color)
            } else {
                HuggingScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                        ForEach(model.followUps) { followUp in
                            row(followUp)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func row(_ followUp: FollowUp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("[ ]").foregroundStyle(palette.yellow.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(followUp.title)
                    .font(Theme.mono(Theme.Size.body, .semibold))
                    .foregroundStyle(palette.text.color)
                if let detail = followUp.detail {
                    Text(detail)
                        .foregroundStyle(palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if let url = followUp.url {
                Button("Open ↗") { model.open(url) }
                    .buttonStyle(.terminal(.link))
                    .help(url.absoluteString)
                    .accessibilityLabel("Open \(followUp.title)")
            }
        }
        .font(Theme.mono(Theme.Size.small))
    }
}

/// Where the transcript is, with a Reveal button.
struct LogFileLine: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    let url: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("LOG").captionStyle(palette.faint.color)
            if let url {
                Text(PathExpansion.abbreviate(url.path, home: model.environment.home))
                    .foregroundStyle(palette.dim.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Reveal") { model.revealLogFile() }
                    .buttonStyle(.terminal(.link))
                    .help("Show the log file in Finder")
                    .accessibilityLabel("Reveal the log file in Finder")
            } else {
                Text(model.missingLogFileNote)
                    .foregroundStyle(palette.faint.color)
                    .lineLimit(1)
            }
        }
        .font(Theme.mono(Theme.Size.small))
    }
}
