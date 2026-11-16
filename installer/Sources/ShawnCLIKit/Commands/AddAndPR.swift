import Foundation
import ShawnCore
import ShawnFun
import ShawnSync

/// Branch, commit, push, `gh pr create`, then back to where the user was. Every step is printed.
///
/// Whatever fails, the checkout ends up on the branch it started on (so the self-update and the next
/// `--pr` work from there) and the last line says exactly where the change is: still uncommitted when
/// nothing could be sent, or on the pushed branch when only the pull request itself is missing.
struct PullRequestFlow {
    let repo: GitRepo
    let context: CLIContext

    struct Plan {
        var branchBase: String
        /// Paths (relative to the repo) to stage and commit.
        var paths: [String]
        var title: String
        var body: String
    }

    /// Refuses when anything outside `paths` is staged: the commit must contain only the config change.
    func unrelatedStagedFiles(allowed paths: [String]) async -> [String] {
        await repo.stagedFiles().filter { file in !paths.contains { file == $0 || file.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
    }

    func open(_ plan: Plan) async -> Int32 {
        let style = context.style
        guard let original = await repo.currentBranch() else {
            context.fail("the checkout is on a detached HEAD; switch to a branch first")
            return ExitCode.failure
        }
        guard let gh = ToolLocator.find("gh", environment: context.environment) else {
            context.fail("gh (the GitHub CLI) is not installed; it is needed to open the pull request")
            return ExitCode.unavailable
        }
        var branch = plan.branchBase
        var suffix = 2
        while await repo.run(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"]).succeeded {
            branch = "\(plan.branchBase)-\(suffix)"
            suffix += 1
        }
        let remote = await repo.remoteName(for: original)
        let files = plan.paths.joined(separator: " ")

        func step(_ arguments: [String], _ done: String, timeout: TimeInterval = 60) async -> Bool {
            let result = await repo.run(arguments, timeout: timeout)
            if result.succeeded {
                context.out.line(style.ok("✓") + " " + done)
                return true
            }
            context.fail("git \(arguments.joined(separator: " ")) failed: \(result.tail(2))")
            return false
        }

        guard await step(["switch", "-c", branch], "created branch \(branch)") else { return ExitCode.failure }

        guard await step(["add", "--"] + plan.paths, "staged " + plan.paths.joined(separator: ", ")),
              await step(["commit", "-q", "-m", plan.title, "--"] + plan.paths, "committed: \(plan.title)") else {
            guard await switchBack(to: original, from: branch) else {
                context.err.line("Nothing was committed; the change is still in the working tree.")
                return ExitCode.failure
            }
            // The branch has no commit of its own; `-d` (not -D) keeps it should that ever not hold.
            let removed = await repo.run(["branch", "-d", branch]).succeeded
            context.err.line("Back on \(original); nothing was committed and the change is still in your working tree"
                             + (removed ? "." : " (the empty branch \(branch) is left over: git branch -d \(branch))."))
            return ExitCode.failure
        }

        guard await step(["push", "-q", "-u", remote, branch], "pushed \(branch) to \(remote)", timeout: 120) else {
            guard await switchBack(to: original, from: branch) else {
                context.err.line("The change is committed on \(branch), not pushed. Push it with: git push -u \(remote) \(branch)")
                return ExitCode.failure
            }
            // Nothing left the Mac: put the change back the way it was (uncommitted) so 'shawn pr' can send it later.
            let restored = await repo.run(["restore", "--source=\(branch)", "--worktree", "--"] + plan.paths)
            guard restored.succeeded else {
                context.err.line("Back on \(original). The change is committed on \(branch), not pushed. Push it with "
                                 + "git push -u \(remote) \(branch), or bring it back with git restore --source=\(branch) --worktree -- \(files)")
                return ExitCode.failure
            }
            let removed = await repo.run(["branch", "-D", branch]).succeeded
            context.err.line("Nothing was sent. Back on \(original) with the change uncommitted, as before (\(files)); "
                             + "send it with 'shawn pr' once \(remote) can be reached."
                             + (removed ? "" : " The unpushed branch \(branch) is still there: git branch -D \(branch)"))
            return ExitCode.failure
        }

        let created = await context.launcher.capture(ProcessRequest(gh, ["pr", "create", "--title", plan.title, "--body", plan.body, "--base", original, "--head", branch],
                                                                    environment: context.childEnvironment(), currentDirectory: repo.root, timeout: 120))
        if created.succeeded {
            let url = created.lines.last { $0.hasPrefix("https://") } ?? created.output
            context.out.line(style.ok("✓") + " pull request: " + style.accent(url))
        } else {
            context.fail("gh pr create failed: \(created.tail(2))")
        }
        let home = await switchBack(to: original, from: branch)
        if created.succeeded {
            if home { context.out.line(style.muted("back on \(original); the change lives on \(branch) until the pull request is merged")) }
            return ExitCode.ok
        }
        context.err.line((home ? "Back on \(original). " : "") + "The change is on \(branch), pushed to \(remote); "
                         + "open the pull request with: gh pr create --base \(original) --head \(branch)")
        return ExitCode.failure
    }

    /// Back to the branch the user started on; when git refuses, says where the checkout is and how to get back.
    private func switchBack(to original: String, from branch: String) async -> Bool {
        let result = await repo.run(["switch", "-q", original])
        if result.succeeded { return true }
        context.fail("could not switch back to \(original): \(result.tail(2))")
        context.err.line("The checkout is still on \(branch); go back with: git switch \(original)")
        return false
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }
}

struct AddCommand: BuiltinCommand {
    let name = "add"
    let section = BuiltinSection.config
    let summary = "Install something now and add it to the config"
    let usage = "<kind> <name> [--option value …] [--no-install] [--pr] [--dry-run] [--repo PATH]"
    let details: String? = """
    Installs it through the same item kinds the installer uses, then adds its line to the step file named for \
    that kind under add: in cli.yaml (next to the items of the same kind, in alphabetical order when they are), \
    keeping comments and formatting. When any step file already declares it, nothing is added. \
    Item options go after the name: shawn add mas 937984704 --name Amphetamine, shawn add webapp Carbon \
    --url https://my.carbonapp.co. A cask gets its app: from Homebrew when the step file's casks name their apps. \
    --pr also creates a branch, commits only that file, pushes and opens a pull request.
    """
    let options = [
        OptionSpec("no-install", "Only add the line; do not install now"),
        OptionSpec("pr", "Open a pull request with the change"),
        OptionSpec("dry-run", short: "n", "Show what would happen; change nothing"),
        OptionSpec("repo", value: "PATH", "Use this checkout instead of the one in ~/.config/shawn/config.yaml"),
    ]

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context, keepUnknown: true)
        guard let parsed else { return code }
        let style = context.style
        let dryRun = parsed.has("dry-run")

        let checkout = parsed.value("repo").map { URL(fileURLWithPath: PathExpansion.expandTilde($0, home: context.environment.home)).standardizedFileURL } ?? context.checkout
        guard let checkout, FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) else {
            context.fail("shawn add: needs a checkout of the dotfiles (the installer clones one), or --repo PATH")
            return ExitCode.usage
        }
        let configPath = context.settings.configPath
        let configRoot = checkout.appendingPathComponent(configPath)
        guard ConfigLoader.isConfigDirectory(configRoot) else {
            context.fail("shawn add: \(context.display(configRoot)) is not a config directory")
            return ExitCode.failure
        }
        let config = LightConfig.load(ConfigPlace(url: configRoot, source: .local(configRoot.path)))
        let (cli, _) = CLIConfig.load(from: config)
        let addable = cli.add.map(\.kind).filter { context.registry.descriptor(for: $0) != nil }

