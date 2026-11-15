import Foundation
import ShawnCore

/// Git repositories under `~/Developer`.
enum Projects {
    struct Entry: Equatable, Sendable {
        var url: URL
        /// Path relative to the Developer directory (`dotfiles`, `org/tool`).
        var name: String
        var branch: String?
        var dirty = false
        var ahead = 0
        var behind = 0
    }

    /// Repositories one or two levels down (`~/Developer/x`, `~/Developer/org/x`).
    static func find(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        func children(_ directory: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        func isRepo(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) }
        var repos: [URL] = []
        for child in children(root) {
            if isRepo(child) {
                repos.append(child)
            } else {
                repos += children(child).filter(isRepo)
            }
        }
        return repos
    }

    /// Branch, dirty state and ahead/behind for each repository, a few at a time.
    static func status(of repos: [URL], root: URL, environment: SystemEnvironment) -> [Entry] {
        let git = ToolLocator.git(environment: environment)
        let processEnvironment = environment.processEnvironment(overrides: ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"])
        let results = ProjectResults(count: repos.count)
        DispatchQueue.concurrentPerform(iterations: repos.count) { index in
            let url = repos[index]
            let rootPath = root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            var entry = Entry(url: url, name: path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent)
            if let git, let output = BoundedProcess.run(git, ["--no-optional-locks", "status", "--porcelain=v2", "--branch"],
                                                         environment: processEnvironment, currentDirectory: path, timeout: 3), output.status == 0 {
                apply(output.stdout, to: &entry)
            } else {
                entry.branch = SystemStatusGit.branchFromHead(url)
            }
            results.set(index, entry)
        }
        return results.all
    }

    static func apply(_ porcelain: String, to entry: inout Entry) {
        if let status = SystemStatusGit.parsePorcelain(porcelain) {
            entry.branch = status.branch
            entry.dirty = status.dirty == true
        }
        if let line = porcelain.split(separator: "\n").first(where: { $0.hasPrefix("# branch.ab ") }) {
            let parts = line.split(separator: " ")
            if parts.count == 4 {
                entry.ahead = Int(parts[2].dropFirst()) ?? 0
                entry.behind = Int(parts[3].dropFirst()) ?? 0
            }
        }
    }
}

private final class ProjectResults: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Projects.Entry?]

    init(count: Int) { entries = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ entry: Projects.Entry) { lock.withLock { entries[index] = entry } }
    var all: [Projects.Entry] { lock.withLock { entries.compactMap { $0 } } }
}

struct ProjectsCommand: BuiltinCommand {
    let name = "projects"
    let section = BuiltinSection.projects
    let summary = "Git repos in ~/Developer with branch and state"
    let usage = "[--paths]"
    let options = [OptionSpec("paths", "Only print their paths (for scripts and fzf)")]

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        let root = context.developerDirectory
        let repos = Projects.find(in: root)
        if parsed.has("paths") {
            for repo in repos { context.out.line(repo.path) }
            return ExitCode.ok
        }
        guard !repos.isEmpty else {
            context.out.line(context.style.muted("No git repositories in \(context.display(root)) yet. Try 'shawn clone owner/repo' or 'shawn new name'."))
            return ExitCode.ok
        }
        let style = context.style
        let entries = Projects.status(of: repos, root: root, environment: context.environment)
        let width = (entries.map { $0.name.count }.max() ?? 0) + 2
        context.out.line(style.heading(context.display(root)) + style.muted(" · \(entries.count) repos"))
        for entry in entries {
            var state: [String] = []
            if entry.dirty { state.append(style.warn("● changes")) }
            if entry.ahead > 0 { state.append(style.accent("↑\(entry.ahead)")) }
            if entry.behind > 0 { state.append(style.fg(Palette.sky, "↓\(entry.behind)")) }
            if state.isEmpty { state.append(style.ok("✓ clean")) }
            context.out.line("  " + TextWidth.pad(entry.name, to: width) + style.fg(Palette.pink, TextWidth.pad(entry.branch ?? "?", to: 18)) + state.joined(separator: " "))
        }
        return ExitCode.ok
    }
}

/// Tells the `shawn` shell function (from `shawn shell-init`) where to `cd` afterwards.
enum ChangeDirectory {
    static let variable = "SHAWN_CD_FILE"

