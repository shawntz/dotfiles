import AppKit
import SwiftUI

/// An sRGB colour usable from both SwiftUI and AppKit (the log view is an NSTextView).
struct ThemeColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    func opacity(_ value: Double) -> Color { color.opacity(value) }
}

/// The CRT phosphor palette: deep purple-black glass, lavender text, pink and star-yellow highlights.
struct Palette: Equatable, Sendable {
    var background: ThemeColor
    var panel: ThemeColor
    var border: ThemeColor
    var text: ThemeColor
    var dim: ThemeColor
    var faint: ThemeColor
    var pink: ThemeColor
    var yellow: ThemeColor
    var mint: ThemeColor
    var red: ThemeColor
    var cyan: ThemeColor
    var orange: ThemeColor
    /// Bloom around bright text; 0 turns it off.
    var glow: Double
    /// Scanline darkness; 0 turns them off.
    var scanlines: Double
    var vignette: Double

    static let standard = Palette(
        background: ThemeColor(0x110A1C),
        panel: ThemeColor(0x170E26),
        border: ThemeColor(0x3B2758),
        text: ThemeColor(0xD6BFF5),
        dim: ThemeColor(0x9A84BE),
        faint: ThemeColor(0x5F4E80),
        pink: ThemeColor(0xFF79D3),
        yellow: ThemeColor(0xFFD84D),
        mint: ThemeColor(0x7DF5C8),
        red: ThemeColor(0xFF6482),
        cyan: ThemeColor(0x8BD8FF),
        orange: ThemeColor(0xEDA77F),
        glow: 1,
        scanlines: 0.13,
        vignette: 0.42
    )

    /// "Increase contrast": brighter secondary text, firmer borders, no bloom, no scanlines.
    static let highContrast = Palette(
        background: ThemeColor(0x0B0614),
        panel: ThemeColor(0x140B22),
        border: ThemeColor(0x8A70B4),
        text: ThemeColor(0xF4EAFF),
        dim: ThemeColor(0xD3C1F0),
        faint: ThemeColor(0xA592C8),
        pink: ThemeColor(0xFF9BE0),
        yellow: ThemeColor(0xFFE173),
        mint: ThemeColor(0x9BFFD8),
        red: ThemeColor(0xFF8DA3),
        cyan: ThemeColor(0xB0E6FF),
        orange: ThemeColor(0xFFC3A0),
        glow: 0,
        scanlines: 0,
        vignette: 0
    )
}

/// Type, spacing and sizes. Everything is monospaced so box-drawing glyphs and status columns line up.
enum Theme {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func nsMono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    enum Size {
        static let caption: CGFloat = 10
        static let small: CGFloat = 11
        static let body: CGFloat = 12
        static let title: CGFloat = 14
        static let headline: CGFloat = 20
        static let display: CGFloat = 26
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Room left at the top for the traffic lights (the content runs under a transparent title bar).
    static let titleBarHeight: CGFloat = 30
    static let gutter: CGFloat = 28
    static let cornerRadius: CGFloat = 5

    static let defaultWindowSize = CGSize(width: 1100, height: 760)
    static let minimumWindowSize = CGSize(width: 960, height: 640)

    /// Advance of one character of the monospaced font, as a fraction of the point size.
    static let monoAdvance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return width / 100
    }()
}

// MARK: - Environment

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.standard
}

private struct MotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }

    /// False when Reduce Motion is on or a snapshot is being rendered: no blinking, typing or frame animation.
    var motionEnabled: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }

    /// True while rendering a PNG: clocks freeze at the model's fixed "now" and timers do not start.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

extension View {
    /// Soft phosphor bloom; disappears when the palette turns glow off.
    func glow(_ color: Color, radius: CGFloat = 6, strength: Double = 0.65, palette: Palette) -> some View {
        shadow(color: color.opacity(strength * palette.glow), radius: palette.glow > 0 ? radius : 0)
    }

    /// Fades content out at the top and bottom edges of a scrolling area, so rows slide under the
    /// panel border instead of being chopped off.
    func edgeFade(top: CGFloat = 12, bottom: CGFloat = 12) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
            }
        }
    }

    /// Small-caps style label used for section titles and chips.
    func captionStyle(_ color: Color, size: CGFloat = Theme.Size.caption) -> some View {
        font(Theme.mono(size, .semibold)).tracking(1.4).foregroundStyle(color)
    }
}