        guard parsed.positionals.count == 2 else {
            context.fail("shawn add: needs a kind and a name, e.g. shawn add \(addable.first ?? "<kind>") <name>")
            context.err.line("kinds you can add: " + (addable.isEmpty ? "none (add an add: section to cli.yaml)" : addable.joined(separator: ", ")))
            return ExitCode.usage
        }
        let kind = parsed.positionals[0], name = parsed.positionals[1]
        guard addable.contains(kind), let target = cli.addTarget(for: kind) else {
            let hint = Suggest.closest(to: kind, in: addable).map { ". Did you mean '\($0)'?" } ?? ""
            context.fail("shawn add: can't add '\(kind)'\(hint) (kinds you can add: \(addable.joined(separator: ", ")))")
            return ExitCode.usage
        }
        let file = configRoot.appendingPathComponent(target.file)
        guard let fileText = try? String(contentsOf: file, encoding: .utf8) else {
            context.fail("shawn add: \(target.file) (from add: in cli.yaml) does not exist or cannot be read")
            return ExitCode.failure
        }

        // The item exactly as it will appear in the YAML, validated by its kind.
        var options: [ConfigEditor.Option] = parsed.extra.map { (key: $0.name.replacingOccurrences(of: "-", with: "_"), value: Self.scalarValue($0.value ?? "true")) }
        var entries = [YAMLMap.Entry(key: kind, value: Self.scalarValue(name))] + options.map { YAMLMap.Entry(key: $0.key, value: $0.value) }
        var raw = RawItem(map: YAMLMap(entries), source: SourceRef(file: target.file))
        let action: any Action
        switch context.registry.resolve(raw, stepID: "add", index: 0) {
        case .failure(let error):
            for issue in error.issues { context.fail(issue.message) }
            return ExitCode.usage
        case .success(let resolved):
            action = resolved.action
        }