    static func request(_ directory: URL, context: CLIContext) {
        guard let file = context.environment.baseEnvironment[variable], !file.isEmpty else {
            context.out.line(context.style.muted("cd \(context.display(directory))"))
            return
        }
        // The shell function reads this right after we exit; failing to write it only skips the cd.
        try? Data(directory.path.utf8).write(to: URL(fileURLWithPath: file))
    }
}

struct CloneCommand: BuiltinCommand {
    let name = "clone"
    let section = BuiltinSection.projects
    let summary = "Clone a GitHub repo into ~/Developer"
    let usage = "<owner/repo | repo | url> [directory]"
    let details: String? = "A bare repo name uses the github_user from installer.yaml. With the shell integration, you end up in the new directory."

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        guard let spec = parsed.positionals.first, parsed.positionals.count <= 2 else {
            context.fail("usage: shawn clone \(usage)")
            return ExitCode.usage
        }
        guard let source = Self.source(for: spec, vars: context.templateVars()) else {
            context.fail("shawn clone: '\(spec)' is not owner/repo, a repo name, or a git URL")
            return ExitCode.usage
        }
        let folder = parsed.positionals.count == 2 ? parsed.positionals[1] : source.name
        guard !folder.contains(".."), !folder.hasPrefix("/") else {
            context.fail("shawn clone: the directory must be a name inside \(context.display(context.developerDirectory))")
            return ExitCode.usage
        }
        let target = context.developerDirectory.appendingPathComponent(folder)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.appendingPathComponent(".git").path) {
            context.out.line(context.style.ok("✓") + " already cloned at \(context.display(target))")
            ChangeDirectory.request(target, context: context)
            return ExitCode.ok
        }
        if let contents = try? fileManager.contentsOfDirectory(atPath: target.path), !contents.isEmpty {
            context.fail("shawn clone: \(context.display(target)) exists and is not empty")
            return ExitCode.failure
        }
        do {
            try fileManager.createDirectory(at: context.developerDirectory, withIntermediateDirectories: true)
        } catch {
            context.fail("shawn clone: cannot create \(context.display(context.developerDirectory)): \(error.localizedDescription)")
            return ExitCode.failure
        }
        let gitRequest = ToolLocator.git(environment: context.environment).map {
            ProcessRequest($0, ["clone", source.url, target.path], environment: context.childEnvironment())
        }
        var request: ProcessRequest
        var status: Int32
        if let slug = source.slug, let gh = ToolLocator.find("gh", environment: context.environment) {
            // gh honours the protocol (ssh/https) chosen at `gh auth login`.
            request = ProcessRequest(gh, ["repo", "clone", slug, target.path], environment: context.childEnvironment())
            status = await context.launcher.interactive(request)
            // gh refuses to do anything while logged out (exit 4), even for a public repo that git clones fine.
            if status != 0, status != ExitCode.interrupted, let gitRequest, Self.nothingCloned(at: target) {
                context.warn("gh repo clone did not work (exit \(status)); trying git clone \(source.url)")
                request = gitRequest
                status = await context.launcher.interactive(request)
            }
        } else if let gitRequest {
            request = gitRequest
            status = await context.launcher.interactive(request)
        } else {
            context.fail("shawn clone: neither gh nor git is available")
            return ExitCode.unavailable
        }
        guard status == 0 else {
            context.fail("shawn clone: \(request.displayString) failed (exit \(status))")
            return status == ExitCode.interrupted ? status : ExitCode.failure
        }
        context.out.line(context.style.ok("✓") + " cloned into \(context.display(target))")
        ChangeDirectory.request(target, context: context)
        return ExitCode.ok
    }

    /// No repository and nothing else at `target`, so another attempt cannot clobber anything.
    static func nothingCloned(at target: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.appendingPathComponent(".git").path) { return false }
        guard fileManager.fileExists(atPath: target.path) else { return true }
        return ((try? fileManager.contentsOfDirectory(atPath: target.path)) ?? ["?"]).isEmpty
    }

    struct Source: Equatable {
        /// `owner/repo` when it is on GitHub.
        var slug: String?
        var url: String
        /// Default folder name.
        var name: String
    }

    static func source(for spec: String, vars: TemplateVars) -> Source? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("://") || trimmed.hasPrefix("git@") {
            var name = (trimmed as NSString).lastPathComponent
            if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
            guard !name.isEmpty else { return nil }
            var slug: String?
            if let range = trimmed.range(of: "github.com[:/]", options: .regularExpression) {
                var rest = String(trimmed[range.upperBound...])
                if rest.hasSuffix(".git") { rest = String(rest.dropLast(4)) }
                if rest.split(separator: "/").count == 2 { slug = rest }
            }
            return Source(slug: slug, url: trimmed, name: name)
        }
        // Each part starts with a letter, digit or underscore, so `..` and dot-files never pass.
        let pattern = "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"
        let parts = trimmed.split(separator: "/").map(String.init)
        if parts.count == 2, parts.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }) {
            return Source(slug: trimmed, url: "https://github.com/\(trimmed).git", name: parts[1])
        }
        if parts.count == 1, trimmed.range(of: pattern, options: .regularExpression) != nil, let user = vars["github_user"], !user.isEmpty {
            return Source(slug: "\(user)/\(trimmed)", url: "https://github.com/\(user)/\(trimmed).git", name: trimmed)
        }
        return nil
    }
}

