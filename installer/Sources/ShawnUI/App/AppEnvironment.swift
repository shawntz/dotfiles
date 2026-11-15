import AppKit
import Foundation
import ShawnCore
import ShawnSync

/// Side effects on the desktop (clipboard, browser, Finder), injectable so tests, snapshots and the
/// simulation never touch the real ones.
struct DesktopActions {
    var copyToPasteboard: @MainActor (String) -> Void
    var open: @MainActor (URL) -> Void
    var reveal: @MainActor (URL) -> Void

    static let live = DesktopActions(
        copyToPasteboard: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        open: { url in NSWorkspace.shared.open(url) },
        reveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
    )

    static let none = DesktopActions(copyToPasteboard: { _ in }, open: { _ in }, reveal: { _ in })
}

/// Keeps the Mac from idling to sleep while a real install runs, so a long unattended run (dozens of
/// casks, an Xcode download) is not paused part-way. The display may still sleep. Injectable so tests
/// count begin/end calls instead of changing the Mac's power state.
struct KeepAwake {
    /// Starts holding off idle sleep; returns the token to hand back to `end`.
    var begin: @MainActor (_ reason: String) -> any NSObjectProtocol
    var end: @MainActor (_ token: any NSObjectProtocol) -> Void

    /// A `PreventUserIdleSystemSleep` assertion for as long as the activity lasts (`pmset -g assertions`
    /// lists it under the app). `.userInitiated` also keeps App Nap from throttling the event pump while
    /// the window is hidden.
    static let live = KeepAwake(
        begin: { reason in ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason) },
        end: { token in ProcessInfo.processInfo.endActivity(token) }
    )

    static let none = KeepAwake(begin: { _ in NSObject() }, end: { _ in })
}

/// Where the model's run goes and which side effects are real.
enum RunMode: Equatable {
    /// The real installer.
    case live
    /// The built-in simulation: real engine, simulated kinds, nothing outside a temp directory is touched.
    case simulation
    /// Rendering a PNG: the model is driven by scripted events and nothing runs.
    case snapshot

    /// Copy attention codes and open their URLs without being asked.
    var performsAutomaticDesktopActions: Bool { self == .live }
}

enum AppEnvironment {
    /// `Contents/Helpers` inside the app bundle, or the executable's own directory during development
    /// (where `swift build` puts `shawn` and `WebAppShell` next to the app's binary).
    static func helpersDirectory(bundle: Bundle = .main) -> URL? {
        if bundle.bundleURL.pathExtension == "app" {
            return bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        }
        return bundle.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// The machine the installer acts on: this Mac, or a sandbox tree for `--sandbox DIR`.
    static func make(options: LaunchOptions, bundle: Bundle = .main) throws -> SystemEnvironment {
        var environment: SystemEnvironment
        if let root = options.sandboxRoot {
            let rootURL = URL(fileURLWithPath: PathExpansion.expandTilde(root, home: FileManager.default.homeDirectoryForCurrentUser))
                .standardizedFileURL
            environment = SystemEnvironment.sandbox(root: rootURL)
            for directory in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } else {
            environment = SystemEnvironment.live()
        }
        environment.helpersDirectory = helpersDirectory(bundle: bundle)
        return environment
    }

    /// How to choose the config. A sandbox does not search the real checkout on its own, so when no
    /// `--config` is given the config is located on this Mac (read-only) and passed explicitly.
    static func resolveOptions(options: LaunchOptions, bundle: Bundle = .main) -> ConfigResolveOptions {
        var explicit = options.configPath.map {
            URL(fileURLWithPath: PathExpansion.expandTilde($0, home: FileManager.default.homeDirectoryForCurrentUser)).standardizedFileURL
        }
        if explicit == nil, options.sandboxRoot != nil {
            explicit = ConfigLocator.locate(environment: .live(), bundle: bundle)?.url
        }
        return ConfigResolveOptions(explicitPath: explicit, allowRemote: options.allowRemote, remoteRef: options.configRef)
    }
}
