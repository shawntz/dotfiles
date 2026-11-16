import Foundation
import ShawnCore

/// `- rosetta: install` installs Rosetta 2, for the occasional Intel-only tool.
struct RosettaAction: Action {
    let system: MacSystem

    var title: String { "Rosetta 2" }
    var subtitle: String? { "softwareupdate --install-rosetta" }
    var sudo: SudoNeed { .always }

    static func parse(_ parser: ItemParser, system: MacSystem) -> RosettaAction {
        requireInstallValue(parser)
        return RosettaAction(system: system)
    }

    private func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: system.rosettaRuntime.path)
    }

    func check(_ context: ActionContext) async -> CheckResult {
        isInstalled() ? .satisfied("installed") : .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        if !context.dryRun, isInstalled() { return .done("already installed") }
        if let refusal = Common.sandboxRefusal("installing Rosetta", context, system: system) { return refusal }
        try await context.runChecked(Command(system.softwareupdate, ["--install-rosetta", "--agree-to-license"]).asRoot())
        if !context.dryRun, !isInstalled() {
            throw ActionError("softwareupdate finished but Rosetta is still missing",
                              hint: "run 'softwareupdate --install-rosetta' in Terminal to see why")
        }
        return Common.done("installed", context)
    }
}
