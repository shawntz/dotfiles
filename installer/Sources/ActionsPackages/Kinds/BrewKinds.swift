import Foundation
import ShawnCore

/// `- tap: user/repo` runs `brew tap`, and `brew trust` when `trusted: true`.
struct TapAction: Action, PackageProviding {
    /// As written, e.g. `nikitabobko/tap`.
    let name: String
    let url: String?
    let trusted: Bool

    var title: String { name }
    var subtitle: String? { [url, trusted ? "trusted" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty }
    var packageRef: PackageRef { PackageRef(manager: .tap, name: name) }

    /// How Homebrew stores the tap: lowercase, without a `homebrew-` repo prefix.
    var normalizedName: String {
        let parts = name.lowercased().split(separator: "/")
        guard parts.count == 2 else { return name.lowercased() }
        let repo = parts[1].hasPrefix("homebrew-") ? parts[1].dropFirst("homebrew-".count) : parts[1]
        return "\(parts[0])/\(repo)"
    }

    static func parse(_ parser: ItemParser) -> TapAction {
        let name = parser.primaryString()
        if !name.isEmpty, name.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil {
            parser.fail("'tap' must look like user/repo (got '\(name)')")
        }
        let url = parser.options.string("url")
        let trusted = parser.options.bool("trusted", default: false)
        return TapAction(name: name, url: url, trusted: trusted)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Common.unknownVariables(context, [("url", url)])
    }

    func check(_ context: ActionContext) async -> CheckResult {
        guard Brew.isInstalled(context) else { return .needed(Brew.notInstalledReason) }
        let tapped = await Brew.installedTaps(context).contains(normalizedName)
        let trustOK = !trusted || Brew.trustedTaps(context).contains(normalizedName)
        switch (tapped, trustOK) {
        case (true, true): return .satisfied(trusted ? "tapped and trusted" : "tapped")
        case (true, false): return .needed("tapped, not trusted yet")
        default: return .needed(nil)
        }
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        try Brew.requireInstalled(context)
        let tapped = await Brew.installedTaps(context).contains(normalizedName)
        if context.dryRun || !tapped {
            try await Brew.run(["tap", name] + (url.map { [context.expand($0)] } ?? []), context)
            await Brew.invalidateInstalledState(context)
        }
        if trusted && (context.dryRun || !Brew.trustedTaps(context).contains(normalizedName)) {
            try await Brew.run(["trust", name], context)
        }
        return Common.done(trusted ? "tapped and trusted" : "tapped", context)
    }
}

/// `- brew: eza` installs a formula; third-party ones are fully qualified (`user/tap/name`).
struct FormulaAction: Action, PackageProviding {
    let name: String
    let args: [String]

    var title: String { Brew.shortName(name) }
    var subtitle: String? {
        let parts: [String?] = [Brew.tapName(of: name), args.isEmpty ? nil : args.joined(separator: " ")]
        return parts.compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
    var packageRef: PackageRef { PackageRef(manager: .formula, name: name) }

    static func parse(_ parser: ItemParser) -> FormulaAction {
        let name = parser.primaryString()
        if !name.isEmpty, !Brew.isValidPackageName(name) {
            parser.fail("'brew' must be a formula name like 'eza', or 'user/tap/name' for a third-party tap (got '\(name)')")
        }
        return FormulaAction(name: name, args: parser.options.stringList("args"))
    }

    func check(_ context: ActionContext) async -> CheckResult {
        guard Brew.isInstalled(context) else { return .needed(Brew.notInstalledReason) }
        return await Brew.installedFormulae(context).contains(Brew.shortName(name)) ? .satisfied("installed") : .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        try Brew.requireInstalled(context)
        try await Brew.run(["install", "--formula", name] + args.map(context.expand), context)
        await Brew.invalidateInstalledState(context)
        return Common.done("installed", context)
    }
}

/// `- cask: dropbox` installs a cask; `app:` lets a copy installed some other way count as installed.
struct CaskAction: Action, PackageProviding {
    let token: String
    let args: [String]
    /// `Dropbox.app` (in `{{applications}}`), or a path.
    let app: String?
    let launch: Bool
    let system: MacSystem

    var title: String { Brew.shortName(token) }
    var subtitle: String? {
        let parts: [String?] = [Brew.tapName(of: token), app, args.isEmpty ? nil : args.joined(separator: " ")]
        return parts.compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
    var sudo: SudoNeed { .maybe }
    var packageRef: PackageRef { PackageRef(manager: .cask, name: token) }

    static func parse(_ parser: ItemParser, system: MacSystem) -> CaskAction {
        let token = parser.primaryString()
        if !token.isEmpty, !Brew.isValidPackageName(token) {
            parser.fail("'cask' must be a cask token like 'ghostty', or 'user/tap/name' for a third-party tap (got '\(token)')")
        }
        let args = parser.options.stringList("args")
        let app = parser.options.string("app").map { $0.contains("/") ? $0 : Common.appBundleName($0) }
        let launch = parser.options.bool("launch", default: false)
        if launch && app == nil {
            parser.options.error("'launch: true' needs 'app:' so the installer knows which app to open", key: "launch")
        }
        return CaskAction(token: token, args: args, app: app, launch: launch, system: system)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Common.unknownVariables(context, [("app", app)])
    }

    func appURL(_ context: ActionContext) -> URL? {
        guard let app else { return nil }
        return app.contains("/") ? context.path(app) : context.environment.applicationsDirectory.appendingPathComponent(context.expand(app))
    }

    func check(_ context: ActionContext) async -> CheckResult {
        let brewInstalled = Brew.isInstalled(context)
        if brewInstalled, await Brew.installedCasks(context).contains(Brew.shortName(token)) {
            return .satisfied("installed")
        }
        if let appURL = appURL(context), context.files.exists(appURL) {
            return .satisfied("\(appURL.lastPathComponent) is already in \(context.display(appURL.deletingLastPathComponent())), installed without Homebrew")
        }
        return brewInstalled ? .needed(nil) : .needed(Brew.notInstalledReason)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        try Brew.requireInstalled(context)
        if !context.dryRun, let appURL = appURL(context), context.files.exists(appURL) {
            return .done("\(appURL.lastPathComponent) is already installed")
        }
        // Homebrew runs a cask's .pkg installer (and anything it must write outside the user's reach) with sudo itself.
        try await Brew.run(["install", "--cask", token] + args.map(context.expand), allowingSudo: true, context)
        await Brew.invalidateInstalledState(context)

        if let appURL = appURL(context), !context.dryRun, !context.files.exists(appURL) {
            context.warn("Homebrew finished, but \(context.display(appURL)) is not there. Check 'app:' on this item.")
            return .done("installed")
        }
        if launch, let appURL = appURL(context) {
            try await Common.open(["-g", "-a", appURL.path], context, system: system)
        }
        return Common.done(launch ? "installed and opened" : "installed", context)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
