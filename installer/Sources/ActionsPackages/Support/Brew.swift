import Foundation
import ShawnCore

/// Everything the package kinds share about running Homebrew.
enum Brew {
    /// Switches every brew call gets (all valid in Homebrew 7; none of the disabled ones, which abort brew).
    /// `CI=1` makes brew's Ruby flush stdout line by line instead of in blocks when it is not a terminal.
    static let standardEnvironment: [String: String] = [
        "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_ASK": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_UPDATE_REPORT_NEW": "1",
        "HOMEBREW_NO_EMOJI": "1",
        "HOMEBREW_NO_COLOR": "1",
        "CI": "1",
    ]

    static let notInstalledReason = "Homebrew is not installed yet"

    private enum Key {
        static let updated = "pkg.brew.updated"
        static let statePrefix = "pkg.brew.state."
        static let formulae = statePrefix + "formulae"
        static let casks = statePrefix + "casks"
        static let taps = statePrefix + "taps"
    }

    // MARK: Executable

    static func isInstalled(_ context: ActionContext) -> Bool {
        FileManager.default.isExecutableFile(atPath: context.environment.brewExecutable)
    }

    /// Fails the item when brew is missing. Dry runs narrate anyway, so they skip this.
    static func requireInstalled(_ context: ActionContext) throws {
        guard context.dryRun || isInstalled(context) else {
            throw ActionError("Homebrew is not installed",
                              hint: "the Homebrew step (homebrew: install) has to succeed first. Fix that, then run the installer again")
        }
    }

    // MARK: Environment

