import Foundation
import ShawnCore
import ShawnFun

/// The parts of Claude Code's status-line JSON we use. Every field is optional; anything malformed is
/// simply absent.
struct StatusLineInput: Equatable, Sendable {
    var model: String?
    var currentDirectory: String?
    var projectDirectory: String?
    var sessionID: String?
    var promptID: String?
    var usedPercentage: Double?
    var costUSD: Double?

    static func parse(_ data: Data) -> StatusLineInput {
        var input = StatusLineInput()
        guard !data.isEmpty, let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            return input
        }
        let model = object["model"] as? [String: Any]
        input.model = nonEmpty(model?["display_name"]) ?? nonEmpty(model?["id"]) ?? nonEmpty(object["model"])
        let workspace = object["workspace"] as? [String: Any]
        input.currentDirectory = nonEmpty(workspace?["current_dir"]) ?? nonEmpty(object["cwd"])
        input.projectDirectory = nonEmpty(workspace?["project_dir"])
        input.sessionID = nonEmpty(object["session_id"])
        input.promptID = nonEmpty(object["prompt_id"])

        let window = object["context_window"] as? [String: Any]
        if let used = number(window?["used_percentage"]) {
            input.usedPercentage = used
        } else if let size = number(window?["context_window_size"]), size > 0, let usage = window?["current_usage"] as? [String: Any] {
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { number(usage[$0]) }.reduce(0, +)
            if tokens > 0 { input.usedPercentage = tokens / size * 100 }
        }
        if let used = input.usedPercentage { input.usedPercentage = min(100, max(0, used)) }
        input.costUSD = number((object["cost"] as? [String: Any])?["total_cost_usd"])
        return input
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// Branch and dirty state of a repository.
struct GitStatus: Equatable, Sendable {
    var branch: String
    /// nil when git was too slow to say.
    var dirty: Bool?
}

protocol StatusGitProbing: Sendable {
    /// The repository containing `directory` (by walking up to a `.git`), without running git.
    func repositoryRoot(for directory: URL) -> URL?
    /// Branch and dirty state, or nil when it cannot be determined.
    func status(of root: URL, directory: URL) -> GitStatus?
}

struct SystemStatusGit: StatusGitProbing {
    let environment: SystemEnvironment
    /// Status lines are re-run on every assistant message; never let git hold one up.
    var budget: TimeInterval = 0.5

    func repositoryRoot(for directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    func status(of root: URL, directory: URL) -> GitStatus? {
        if let git = ToolLocator.git(environment: environment),
           let result = BoundedProcess.run(git, ["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain=v2", "--branch"],
                                           environment: environment.processEnvironment(overrides: ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]),
                                           currentDirectory: directory.path, timeout: budget),
           result.status == 0 {
            return Self.parsePorcelain(result.stdout)
        }
        // git was slow or failed: the branch is still one file read away; the dirty state is unknown.
        return Self.branchFromHead(root).map { GitStatus(branch: $0, dirty: nil) }
    }

    static func parsePorcelain(_ text: String) -> GitStatus? {
        var branch: String?
        var oid: String?
        var dirty = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
            } else if !line.hasPrefix("#") {
                dirty = true
            }
        }
        guard var name = branch else { return nil }
        if name == "(detached)" { name = oid.map { String($0.prefix(7)) } ?? "detached" }
        return GitStatus(branch: name, dirty: dirty)
    }

    static func branchFromHead(_ root: URL) -> String? {
        var gitDirectory = root.appendingPathComponent(".git")
        // A worktree or submodule has a `.git` file pointing at the real git directory.
        if let pointer = try? String(contentsOf: gitDirectory, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }
}

/// Renders the one status line. Pure: everything it needs comes in.
struct StatusLineRenderer: Sendable {
    var style: Style
    /// Terminal columns (Claude Code passes COLUMNS).
    var columns: Int
    var home: URL
    var quips: [String]

    static let glyph = "✦"
    /// Short lines in LSP's voice for when cli.yaml has none.
    static let fallbackQuips = ["lumping along", "what the lump", "so lumpy rn", "princess-grade code", "ugh, fine, I'll help"]

    enum Part: Equatable {
        case model, directory, meter, git, cost, quip
    }

    struct Segment {
        var part: Part
        var text: String
    }

    /// How the line shrinks when COLUMNS is small, least important first.
    enum Reduction: CaseIterable {
        case dropQuip, dropCost, compactMeter, dropGit, shortenDirectory, dropMeter, dropDirectory
    }

