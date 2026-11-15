import ShawnCore
import SwiftUI

/// The banner plus the tagline and where the config came from.
struct HeaderBlock: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            ASCIIHeaderView(text: model.fun.header, accessibilityTitle: model.appName,
                            maxHeight: compact ? 44 : 96, maxFontSize: compact ? 8.5 : 15)
            HStack(spacing: Theme.Space.s) {
                if let tagline = model.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .foregroundStyle(palette.pink.color)
                        .glow(palette.pink.color, radius: 4, strength: 0.5, palette: palette)
                    if !model.configSourceLine.isEmpty {
                        Text("·").foregroundStyle(palette.faint.color)
                    }
                }
                Text(model.configSourceLine)
                    .foregroundStyle(palette.dim.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.mono(compact ? Theme.Size.small : Theme.Size.body))
        }
        .frame(maxWidth: .infinity)
    }
}

/// The strip along the bottom of every screen: a hairline, then controls.
struct BottomBar<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Rectangle().fill(palette.border.color).frame(height: 1)
            HStack(alignment: .center, spacing: Theme.Space.m) {
                content
            }
            .frame(minHeight: 34)
        }
    }
}

/// `[x] DRY RUN` with an explanation that follows the switch.
struct DryRunToggle: View {
    @Environment(\.palette) private var palette
    @Bindable var model: InstallerModel

    var body: some View {
        Toggle(isOn: $model.dryRun) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("DRY RUN")
                    .font(Theme.mono(Theme.Size.body, .bold))
                    .tracking(1.4)
                    .foregroundStyle(model.dryRun ? palette.yellow.color : palette.text.color)
                Text(model.dryRun ? "nothing on this Mac will change" : "off: this run changes the Mac")
                    .font(Theme.mono(Theme.Size.small))
                    .foregroundStyle(model.dryRun ? palette.yellow.color.opacity(0.8) : palette.dim.color)
                    .lineLimit(1)
            }
        }
        .toggleStyle(TerminalCheckboxStyle())
        .keyboardShortcut("d", modifiers: .command)
        .help("Dry run: show what would happen without changing anything (⌘D)")
        .accessibilityLabel("Dry run")
        .accessibilityHint("When on, nothing on this Mac is changed")
    }
}

/// START, with the dry-run state in its label, plus the "N items will run" count.
struct StartControls: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        let count = model.enabledItemCount
        Text(count == 0 ? "nothing selected" : "\(Format.count(count, "item")) will run")
            .font(Theme.mono(Theme.Size.small))
            .foregroundStyle(count == 0 ? palette.red.color : palette.dim.color)
            .monospacedDigit()
            .accessibilityLabel(count == 0 ? "Nothing selected" : "\(count) items will run")
        Button(model.dryRun ? "Start dry run ⏎" : "Start ⏎") { model.start() }
            .buttonStyle(.terminal(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canStart)
            .help(count == 0 ? "Select at least one step or item first" : "Start the install (Return)")
            .accessibilityLabel(model.dryRun ? "Start dry run" : "Start")
    }
}

struct WelcomeView: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        VStack(spacing: Theme.Space.l + 2) {
            HeaderBlock(model: model)
                .padding(.top, Theme.Space.xs)
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                TerminalPanel(title: "THE PLAN") {
                    Text("\(model.steps.count) STEPS")
                        .captionStyle(palette.faint.color)
                } content: {
                    WelcomeStepList(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    MascotCard(sprite: model.speaker, speaker: model.speaker?.name, quip: model.quip, spriteSize: 112)
                        .padding(.top, Theme.Space.s)
                    if !model.notes.isEmpty {
                        NotesPanel(notes: model.notes)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 330)
            }
            .frame(maxHeight: .infinity)

            BottomBar {
                DryRunToggle(model: model)
                Spacer(minLength: Theme.Space.s)
                Button("Customize…") { model.showCustomize() }
                    .buttonStyle(.terminal(.secondary))
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Choose individual items (⌘K)")
                StartControls(model: model)
            }
        }
    }
}

/// Things worth knowing about the config that do not stop the install.
struct NotesPanel: View {
    @Environment(\.palette) private var palette
    let notes: [String]

    var body: some View {
        TerminalPanel(title: "NOTES", padding: Theme.Space.s + 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("›").foregroundStyle(palette.faint.color)
                            Text(note)
                                .foregroundStyle(palette.dim.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(Theme.mono(Theme.Size.small))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CustomizeView: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        VStack(spacing: Theme.Space.l + 2) {
            HeaderBlock(model: model, compact: true)
            TerminalPanel(title: "CUSTOMIZE") {
                Text("OPTIONAL ITEMS START UNTICKED")
                    .captionStyle(palette.faint.color)
            } content: {
                CustomizeList(model: model)
            }
            .frame(maxHeight: .infinity)

            BottomBar {
                DryRunToggle(model: model)
                Spacer(minLength: Theme.Space.s)
                Button("Done") { model.closeCustomize() }
                    .buttonStyle(.terminal(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .help("Back to the overview (Esc)")
                StartControls(model: model)
            }
        }
    }
}
