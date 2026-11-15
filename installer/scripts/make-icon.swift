// Draws the app icon for Shawn's Dotfiles: a little purple CRT terminal with a chunky pixel star
// and a ">_" prompt glowing on its screen. Original art, drawn with CoreGraphics; no image files.
//
//   swift scripts/make-icon.swift <out.icns>               every iconset size, packed with iconutil
//   swift scripts/make-icon.swift --png <out.png> [SIZE]   one PNG (default 1024) for a quick look
//
// The drawing lives on a 1024-unit canvas. Everything on the screen sits on a 32-unit grid, so at
// 32, 64, 128 px and up each art pixel lands on whole device pixels and stays sharp. Details that
// would only turn to mush (scanlines, text lines, sparkles, the glass sheen) are left out at
// small sizes, where the icon has to read as "dark screen, yellow star, prompt" and nothing else.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Palette (the installer's CRT theme)

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

enum Palette {
    static let caseTop = RGB(0x6A48A6)
    static let caseBottom = RGB(0x2E1A4F)
    static let caseRim = RGB(0xC9B0F0)
    static let chinGroove = RGB(0x1E1035)
    static let screenCenter = RGB(0x2B1748)
    static let screenEdge = RGB(0x0B0614)
    static let lavender = RGB(0xD6BFF5)
    static let dimLavender = RGB(0x9A84BE)
    static let pink = RGB(0xFF79D3)
    static let star = RGB(0xFFD84D)
    static let starLight = RGB(0xFFF3B0)
    static let starShade = RGB(0xF2A93B)
    static let mint = RGB(0x7DF5C8)
}

// MARK: - Pixel art (one character per 32-unit cell; '.' is empty)

/// The star: Y body, H highlight (lit from the top left), O shade. The outline is symmetric.
let starArt = [
    ".....H.....",
    "....HYY....",
    "....HYO....",
    "HHHHYYYYYYO",
    ".HYYYYYYYO.",
    "..HYYYYYO..",
    "...YYYYO...",
    "..HYYYYYO..",
    "..HYO.YYO..",
    ".HYO...YYO.",
    ".HO.....YO.",
]

/// The prompt's chevron, two cells thick.
let chevronArt = [
    "XX...",
    ".XX..",
    "..XX.",
    "...XX",
    "..XX.",
    ".XX..",
    "XX...",
]

let cell: CGFloat = 32
/// The screen: 22 x 19 cells, inside a case with a deeper chin underneath.
let screenRect = CGRect(x: 160, y: 160, width: 22 * cell, height: 19 * cell)
let caseRect = CGRect(x: 100, y: 100, width: 824, height: 824)

// MARK: - Drawing

struct Canvas {
    let context: CGContext
    let pixels: Int
    /// Device pixels per canvas unit.
    var scale: CGFloat { CGFloat(pixels) / 1024 }
    var detailed: Bool { pixels >= 128 }