    func render(_ input: StatusLineInput, directory: URL, repositoryRoot: URL?, git: GitStatus?) -> String {
        var segments: [Segment] = []
        let model = input.model.map { TextWidth.truncate($0, to: 24) }
        segments.append(Segment(part: .model, text: style.accent(Self.glyph) + (model.map { " " + style.bold(style.fg(Palette.pink, $0)) } ?? "")))
        let label = directoryLabel(directory, repositoryRoot: repositoryRoot)
        segments.append(Segment(part: .directory, text: style.fg(Palette.sky, label)))
        if let used = input.usedPercentage {
            segments.append(Segment(part: .meter, text: meter(used, compact: false)))
        }
        if let git {
            let marker = git.dirty == true ? style.fg(Palette.star, "*") : ""
            segments.append(Segment(part: .git, text: style.fg(Palette.lavender, git.branch) + marker))
        }
        if let cost = input.costUSD, cost >= 0 {
            segments.append(Segment(part: .cost, text: style.fg(Palette.mint, Self.formatCost(cost))))
        }
        if let quip = quip(for: input) {
            segments.append(Segment(part: .quip, text: style.italic(style.muted(quip))))
        }

        let separator = style.muted(" · ")
        let limit = max(16, columns - 4)
        func width(_ segments: [Segment]) -> Int { TextWidth.of(segments.map(\.text).joined(separator: separator)) }

        for reduction in Reduction.allCases where width(segments) > limit {
            switch reduction {
            case .dropQuip: segments.removeAll { $0.part == .quip }
            case .dropCost: segments.removeAll { $0.part == .cost }
            case .dropGit: segments.removeAll { $0.part == .git }
            case .dropMeter: segments.removeAll { $0.part == .meter }
            case .dropDirectory: segments.removeAll { $0.part == .directory }
            case .compactMeter:
                if let index = segments.firstIndex(where: { $0.part == .meter }), let used = input.usedPercentage {
                    segments[index].text = meter(used, compact: true)
                }
            case .shortenDirectory:
                guard let index = segments.firstIndex(where: { $0.part == .directory }) else { continue }
                let others = segments.filter { $0.part != .directory }
                let room = limit - width(others) - TextWidth.of(separator)
                // Keep the end of the path: the folder you are in matters more than where it lives.
                if room >= 8 {
                    segments[index].text = style.fg(Palette.sky, "…" + String(label.suffix(room - 1)))
                }
            }
        }
        return segments.map(\.text).joined(separator: separator)
    }

    /// `repo/sub/dir` inside a git repository, `~/…` elsewhere.
    func directoryLabel(_ directory: URL, repositoryRoot: URL?) -> String {
        let path = directory.standardizedFileURL.path
        if let root = repositoryRoot?.standardizedFileURL.path {
            let name = (root as NSString).lastPathComponent
            if path == root { return name }
            if path.hasPrefix(root + "/") { return name + "/" + path.dropFirst(root.count + 1) }
        }
        return PathExpansion.abbreviate(path, home: home)
    }

    /// `▰▰▱▱▱▱▱▱▱▱ 23%`, shifting from mint to red as the context window fills; `ctx 23%` when compact.
    func meter(_ percent: Double, compact: Bool) -> String {
        let cells = 10
        let filled = min(cells, max(0, Int((percent / 100 * Double(cells)).rounded())))
        let color: RGBA = percent < 50 ? Palette.mint : percent < 75 ? Palette.star : percent < 90 ? Palette.orange : Palette.red
        let number = style.fg(color, "\(Int(percent.rounded()))%")
        if compact { return style.muted("ctx ") + number }
        let bar = style.fg(color, String(repeating: "▰", count: filled)) + style.muted(String(repeating: "▱", count: cells - filled))
        return bar + " " + number
    }

    static func formatCost(_ cost: Double) -> String {
        cost >= 100 ? String(format: "$%.0f", cost) : String(format: "$%.2f", cost)
    }

    /// Stable within a prompt (no flicker on every redraw), different on the next one.
    func quip(for input: StatusLineInput) -> String? {
        let pool = quips.isEmpty ? Self.fallbackQuips : quips
        guard !pool.isEmpty else { return nil }
        let key = input.promptID ?? input.sessionID ?? ""
        return pool[Int(Self.fnv1a(key) % UInt64(pool.count))]
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

struct StatusLineCommand: BuiltinCommand {
    let name = "statusline"
    let section = BuiltinSection.shell
    let summary = "Claude Code's status line (reads its JSON on stdin)"
    let details: String? = """
    Used by 'shawn claude' through --settings. Prints one line: model, directory, git branch, context meter, \
    cost and a quip, dropping the least important parts when COLUMNS is small. It never fails. Bad input gives \
    a shorter line, and the exit status is always 0.
    """

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        if arguments.contains("-h") || arguments.contains("--help") {
            HelpCommand.printUsage(of: self, context: context)
            return ExitCode.ok
        }
        // Typed by hand at a prompt: there is no JSON coming, so do not wait for it.
        let data = context.terminal.stdinIsTTY ? Data() : context.services.readStdin()
        let input = StatusLineInput.parse(data)
        let directory = (input.currentDirectory ?? input.projectDirectory).map { URL(fileURLWithPath: $0) } ?? context.currentDirectory
        let probe = context.statusGit
        let root = probe.repositoryRoot(for: directory)
        let git = root.flatMap { probe.status(of: $0, directory: directory) }
        let policy = ColorPolicy(environment: context.environment.baseEnvironment, noColorFlag: context.globals.noColor)
        let environment = context.environment.baseEnvironment
        let renderer = StatusLineRenderer(
            // Claude Code captures the output (no TTY) but renders ANSI color, so only an explicit opt-out turns it off.
            style: Style(enabled: !policy.forcedOff, trueColor: true),
            columns: environment["COLUMNS"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 120,
            home: context.environment.home,
            quips: context.cli.statuslineQuips
        )
        context.out.line(renderer.render(input, directory: directory, repositoryRoot: root, git: git))
        return ExitCode.ok
    }
}
