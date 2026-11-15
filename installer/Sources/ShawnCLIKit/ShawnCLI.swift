import Foundation
import ShawnCore
import ShawnFun
import ShawnSync

/// The `shawn` command line tool.
public enum ShawnCLI {
    /// Runs one invocation and returns its exit status. `arguments` excludes the program name.
    public static func run(arguments: [String], registry: ActionRegistry, environment: SystemEnvironment = .live()) async -> Int32 {
        var environment = environment
        let binary = ShawnBinary.current()
        // Running from the app bundle (Contents/Helpers) or a build directory: the web-app shell and
        // friends sit next to this binary, so let the item kinds find them there.
        if environment.helpersDirectory == nil,
           FileManager.default.isExecutableFile(atPath: binary.deletingLastPathComponent().appendingPathComponent("WebAppShell").path) {
            environment.helpersDirectory = binary.deletingLastPathComponent()
        }
        let probe = try? Dispatcher.parseGlobals(arguments, environment: environment.baseEnvironment)
        let context = CLIContext(
            environment: environment,
            registry: registry,
            terminal: Terminal.detect(environment: environment.baseEnvironment, noColorFlag: probe?.options.noColor ?? false),
            out: FileDescriptorOutput.standardOutput,
            err: FileDescriptorOutput.standardError,
            shawnBinary: binary,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            arguments: arguments
        )
        return await Dispatcher.run(arguments: arguments, context: context)
    }
}
