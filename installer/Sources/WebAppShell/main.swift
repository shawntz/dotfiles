import AppKit

// One binary serves every generated web app: it reads its own bundle's Info.plist to learn which site it is.
// The command-line requests are handled before the application starts, so they never open a window.
let request = ShellCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
if let status = ShellCommandLine.handle(request) {
    exit(status)
}

MainActor.assumeIsolated {
    WebAppLauncher.run()
}
