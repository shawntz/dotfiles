import AppKit
import ShawnCore
import SwiftUI

struct LoadingView: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            HeaderBlock(model: model)
                .padding(.top, Theme.Space.xs)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.s) {
                Text("> loading the config")
                    .font(Theme.mono(Theme.Size.title))
                    .foregroundStyle(palette.text.color)
                BlinkingCursor(size: Theme.Size.title)
            }
            Text(model.resolveOptions.allowRemote && model.resolveOptions.explicitPath == nil
                 ? "checking GitHub for the newest version first; if it can't be reached, the copy on disk is used"
                 : "reading it from disk")
                .font(Theme.mono(Theme.Size.small))
                .foregroundStyle(palette.dim.color)
            Spacer(minLength: 0)
            BottomBar {
                Spacer()
                Button("Start ⏎") {}
                    .buttonStyle(.terminal(.primary))
                    .disabled(true)
                    .accessibilityLabel("Start, unavailable while the config loads")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loading the config")
    }
}

/// The config could not be loaded: every problem, with where it is, and a way out.
struct ConfigErrorView: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        let failure = model.loadFailure ?? InstallerModel.LoadFailure(message: "The config could not be loaded.", issues: [])
        VStack(spacing: Theme.Space.l) {
            HeaderBlock(model: model, compact: true)
            HStack(alignment: .bottom, spacing: Theme.Space.l + 4) {
                SpriteView(sprite: model.speaker)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("✗ THE CONFIG HAS PROBLEMS")
                        .font(Theme.mono(Theme.Size.headline, .heavy))
                        .tracking(2)
                        .foregroundStyle(palette.red.color)
                        .glow(palette.red.color, radius: 10, strength: 0.6, palette: palette)
                        .accessibilityAddTraits(.isHeader)
                    Text(failure.message)
                        .font(Theme.mono(Theme.Size.body))
                        .foregroundStyle(palette.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }

            TerminalPanel(title: failure.issues.isEmpty ? "DETAILS" : "ISSUES (\(failure.issues.count))", tint: .red) {
                HuggingScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if failure.issues.isEmpty {
                            Text("No further details.")
                                .foregroundStyle(palette.dim.color)
                        }
                        ForEach(Array(failure.issues.enumerated()), id: \.offset) { _, issue in
                            IssueRow(issue: issue)
                        }
                    }
                    .font(Theme.mono(Theme.Size.small))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)

            BottomBar {
                HStack(spacing: 0) {
                    Text("Fix the YAML and open the installer again. ")
                        .foregroundStyle(palette.dim.color)
                    Text("shawn config validate")
                        .foregroundStyle(palette.cyan.color)
                    Text(" lists the same problems.")
                        .foregroundStyle(palette.dim.color)
                }
                .font(Theme.mono(Theme.Size.small))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: Theme.Space.s)
                Button("Copy issues") { model.desktop.copyToPasteboard(Self.report(failure)) }
                    .buttonStyle(.terminal(.secondary))
                    .help("Copy every problem as text")
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.terminal(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func report(_ failure: InstallerModel.LoadFailure) -> String {
        ([failure.message] + failure.issues.map(\.description)).joined(separator: "\n")
    }
}

/// `steps/03-packages.yaml:14  ERROR  item 3 (cask): unknown key…`
struct IssueRow: View {
    @Environment(\.palette) private var palette
    let issue: ConfigIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(issue.severity == .error ? "ERROR" : "WARN ")
                .font(Theme.mono(Theme.Size.caption, .bold))
                .foregroundStyle(issue.severity == .error ? palette.red.color : palette.yellow.color)
            VStack(alignment: .leading, spacing: 2) {
                if let source = issue.source {
                    Text(source.description)
                        .foregroundStyle(palette.cyan.color)
                }
                Text(issue.message)
                    .foregroundStyle(palette.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
