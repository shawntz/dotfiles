import ShawnCore
import SwiftUI

struct RunningView: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            HeaderBlock(model: model, compact: true)
            HStack(alignment: .top, spacing: Theme.Space.l) {
                TerminalPanel(title: "STEPS", padding: Theme.Space.s + 2) {
                    Text("\(model.finishedItemCount)/\(model.totalItems)")
                        .captionStyle(palette.faint.color)
                        .monospacedDigit()
                } content: {
                    RunningStepList(model: model)
                }
                .frame(width: 318)
                .frame(maxHeight: .infinity)

                VStack(spacing: Theme.Space.m) {
                    NowCard(model: model)
                    if let attention = model.attention {
                        AttentionBanner(model: model, active: attention)
                            .transition(.opacity)
                    }
                    LogPanel(model: model)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            BottomBar {
                RunProgress(model: model)
                Button(model.isStopping ? "Stopping…" : "Stop") { model.stop() }
                    .buttonStyle(.terminal(.danger))
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.isStopping)
                    .help("Stop after the current item winds down (⌘.)")
                    .accessibilityLabel(model.isStopping ? "Stopping" : "Stop the install")
            }
        }
    }
}

/// The current step's character, what it is saying, and what is happening right now.
struct NowCard: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.l + 4) {
            SpriteView(sprite: model.mascot)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SpeechBubble(speaker: model.speaker?.name, text: model.quip)
                nowLine
                    .padding(.leading, 2)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    private var nowLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(model.isStopping ? "STOPPING" : "NOW")
                .captionStyle(model.isStopping ? palette.red.color : palette.pink.color)
            if let step = model.currentStep {
                Text(step.config.title)
                    .foregroundStyle(palette.dim.color)
                    .lineLimit(1)
                if let item = model.currentItem {
                    Text("›").foregroundStyle(palette.faint.color)
                    Text(item.title)
                        .foregroundStyle(palette.text.color)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            } else {
                Text("getting ready…").foregroundStyle(palette.dim.color)
            }
            BlinkingCursor(size: Theme.Size.small)
            Spacer(minLength: 0)
        }
        .font(Theme.mono(Theme.Size.small))
        .accessibilityElement(children: .combine)
    }
}

/// Progress bar, counts and elapsed time.
struct RunProgress: View {
    @Environment(\.palette) private var palette
    @Environment(\.isSnapshot) private var isSnapshot
    let model: InstallerModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            BlockProgressBar(fraction: model.progressFraction, tone: model.runIsDryRun ? .yellow : .pink)
                .frame(minWidth: 120, maxWidth: .infinity)
            Text("\(Int((model.progressFraction * 100).rounded()))%")
                .foregroundStyle(palette.text.color)
                .frame(width: 40, alignment: .trailing)
            Text("\(model.finishedItemCount)/\(model.totalItems) items")
                .foregroundStyle(palette.dim.color)
            elapsed
        }
        .font(Theme.mono(Theme.Size.small))
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var elapsed: some View {
        if isSnapshot {
            elapsedText(model.elapsed(at: model.now()))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                elapsedText(model.elapsed(at: context.date))
            }
        }
    }

    private func elapsedText(_ interval: TimeInterval) -> some View {
        Text(Format.clock(interval))
            .foregroundStyle(palette.dim.color)
            .accessibilityLabel("Elapsed time \(Format.duration(interval))")
    }
}

/// "Waiting on you": what to do, the code (big, already on the clipboard) and a way back to the page.
struct AttentionBanner: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    let active: InstallerModel.ActiveAttention

    var body: some View {
        let attention = active.attention
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("!")
                    .font(Theme.mono(Theme.Size.title, .heavy))
                    .foregroundStyle(palette.background.color)
                    .frame(width: 20, height: 20)
                    .background(palette.yellow.color, in: RoundedRectangle(cornerRadius: 3))
                Text("WAITING ON YOU")
                    .captionStyle(palette.yellow.color, size: Theme.Size.small)
                Text(attention.title)
                    .font(Theme.mono(Theme.Size.title, .bold))
                    .foregroundStyle(palette.text.color)
                    .lineLimit(1)
            }
            Text(attention.message)
                .font(Theme.mono(Theme.Size.body))
                .foregroundStyle(palette.text.color.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            if attention.code != nil || attention.url != nil {
                // Side by side when there is room; the code never wraps, so stack the controls otherwise.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Theme.Space.l) {
                        codeBlock(attention, size: 30)
                        Spacer(minLength: Theme.Space.s)
                        openButton(attention)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        codeBlock(attention, size: 26)
                        openButton(attention)
                    }
                }
            }
        }
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.yellow.color.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(palette.yellow.color.opacity(0.85), lineWidth: 1.5))
        .glow(palette.yellow.color, radius: 10, strength: 0.25, palette: palette)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting on you: \(attention.title)")
    }

    @ViewBuilder private func codeBlock(_ attention: Attention, size: CGFloat) -> some View {
        if let code = attention.code {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                Text(code)
                    .font(Theme.mono(size, .bold))
                    .tracking(size / 5)
                    .foregroundStyle(palette.yellow.color)
                    .glow(palette.yellow.color, radius: 8, strength: 0.6, palette: palette)
                    .lineLimit(1)
                    .fixedSize()
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                VStack(alignment: .leading, spacing: 4) {
                    if model.attentionCodeCopied {
                        Text("✓ copied to the clipboard")
                            .font(Theme.mono(Theme.Size.small))
                            .foregroundStyle(palette.mint.color)
                    }
                    Button(model.attentionCodeCopied ? "Copy again" : "Copy code") { model.copyAttentionCode() }
                        .buttonStyle(.terminal(.link))
                        .accessibilityLabel("Copy the code")
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder private func openButton(_ attention: Attention) -> some View {
        if let url = attention.url {
            Button("Open \(url.host ?? "the page") again") { model.openAttentionURL() }
                .buttonStyle(.terminal(.secondary))
                .fixedSize()
                .help(url.absoluteString)
        }
    }
}
