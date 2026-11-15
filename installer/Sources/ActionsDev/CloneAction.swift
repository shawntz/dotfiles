import Foundation
import ShawnCore

/// `clone:` clones a repository unless the destination already is one.
struct CloneAction: Action {
    /// `owner/repo` or a git URL, as written (may contain `{{vars}}`).
    let repository: String
    let destination: String
    /// nil = decide at run time (ssh when gh is signed in to github.com with git_protocol ssh).
    let protocolOverride: String?
    let branch: String?
    /// The whole clone, start to finish. A transfer that stalls without failing would otherwise hold up the run for good.
    var timeLimit: TimeInterval = 30 * 60

    /// Fails an https transfer that has received nothing for two minutes (slow but moving transfers carry on).
    static let stallSettings = ["-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=120"]
    /// ssh asks about unknown host keys on /dev/tty, not stdin, so batch mode makes it fail instead of hang;
    /// the keep-alives notice a connection that died mid-transfer within about a minute.
    static let sshCommand = "ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

    enum Source: Equatable {
        case github(owner: String, name: String)
        case url(String)
    }

    var title: String { repository }
    var subtitle: String? { "→ \(destination)" }

    static let descriptor = ActionDescriptor(
        kind: "clone",
        summary: "Clones a git repository (owner/repo on GitHub, or any git URL) unless the destination already is a repository.",
        example: """
        - clone: "{{dotfiles_repo}}"
          to: ~/Developer/dotfiles
        """
    ) { parser in
        let repository = parser.primaryString()
        let destination = parser.options.requiredString("to")
        var protocolOverride = parser.options.string("protocol")
        if let value = protocolOverride, !["ssh", "https"].contains(value) {
            parser.options.error("'protocol' must be one of: ssh, https (got '\(value)')", key: "protocol")
            protocolOverride = nil
        }
        return CloneAction(repository: repository, destination: destination, protocolOverride: protocolOverride,
                           branch: parser.options.string("branch"))
    }

    private static let shorthand = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$")
    private static let scpLike = try! NSRegularExpression(pattern: "^[^/\\s@]+@[^/\\s:]+:.+$")

    static func classify(_ text: String) -> Source? {
        let value = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        if shorthand.firstMatch(in: value, range: range) != nil {
            let parts = value.split(separator: "/").map(String.init)
            return .github(owner: parts[0], name: parts[1])
        }
        if value.contains("://") || scpLike.firstMatch(in: value, range: range) != nil || value.hasPrefix("/") || value.hasPrefix("~/") {
            return .url(value)
        }
        return nil
    }

    static func githubURL(owner: String, name: String, protocol scheme: String) -> String {
        let repo = name.hasSuffix(".git") ? name : name + ".git"
        return scheme == "ssh" ? "git@github.com:\(owner)/\(repo)" : "https://github.com/\(owner)/\(repo)"
    }

    func validate(_ context: ValidationContext) -> [String] {
        var messages = context.unknownVariableMessages(in: repository, field: "clone") + context.unknownVariableMessages(in: destination, field: "to")
        guard messages.isEmpty else { return messages }
        switch Self.classify(context.vars.expand(repository)) {
        case nil:
            messages.append("'\(context.vars.expand(repository))' is neither owner/repo nor a git URL")
        case .url where protocolOverride != nil:
            messages.append("'protocol' only applies to owner/repo; this item already gives a full URL")
        default:
            break
        }
        return messages
    }

    private func gitDirectory(_ context: ActionContext) -> URL {
        context.path(destination).appendingPathComponent(".git")
    }

    private func isNonEmptyNonRepository(_ url: URL, context: ActionContext) -> Bool {
        guard context.files.exists(url), !context.files.exists(url.appendingPathComponent(".git")) else { return false }
        guard context.files.isDirectory(url) else { return true }
        return !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }

    func check(_ context: ActionContext) async -> CheckResult {
        let target = context.path(destination)
        if context.files.exists(gitDirectory(context)) { return .satisfied("already cloned at \(context.display(target))") }
        if isNonEmptyNonRepository(target, context: context) {
            return .needed("\(context.display(target)) exists but is not a git repository")
        }
        return .needed("not cloned yet")
    }

