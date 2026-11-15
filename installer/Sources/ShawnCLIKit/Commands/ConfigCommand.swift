import Foundation
import ShawnCore
import ShawnFun
import ShawnSync

struct ConfigCommand: BuiltinCommand {
    let name = "config"
    let section = BuiltinSection.config
    let summary = "Where the config is, what it plans, and whether it is valid"
    let usage = "[path | show | validate [DIR] | kinds | answers | edit | brewfile]"
    let subcommands: [(name: String, summary: String)] = [
        ("path", "Where the config comes from (the default)"),
        ("show", "Every step and item the installer would run"),
        ("validate", "Check the config (or DIR) and list every problem; exit 1 if any"),
        ("kinds", "Every item kind with its summary and an example"),
        ("answers", "The config's questions and the answers saved on this Mac (read-only)"),
        ("edit", "Open the config directory in $EDITOR"),
        ("brewfile", "A Brewfile generated from the config's packages"),
    ]

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        let action = parsed.positionals.first ?? "path"
        switch action {
        case "path": return path(context)
        case "show": return show(context)
        case "validate": return validate(parsed.positionals.dropFirst().first, context: context)
        case "kinds": return kinds(context)
        case "answers": return answers(context)
        case "edit": return edit(context)
        case "brewfile": return brewfile(context)
        default:
            let hint = Suggest.closest(to: action, in: subcommands.map(\.name)).map { ". Did you mean '\($0)'?" } ?? ""
            context.fail("shawn config: unknown action '\(action)'\(hint)")
            context.err.line("usage: shawn config \(usage)")
            return ExitCode.usage
        }
    }

    private func path(_ context: CLIContext) -> Int32 {
        let style = context.style
        guard let place = context.configLocation() else {
            context.fail("no config found; looked in:")
            for candidate in ConfigLocator.candidates(explicit: context.globals.configPath, environment: context.environment, bundle: context.bundle, currentDirectory: context.currentDirectory) {
                context.err.line("  " + context.display(candidate.url))
            }
            return ExitCode.failure
        }
        context.out.line(place.url.path)
        let source: String
        if place.source == .bundled {
            source = "bundled with the app"
        } else if let checkout = context.checkout, place.url.path.hasPrefix(checkout.path + "/") {
            source = "your checkout (\(context.display(checkout)))"
        } else if place.url.path.hasPrefix(context.environment.cacheDirectory.path) {
            source = "fetched from GitHub"
        } else {
            source = "local copy"
        }
        context.err.line(style.muted("  \(source) · cli.yaml: \(FileManager.default.fileExists(atPath: place.url.appendingPathComponent(CLIConfig.fileName).path) ? "yes" : "none")"))
        return ExitCode.ok
    }

    private func show(_ context: CLIContext) -> Int32 {
        let style = context.style
        switch PlanLoader.local(context: context) {
        case .failure(let error):
            context.fail(error.description)
            return ExitCode.failure
        case .success(let resolved):
            let plan = resolved.plan
            let kindWidth = (plan.allItems.map { $0.config.kind.count }.max() ?? 0) + 2
            context.out.line(style.heading(resolved.config.meta.name) + style.muted(" · \(resolved.config.source)"))
            for step in plan.steps {
                context.out.line("")
                let off = step.config.enabledByDefault ? "" : style.muted(" (off by default)")
                context.out.line(style.heading("\(step.id)") + "  \(step.config.title)" + off + style.muted("  \(step.config.file)"))
                for item in step.items {
                    var line = "  " + style.accent(TextWidth.pad(item.config.kind, to: kindWidth)) + item.title
                    if let subtitle = item.subtitle { line += style.muted("  \(subtitle)") }
                    if item.config.optional { line += style.warn("  optional") }
                    if let note = item.config.note { line += style.muted("  \(note)") }
                    context.out.line(line)
                }
            }
            for warning in plan.warnings { context.warn(warning.description) }
            return ExitCode.ok
        }
    }

    /// Every problem in the config, the CLI file and the fun files. Used by CI.
    private func validate(_ directory: String?, context: CLIContext) -> Int32 {
        let style = context.style
        let root: URL
        if let directory {
            root = URL(fileURLWithPath: PathExpansion.expandTilde(directory, home: context.environment.home)).standardizedFileURL
        } else if let place = context.configLocation() {
            root = place.url
        } else {
            context.fail("no config found (pass the directory: shawn config validate DIR)")
            return ExitCode.failure
        }
        var issues: [ConfigIssue] = []
        var config: InstallerConfig?
        do {
            let loaded = try ConfigLoader.load(from: root)
            issues += loaded.warnings
            let plan = InstallPlan.build(config: loaded.config, registry: context.registry, environment: context.environment)
            issues += plan.issues
            config = loaded.config
        } catch let error as ConfigError {
            issues += error.issues
        } catch {
            issues.append(.error(String(describing: error)))
        }
        let light = config ?? LightConfig.load(ConfigPlace(url: root, source: .local(root.path)))
        let (cli, cliIssues) = CLIConfig.load(from: light)
        issues += cliIssues
        issues += cli.validate(config: light, registry: context.registry, builtinNames: Builtins.names,
                               vars: ActionContext.makeVars(config: light, environment: context.environment))
        if let config { issues += FunConfig.load(from: config).issues }

        let errors = issues.filter { $0.severity == .error }
        let warnings = issues.filter { $0.severity == .warning }
        for issue in errors { context.out.line(style.bad("✗ ") + issue.description) }
        for issue in warnings { context.out.line(style.warn("! ") + issue.description) }
        if errors.isEmpty {
            context.out.line(style.ok("✓") + " \(context.display(root)) is valid" + (warnings.isEmpty ? "" : " (\(warnings.count) warning\(warnings.count == 1 ? "" : "s"))"))
            return ExitCode.ok
        }
        context.out.line(style.bad("\(errors.count) problem\(errors.count == 1 ? "" : "s")") + " in \(context.display(root))")
        return ExitCode.failure
    }

    private func kinds(_ context: CLIContext) -> Int32 {
        let style = context.style
        let kinds = context.registry.kinds
        if kinds.isEmpty {
            context.out.line(style.muted("this build has no item kinds registered"))
            return ExitCode.ok
        }
        for kind in kinds {
            guard let descriptor = context.registry.descriptor(for: kind) else { continue }
            context.out.line(style.heading(kind) + "  " + descriptor.summary)
            for line in descriptor.example.trimmingCharacters(in: .newlines).components(separatedBy: "\n") {
                context.out.line("    " + style.accent(line))
            }
            context.out.line("")
        }
        return ExitCode.ok
    }

    /// Each question with its saved answer, and where the answers file is. Reads only; asks nothing.
    private func answers(_ context: CLIContext) -> Int32 {
        let style = context.style
        guard let config = context.lightConfig() else {
            context.fail("no config found")
            return ExitCode.failure
        }
        let store = AnswerStore(environment: context.environment)
        context.out.line(style.heading("Answers") + style.muted(" · \(context.display(store.url))"))
        if store.load() == .unreadable {
            context.warn("\(context.display(store.url)) is not a JSON object of text values, so it counts as empty. "
                         + "The next answer saved replaces it, and the old copy goes to the backups folder.")
        }
        let questions = config.meta.ask
        guard !questions.isEmpty else {
            context.out.line(style.muted("  This config asks no questions."))
            return ExitCode.ok
        }
        let saved = store.saved
        let valid = store.answers(for: questions)
        let installAsks = context.questionsInstallAsks()
        let nameWidth = (questions.map { $0.name.count }.max() ?? 0) + 2
        let answerWidth = (questions.map { TextWidth.of(valid[$0.name] ?? Self.notAnswered) }.max() ?? 0) + 2
        for question in questions {
            let answer = valid[question.name].map { TextWidth.pad($0, to: answerWidth) } ?? style.muted(TextWidth.pad(Self.notAnswered, to: answerWidth))
            context.out.line("  " + style.accent(TextWidth.pad(question.name, to: nameWidth)) + answer + style.muted(question.prompt))
            // In quotes, with any escape code shown as text rather than sent to the terminal.
            if valid[question.name] == nil, let rejected = saved[question.name], let problem = question.format.problem(with: rejected) {
                context.out.line("  " + String(repeating: " ", count: nameWidth) + style.warn("The saved answer, \(rejected.debugDescription), does not count. \(problem)"))
            }
            if let installAsks, !installAsks.contains(question.name) {
                context.out.line("  " + String(repeating: " ", count: nameWidth)
                                 + style.muted("'shawn install' does not ask it, because nothing it runs by default uses it."))
            }
        }
        let installAsksAny = installAsks.map { asked in questions.contains { asked.contains($0.name) } } ?? true
        context.out.line(style.muted(installAsksAny ? "Ask again with 'shawn install --ask', or edit the file." : "Edit the file to change an answer."))
        return ExitCode.ok
    }

    private static let notAnswered = "not answered yet"

    private func edit(_ context: CLIContext) -> Int32 {
        guard let place = context.configLocation() else {
            context.fail("no config found")
            return ExitCode.failure
        }
        let editor = context.environment.baseEnvironment["VISUAL"] ?? context.environment.baseEnvironment["EDITOR"] ?? "vi"
        // $EDITOR may carry arguments ("code -w"), so let the shell split it; the path is passed as $1.
        let request = ExecRequest(path: "/bin/sh", argv: ["sh", "-c", "exec \(editor) \"$1\"", "shawn", place.url.path], environment: context.childEnvironment())
        if case .failed(let code) = context.services.replacer.replace(request) {
            context.fail("could not start \(editor): \(String(cString: strerror(code)))")
            return ExitCode.cannotExecute
        }
        return ExitCode.ok
    }

    /// A Brewfile from the packages the config declares (optional ones commented as such).
    private func brewfile(_ context: CLIContext) -> Int32 {
        switch PlanLoader.local(context: context) {
        case .failure(let error):
            context.fail(error.description)
            return ExitCode.failure
        case .success(let resolved):
            for line in Self.brewfile(plan: resolved.plan, name: resolved.config.meta.name) { context.out.line(line) }
            return ExitCode.ok
        }
    }

    static func brewfile(plan: InstallPlan, name: String) -> [String] {
        var sections: [PackageRef.Manager: [String]] = [:]
        for item in plan.allItems {
            guard let ref = (item.action as? any PackageProviding)?.packageRef else { continue }
            let note = item.config.optional ? "  # optional" : ""
            let line: String
            switch ref.manager {
            case .tap: line = "tap \"\(ref.name)\""
            case .formula: line = "brew \"\(ref.name)\""
            case .cask: line = "cask \"\(ref.name)\""
            case .mas: line = "mas \"\(ref.label ?? ref.name)\", id: \(ref.name)"
            case .npm: line = "npm \"\(ref.name)\""
            }
            sections[ref.manager, default: []].append(line + note)
        }
        var lines = ["# Brewfile generated from \(name) by `shawn config brewfile`.", "# Install with: brew bundle --file=<this file>"]
        for manager in [PackageRef.Manager.tap, .formula, .cask, .mas, .npm] {
            guard let entries = sections[manager] else { continue }
            lines.append("")
            lines += entries
        }
        return lines
    }
}