    static func environment(_ context: ActionContext) async -> [String: String] {
        var environment = standardEnvironment
        // Only after one successful `brew update` this run: skipping it before then can break freshly added taps.
        if await hasUpdated(context) { environment["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        return environment
    }

    static func hasUpdated(_ context: ActionContext) async -> Bool {
        await context.shared.value(Key.updated, as: Bool.self) ?? false
    }

    static func markUpdated(_ context: ActionContext) async {
        await context.shared.set(Key.updated, true)
    }

    /// A brew command. `allowingSudo` is only for commands that can make Homebrew call sudo itself (a cask's
    /// .pkg installer, files outside the user's reach); everything else is not told where the password helper is.
    static func command(_ arguments: [String], allowingSudo: Bool = false, _ context: ActionContext) async -> Command {
        Command(context.environment.brewExecutable, arguments).env(await environment(context)).allowingSudo(allowingSudo)
    }

    /// Runs brew and turns a failure into an error that says what to do about it.
    @discardableResult
    static func run(_ arguments: [String], allowingSudo: Bool = false, _ context: ActionContext) async throws -> CommandResult {
        let command = await command(arguments, allowingSudo: allowingSudo, context)
        let result = try await context.run(command)
        guard result.succeeded else {
            let tail = result.tail()
            let message = tail.isEmpty ? "\(command.displayString) failed (exit \(result.exitCode))"
                                       : "\(command.displayString) failed (exit \(result.exitCode)): \(tail)"
            throw ActionError(message, hint: hint(forFailureOutput: result.stdout + "\n" + result.stderr))
        }
        return result
    }

    static func hint(forFailureOutput output: String) -> String {
        let text = output.lowercased()
        // brew.sh refuses every command while the active developer directory is an Xcode with an unaccepted license.
        if text.contains("agreed to the xcode license") {
            return "the Xcode license has not been accepted yet. Run 'sudo xcodebuild -license accept' in Terminal (or let 'xcode: finish' do it), then run the installer again"
        }
        if text.contains("untrusted tap") || text.contains("refusing to load") {
            return "Homebrew only loads third-party taps you trust. Write the fully qualified name (user/tap/name), or add 'trusted: true' to that tap's item"
        }
        if text.contains("already an app at") {
            return "that app is already installed outside Homebrew. Add 'app: <Name>.app' to this item so the existing copy counts as installed, or 'args: [--adopt]' to let Homebrew take it over"
        }
        if text.contains("no available formula") || text.contains("no available cask") || text.contains("no formulae or casks found")
            || text.contains("is unavailable") {
            return "check the name with 'brew search'; formulae and casks from a third-party tap need that tap first and their fully qualified name"
        }
        if text.contains("a terminal is required to read the password") || text.contains("password is required") {
            return "this one needs administrator rights. Run the installer again and enter your password when asked"
        }
        if text.contains("could not resolve host") || text.contains("failed to connect") || text.contains("timed out") {
            return "the network looks unreachable. Check the connection and run the installer again"
        }
        return "Homebrew's own output is in the log above; fix what it says, then run the installer again"
    }

    // MARK: Installed state (filesystem probes, cached for the run)

    /// Formula racks under `<prefix>/Cellar` that hold at least one installed version.
    static func installedFormulae(_ context: ActionContext) async -> Set<String> {
        let cellar = context.environment.brewPrefix.appendingPathComponent("Cellar")
        return await context.shared.cached(Key.formulae) { populatedChildren(of: cellar) }
    }

    /// Casks under `<prefix>/Caskroom` that hold at least one installed version.
    static func installedCasks(_ context: ActionContext) async -> Set<String> {
        let caskroom = context.environment.brewPrefix.appendingPathComponent("Caskroom")
        return await context.shared.cached(Key.casks) { populatedChildren(of: caskroom) }
    }

    /// Taps as lowercase `user/repo`, from `<prefix>/Library/Taps/<user>/homebrew-<repo>`.
    static func installedTaps(_ context: ActionContext) async -> Set<String> {
        let taps = context.environment.brewPrefix.appendingPathComponent("Library/Taps")
        return await context.shared.cached(Key.taps) {
            var result = Set<String>()
            let fileManager = FileManager.default
            for user in (try? fileManager.contentsOfDirectory(atPath: taps.path)) ?? [] where !user.hasPrefix(".") {
                let userDirectory = taps.appendingPathComponent(user)
                for repo in (try? fileManager.contentsOfDirectory(atPath: userDirectory.path)) ?? [] where repo.hasPrefix("homebrew-") {
                    result.insert("\(user)/\(repo.dropFirst("homebrew-".count))".lowercased())
                }
            }
            return result
        }
    }

    /// Call after anything that installs, removes or taps.
    static func invalidateInstalledState(_ context: ActionContext) async {
        await context.shared.invalidate(prefix: Key.statePrefix)
    }

    private static func populatedChildren(of directory: URL) -> Set<String> {
        let fileManager = FileManager.default
        var result = Set<String>()
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where !name.hasPrefix(".") {
            let versions = (try? fileManager.contentsOfDirectory(atPath: directory.appendingPathComponent(name).path)) ?? []
            if versions.contains(where: { !$0.hasPrefix(".") }) { result.insert(name) }
        }
        return result
    }

    // MARK: Tap trust

    /// The taps Homebrew trusts, read from its trust store (`$XDG_CONFIG_HOME/homebrew/trust.json`, else `~/.homebrew/trust.json`).
    static func trustedTaps(_ context: ActionContext) -> Set<String> {
        let store: URL
        if let xdg = context.environment.baseEnvironment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            store = URL(fileURLWithPath: xdg).appendingPathComponent("homebrew/trust.json")
        } else {
            store = context.environment.home.appendingPathComponent(".homebrew/trust.json")
        }
        guard let data = FileManager.default.contents(atPath: store.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taps = object["trustedtaps"] as? [String] else { return [] }
        return Set(taps.map { $0.lowercased() })
    }

    // MARK: Names

    /// `aerospace` for `nikitabobko/tap/aerospace`.
    static func shortName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// `nikitabobko/tap` for `nikitabobko/tap/aerospace`; nil for a plain name.
    static func tapName(of name: String) -> String? {
        let parts = name.split(separator: "/")
        return parts.count == 3 ? "\(parts[0])/\(parts[1])" : nil
    }

    /// True for `eza` and `user/tap/name`; formula and cask names never contain spaces.
    static func isValidPackageName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "@+-_.".unicodeScalars.contains($0) }
        }
    }
}