        // Already declared in any step file (not only the one it would go to)? Then there is nothing to add.
        let declared = Self.existingDeclaration(of: action, kind: kind, value: name, configRoot: configRoot, context: context)

        if declared == nil, CaskApps.wanted(kind: kind, entries: entries, registry: context.registry), CaskApps.fileUsesApps(kind: kind, text: fileText) {
            if let app = await CaskApps.lookup([name], context: context)[name] {
                options.append((key: CaskApps.optionKey, value: .string(app)))
                entries.append(YAMLMap.Entry(key: CaskApps.optionKey, value: .string(app)))
                raw = RawItem(map: YAMLMap(entries), source: SourceRef(file: target.file))
                context.out.line(style.muted("· \(name) installs \(app) (brew info), so the line gets app: \(app)"))
            } else {
                context.warn("the \(kind) items in \(target.file) name their app; add --app '<Name>.app' so a copy that is already installed counts as done")
            }
        }

        // Work out the edit before installing anything, so an edit that cannot be made never leaves an
        // installed package the config does not know about.
        var preview: ConfigEditor.Result?
        if declared == nil {
            do {
                preview = try ConfigEditor.insert(kind: kind, value: name, options: options, into: fileText).result
            } catch {
                context.fail("shawn add: \(error). Nothing was installed")
                return ExitCode.failure
            }
        }
        let existing: Declaration? = declared ?? {
            if case .alreadyPresent(let line)? = preview { return Declaration(place: "\(target.file):\(line)", optional: false) }
            return nil
        }()

        let repo = GitRepo(root: checkout, git: context.git)
        let relativeFile = configPath + "/" + target.file
        let flow = PullRequestFlow(repo: repo, context: context)
        if parsed.has("pr") && existing == nil {
            let unrelated = await flow.unrelatedStagedFiles(allowed: [relativeFile])
            if !unrelated.isEmpty {
                context.fail("shawn add --pr: the checkout has other staged changes (\(unrelated.joined(separator: ", "))); commit or unstage them first")
                return ExitCode.failure
            }
            if await !repo.changedFiles(under: relativeFile).isEmpty {
                context.fail("shawn add --pr: \(target.file) already has uncommitted changes; commit or stash them first so the pull request holds only this addition")
                return ExitCode.failure
            }
        }

