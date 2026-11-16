import SwiftUI

extension Palette {
    func color(_ tone: Tone) -> Color {
        switch tone {
        case .faint: return faint.color
        case .dim: return dim.color
        case .text: return text.color
        case .pink: return pink.color
        case .yellow: return yellow.color
        case .mint: return mint.color
        case .red: return red.color
        case .cyan: return cyan.color
        }
    }
}

// MARK: - Panels

/// A bordered terminal pane with its title set into the top border.
struct TerminalPanel<Content: View, Accessory: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var tint: Tone = .dim
    var padding: CGFloat = Theme.Space.m
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, padding)
            .padding(.top, padding + 4)
            .padding(.bottom, padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(palette.panel.color, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(palette.color(tint).opacity(tint == .dim ? 0.45 : 0.85), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Text(" \(title) ")
                        .captionStyle(palette.color(tint))
                        .background(palette.panel.color)
                    Spacer(minLength: Theme.Space.s)
                    accessory
                        .padding(.horizontal, 6)
                        .background(palette.panel.color)
                }
                .padding(.horizontal, Theme.Space.s)
                .offset(y: -7)
                .accessibilityElement(children: .contain)
            }
    }
}

extension TerminalPanel where Accessory == EmptyView {
    init(title: String, tint: Tone = .dim, padding: CGFloat = Theme.Space.m, @ViewBuilder content: () -> Content) {
        self.init(title: title, tint: tint, padding: padding, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Buttons

struct TerminalButtonStyle: ButtonStyle {
    enum Kind {
        /// Filled pink: the one thing to do next.
        case primary
        case secondary
        case danger
        /// Text-only, for small inline actions (Open, Reveal, Copy).
        case link
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        @Environment(\.palette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration
        let kind: Kind

        var body: some View {
            let pressed = configuration.isPressed
            switch kind {
            case .link:
                configuration.label
                    .font(Theme.mono(Theme.Size.small, .semibold))
                    .foregroundStyle(palette.cyan.color.opacity(pressed ? 0.6 : 1))
                    .underline(true, color: palette.cyan.color.opacity(0.35))
                    .opacity(isEnabled ? 1 : 0.4)
                    .contentShape(Rectangle())
            case .primary, .secondary, .danger:
                let accent = kind == .danger ? palette.red.color : palette.pink.color
                configuration.label
                    .font(Theme.mono(Theme.Size.body, .bold))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 32)
                    .foregroundStyle(kind == .primary ? palette.background.color : (kind == .danger ? accent : palette.text.color))
                    .background {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(kind == .primary ? accent.opacity(pressed ? 0.75 : 1) : accent.opacity(pressed ? 0.18 : 0.06))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(kind == .primary ? accent : accent.opacity(kind == .danger ? 0.8 : 0.55), lineWidth: 1)
                    }
                    .glow(accent, radius: kind == .primary ? 10 : 0, strength: isEnabled && kind == .primary ? 0.55 : 0, palette: palette)
                    .opacity(isEnabled ? 1 : 0.35)
                    .contentShape(Rectangle())
            }
        }
    }
}

extension ButtonStyle where Self == TerminalButtonStyle {
    static func terminal(_ kind: TerminalButtonStyle.Kind = .secondary) -> TerminalButtonStyle {
        TerminalButtonStyle(kind: kind)
    }
}

/// `[x]` / `[ ]` checkbox in the monospaced font. The whole label is the hit target.
struct TerminalCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Checkbox(configuration: configuration)
    }

    private struct Checkbox: View {
        @Environment(\.palette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ToggleStyleConfiguration

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    HStack(spacing: 0) {
                        Text("[").foregroundStyle(palette.dim.color)
                        Text(configuration.isOn ? "x" : " ").foregroundStyle(palette.pink.color).fontWeight(.bold)
                        Text("]").foregroundStyle(palette.dim.color)
                    }
                    .font(Theme.mono(Theme.Size.body))
                    configuration.label
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

// MARK: - Small pieces

/// A small labeled badge: `DRY RUN`, `SIMULATION`, `OPTIONAL`.
struct Chip: View {
    @Environment(\.palette) private var palette
    let text: String
    var tone: Tone = .yellow
    var filled = false
    /// Sized to sit inside a line of small text without making the row taller.
    var compact = false

    var body: some View {
        Text(text)
            .font(Theme.mono(compact ? 8.5 : Theme.Size.caption, .bold))
            .tracking(compact ? 0.8 : 1.2)
            .lineLimit(1)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 0 : 2)
            .foregroundStyle(filled ? palette.background.color : palette.color(tone))
            .background(RoundedRectangle(cornerRadius: 2).fill(palette.color(tone).opacity(filled ? 1 : 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(palette.color(tone).opacity(0.7), lineWidth: 1))
            .fixedSize()
    }
}

/// A status glyph in a fixed-width column, spinning while work is in progress.
struct StatusGlyph: View {
    @Environment(\.palette) private var palette
    @Environment(\.motionEnabled) private var motionEnabled
    let look: StatusLook
    var size: CGFloat = Theme.Size.body

    var body: some View {
        Group {
            if look.spins && motionEnabled {
                TimelineView(.periodic(from: .now, by: StatusLook.spinnerInterval)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / StatusLook.spinnerInterval)
                    Text(StatusLook.spinnerFrames[tick % StatusLook.spinnerFrames.count])
                }
            } else {
                Text(look.glyph)
            }
        }
        .font(Theme.mono(size, .bold))
        .foregroundStyle(palette.color(look.tone))
        .frame(width: size * Theme.monoAdvance * 1.6, alignment: .center)
        .accessibilityLabel(look.label)
    }
}

/// The phosphor cursor: blinks unless motion is off.
struct BlinkingCursor: View {
    @Environment(\.palette) private var palette
    @Environment(\.motionEnabled) private var motionEnabled
    var size: CGFloat = Theme.Size.body
    var tone: Tone = .pink

    var body: some View {
        Group {
            if motionEnabled {
                TimelineView(.periodic(from: .now, by: 0.53)) { context in
                    let visible = Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
                    cursor.opacity(visible ? 1 : 0)
                }
            } else {
                cursor
            }
        }
        .accessibilityHidden(true)
    }

    private var cursor: some View {
        Text("█").font(Theme.mono(size)).foregroundStyle(palette.color(tone))
    }
}

/// Text that types itself out, one character at a time (instantly when motion is off).
struct TypewriterText: View {
    @Environment(\.motionEnabled) private var motionEnabled
    let text: String
    var characterDelay: Duration = .milliseconds(22)
    @State private var shown = 0

    var body: some View {
        // The full text sizes the view so the bubble does not grow while typing.
        Text(text)
            .hidden()
            .overlay(alignment: .topLeading) {
                Text(motionEnabled ? String(text.prefix(shown)) : text)
            }
            .accessibilityElement()
            .accessibilityLabel(text)
            .task(id: text) {
                guard motionEnabled else { return }
                shown = 0
                for index in 1...max(1, text.count) {
                    do {
                        try await Task.sleep(for: characterDelay)
                    } catch {
                        return
                    }
                    shown = index
                }
            }
    }
}

/// Shows its content at its natural height when that fits, and scrolls it when it does not, so a
/// short list hugs its rows and a long one never pushes the window's buttons off screen.
struct HuggingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                content
                    .padding(.vertical, Theme.Space.xs)
            }
            .edgeFade(top: 6, bottom: 10)
        }
    }
}

/// A one-line `label ··· value` row.
struct LeaderRow: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var tone: Tone = .text

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).foregroundStyle(palette.dim.color)
            Spacer(minLength: Theme.Space.s)
            Text(value).foregroundStyle(palette.color(tone))
        }
        .font(Theme.mono(Theme.Size.small))
    }
}