    /// The URL to clone and the protocol it uses (nil for non-GitHub URLs).
    private func resolveURL(_ context: ActionContext) async throws -> (url: String, protocol: String?) {
        let expanded = context.expand(repository)
        switch Self.classify(expanded) {
        case .github(let owner, let name):
            let scheme: String
            if let protocolOverride {
                scheme = protocolOverride
            } else if let gh = GitHubCLI.locate(context.environment),
                      case .account(let account) = await gh.authState(host: GitHubHostKeys.host, context: context),
                      account.isSignedIn, account.gitProtocol == "ssh" {
                scheme = "ssh"
            } else {
                scheme = "https"
            }
            return (Self.githubURL(owner: owner, name: name, protocol: scheme), scheme)
        case .url(let url):
            if url.hasPrefix("~/") { return (context.path(url).path, nil) }
            return (url, nil)
        case nil:
            throw ActionError("'\(expanded)' is neither owner/repo nor a git URL", hint: "Write it as owner/repo or a full clone URL")
        }
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let target = context.path(destination)
        if context.files.exists(gitDirectory(context)) { return .done("already cloned") }
        if isNonEmptyNonRepository(target, context: context) {
            throw ActionError("\(context.display(target)) already exists and is not a git repository, so nothing was cloned into it",
                              hint: "Move it aside (or point 'to:' somewhere else), then run this again")
        }
        guard let git = GitTool.locate(context.environment) else {
            if let outcome = DryRun.whenMissing("git", would: "clone into \(context.display(target))", context) { return outcome }
            throw GitTool.missingError(for: "git clone")
        }

        let (url, scheme) = try await resolveURL(context)
        let targetExisted = context.files.exists(target)
        try context.files.ensureDirectory(target.deletingLastPathComponent())

        var arguments = Self.stallSettings + ["clone", "--progress"]
        if let branch { arguments += ["--branch", context.expand(branch)] }
        arguments += ["--", url, target.path]
        var variables: [String: String] = [:]
        if context.environment.baseEnvironment["GIT_SSH_COMMAND"] == nil { variables["GIT_SSH_COMMAND"] = Self.sshCommand }
        let command = GitTool.command(git, arguments, environment: context.environment, set: variables).timeout(timeLimit)

        let result: CommandResult
        do {
            result = try await context.commands.run(command)
        } catch {
            removePartialClone(target, existedBefore: targetExisted, context: context)
            if let error = error as? CommandError, error.isTimeout {
                // Sign-in problems fail fast (ssh runs in batch mode, git never prompts); a clone that runs out of time stalled.
                throw ActionError("Cloning \(url) did not finish within \(TimeLimit.describe(timeLimit))",
                                  hint: "Check the network connection, then run this again")
            }
            throw error
        }
        if result.wasDryRun { return .done("would clone \(url)") }
        guard result.succeeded else {
            removePartialClone(target, existedBefore: targetExisted, context: context)
            throw ActionError("Cloning \(url) failed: \(result.tail(3))", hint: Self.hint(for: scheme))
        }
        return .done("cloned \(url) to \(context.display(target))")
    }

    private static func hint(for scheme: String?) -> String {
        switch scheme {
        case "ssh": return "Make sure your SSH key is on GitHub and github.com is in ~/.ssh/known_hosts (the github item does both), or set protocol: https"
        case "https": return "If the repository is private, sign in with the github item first (it runs gh auth setup-git), then run this again"
        default: return "Check the URL and that you have access to it, then run this again"
        }
    }

    /// git removes a half-made clone itself, but not when it is killed before it can, and a leftover
    /// `.git` would make the next check report the repository as cloned.
    private func removePartialClone(_ target: URL, existedBefore: Bool, context: ActionContext) {
        let leftovers: [URL]
        if existedBefore {
            // Only an empty folder is cloned into, so everything in it now came from git.
            leftovers = (try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? []
        } else {
            leftovers = context.files.exists(target) ? [target] : []
        }
        for url in leftovers {
            do {
                try context.files.remove(url, backup: false)
            } catch {
                context.warn("Could not remove the unfinished clone at \(context.display(url)) (\(InstallEngine.describe(error))); delete it before running this again")
            }
        }
    }
}