struct UpgradeCommand: BuiltinCommand {
    let name = "upgrade"
    let section = BuiltinSection.setup
    let summary = "Upgrade everything (Homebrew, App Store, AI CLIs, skills, …)"
    let usage = "[name …] [--list]"
    let details: String? = "Runs each entry under upgrade: in cli.yaml in your terminal and reports how each went. Name entries to run only those."
    let options = [OptionSpec("list", "Show the entries without running them")]

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        let style = context.style
        let steps = context.cli.upgrade
        guard !steps.isEmpty else {
            context.out.line(style.muted("nothing to upgrade: cli.yaml has no upgrade: entries"))
            return ExitCode.ok
        }
        if parsed.has("list") {
            for step in steps {
                context.out.line(style.accent(TextWidth.pad(step.name, to: 18)) + step.run.components(separatedBy: "\n").first!)
            }
            return ExitCode.ok
        }
        let wanted = parsed.positionals.map { $0.lowercased() }
        for name in wanted where !steps.contains(where: { $0.name.lowercased() == name }) {
            let hint = Suggest.closest(to: name, in: steps.map { $0.name.lowercased() }).map { ". Did you mean '\($0)'?" } ?? ""
            context.fail("shawn upgrade: no entry named '\(name)'\(hint)")
            return ExitCode.usage
        }
        let selected = wanted.isEmpty ? steps : steps.filter { wanted.contains($0.name.lowercased()) }
        let environment = context.childEnvironment()
        var results: [(String, String)] = []
        var failures = 0
        for step in selected {
            if let condition = step.condition {
                let check = await context.launcher.capture(ProcessRequest("/bin/bash", ["-c", condition], environment: environment, timeout: 30))
                if !check.succeeded {
                    results.append((step.name, style.muted("↷ skipped (not installed here)")))
                    continue
                }
            }
            context.out.line("")
            context.out.line(style.heading("▶ \(step.name)") + style.muted("  \(step.run.components(separatedBy: "\n").first!)"))
            let status = await context.launcher.interactive(ProcessRequest("/bin/bash", ["-c", step.run], environment: environment))
            if status == ExitCode.interrupted {
                results.append((step.name, style.warn("■ interrupted")))
                failures += 1
                break
            }
            if status == 0 {
                results.append((step.name, style.ok("✓ done")))
            } else {
                results.append((step.name, style.bad("✗ failed (exit \(status))")))
                failures += 1
            }
        }
        context.out.line("")
        context.out.line(style.heading("== Upgrade summary =="))
        let width = (results.map { $0.0.count }.max() ?? 0) + 2
        for (name, outcome) in results { context.out.line("  " + TextWidth.pad(name, to: width) + outcome) }
        return failures == 0 ? ExitCode.ok : ExitCode.failure
    }
}

