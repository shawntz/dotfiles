import Foundation
import ShawnCore

/// `- homebrew: install` installs Homebrew itself.
///
/// Prefers the signed, notarized `Homebrew.pkg` from the latest release (one `sudo installer` call),
/// and falls back to the official install.sh with `NONINTERACTIVE=1` (it gets administrator rights
/// through the installer's askpass helper). Then `brew update`.
struct HomebrewAction: Action {
    enum Method: String, CaseIterable {
        case pkg, script
    }

    let method: Method
    let system: MacSystem

    var title: String { "Homebrew" }
    var subtitle: String? { method == .pkg ? "Homebrew.pkg on Apple silicon (install.sh on Intel or as a fallback)" : "install.sh" }
    var sudo: SudoNeed { .always }

    static func parse(_ parser: ItemParser, system: MacSystem) -> HomebrewAction {
        requireInstallValue(parser)
        let method = Method(rawValue: parser.options.oneOf("method", Method.allCases.map(\.rawValue), default: Method.pkg.rawValue)) ?? .pkg
        return HomebrewAction(method: method, system: system)
    }

    func works(_ context: ActionContext) async -> Bool {
        guard Brew.isInstalled(context) else { return false }
        return await context.commands.succeeds(context.environment.brewExecutable, ["--version"], timeout: 60)
    }

    func check(_ context: ActionContext) async -> CheckResult {
        if await works(context) { return .satisfied("installed") }
        return Brew.isInstalled(context) ? .needed("brew is there but does not run") : .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        if !context.dryRun, await works(context) { return .done("already installed") }
        if let refusal = Common.sandboxRefusal("installing Homebrew", context, system: system) { return refusal }

        var installed = false
        // The package is built for Apple Silicon only.
        if method == .pkg && context.environment.architecture == "arm64" {
            do {
                try await installPackage(context)
                installed = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                context.warn("Homebrew.pkg did not install: \(Common.describe(error)). Trying the official install script instead.")
            }
        }
        if !installed {
            try await installWithScript(context)
        }
        await Brew.invalidateInstalledState(context)

        if !context.dryRun, !(await works(context)) {
            throw ActionError("Homebrew was installed but \(context.environment.brewExecutable) does not run",
                              hint: "look at the installer output above; running the installer again repairs a half-finished install")
        }

        let update = try await context.run(await Brew.command(["update"], context))
        guard update.succeeded else {
            context.warn("brew update failed: \(update.tail(3)). Homebrew updates itself on its next command instead.")
            return Common.done("installed (brew update failed)", context)
        }
        if !context.dryRun { await Brew.markUpdated(context) }
        return Common.done("installed", context)
    }

    private func installPackage(_ context: ActionContext) async throws {
        let package = try await Downloader.fetch(system.homebrewPackageURL, fileName: "Homebrew.pkg", context, system: system)
        defer { Downloader.discard(package, context) }
        if !context.dryRun {
            try await Downloader.verifyPackage(package, displayName: "Homebrew.pkg", teamID: nil, context, system: system)
        }
        try await context.runChecked(Command(system.installer, ["-pkg", package.path, "-target", "/"]).asRoot())
    }

    private func installWithScript(_ context: ActionContext) async throws {
        let script = try await Downloader.fetch(system.homebrewScriptURL, fileName: "homebrew-install.sh", context, system: system)
        defer { Downloader.discard(script, context) }
        // Never as root: install.sh refuses that and asks for rights itself (sudo -A), so it is the one
        // user-level command here that may reach the installer's password helper.
        var environment = await Brew.environment(context)
        environment["NONINTERACTIVE"] = "1"
        let command = Command(system.bash, [script.path]).env(environment).labeled("NONINTERACTIVE=1 bash install.sh").allowingSudo()
        try await context.runChecked(command)
    }
}