        if !parsed.has("no-install") {
            let step = StepConfig(id: "add", title: "Add \(kind) \(name)", rawItems: [raw], file: target.file)
            let single = InstallerConfig(root: config.root, meta: config.meta, steps: [step], source: config.source)
            let plan = InstallPlan.build(config: single, registry: context.registry, environment: context.environment)
            if plan.hasErrors {
                for issue in plan.errors { context.fail(issue.message) }
                return ExitCode.failure
            }
            let interactive = context.terminal.stdinIsTTY || context.terminal.stderrIsTTY
            let engine = InstallEngine(plan: plan, environment: context.environment, options: RunOptions(dryRun: dryRun),
                                       interaction: context.interaction(TerminalInteraction.Options(assumeYes: false, allowPrompts: interactive && !dryRun)))
            let selection = Selection(itemOverrides: Dictionary(uniqueKeysWithValues: plan.allItems.map { ($0.id, true) }))
            let renderer = InstallRenderer(plan: plan, selection: selection, fun: context.fun, terminal: context.terminal, out: context.out, desktop: nil)
            let summary = await InstallCommand.run(engine: engine, selection: selection, renderer: renderer, catchInterrupts: interactive, context: context)
            if summary.wasCancelled { return ExitCode.interrupted }
            if !summary.failures.isEmpty {
                context.fail("\(name) did not install, so it was not added to the config")
                return ExitCode.failure
            }
        }

        if let existing {
            let off = existing.optional ? " (as optional: true, so it is off unless switched on)" : ""
            context.out.line((dryRun ? style.muted("[dry-run]") + " " : "") + style.muted("· \(existing.place) already has \(kind) \(name)\(off); nothing to add"))
            if parsed.has("pr") { context.out.line(style.muted("no pull request needed")) }
            return ExitCode.ok
        }

        let line = ConfigEditor.itemLines(kind: kind, value: name, options: options, indent: "")
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        if dryRun {
            if case .inserted(let lineNumber)? = preview {
                context.out.line(style.muted("[dry-run]") + " would add \(line) to \(target.file):\(lineNumber)")
            }
            if parsed.has("pr") { context.out.line(style.muted("[dry-run]") + " would open a pull request from shawn/add-\(kind)-\(PullRequestFlow.slug(name))") }
            return ExitCode.ok
        }

