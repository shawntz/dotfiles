import AppKit
import Foundation
import ShawnCore

/// The installer window.
public enum ShawnUI {
    /// Starts the app's run loop and never returns. Call from the main thread (top-level code in `main.swift`).
    /// `registry` supplies every item kind; `arguments` is the full command line including the executable
    /// (see `LaunchOptions.usage`). With `--snapshot PATH` it renders one screen to a PNG and exits without
    /// showing a window.
    public static func runApp(registry: ActionRegistry, arguments: [String] = CommandLine.arguments) -> Never {
        let options: LaunchOptions
        do {
            options = try LaunchOptions.parse(Array(arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("ShawnsDotfiles: \(error)\n\n\(LaunchOptions.usage)\n".utf8))
            exit(64)
        }
        if options.showHelp {
            print(LaunchOptions.usage)
            exit(0)
        }

        let status: Int32 = MainActor.assumeIsolated {
            if options.snapshotPath != nil {
                return SnapshotCommand.run(options: options, registry: registry)
            }
            let app = NSApplication.shared
            let controller = AppController(options: options, registry: registry)
            app.delegate = controller
            // Outside an app bundle the process would otherwise have no Dock icon or menu bar.
            app.setActivationPolicy(.regular)
            withExtendedLifetime(controller) {
                app.run()
            }
            return 0
        }
        exit(status)
    }
}
