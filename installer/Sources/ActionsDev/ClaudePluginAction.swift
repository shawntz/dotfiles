import Foundation
import ShawnCore

/// `claude-plugin:` installs a Claude Code plugin with `claude plugin install`, adding its
/// marketplace first when Claude Code does not know it yet.
struct ClaudePluginAction: Action {
    /// `name@marketplace`.
    let plugin: String
    /// `owner/repo` (or URL) of the marketplace, for adding it when missing.
    let marketplaceSource: String?
    let scope: String

    /// Registered by Claude Code on first interactive launch, which a fresh Mac has not had yet.
    static let officialMarketplace = (name: "claude-plugins-official", source: "anthropics/claude-plugins-official")

    var marketplaceName: String { plugin.split(separator: "@", maxSplits: 1).last.map(String.init) ?? "" }

    var title: String { plugin }
    var subtitle: String? { "Claude Code plugin (\(scope) scope)" }

    static let descriptor = ActionDescriptor(
        kind: "claude-plugin",
        summary: "Installs a Claude Code plugin (`claude plugin install name@marketplace`), adding the marketplace first when needed.",
        example: """
        - claude-plugin: warp@claude-code-warp
          marketplace: warpdotdev/claude-code-warp
        """
    ) { parser in
        let plugin = parser.primaryString()
        if !plugin.isEmpty, plugin.range(of: "^[^@\\s]+@[^@\\s]+$", options: .regularExpression) == nil {
            parser.fail("'claude-plugin' must look like name@marketplace (got '\(plugin)')")
        }
        let marketplace = parser.options.string("marketplace")
        if let marketplace, marketplace.isEmpty || marketplace.contains(where: { $0 == " " || $0 == "\t" }) {
            parser.options.error("'marketplace' must look like owner/repo or a git URL (got '\(marketplace)')", key: "marketplace")
        }
        let scope = parser.options.oneOf("scope", ["user", "project", "local"], default: "user")
        return ClaudePluginAction(plugin: plugin, marketplaceSource: marketplace, scope: scope)
    }

    // MARK: claude CLI

    struct InstalledPlugin: Decodable, Equatable, Sendable {
        let id: String
        let scope: String?
        let enabled: Bool?
    }

    struct Marketplace: Decodable, Equatable, Sendable {
        let name: String
        let repo: String?
        let url: String?
    }

