import Foundation
import ShawnCore

/// `symlink: ~/.config/thing` makes a symbolic link whose target is stored as written (so it may be relative).
struct SymlinkAction: Action {
    let link: String
    let target: String

    var title: String { link }
    var subtitle: String? { "→ \(target)" }

    static let descriptor = ActionDescriptor(
        kind: "symlink",
        summary: "Create (or repoint) a symbolic link; the target is stored as written, so it may be relative.",
        example: """
        - symlink: ~/.claude/skills/unslop
          to: ../../.agents/skills/unslop
        """,
        make: { parser in
            SymlinkAction(link: parser.primaryString(), target: parser.options.requiredString("to"))
        }
    )

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, [("symlink", link), ("to", target)])
    }

    /// `{{vars}}` are expanded and a leading `~` too (a literal `~` in a link never resolves); relative targets stay relative.
    func resolvedTarget(_ context: ActionContext) -> String {
        PathExpansion.expandTilde(context.expand(target), home: context.environment.home)
    }

    func check(_ context: ActionContext) async -> CheckResult {
        let url = context.path(link)
        if context.files.symlinkMatches(at: url, target: resolvedTarget(context)) { return .satisfied("link in place") }
        return .needed(context.files.exists(url) ? "points elsewhere" : "missing")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let url = context.path(link)
        let change: FileChange
        do {
            change = try context.files.symlink(at: url, pointingTo: resolvedTarget(context), backup: true)
        } catch {
            throw context.fileError(error, doing: "link \(context.display(url))")
        }
        return .done(context.describe(change, url))
    }
}

/// `mkdir: ~/Developer` makes a directory, optionally with exact permissions.
struct MkdirAction: Action {
    let path: String
    let mode: Int?

    var title: String { path }
    var subtitle: String? { mode.map { "mode \(FileMode.describe($0))" } }

    static let descriptor = ActionDescriptor(
        kind: "mkdir",
        summary: "Create a directory (and its parents), optionally with a permission mode.",
        example: """
        - mkdir: ~/Developer
        - mkdir: ~/.ssh
          mode: "0700"
        """,
        make: { parser in
            MkdirAction(path: parser.primaryString(), mode: parser.options.fileMode("mode"))
        }
    )

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, [("mkdir", path)])
    }

    func check(_ context: ActionContext) async -> CheckResult {
        let url = context.path(path)
        guard context.files.isDirectory(url) else {
            return .needed(context.files.exists(url) ? "something else is in the way" : "missing")
        }
        // A link to a folder counts as the folder being there. Its permissions belong to whoever owns the target,
        // and `run` leaves them alone, so asking for them here would never come true.
        if context.files.isSymlink(url) { return .satisfied("exists as a link to a folder") }
        if let mode, context.files.permissions(of: url) != mode { return .needed("permissions differ") }
        return .satisfied("exists")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let url = context.path(path)
        if context.files.exists(url) && !context.files.isDirectory(url) {
            throw ActionError("\(context.display(url)) exists but is not a folder", hint: "move or rename it, then run this step again")
        }
        let change: FileChange
        do {
            change = try context.files.ensureDirectory(url, permissions: mode)
        } catch {
            throw context.fileError(error, doing: "create \(context.display(url))")
        }
        switch change {
        case .unchanged: return .done("\(context.display(url)) already exists")
        case .created: return .done(context.dryRun ? "would create \(context.display(url))" : "created \(context.display(url))")
        case .replaced: return .done("set permissions of \(context.display(url)) to \(mode.map(FileMode.describe) ?? "")")
        }
    }
}
