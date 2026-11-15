import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ActionsWebApp
import ShawnCore

/// A throwaway directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    init(_ name: String = "shawn-webapp-tests") {
        // /tmp (not the long per-user temp path) keeps paths short and readable in failure messages.
        url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String, permissions: Int? = nil) -> URL {
        write(relativePath, Data(contents.utf8), permissions: permissions)
    }

    @discardableResult
    func write(_ relativePath: String, _ data: Data, permissions: Int? = nil) -> URL {
        let file = url.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: file)
        if let permissions {
            try! FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
        return file
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }
}

/// Collects values from concurrent callbacks.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func add(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    var all: [Element] { lock.withLock { storage } }
}

/// Serves canned responses; anything not listed fails like an unreachable server. Records every request.
final class FakeFetcher: WebAppFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: FetchedResource] = [:]
    private var requested: [String] = []

    func serve(_ url: String, _ data: Data, finalURL: String? = nil) {
        lock.withLock { responses[url] = FetchedResource(data: data, url: URL(string: finalURL ?? url)!) }
    }

    func serve(_ url: String, html: String, finalURL: String? = nil) {
        serve(url, Data(html.utf8), finalURL: finalURL)
    }

    var requests: [String] { lock.withLock { requested } }

    func fetch(_ url: URL, userAgent: String, maxBytes: Int, timeout: TimeInterval) async throws -> FetchedResource {
        let response: FetchedResource? = lock.withLock {
            requested.append(url.absoluteString)
            return responses[url.absoluteString]
        }
        guard let response else { throw FetchError("\(url.absoluteString) is unreachable (test)") }
        return response
    }
}

enum TestImages {
    /// Draws into a transparent RGBA canvas (CoreGraphics coordinates: origin bottom left).
    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// An opaque square in one color.
    static func solidPNG(size: Int, red: CGFloat = 0.9, green: CGFloat = 0.1, blue: CGFloat = 0.1) -> Data {
        png(image(width: size, height: size) { context in
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        })
    }

    /// RGBA of one pixel, with (x, y) measured from the top left.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }

    /// Pixel widths of every image in a file (an .icns holds several).
    static func pixelWidths(of url: URL) -> [Int] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        }
    }
}

/// Runs a program and captures its output (for real tools on temp files: codesign, the built WebAppShell).
struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

func runProcess(_ executable: String, _ arguments: [String], environment: [String: String] = ["PATH": "/usr/bin:/bin"]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self))
}

/// A sandboxed machine with a config directory holding one web-apps step, and a fake WebAppShell.
final class WebAppSandbox {
    let directory = TempDirectory()
    let fetcher = FakeFetcher()
    var environment: SystemEnvironment
    let configRoot: URL

    /// The fake shell is a script: codesign signs scripts too, and its bytes stay untouched by signing.
    static let fakeShell = "#!/bin/sh\necho 'fake WebAppShell' \"$@\"\n"

    init(items: String, installShell: Bool = true) {
        environment = SystemEnvironment.sandbox(root: directory.url)
        for url in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        environment.helpersDirectory = directory.url.appendingPathComponent("helpers")
        configRoot = directory.url.appendingPathComponent("config")
        directory.write("config/installer.yaml", "name: Test Dotfiles\nvars:\n  site: x.com\n")
        setItems(items)
        if installShell { writeShell(Self.fakeShell) }
    }

    func setItems(_ items: String) {
        directory.write("config/steps/13-webapps.yaml", "id: webapps\ntitle: Web Apps\nitems:\n" + items)
    }

    func writeShell(_ contents: String, at relativePath: String = "helpers/WebAppShell") {
        directory.write(relativePath, contents, permissions: 0o755)
    }

    func registry() -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(WebAppActions.descriptors(fetcher: fetcher))
        return registry
    }

    func plan() throws -> InstallPlan {
        let config = try ConfigLoader.load(from: configRoot).config
        return InstallPlan.build(config: config, registry: registry(), environment: environment)
    }

    func app(_ name: String = "X") -> URL {
        environment.applicationsDirectory.appendingPathComponent("\(name).app")
    }

    func info(_ name: String = "X") -> [String: Any]? {
        WebAppInfoPlist.read(bundle: app(name))
    }

    /// Runs the whole plan through the real engine.
    @discardableResult
    func install(dryRun: Bool = false, log: Recorder<LogLine>? = nil) async throws -> InstallSummary {
        let plan = try self.plan()
        XCTAssertEqual(plan.errors, [], "config should be valid")
        let engine = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: dryRun))
        return await engine.run(selection: .defaults(for: plan)) { event in
            if case .log(let line) = event { log?.add(line) }
        }
    }

    /// The first item's action and the context the engine would give it.
    func firstItem(dryRun: Bool = false) throws -> (action: WebAppAction, context: ActionContext) {
        let plan = try self.plan()
        XCTAssertEqual(plan.errors, [], "config should be valid")
        let step = plan.steps[0]
        let item = step.items[0]
        let context = ActionContext(config: plan.config, environment: environment, options: RunOptions(dryRun: dryRun),
                                    step: step.config, item: item.config, sudo: nil, interaction: NonInteractive(),
                                    shared: SharedState(), emit: { _ in })
        return (try XCTUnwrap(item.action as? WebAppAction), context)
    }

    /// `check` for the first item, the way the engine calls it.
    func check(dryRun: Bool = false) async throws -> CheckResult {
        let (action, context) = try firstItem(dryRun: dryRun)
        return await action.check(context)
    }
}

/// Denies the current user adding folders to `folder` (an ACL entry), until `allow` is called.
/// Moving a folder out still works, so a bundle can be moved away but nothing can be moved back in.
struct FolderLock {
    let folder: URL

    static func denyAddingFolders(to folder: URL) throws -> FolderLock {
        let result = try runProcess("/bin/chmod", ["+a", "\(NSUserName()) deny add_subdirectory", folder.path])
        guard result.status == 0 else { throw FetchError("chmod +a failed: \(result.stderr)") }
        return FolderLock(folder: folder)
    }

    func allow() {
        _ = try? runProcess("/bin/chmod", ["-N", folder.path])
    }
}

extension CheckResult {
    var reason: String? {
        switch self {
        case .satisfied(let reason), .needed(let reason): return reason
        }
    }
}