    /// Decodes a JSON array, tolerating chatter before or after it.
    static func decodeArray<T: Decodable>(_ type: T.Type, from text: String) -> [T]? {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode([T].self, from: Data(text.utf8)) { return direct }
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return nil }
        return try? decoder.decode([T].self, from: Data(text[start...end].utf8))
    }

    private func command(_ claude: String, _ arguments: [String], context: ActionContext) -> Command {
        ToolCommand.make(claude, arguments,
                         unset: ToolCommand.agentSessionVariables(context.environment) + GitTool.isolationVariables(context.environment),
                         set: ["CLAUDE_CODE_PLUGIN_PREFER_HTTPS": "1", "DISABLE_AUTOUPDATER": "1"],
                         display: "claude")
    }

    private static let pluginsKey = "dev.claude.plugins"
    private static let marketplacesKey = "dev.claude.marketplaces"

    /// Installed plugins, or nil when `claude plugin list --json` could not be read.
    private func installed(_ claude: String, context: ActionContext, useCache: Bool = true) async -> [InstalledPlugin]? {
        if useCache, let cached = await context.shared.value(Self.pluginsKey, as: [InstalledPlugin].self) { return cached }
        guard let result = try? await context.commands.run(command(claude, ["plugin", "list", "--json"], context: context).timeout(120).readOnly()),
              result.succeeded, let plugins = Self.decodeArray(InstalledPlugin.self, from: result.stdout) else { return nil }
        await context.shared.set(Self.pluginsKey, plugins)
        return plugins
    }

    private func marketplaces(_ claude: String, context: ActionContext) async -> [Marketplace]? {
        if let cached = await context.shared.value(Self.marketplacesKey, as: [Marketplace].self) { return cached }
        let probe = command(claude, ["plugin", "marketplace", "list", "--json"], context: context).timeout(120).readOnly()
        guard let result = try? await context.commands.run(probe), result.succeeded,
              let list = Self.decodeArray(Marketplace.self, from: result.stdout) else { return nil }
        await context.shared.set(Self.marketplacesKey, list)
        return list
    }

    private func entry(in plugins: [InstalledPlugin]) -> InstalledPlugin? {
        plugins.first { $0.id == plugin && ($0.scope ?? "user") == scope }
    }

    static let missingError = ActionError("Claude Code (claude) is not installed",
                                          hint: "Install it with the AI step (it puts claude in ~/.local/bin), then run this again")

    // MARK: Action

    func check(_ context: ActionContext) async -> CheckResult {
        guard let claude = context.environment.resolveExecutable("claude") else { return .needed("Claude Code is not installed yet") }
        guard let plugins = await installed(claude, context: context) else { return .needed("could not read `claude plugin list`") }
        guard let found = entry(in: plugins) else { return .needed("not installed") }
        if found.enabled == false { return .needed("installed but disabled") }
        return .satisfied("installed at \(scope) scope")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        guard let claude = context.environment.resolveExecutable("claude") else {
            if let outcome = DryRun.whenMissing("claude", would: "install the \(plugin) plugin", context) { return outcome }
            throw Self.missingError
        }
        // Marketplaces and git-hosted plugins are cloned with git; never let that hit the /usr/bin/git shim.
        guard GitTool.locate(context.environment) != nil else {
            if let outcome = DryRun.whenMissing("git", would: "install the \(plugin) plugin", context) { return outcome }
            throw GitTool.missingError(for: "claude plugin install")
        }

        if let current = await installed(claude, context: context, useCache: false), let found = entry(in: current) {
            guard found.enabled == false else { return .done("already installed") }
            try await runClaude(claude, ["plugin", "enable", plugin, "--scope", scope, "--json"], action: "enable", context: context)
            return try await verified(claude, context: context, message: "enabled")
        }

        try await ensureMarketplace(claude, context: context)
        try await runClaude(claude, ["plugin", "install", plugin, "--scope", scope, "--json"], action: "install", context: context)
        return try await verified(claude, context: context, message: "installed")
    }

    private func ensureMarketplace(_ claude: String, context: ActionContext) async throws {
        let known = await marketplaces(claude, context: context)
        let isKnown = known?.contains { market in
            market.name == marketplaceName
                || (marketplaceSource.map { source in market.repo?.caseInsensitiveCompare(source) == .orderedSame || market.url == source } ?? false)
        } ?? false
        if isKnown { return }

        let source = marketplaceSource ?? (marketplaceName == Self.officialMarketplace.name ? Self.officialMarketplace.source : nil)
        guard let source else {
            throw ActionError("Claude Code does not know the plugin marketplace '\(marketplaceName)'",
                              hint: "Add 'marketplace: owner/repo' to this item so the installer can add it first")
        }
        try await runClaude(claude, ["plugin", "marketplace", "add", source, "--json"], action: "add marketplace \(source) for", context: context)
        await context.shared.invalidate(Self.marketplacesKey)
    }

    private func runClaude(_ claude: String, _ arguments: [String], action: String, context: ActionContext) async throws {
        let result = try await context.commands.run(command(claude, arguments, context: context).timeout(600),
                                                    hintIfTimedOut: "Check the network connection, then run this again")
        if result.wasDryRun || result.succeeded { return }
        throw ActionError("`claude plugin` could not \(action) \(plugin): \(result.tail(3))",
                          hint: "Check the network, then run this again (`\(Shell.join(["claude"] + arguments.filter { $0 != "--json" }))` shows the full error)")
    }

    /// Confirms with `claude plugin list` that the plugin really is there and enabled.
    private func verified(_ claude: String, context: ActionContext, message: String) async throws -> ActionOutcome {
        if context.dryRun { return .done("would be \(message)") }
        await context.shared.invalidate(Self.pluginsKey)
        guard let plugins = await installed(claude, context: context, useCache: false), let found = entry(in: plugins), found.enabled != false else {
            throw ActionError("claude reported success, but \(plugin) is not enabled in `claude plugin list`",
                              hint: "Run `claude plugin list` to see what happened, then run this again")
        }
        return .done(message)
    }
}
