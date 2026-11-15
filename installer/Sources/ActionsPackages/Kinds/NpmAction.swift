import Foundation
import ShawnCore

/// `- npm: ghostty-config-cli` installs a global npm package.
struct NpmAction: Action, PackageProviding {
    let package: String

    var title: String { package }
    var subtitle: String? { "npm install -g \(package)" }
    var packageRef: PackageRef { PackageRef(manager: .npm, name: package) }

    /// Keeps npm quiet and from asking anything.
    static let environment = [
        "npm_config_fund": "false",
        "npm_config_audit": "false",
        "npm_config_update_notifier": "false",
        "npm_config_yes": "true",
    ]

    static func parse(_ parser: ItemParser) -> NpmAction {
        let package = parser.primaryString()
        if package.contains(where: \.isWhitespace) {
            parser.fail("'npm' must be one package name (got '\(package)')")
        }
        return NpmAction(package: package)
    }

    func check(_ context: ActionContext) async -> CheckResult {
        guard let npm = context.environment.resolveExecutable("npm") else { return .needed("npm is not installed yet") }
        let probe = Command(npm, ["ls", "-g", "--depth=0", package]).env(Self.environment).readOnly().timeout(60)
        do {
            return try await context.run(probe).succeeded ? .satisfied("installed") : .needed(nil)
        } catch {
            return .needed("could not ask npm: \(Common.describe(error))")
        }
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let npm = context.environment.resolveExecutable("npm")
        guard npm != nil || context.dryRun else {
            throw ActionError("npm is not installed", hint: "add '- brew: node' to a step before this item")
        }
        // A global install changes npm's own prefix; in a sandbox run only an npm inside the sandbox may do that.
        if let npm, !context.dryRun, context.environment.isSandbox,
           ![context.environment.brewPrefix, context.environment.home].contains(where: { npm.hasPrefix($0.path + "/") }) {
            context.warn("Sandbox run: not running \(npm) install -g, because that npm lives outside the sandbox.")
            return .skipped("sandbox run: npm is outside the sandbox")
        }
        try await context.runChecked(Command(npm ?? "npm", ["install", "-g", package]).env(Self.environment))
        return Common.done("installed", context)
    }
}