        let result: ConfigEditor.Result
        do {
            result = try ConfigEditor.insert(kind: kind, value: name, options: options, file: file)
        } catch {
            context.fail("shawn add: \(error)")
            return ExitCode.failure
        }
        switch result {
        case .inserted(let lineNumber):
            context.out.line(style.ok("✓") + " added \(style.accent(line)) to \(target.file):\(lineNumber)")
        case .alreadyPresent(let lineNumber):
            context.out.line(style.muted("· \(target.file):\(lineNumber) already has \(kind) \(name); nothing to add"))
            if parsed.has("pr") { context.out.line(style.muted("no pull request needed")) }
            return ExitCode.ok
        }
        guard parsed.has("pr") else {
            context.out.line(style.muted("Send it with 'shawn pr' (or run add with --pr next time)."))
            return ExitCode.ok
        }
        return await flow.open(PullRequestFlow.Plan(
            branchBase: "shawn/add-\(kind)-\(PullRequestFlow.slug(name))",
            paths: [relativeFile],
            title: "Add \(kind) \(name)",
            body: "Adds `\(line)` to `\(relativeFile)`.\n\nAdded with `shawn add` on \(context.environment.hostName)."
        ))
    }

    struct Declaration: Equatable {
        /// `steps/03-packages.yaml:12`
        var place: String
        var optional: Bool
    }

    /// Where the config already declares the same thing, in any step file: the same package (same manager
    /// and name, tap prefix ignored) or, for other kinds, the same kind and value. Nil when nothing does, or
    /// when the step files cannot be read (then only the target file is checked).
    static func existingDeclaration(of action: any Action, kind: String, value: String, configRoot: URL, context: CLIContext) -> Declaration? {
        let loaded: ConfigLoader.Result
        do {
            loaded = try ConfigLoader.load(from: configRoot)
        } catch {
            context.warn("could not read every step file (\(error)); only the add: target was checked for an existing entry")
            return nil
        }
        let plan = InstallPlan.build(config: loaded.config, registry: context.registry, environment: context.environment)
        let wanted = (action as? any PackageProviding)?.packageRef
        let match = plan.allItems.first { item in
            if let wanted, let other = (item.action as? any PackageProviding)?.packageRef {
                return other.manager == wanted.manager && Drift.key(wanted.manager, other.name) == Drift.key(wanted.manager, wanted.name)
            }
            return item.config.kind == kind && item.config.value.string == value
        }
        guard let match else { return nil }
        return Declaration(place: match.config.source.description, optional: match.config.optional)
    }

    /// Command-line text as the YAML scalar it stands for (`937984704` is a number, `true` a boolean).
    /// Only canonical whole numbers count as numbers: `007` stays the string it was typed as.
    static func scalarValue(_ text: String) -> YAMLValue {
        if ConfigEditor.isCanonicalInteger(text), let number = Int(text) { return .int(number) }
        if text == "true" || text == "false" { return .bool(text == "true") }
        return .string(text)
    }
}

struct PRCommand: BuiltinCommand {
    let name = "pr"
    let section = BuiltinSection.config
    let summary = "Open a pull request with your config changes"
    let usage = "[-m message] [--repo PATH]"
    let details: String? = "Takes everything uncommitted under the config directory of the checkout, commits it on a new branch, pushes it and opens a pull request with gh."
    let options = [
        OptionSpec("message", short: "m", value: "TEXT", "Commit message and pull request title"),
        OptionSpec("repo", value: "PATH", "Use this checkout instead of the one in ~/.config/shawn/config.yaml"),
    ]

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        let checkout = parsed.value("repo").map { URL(fileURLWithPath: PathExpansion.expandTilde($0, home: context.environment.home)).standardizedFileURL } ?? context.checkout
        guard let checkout, FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) else {
            context.fail("shawn pr: needs a checkout of the dotfiles, or --repo PATH")
            return ExitCode.usage
        }
        let configPath = context.settings.configPath
        let repo = GitRepo(root: checkout, git: context.git)
        let changed = await repo.changedFiles(under: configPath)
        guard !changed.isEmpty else {
            context.out.line(context.style.ok("✓") + " nothing to send: no changes under \(configPath)")
            return ExitCode.ok
        }
        let flow = PullRequestFlow(repo: repo, context: context)
        let unrelated = await flow.unrelatedStagedFiles(allowed: [configPath])
        if !unrelated.isEmpty {
            context.fail("shawn pr: other files are staged (\(unrelated.joined(separator: ", "))); commit or unstage them first")
            return ExitCode.failure
        }
        let short = changed.map { $0.hasPrefix(configPath + "/") ? String($0.dropFirst(configPath.count + 1)) : $0 }
        let title = parsed.value("message") ?? "Update config: " + (short.count <= 3 ? short.joined(separator: ", ") : "\(short.prefix(2).joined(separator: ", ")) and \(short.count - 2) more")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return await flow.open(PullRequestFlow.Plan(
            branchBase: "shawn/config-\(formatter.string(from: context.services.clock.now()))",
            paths: [configPath],
            title: title,
            body: "Config changes from \(context.environment.hostName):\n\n" + short.map { "- `\($0)`" }.joined(separator: "\n")
        ))
    }
}
