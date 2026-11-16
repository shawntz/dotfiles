import ShawnCore
import SwiftUI

/// Scanlines and a vignette over everything. Subtle enough to keep text crisp; off with Increase
/// Contrast; the slow refresh band only moves when motion is allowed.
struct CRTOverlay: View {
    @Environment(\.palette) private var palette
    @Environment(\.motionEnabled) private var motionEnabled
    /// Where the vignette is lightest, and how far from there it reaches its full darkness.
    var vignetteCenter = UnitPoint.center
    var vignetteRadius: CGFloat = 900

    var body: some View {
        ZStack {
            if palette.scanlines > 0 {
                Canvas(rendersAsynchronously: true) { context, size in
                    var lines = Path()
                    var y: CGFloat = 0
                    while y < size.height {
                        lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                        y += 3
                    }
                    context.fill(lines, with: .color(.black.opacity(palette.scanlines)))
                }
            }
            if palette.vignette > 0 {
                RadialGradient(colors: [.clear, .clear, .black.opacity(palette.vignette)],
                               center: vignetteCenter, startRadius: 0, endRadius: vignetteRadius)
                    .blendMode(.multiply)
            }
            if motionEnabled && palette.scanlines > 0 {
                RefreshBand()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A faint bright band rolling down the glass every few seconds.
private struct RefreshBand: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            GeometryReader { geometry in
                let period = 9.0
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let bandHeight: CGFloat = 140
                LinearGradient(colors: [.clear, .white.opacity(0.025), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bandHeight)
                    .offset(y: CGFloat(phase) * (geometry.size.height + bandHeight) - bandHeight)
            }
        }
    }
}

/// The whole window.
struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let model: InstallerModel
    var isSnapshot = false
    /// Overrides the system's Increase Contrast setting (snapshots of the high-contrast look).
    var forcedPalette: Palette?

    var body: some View {
        let palette = forcedPalette ?? (contrast == .increased ? Palette.highContrast : Palette.standard)
        ZStack {
            palette.background.color

            VStack(spacing: 0) {
                TopStrip(model: model, isSnapshot: isSnapshot)
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, Theme.Space.l + 2)
            .disabled(model.activePrompt != nil)
            .accessibilityHidden(model.activePrompt != nil)

            if let prompt = model.activePrompt {
                PromptOverlay(model: model, prompt: prompt)
            }

            CRTOverlay()
        }
        .ignoresSafeArea()
        .font(Theme.mono(Theme.Size.body))
        .foregroundStyle(palette.text.color)
        .environment(\.palette, palette)
        .environment(\.motionEnabled, !reduceMotion && !isSnapshot)
        .environment(\.isSnapshot, isSnapshot)
        .environment(\.colorScheme, .dark)
        .tint(palette.pink.color)
        .task(id: QuipClock(phase: model.phase, runCount: model.runCount)) {
            // Speech-bubble rotation; snapshots stay on their first line.
            guard !isSnapshot else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(model.settings.quipInterval))
                } catch {
                    return
                }
                model.advanceQuip()
            }
        }
    }

    private struct QuipClock: Equatable {
        let phase: InstallerModel.Phase
        let runCount: Int
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .loading: LoadingView(model: model)
        case .configError: ConfigErrorView(model: model)
        case .welcome: WelcomeView(model: model)
        case .customize: CustomizeView(model: model)
        case .running: RunningView(model: model)
        case .finished: FinishedView(model: model)
        }
    }
}

/// The title-bar row: room for the traffic lights, then the run's mode and the version.
private struct TopStrip: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    let isSnapshot: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if isSnapshot {
                // Where the window's traffic lights sit, so snapshots show the real spacing.
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(palette.faint.color.opacity(0.6)).frame(width: 12, height: 12)
                    }
                }
                .padding(.leading, 20 - Theme.gutter)
                .accessibilityHidden(true)
            }
            Spacer()
            if model.settings.isSimulation {
                Chip(text: "SIMULATION", tone: .cyan)
                    .help("Built-in simulation: nothing on this Mac is changed")
            }
            if showsDryRun {
                Chip(text: "DRY RUN · NOTHING CHANGES", tone: .yellow, filled: true)
                    .accessibilityLabel("Dry run: nothing on this Mac will change")
            }
            Text("v\(ShawnCore.version)")
                .font(Theme.mono(Theme.Size.caption))
                .foregroundStyle(palette.faint.color)
        }
        .frame(height: Theme.titleBarHeight)
        .padding(.top, 2)
    }

    private var showsDryRun: Bool {
        switch model.phase {
        case .running, .finished: return model.runIsDryRun
        case .welcome, .customize: return model.dryRun
        case .loading, .configError: return false
        }
    }
}