struct LSPCommand: BuiltinCommand {
    let name = "lsp"
    let section = BuiltinSection.fun
    let summary = "Lumpy Space Princess has something to say"

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard parsed != nil else { return code }
        let fun = context.fun
        let moments: [Moment] = [.idle, .launch, .success, .waiting]
        let seed = Int.random(in: 0..<10_000)
        let quip = fun.line(for: moments[seed % moments.count], seed: seed / 7)
        context.out.line("")
        for line in Painter.speaking(fun.sprite(fun.speaker), says: quip, style: context.style, width: context.terminal.width) {
            context.out.line(line)
        }
        context.out.line("")
        return ExitCode.ok
    }
}

struct QuoteCommand: BuiltinCommand {
    let name = "quote"
    let section = BuiltinSection.fun
    let summary = "A random line from the show (or a quip)"

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard parsed != nil else { return code }
        let fun = context.fun
        let style = context.style
        if let quote = fun.showQuotes.randomElement() {
            context.out.line(style.fg(Palette.star, "\"\(quote.text)\""))
            context.out.line(style.muted("  \(fun.sprite(fun.speaker)?.name ?? "LSP")" + (quote.episode.map { ", \"\($0)\"" } ?? "")))
        } else {
            context.out.line(style.fg(Palette.star, "\"\(fun.line(for: .idle, seed: Int.random(in: 0..<10_000)))\""))
        }
        if let about = fun.about { context.out.line(style.muted("  " + about)) }
        return ExitCode.ok
    }
}

