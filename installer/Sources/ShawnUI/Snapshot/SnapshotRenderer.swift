import AppKit
import Foundation
import ShawnCore
import ShawnFun
import ShawnSync
import SwiftUI

struct SnapshotError: Error, CustomStringConvertible {
    let description: String
}

/// Renders SwiftUI content to PNG in an offscreen window that is never ordered front,
/// so nothing appears on screen, nothing takes focus and no screen-recording permission is needed.
@MainActor
enum SnapshotRenderer {
    static func png<Content: View>(of content: Content, size: CGSize, scale: Int = 2) throws -> Data {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)

        // Give SwiftUI a few turns of the run loop to lay out and apply state set in onAppear.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let pixelsWide = Int(size.width) * scale
        let pixelsHigh = Int(size.height) * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw SnapshotError(description: "could not allocate a \(pixelsWide)×\(pixelsHigh) bitmap")
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.contentView = nil
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError(description: "could not encode the snapshot as PNG")
        }
        return data
    }
}

/// `--snapshot PATH`: builds the model for the requested state and writes the window content as a PNG.
@MainActor
enum SnapshotCommand {
    static func run(options: LaunchOptions, registry: ActionRegistry) -> Int32 {
        guard let path = options.snapshotPath else { return 64 }
        NSApplication.shared.setActivationPolicy(.prohibited)
        var scratch: URL?
        defer { if let scratch { Simulation.cleanUp(scratch) } }

        do {
            let model: InstallerModel
            if options.simulate {
                let directory = try Simulation.makeScratchDirectory()
                scratch = directory
                model = try makeSimulationModel(options: options, scratch: directory, mode: .snapshot,
                                                configureNow: options.snapshotState != .loading)
            } else {
                model = try makeLocalModel(options: options, registry: registry)
            }
            try SnapshotProgress.apply(options, to: model)

            let view = RootView(model: model, isSnapshot: true, forcedPalette: options.snapshotHighContrast ? .highContrast : nil)
            let data = try SnapshotRenderer.png(of: view, size: options.snapshotSize, scale: options.snapshotScale)
            let url = URL(fileURLWithPath: PathExpansion.expandTilde(path, home: FileManager.default.homeDirectoryForCurrentUser))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            print("wrote \(url.path) (\(options.snapshotState.rawValue), \(Int(options.snapshotSize.width))×\(Int(options.snapshotSize.height)) @\(options.snapshotScale)x)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return 1
        }
    }

    /// A model over the simulation config, configured synchronously (no network, nothing outside `scratch`).
    /// `timeScale` shrinks the simulated delays (tests).
    static func makeSimulationModel(options: LaunchOptions, scratch: URL, mode: RunMode, configureNow: Bool = true,
                                    timeScale: Double = 1) throws -> InstallerModel {
        let registry = Simulation.makeRegistry(timeScale: timeScale)
        let environment = try Simulation.makeEnvironment(root: scratch.appendingPathComponent("machine"))
        let root = try SimulationConfig.write(into: scratch)
        let resolved = try ConfigResolver.load(directory: root, source: .local(root.path), registry: registry, environment: environment)
        let fun = FunConfig.load(from: resolved.config)
        let model = InstallerModel(registry: registry, environment: environment,
                                   resolveOptions: ConfigResolveOptions(explicitPath: root, allowRemote: false),
                                   settings: InstallerModel.Settings(options: options, mode: mode, isSimulation: true),
                                   dryRun: options.startsInDryRun)
        if configureNow {
            model.configure(resolved, fun: fun.fun, funIssues: fun.issues, extraNotes: [simulationNote])
        }
        return model
    }

    /// A snapshot of the real config on disk (never fetched: a snapshot must not touch the network or the cache).
    private static func makeLocalModel(options: LaunchOptions, registry: ActionRegistry) throws -> InstallerModel {
        let environment = try AppEnvironment.make(options: options)
        var resolveOptions = AppEnvironment.resolveOptions(options: options)
        resolveOptions.allowRemote = false
        var settings = InstallerModel.Settings()
        settings.mode = .snapshot
        let model = InstallerModel(registry: registry, environment: environment, resolveOptions: resolveOptions,
                                   settings: settings, dryRun: options.startsInDryRun)
        guard options.snapshotState != .loading else { return model }
        do {
            let resolved = try ConfigResolver.resolveLocal(options: resolveOptions, registry: registry, environment: environment)
            let fun = FunConfig.load(from: resolved.config)
            model.configure(resolved, fun: fun.fun, funIssues: fun.issues)
        } catch let error as ConfigResolveError {
            model.showLoadFailure(.init(message: error.message, issues: error.issues))
        }
        return model
    }

    static let simulationNote = "Simulation: placeholder steps and characters. Nothing on this Mac is changed. Even a real run only prints canned output."
}