    func fill(_ path: CGPath, _ color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    func cellRect(column: Int, row: Int, width: Int = 1, height: Int = 1) -> CGRect {
        CGRect(x: screenRect.minX + CGFloat(column) * cell, y: screenRect.minY + CGFloat(row) * cell,
               width: CGFloat(width) * cell, height: CGFloat(height) * cell)
    }

    /// Draws `art` with its top-left cell at (column, row); `colors` maps characters to colours.
    func pixelArt(_ art: [String], column: Int, row: Int, colors: [Character: CGColor]) {
        for (y, line) in art.enumerated() {
            for (x, character) in line.enumerated() {
                guard let color = colors[character] else { continue }
                context.setFillColor(color)
                context.fill(cellRect(column: column + x, row: row + y))
            }
        }
    }

    /// Runs `body` so that everything it draws shares one soft phosphor glow.
    func glowing(_ color: CGColor, radius: CGFloat, _ body: () -> Void) {
        context.saveGState()
        // Shadow geometry is in device pixels, not canvas units.
        context.setShadow(offset: .zero, blur: radius * scale, color: color)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// A superellipse ("squircle") close to the macOS icon shape.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = a * copysign(pow(abs(c), 2 / exponent), c)
        let y = b * copysign(pow(abs(s), 2 / exponent), s)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func drawCase(_ canvas: Canvas) {
    let context = canvas.context
    let body = squircle(in: caseRect)

    // Drop shadow under the whole case, as macOS icons have.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * canvas.scale), blur: 28 * canvas.scale,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
    canvas.fill(body, Palette.caseBottom.cg())
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(linearGradient([Palette.caseTop.cg(), Palette.caseBottom.cg()], locations: [0, 1]),
                               start: CGPoint(x: 0, y: caseRect.minY), end: CGPoint(x: 0, y: caseRect.maxY), options: [])
    // A light top edge so the case still stands out on a dark Dock.
    context.addPath(body)
    context.setStrokeColor(Palette.caseRim.cg(0.55))
    context.setLineWidth(max(1 / canvas.scale, 10))
    context.strokePath()
    context.restoreGState()

    // The chin: a recessed groove and a mint power light.
    let chinTop = screenRect.maxY
    if canvas.pixels >= 64 {
        let grooveY = chinTop + 62
        for index in 0..<3 {
            let groove = CGRect(x: 208, y: grooveY + CGFloat(index) * 24, width: 160, height: 10)
            canvas.fill(CGPath(roundedRect: groove, cornerWidth: 5, cornerHeight: 5, transform: nil), Palette.chinGroove.cg(0.85))
        }
    }
    let light = CGRect(x: 776, y: chinTop + 62, width: 40, height: 40)
    canvas.glowing(Palette.mint.cg(0.9), radius: 26) {
        canvas.fill(CGPath(ellipseIn: light, transform: nil), Palette.mint.cg())
    }
}

func drawScreen(_ canvas: Canvas) {
    let context = canvas.context
    let screen = CGPath(roundedRect: screenRect, cornerWidth: 72, cornerHeight: 72, transform: nil)

    // The bezel's lip: a dark ring just outside the glass.
    let lip = CGPath(roundedRect: screenRect.insetBy(dx: -14, dy: -14), cornerWidth: 84, cornerHeight: 84, transform: nil)
    canvas.fill(lip, Palette.chinGroove.cg())

    context.saveGState()
    context.addPath(screen)
    context.clip()

    // Phosphor-dark glass, brightest in the middle.
    let center = CGPoint(x: screenRect.midX, y: screenRect.midY - 20)
    context.drawRadialGradient(linearGradient([Palette.screenCenter.cg(), Palette.screenEdge.cg()], locations: [0, 1]),
                               startCenter: center, startRadius: 0, endCenter: center, endRadius: screenRect.width * 0.62,
                               options: [.drawsAfterEndLocation])

    drawScreenContent(canvas)

    if canvas.pixels >= 256 {
        // Scanlines: a fixed 4-device-pixel rhythm per 512 px reads as CRT without moiré.
        let period = max(2, CGFloat(canvas.pixels) / 128) / canvas.scale
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        var y = screenRect.minY
        while y < screenRect.maxY {
            context.fill(CGRect(x: screenRect.minX, y: y + period / 2, width: screenRect.width, height: period / 2))
            y += period
        }
    }
    if canvas.detailed {
        // Curved-glass sheen, brightest at the top left and fading out with no visible edge.
        let sheenCenter = CGPoint(x: screenRect.minX + 120, y: screenRect.minY + 60)
        context.drawRadialGradient(linearGradient([CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09),
                                                   CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)], locations: [0, 1]),
                                   startCenter: sheenCenter, startRadius: 0, endCenter: sheenCenter,
                                   endRadius: screenRect.width * 0.55, options: [])
    }
    // Vignette: the tube darkens towards its corners.
    context.drawRadialGradient(linearGradient([CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
                                               CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)], locations: [0.55, 1]),
                               startCenter: center, startRadius: 0, endCenter: center, endRadius: screenRect.width * 0.78,
                               options: [.drawsAfterEndLocation])
    context.restoreGState()
}