struct PartyCommand: BuiltinCommand {
    let name = "party"
    let section = BuiltinSection.fun
    let summary = "Everybody on screen at once"

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard parsed != nil else { return code }
        let fun = context.fun
        let sprites = fun.sprites.values.sorted { lhs, rhs in
            // The speaker hosts the party.
            if lhs.id == fun.speaker { return true }
            if rhs.id == fun.speaker { return false }
            return lhs.id < rhs.id
        }
        guard !sprites.isEmpty else {
            context.out.line(context.style.muted("No sprites in this config (fun/sprites/). It's a very small party."))
            return ExitCode.ok
        }
        context.out.line("")
        for line in Painter.lineUp(sprites, style: context.style, width: context.terminal.width) { context.out.line(line) }
        context.out.line("  " + context.style.fg(Palette.star, "\"\(fun.line(for: .finished, seed: Int.random(in: 0..<10_000)))\""))
        if let about = fun.about { context.out.line(context.style.muted("  " + about)) }
        return ExitCode.ok
    }
}

struct BannerCommand: BuiltinCommand {
    let name = "banner"
    let section = BuiltinSection.fun
    let summary = "The ASCII header"

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard parsed != nil else { return code }
        for line in Painter.banner(context.fun.header, style: context.style, width: context.terminal.width, tagline: context.lightConfig()?.meta.tagline) {
            context.out.line(line)
        }
        return ExitCode.ok
    }
}
