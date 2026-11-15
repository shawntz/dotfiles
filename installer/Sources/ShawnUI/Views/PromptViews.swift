import ShawnCore
import SwiftUI

/// A modal panel over the dimmed window. Drawn in the window (not as a separate sheet window)
/// so it matches the CRT look and appears in snapshots.
struct PromptOverlay: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    let prompt: PendingPrompt

    var body: some View {
        ZStack {
            palette.background.color.opacity(0.82)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
            Group {
                switch prompt.kind {
                case .password(let request, _):
                    PasswordPanel(model: model, request: request)
                case .question(let question, _):
                    QuestionPanel(model: model, question: question)
                }
            }
            .id(prompt.id)
            .padding(Theme.gutter)
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// Shared chrome for the prompt panels.
private struct PromptCard<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var tint: Tone = .pink
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m + 2) {
            Text(title)
                .captionStyle(palette.color(tint), size: Theme.Size.small)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 540, alignment: .leading)
        .background(palette.panel.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.color(tint).opacity(0.8), lineWidth: 1.5))
        .glow(palette.color(tint), radius: 24, strength: 0.35, palette: palette)
    }
}

struct PasswordPanel: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    let request: PasswordRequest
    @State private var password = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        PromptCard(title: "ADMINISTRATOR PASSWORD") {
            MascotCard(sprite: model.speaker, speaker: model.speaker?.name, quip: model.quip, spriteSize: 64)
            Text(request.reason)
                .font(Theme.mono(Theme.Size.body))
                .foregroundStyle(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
            if let lastError = request.lastError {
                Text("✗ " + ActionError.sentences(lastError, "try \(request.attempt) of \(request.maxAttempts)."))
                    .font(Theme.mono(Theme.Size.small, .semibold))
                    .foregroundStyle(palette.red.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Text(">").font(Theme.mono(Theme.Size.title, .bold)).foregroundStyle(palette.pink.color)
                SecureField("password", text: $password)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(Theme.Size.title))
                    .foregroundStyle(palette.text.color)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .accessibilityLabel("Administrator password")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 9)
            .background(palette.background.color, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.pink.color.opacity(fieldFocused ? 0.9 : 0.5), lineWidth: 1))
            Text("The password you use to log in to this Mac. It goes straight to sudo for this run and is never saved.")
                .font(Theme.mono(Theme.Size.small))
                .foregroundStyle(palette.dim.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.m) {
                Spacer()
                Button("Cancel") { model.cancelPassword() }
                    .buttonStyle(.terminal(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .help("Continue without administrator rights; steps that need them will fail")
                Button("Unlock ⏎", action: submit)
                    .buttonStyle(.terminal(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
                    .accessibilityLabel("Unlock")
            }
        }
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""
        model.submitPassword(entered)
    }
}

struct QuestionPanel: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    let question: Question

    var body: some View {
        PromptCard(title: "QUESTION", tint: .yellow) {
            MascotCard(sprite: model.speaker, speaker: model.speaker?.name, quip: model.quip, spriteSize: 64)
            Text(question.title)
                .font(Theme.mono(Theme.Size.title + 2, .bold))
                .foregroundStyle(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
            if !question.message.isEmpty {
                Text(question.message)
                    .font(Theme.mono(Theme.Size.body))
                    .foregroundStyle(palette.text.color.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = question.url {
                Button("Open \(Self.describe(url))…") { model.open(url) }
                    .buttonStyle(.terminal(.link))
                    .help(url.absoluteString)
            }
            let primaryID = question.defaultOptionID
            HStack(spacing: Theme.Space.m) {
                Spacer()
                ForEach(question.options.filter { $0.id != primaryID }) { option in
                    Button(option.label) { model.answer(optionID: option.id) }
                        .buttonStyle(.terminal(.secondary))
                }
                if let primary = question.options.first(where: { $0.id == primaryID }) {
                    Button(primary.label + " ⏎") { model.answer(optionID: primary.id) }
                        .buttonStyle(.terminal(.primary))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(primary.label)
                }
            }
        }
    }

    /// "the App Store" for macappstore: links, otherwise the host name.
    static func describe(_ url: URL) -> String {
        switch url.scheme {
        case "macappstore", "itms-apps": return "the App Store"
        case "x-apple.systempreferences": return "System Settings"
        default: return url.host ?? url.absoluteString
        }
    }
}