func drawScreenContent(_ canvas: Canvas) {
    if canvas.detailed {
        // A few lines of terminal output, dim, so the star and prompt stay the focus.
        let lines: [(column: Int, row: Int, width: Int, color: CGColor)] = [
            (2, 2, 1, Palette.pink.cg(0.85)), (4, 2, 3, Palette.dimLavender.cg(0.75)),
            (2, 4, 5, Palette.dimLavender.cg(0.55)),
            (2, 6, 2, Palette.dimLavender.cg(0.55)), (5, 6, 2, Palette.dimLavender.cg(0.55)),
        ]
        canvas.glowing(Palette.lavender.cg(0.35), radius: 14) {
            for line in lines {
                canvas.context.setFillColor(line.color)
                canvas.context.fill(canvas.cellRect(column: line.column, row: line.row, width: line.width))
            }
        }
        // Sparkles around the star.
        canvas.glowing(Palette.star.cg(0.8), radius: 16) {
            for (column, row) in [(9, 1), (20, 1), (15, 15)] {
                canvas.context.setFillColor(Palette.starLight.cg())
                canvas.context.fill(canvas.cellRect(column: column, row: row))
            }
        }
    }

    canvas.glowing(Palette.star.cg(0.85), radius: canvas.detailed ? 46 : 20) {
        canvas.pixelArt(starArt, column: 9, row: 2,
                        colors: ["Y": Palette.star.cg(), "H": Palette.starLight.cg(), "O": Palette.starShade.cg()])
    }
    canvas.glowing(Palette.lavender.cg(0.8), radius: canvas.detailed ? 34 : 14) {
        canvas.pixelArt(chevronArt, column: 2, row: 10, colors: ["X": Palette.lavender.cg()])
    }
    canvas.glowing(Palette.pink.cg(0.9), radius: canvas.detailed ? 34 : 14) {
        canvas.context.setFillColor(Palette.pink.cg())
        canvas.context.fill(canvas.cellRect(column: 8, row: 15, width: 4, height: 2))
    }
}

func render(pixels: Int) -> CGImage {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create a \(pixels)x\(pixels) drawing context")
    }
    let canvas = Canvas(context: context, pixels: pixels)
    // Work top-down on the 1024-unit canvas.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: canvas.scale, y: -canvas.scale)
    context.interpolationQuality = .high
    drawCase(canvas)
    drawScreen(canvas)
    guard let image = context.makeImage() else { fail("could not finish the \(pixels)px image") }
    return image
}

// MARK: - Output

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

func writeICNS(to output: URL) {
    let fileManager = FileManager.default
    let work = fileManager.temporaryDirectory.appendingPathComponent("make-icon-\(UUID().uuidString)")
    let iconset = work.appendingPathComponent("AppIcon.iconset")
    defer { try? fileManager.removeItem(at: work) }
    do {
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        fail("cannot create a working directory: \(error.localizedDescription)")
    }

    var rendered: [Int: CGImage] = [:]
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = points * factor
            let image = rendered[pixels] ?? render(pixels: pixels)
            rendered[pixels] = image
            let suffix = factor == 2 ? "@2x" : ""
            writePNG(image, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        }
    }

    // Write next to the destination, then move into place, so a failed run never leaves half a file.
    // iconutil insists on the .icns extension, so the temporary name keeps it.
    let staged = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(output.lastPathComponent)")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", staged.path, iconset.path]
    do {
        try iconutil.run()
    } catch {
        fail("cannot run iconutil: \(error.localizedDescription)")
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        try? fileManager.removeItem(at: staged)
        fail("iconutil failed with status \(iconutil.terminationStatus)")
    }
    guard rename(staged.path, output.path) == 0 else {
        let reason = String(cString: strerror(errno))
        try? fileManager.removeItem(at: staged)
        fail("cannot write \(output.path): \(reason)")
    }
}

let usage = """
usage: swift scripts/make-icon.swift <out.icns>
       swift scripts/make-icon.swift --png <out.png> [size]
"""

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "-h", "--help":
    print(usage)
case "--png":
    guard arguments.count == 2 || arguments.count == 3 else { fail(usage) }
    let size = arguments.count == 3 ? Int(arguments[2]) : 1024
    guard let size, (16...2048).contains(size) else { fail("size must be a number of pixels from 16 to 2048") }
    let output = URL(fileURLWithPath: arguments[1])
    writePNG(render(pixels: size), to: output)
    print(output.path)
case .some(let path) where arguments.count == 1 && !path.hasPrefix("-"):
    let output = URL(fileURLWithPath: path)
    guard output.pathExtension == "icns" else { fail("the output file must end in .icns") }
    writeICNS(to: output)
    print(output.path)
default:
    fail(usage)
}