struct NewCommand: BuiltinCommand {
    let name = "new"
    let section = BuiltinSection.projects
    let summary = "Start a new project in ~/Developer (git, README, .gitignore)"
    let usage = "<name> [--github] [--public]"
    let options = [
        OptionSpec("github", "Also create the GitHub repo and push (gh repo create)"),
        OptionSpec("public", "Make the GitHub repo public (default: private)"),
    ]

    static let gitignore = """
    # macOS
    .DS_Store
    ._*

    # Editors
    .vscode/
    .idea/
    *.swp

    # Secrets
    .env
    .env.*
    !.env.example

    # Dependencies and builds
    node_modules/
    .venv/
    __pycache__/
    dist/
    build/
    .build/

    """

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        guard parsed.positionals.count == 1, let project = parsed.positionals.first else {
            context.fail("usage: shawn new \(usage)")
            return ExitCode.usage
        }
        guard project.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
            context.fail("shawn new: '\(project)' is not a good folder name (letters, digits, dot, dash, underscore)")
            return ExitCode.usage
        }
        let target = context.developerDirectory.appendingPathComponent(project)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            context.fail("shawn new: \(context.display(target)) already exists")
            return ExitCode.failure
        }
        guard let git = ToolLocator.git(environment: context.environment) else {
            context.fail("shawn new: git is not available (install the command line developer tools)")
            return ExitCode.unavailable
        }
        let style = context.style
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("# \(project)\n".utf8).write(to: target.appendingPathComponent("README.md"))
            try Data(Self.gitignore.utf8).write(to: target.appendingPathComponent(".gitignore"))
        } catch {
            context.fail("shawn new: could not create \(context.display(target)): \(error.localizedDescription)")
            return ExitCode.failure
        }
        let environment = context.childEnvironment()
        for arguments in [["init", "-q", "-b", "main"], ["add", "."]] {
            let result = await context.launcher.capture(ProcessRequest(git, arguments, environment: environment, currentDirectory: target, timeout: 30))
            guard result.succeeded else {
                context.fail("shawn new: git \(arguments.joined(separator: " ")) failed: \(result.tail(2))")
                return ExitCode.failure
            }
        }
        let commit = await context.launcher.capture(ProcessRequest(git, ["commit", "-q", "-m", "Start \(project)"], environment: environment, currentDirectory: target, timeout: 30))
        context.out.line(style.ok("✓") + " created \(context.display(target)) (README.md, .gitignore, git on main)")
        if !commit.succeeded {
            context.warn("first commit skipped: \(commit.tail(1)); set git user.name/user.email, then commit")
        }
        if parsed.has("github") {
            guard let gh = ToolLocator.find("gh", environment: context.environment) else {
                context.fail("shawn new --github: gh is not installed")
                return ExitCode.unavailable
            }
            let visibility = parsed.has("public") ? "--public" : "--private"
            let status = await context.launcher.interactive(ProcessRequest(gh, ["repo", "create", project, visibility, "--source", target.path, "--push"],
                                                                           environment: environment, currentDirectory: target))
            if status != 0 {
                context.fail("gh repo create failed (exit \(status)); the local project is ready")
                ChangeDirectory.request(target, context: context)
                return ExitCode.failure
            }
            context.out.line(style.ok("✓") + " created the GitHub repo and pushed")
        }
        ChangeDirectory.request(target, context: context)
        return ExitCode.ok
    }
}
