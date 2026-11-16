import ShawnFun
import SwiftUI

/// Where things sit in the Finder window that opens for the disk image, in points from the top left corner
/// of the area under its title bar.
///
/// Finder draws the two icons and their names. `DiskImageBackground` draws everything behind them, and
/// `scripts/make-dmg-art.sh` writes these numbers into the layout file Finder reads (`Resources/dmg/DS_Store`).
public enum DiskImageLayout {
    /// The window under its title bar.
    public static let window = CGSize(width: 680, height: 460)
    /// The picture. It is larger than the window, so a taller title bar or a window someone made larger
    /// shows more of the same dark glass and not a white edge.
    public static let canvas = CGSize(width: 800, height: 560)
    /// What Finder's title bar adds to the window's height when the toolbar is hidden (macOS 27).
    public static let titleBarHeight: CGFloat = 32
    public static let iconSize: CGFloat = 128
    /// Point size of the names Finder draws under the icons.
    public static let textSize: CGFloat = 12
    /// The center of the app's icon.
    public static let app = CGPoint(x: 180, y: 218)
    /// The center of the shortcut to the Applications folder.
    public static let applications = CGPoint(x: 500, y: 218)

    /// How far under an icon's center Finder draws the middle of its name, at this icon and text size.
    /// Measured in Finder on macOS 27.2.
    static let nameCenter: CGFloat = 82
    /// The band of each card that the icon's name is drawn on, as offsets down from the icon's center.
    static let nameBand: ClosedRange<CGFloat> = (nameCenter - 15)...(nameCenter + 15)

    /// The numbers on one line, for the script that builds the layout file.
    public static var summary: String {
        func pair(_ point: CGPoint) -> String { "\(Int(point.x)),\(Int(point.y))" }
        return "layout window=\(Int(window.width))x\(Int(window.height)) title-bar=\(Int(titleBarHeight)) "
            + "icon=\(Int(iconSize)) text=\(Int(textSize)) app=\(pair(app)) applications=\(pair(applications)) "
            + "background=\(DiskImageBackground.backgroundHex)"
    }
}

/// The picture behind the icons in the disk image's Finder window: the config's banner, a card for each icon,
/// an arrow from the app to the Applications folder, and the narrator with the first line the app opens on.
struct DiskImageBackground: View {
    let fun: FunConfig
    /// The config's name, for the banner's accessibility label.
    let title: String
    var palette = Palette.standard

    /// The window's background color as Finder's layout file stores it, `RRGGBB`.
    static let backgroundHex = "110A1C"
    /// The band under each icon. Over a picture, Finder on macOS 27 draws an icon's name in black, in the
    /// light and in the dark appearance, and black does not read on the window's dark glass. The band is a
    /// purple that black reads on, and white too should another Finder pick that (about 4.6 to 1 against each).
    static let nameBand = ThemeColor(0x8466C0)

    var body: some View {
        let window = DiskImageLayout.window
        let canvas = DiskImageLayout.canvas
        ZStack(alignment: .topLeading) {
            palette.background.color
            content
                .frame(width: window.width, height: window.height)
            CRTOverlay(vignetteCenter: UnitPoint(x: window.width / 2 / canvas.width, y: window.height / 2 / canvas.height),
                       vignetteRadius: 620)
        }
        .frame(width: canvas.width, height: canvas.height)
        // The offscreen window that renders this has a title bar. Without this the picture starts under it.
        .ignoresSafeArea()
        .font(Theme.mono(Theme.Size.body))
        .foregroundStyle(palette.text.color)
        .environment(\.palette, palette)
        .environment(\.motionEnabled, false)
        .environment(\.isSnapshot, true)
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        let window = DiskImageLayout.window
        let middle = window.width / 2
        let iconY = DiskImageLayout.app.y
        let band = DiskImageLayout.nameBand
        let cardTop = iconY - DiskImageLayout.iconSize / 2 - 14
        let cardBottom = iconY + band.upperBound
        return ZStack(alignment: .topLeading) {
            Color.clear

            ASCIIHeaderView(text: fun.header, accessibilityTitle: title, maxHeight: 84, maxFontSize: 8.5)
                .frame(width: window.width - 2 * 40)
                .position(x: middle, y: 64)

            ForEach([DiskImageLayout.app, DiskImageLayout.applications], id: \.x) { center in
                IconCard(bandHeight: band.upperBound - band.lowerBound)
                    .frame(width: DiskImageLayout.iconSize + 40, height: cardBottom - cardTop)
                    .position(x: center.x, y: (cardTop + cardBottom) / 2)
            }

            PixelArrow()
                .frame(width: 91, height: 63)
                .position(x: middle, y: iconY - 8)
            Text("DRAG TO INSTALL")
                .captionStyle(palette.dim.color)
                .position(x: middle, y: iconY + 44)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: Theme.Space.l) {
                SpriteView(sprite: fun.sprite(nil))
                    .frame(width: 72, height: 72)
                SpeechBubble(speaker: fun.sprite(nil)?.name, text: fun.line(for: .launch, seed: 0), fillsWidth: false)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 44)
            .padding(.bottom, 24)
        }
    }
}

/// The card an icon sits on, with the band its name is drawn on along the bottom.
private struct IconCard: View {
    @Environment(\.palette) private var palette
    let bandHeight: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        VStack(spacing: 0) {
            palette.panel.color
            DiskImageBackground.nameBand.color.frame(height: bandHeight)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.border.color, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// A chunky arrow made of square cells, pink at the tail and yellow at the tip.
struct PixelArrow: View {
    @Environment(\.palette) private var palette

    /// One string per row, `#` for a filled cell.
    static let cells = [
        "........#....",
        "........##...",
        "........###..",
        "############.",
        "#############",
        "############.",
        "........###..",
        "........##...",
        "........#....",
    ]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let columns = Self.cells.map(\.count).max() ?? 1
            let cell = min(size.width / CGFloat(columns), size.height / CGFloat(Self.cells.count)).rounded(.down)
            let origin = CGPoint(x: ((size.width - cell * CGFloat(columns)) / 2).rounded(),
                                 y: ((size.height - cell * CGFloat(Self.cells.count)) / 2).rounded())
            let stops = [palette.pink.nsColor, palette.yellow.nsColor]
            for (row, line) in Self.cells.enumerated() {
                for (column, character) in line.enumerated() where character == "#" {
                    let color = ASCIIHeaderView.blend(stops, at: CGFloat(column) / CGFloat(max(1, columns - 1)))
                    let rect = CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(row) * cell,
                                      width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(nsColor: color)))
                }
            }
        }
        .glow(palette.pink.color, radius: 8, strength: 0.6, palette: palette)
        .accessibilityHidden(true)
    }
}
