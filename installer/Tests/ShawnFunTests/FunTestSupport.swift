import CoreGraphics
import Foundation
import ShawnCore
import XCTest
@testable import ShawnFun

/// A throwaway directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    init(_ name: String = "shawn-fun-tests") {
        url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) -> URL {
        let file = url.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: file)
        return file
    }
}

/// An `InstallerConfig` rooted at `root` with empty steps for `stepIDs`; `fun/` is all FunConfig reads.
func makeInstallerConfig(root: URL, stepIDs: [String] = []) -> InstallerConfig {
    InstallerConfig(root: root,
                    meta: ConfigMeta(schema: ShawnCore.schemaVersion, name: "Test Dotfiles"),
                    steps: stepIDs.map { StepConfig(id: $0, title: $0, file: "steps/\($0).yaml") },
                    source: .local(root.path))
}

enum TestColors {
    static let red = RGBA(red: 255, green: 0, blue: 0)
    static let green = RGBA(red: 0, green: 255, blue: 0)
    static let blue = RGBA(red: 0, green: 0, blue: 255)
    static let lavender = RGBA(hex: "#B57EDC")!
    static let star = RGBA(hex: "#FFD93B")!
}

extension SpriteFrame {
    /// A frame from rows of symbols; any symbol missing from `palette` is transparent.
    init(_ rows: [String], _ palette: [Character: RGBA]) {
        self.init(pixels: rows.map { row in row.map { palette[$0] } })
    }
}

/// Every pixel of `image` as straight RGBA, top row first (drawn into a known sRGB RGBA context).
func readPixels(_ image: CGImage) -> [[RGBA]] {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (0..<height).map { y in
        (0..<width).map { x in
            let offset = (y * width + x) * 4
            let alpha = bytes[offset + 3]
            func straight(_ value: UInt8) -> UInt8 {
                alpha == 0 ? 0 : UInt8(min(255, (Double(value) * 255 / Double(alpha)).rounded()))
            }
            return RGBA(red: straight(bytes[offset]), green: straight(bytes[offset + 1]), blue: straight(bytes[offset + 2]), alpha: alpha)
        }
    }
}
