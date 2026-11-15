import Foundation
import ShawnCore

/// `skill:` installs an agent skill in `~/.agents/skills/<name>` (Codex reads that directory itself),
/// with relative symlinks from `~/.claude/skills` and `~/.grok/skills`, the same layout the
/// `skills` CLI creates. Bundled skills are mirrored from the config; upstream ones are
/// installed with `npx skills add`.
struct SkillAction: Action {
    enum Origin: Equatable, Sendable {
        /// Folder relative to the config root.
        case bundled(String)
        /// `owner/repo` for the skills CLI.
        case upstream(String)
    }

    let name: String
    let origin: Origin
    let agents: [String]
    /// Bundled only: replace the person's own copy at an agent's link path (it goes to the backups)
    /// instead of leaving it alone.
    var replaceExisting = false

    static let allAgents = ["claude", "codex", "grok"]
    /// Agents that need a link; Codex reads the canonical directory.
    static let linkDirectories = ["claude": "~/.claude/skills", "grok": "~/.grok/skills"]
    static let agentNames = ["claude": "Claude Code", "codex": "Codex", "grok": "Grok"]
    /// Names the skills CLI uses for `-a`.
    static let cliAgentNames = ["claude": "claude-code", "codex": "codex", "grok": "grok"]
    static let excluded = FileOps.defaultExcludes.union(["__pycache__"])

    var title: String { name }

    var subtitle: String? {
        switch origin {
        case .bundled: return "bundled skill → \(agents.joined(separator: ", "))"
        case .upstream(let source): return "from \(source) → \(agents.joined(separator: ", "))"
        }
    }

