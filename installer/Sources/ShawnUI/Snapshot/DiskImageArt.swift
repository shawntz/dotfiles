import AppKit
import Foundation
import ShawnCore
import ShawnFun
import ShawnSync
import SwiftUI

/// `--disk-image-art PATH`: draws the picture behind the disk image's Finder window from the config's own
/// banner and narrator, writes it as a PNG and prints where Finder should put the two icons.
@MainActor
enum DiskImageArtCommand {
    static func run(options: LaunchOptions, registry: ActionRegistry) -> Int32 {
        guard let path = options.diskImageArtPath else { return 64 }
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let environment = try AppEnvironment.make(options: options)
            // Like a snapshot, this never touches the network or the cache.
            var resolveOptions = AppEnvironment.resolveOptions(options: options)
            resolveOptions.allowRemote = false
            let resolved = try ConfigResolver.resolveLocal(options: resolveOptions, registry: registry, environment: environment)
            let fun = FunConfig.load(from: resolved.config).fun
            let view = DiskImageBackground(fun: fun, title: resolved.config.meta.name)
            let data = try SnapshotRenderer.png(of: view, size: DiskImageLayout.canvas, scale: options.snapshotScale)
            let url = URL(fileURLWithPath: PathExpansion.expandTilde(path, home: FileManager.default.homeDirectoryForCurrentUser))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            print("wrote \(url.path) (@\(options.snapshotScale)x)")
            print(DiskImageLayout.summary)
            return 0
        } catch {
            FileHandle.standardError.write(Data("disk image art failed: \(error)\n".utf8))
            return 1
        }
    }
}