    static let descriptor = ActionDescriptor(
        kind: "skill",
        summary: "Installs an agent skill into ~/.agents/skills (bundled from config/skills/<name>, or `source: owner/repo` via the skills CLI) "
            + "and links it into ~/.claude/skills and ~/.grok/skills. A folder of your own already at one of those links (one that holds "
            + "an edited or extra file, or a git checkout) is left alone (the item then needs attention; ~/.agents/skills still gets the "
            + "bundled copy) unless `replace_existing: true`, which moves it to the backups.",
        example: """
        - skill: unslop                  # bundled: config/skills/unslop
          replace_existing: true         # optional: move your own ~/.claude/skills/unslop to the backups
        - skill: find-skills
          source: vercel-labs/skills     # upstream, installed with npx skills
        """
    ) { parser in
        let name = parser.primaryString()
        if !name.isEmpty, name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) == nil {
            parser.fail("skill names may only contain letters, digits, '.', '_' and '-' (got '\(name)')")
        }
        let from = parser.options.string("from")
        let source = parser.options.string("source")
        if from != nil && source != nil {
            parser.options.error("use either 'from:' (a bundled folder) or 'source:' (owner/repo for the skills CLI), not both", key: "source")
        }
        if let source, source.isEmpty || source.contains(where: { $0 == " " || $0 == "\t" }) {
            parser.options.error("'source' must look like owner/repo (got '\(source)')", key: "source")
        }
        let replaceExisting = parser.options.bool("replace_existing", default: false)
        if source != nil && parser.options.has("replace_existing") {
            parser.options.error("'replace_existing' only applies to bundled skills (the skills CLI installs 'source:' ones)", key: "replace_existing")
        }
        var agents = parser.options.stringList("agents")
        if !parser.options.has("agents") { agents = allAgents }
        for agent in agents where !allAgents.contains(agent) {
            parser.options.error("'agents' entries must be claude, codex or grok (got '\(agent)')", key: "agents")
        }
        if parser.options.has("agents") && agents.isEmpty {
            parser.options.error("'agents' must list at least one of claude, codex, grok", key: "agents")
        }
        let origin: Origin = source.map { .upstream($0) } ?? .bundled(from ?? "skills/\(name)")
        return SkillAction(name: name, origin: origin, agents: allAgents.filter(agents.contains), replaceExisting: replaceExisting)
    }

    func validate(_ context: ValidationContext) -> [String] {
        guard case .bundled(let folder) = origin else { return [] }
        if !context.configPathIsDirectory(folder) {
            return ["bundled skill folder '\(folder)' does not exist in the config directory"]
        }
        if !context.configPathExists("\(folder)/SKILL.md") {
            return ["bundled skill folder '\(folder)' has no SKILL.md"]
        }
        return []
    }

    // MARK: Paths

    private func canonical(_ context: ActionContext) -> URL { context.path("~/.agents/skills/\(name)") }

    /// The bundled folder by its real path, so a config reached through a link (a checkout under a linked
    /// ~/Dropbox) is compared and copied under one spelling.
    private func bundle(_ folder: String, _ context: ActionContext) -> URL {
        context.configURL(folder).resolvingSymlinksInPath()
    }

    private var linkAgents: [String] { agents.filter { Self.linkDirectories[$0] != nil } }

    private func link(for agent: String, _ context: ActionContext) -> URL {
        context.path("\(Self.linkDirectories[agent]!)/\(name)")
    }

    /// Relative, so the layout survives a renamed home folder (and matches the skills CLI's links).
    var linkTarget: String { "../../.agents/skills/\(name)" }

    /// What is at an agent's link path, as far as replacing it with the link is concerned.
    private enum LinkSpot {
        /// Already the link.
        case linked
        /// Nothing that would be lost: no entry, a dangling link, a link to the canonical copy, a file
        /// where the folder belongs (moved to the backups), or a folder with nothing of its own (every
        /// file in it is in the bundle, byte for byte; the bundle may hold more, such as a LICENSE).
        case replaceable
        /// The person's own version of the skill (a folder, or a link to one) and what makes it theirs.
        case ownCopy(OwnCopy, linkedTo: URL?)
    }

    private enum OwnCopy {
        /// An edited file, or one the bundle does not have.
        case edited
        /// A git working copy: its history and branches are not in the bundle, whatever its files hold.
        case checkout
    }

    private func spot(at link: URL, bundle: URL, context: ActionContext) -> LinkSpot {
        let files = context.files
        if files.symlinkMatches(at: link, target: linkTarget) { return .linked }
        guard files.exists(link) else { return .replaceable }
        if files.isSymlink(link) {
            let target = link.followingLinks()
            guard files.isDirectory(target),
                  target.resolvingSymlinksInPath() != canonical(context).resolvingSymlinksInPath(),
                  let own = ownCopy(target, bundle: bundle, files: files) else { return .replaceable }
            return .ownCopy(own, linkedTo: target)
        }
        guard files.isDirectory(link), let own = ownCopy(link, bundle: bundle, files: files) else { return .replaceable }
        return .ownCopy(own, linkedTo: nil)
    }

    /// What makes `folder` the person's own copy, or nil when it is not a git checkout and every file in
    /// it is in the bundle with the same content, so switching to the bundled skill changes nothing the
    /// person wrote. An older copy of a skill that has since gained a file (a LICENSE, a new reference)
    /// is such a folder; one with an edited or extra file is not.
    private func ownCopy(_ folder: URL, bundle: URL, files: FileOps) -> OwnCopy? {
        // `.git` is left out of the comparison below, so it is looked for first.
        if files.exists(folder.appendingPathComponent(".git")) { return .checkout }
        // By its real path, so a folder reached through a link (~/.claude/skills stowed into a dotfiles
        // checkout, or a link to ~/Projects/…) is compared as the folder it is.
        let real = folder.resolvingSymlinksInPath()
        return files.directoryMatches(source: real, destination: bundle, exact: false, excluding: Self.excluded) ? nil : .edited
    }

    // MARK: Check

    func check(_ context: ActionContext) async -> CheckResult {
        let skillFile = canonical(context).appendingPathComponent("SKILL.md")
        guard context.files.exists(skillFile) else { return .needed("not installed in ~/.agents/skills yet") }
        switch origin {
        case .bundled(let folder):
            let source = bundle(folder, context)
            guard context.files.isDirectory(source) else { return .needed("bundled folder \(folder) is missing") }
            if !context.files.directoryMatches(source: source, destination: canonical(context), exact: true, excluding: Self.excluded) {
                return .needed("installed copy differs from the bundled one")
            }
            for agent in linkAgents {
                let url = link(for: agent, context)
                switch spot(at: url, bundle: source, context: context) {
                case .linked: continue
                case .ownCopy where !replaceExisting: return .needed("\(context.display(url)) is your own copy, not the bundled one")
                default: return .needed("\(agent) link is missing")
                }
            }
        case .upstream:
            for agent in linkAgents where !context.files.exists(link(for: agent, context).appendingPathComponent("SKILL.md")) {
                return .needed("\(agent) cannot see it yet")
            }
        }
        return .satisfied("installed for \(agents.joined(separator: ", "))")
    }

    // MARK: Run

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        switch origin {
        case .bundled(let folder): return try installBundled(folder, context: context)
        case .upstream(let source): return try await installUpstream(source, context: context)
        }
    }

    /// The canonical copy is always mirrored from the bundle, so Codex (which reads ~/.agents/skills
    /// itself) gets the skill even when an agent's link path holds the person's own copy. That copy is
    /// left alone, and the item needs attention, unless `replace_existing` says otherwise.
    private func installBundled(_ folder: String, context: ActionContext) throws -> ActionOutcome {
        let source = bundle(folder, context)
        guard context.files.exists(source.appendingPathComponent("SKILL.md")) else {
            throw ActionError("The bundled skill '\(name)' is missing (\(folder)/SKILL.md is not in the config)",
                              hint: "Add the folder under config/\(folder) or remove this item")
        }
        let destination = canonical(context)
        var parts: [String] = []

        // The old copy may hold edits made through a link, so where it went is part of the outcome.
        // In a dry run it stays put and installDirectory narrates the backup itself.
        var previous: URL?
        if !context.dryRun, context.files.exists(destination),
           !context.files.directoryMatches(source: source, destination: destination, exact: true, excluding: Self.excluded) {
            // First swap a linked parent folder for a real one, exactly as installDirectory would.
            if context.files.isDirectory(destination) { try context.files.ensureDirectory(destination) }
            previous = try context.files.backUp(destination)
        }
        let changed = try context.files.installDirectory(from: source, to: destination, replace: true, excluding: Self.excluded)
        if changed > 0 {
            let files = "\(changed) file\(changed == 1 ? "" : "s")"
            if context.dryRun {
                let moved = previous.map { " (the previous copy would go to \(context.display($0)))" } ?? ""
                parts.append("would write \(files) to ~/.agents/skills/\(name)\(moved)")
            } else {
                let moved = previous.map { " (the previous copy is in \(context.display($0)))" } ?? ""
                parts.append("\(files) written to ~/.agents/skills/\(name)\(moved)")
            }
        }

        var linked: [String] = []
        var replaced: [String] = []
        var ownCopies: [(agent: String, url: URL, kind: OwnCopy)] = []
        for agent in linkAgents {
            let url = link(for: agent, context)
            let found = spot(at: url, bundle: source, context: context)
            if case .ownCopy(let kind, _) = found, !replaceExisting {
                ownCopies.append((agent, url, kind))
                continue
            }
            let change = try context.files.symlink(at: url, pointingTo: linkTarget)
            if case .replaced(let backup?) = change {
                replaced.append("\(context.dryRun ? "would move" : "moved") \(context.display(url)) to \(context.display(backup))")
            } else if case .ownCopy(_, let target?) = found {
                replaced.append("\(context.display(url)) pointed to \(context.display(target)) before (that folder is untouched)")
            }
            if change.didChange { linked.append(agent) }
        }
        if !linked.isEmpty { parts.append("\(context.dryRun ? "would link" : "linked") for \(linked.joined(separator: ", "))") }
        parts += replaced

        guard !ownCopies.isEmpty else { return .done(parts.isEmpty ? "already installed" : parts.joined(separator: "; ")) }
        let paths = ownCopies.map { context.display($0.url) }.joined(separator: " and ")
        let reasons = ownCopies.map { copy in
            "\(context.display(copy.url)) \(copy.kind == .checkout ? "is a git checkout" : "differs from the bundled \(name) skill")"
        }.joined(separator: " and ")
        let users = ownCopies.compactMap { Self.agentNames[$0.agent] }.joined(separator: " and ")
        let one = ownCopies.count == 1
        let codex = agents.contains("codex") ? "Codex uses the bundled copy in ~/.agents/skills/\(name). " : ""
        context.followUp("Your own copy of the \(name) skill",
                         detail: "\(reasons), so \(one ? "it was" : "they were") left alone and \(users) \(one ? "keeps using it" : "keep using them"). "
                            + "\(codex)To switch to the bundled one, move your \(one ? "copy" : "copies") somewhere safe and run the installer again, "
                            + "or add 'replace_existing: true' to this item to have \(one ? "it" : "them") moved to the backups.")
        parts.append("left your own \(paths) alone")
        return .needsAttention(parts.joined(separator: "; "))
    }

    private func installUpstream(_ source: String, context: ActionContext) async throws -> ActionOutcome {
        guard let npx = context.environment.resolveExecutable("npx") else {
            if let outcome = DryRun.whenMissing("npx", would: "fetch the '\(name)' skill from \(source)", context) { return outcome }
            throw ActionError("npx is not installed, so the '\(name)' skill cannot be fetched from \(source)",
                              hint: "Install Node with the Homebrew packages step (brew: node), then run this again")
        }
        // The skills CLI clones the source with git; on a Mac without developer tools that would pop a dialog.
        guard GitTool.locate(context.environment) != nil else {
            if let outcome = DryRun.whenMissing("git", would: "fetch the '\(name)' skill from \(source)", context) { return outcome }
            throw GitTool.missingError(for: "the skills CLI")
        }

        // Codex is always passed: it reads the canonical directory, and with a single agent the CLI
        // would copy straight into that agent's folder instead of ~/.agents/skills.
        let cliAgents = Self.allAgents.filter { $0 == "codex" || agents.contains($0) }.compactMap { Self.cliAgentNames[$0] }
        var arguments = ["--yes", "skills@latest", "add", source, "-g", "-s", name]
        for agent in cliAgents { arguments += ["-a", agent] }
        arguments.append("-y")

        let unset = ToolCommand.agentSessionVariables(context.environment)
            + ToolCommand.inherited(context.environment, prefixes: ["CODEX_"], exact: ["CI"])
            + GitTool.isolationVariables(context.environment)
        let command = ToolCommand.make(npx, arguments, unset: unset, set: ["DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1"], display: "npx")
        let result = try await context.commands.run(command.timeout(600), hintIfTimedOut: "Check the network connection, then run this again")
        if result.wasDryRun { return .done("would install \(name) from \(source)") }
        guard result.succeeded else {
            throw ActionError("The skills CLI could not install '\(name)' from \(source): \(result.tail(3))",
                              hint: "Check the network and that \(source) has a skill named \(name), then run this again")
        }
        guard context.files.exists(canonical(context).appendingPathComponent("SKILL.md")) else {
            throw ActionError("The skills CLI finished, but ~/.agents/skills/\(name)/SKILL.md does not exist",
                              hint: "Check that \(source) has a skill named exactly '\(name)'")
        }
        var notes: [String] = []
        var linked: [String] = []
        // Whatever the CLI put there is kept if the skill is reachable through it (a link or a copy).
        for agent in linkAgents where !context.files.exists(link(for: agent, context).appendingPathComponent("SKILL.md")) {
            let url = link(for: agent, context)
            if case .replaced(let backup?) = try context.files.symlink(at: url, pointingTo: linkTarget) {
                notes.append("\(context.dryRun ? "would move" : "moved") \(context.display(url)) to \(context.display(backup))")
            }
            linked.append(agent)
        }
        if !linked.isEmpty { notes.insert("\(context.dryRun ? "would link" : "linked") for \(linked.joined(separator: ", "))", at: 0) }
        let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
        return .done("installed from \(source)\(suffix)")
    }
}
