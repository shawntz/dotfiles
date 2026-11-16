import Foundation
import ShawnCore

/// Runs git. The real one shells out; tests use it against local bare repositories, or a fake that
/// pretends to be offline or slow.
protocol GitClient: Sendable {
    func run(_ arguments: [String], in directory: URL?, timeout: TimeInterval?) async -> ProcessResult
}

struct SystemGitClient: GitClient {
    let launcher: any ProcessLaunching
    let environment: SystemEnvironment

    /// What keeps git from ever waiting for a person. Its children already have no terminal (they run in a
    /// session of their own); these also stop the programs that would answer with a window instead.
    static func nonInteractiveOverrides(base: [String: String]) -> [String: String] {
        var overrides = [
            "GIT_TERMINAL_PROMPT": "0",
            // Set but empty, GIT_ASKPASS also switches off core.askPass and SSH_ASKPASS for git's own prompts.
            "GIT_ASKPASS": "",
            // OpenSSH never runs an askpass program (a graphical one would open a passphrase dialog).
            "SSH_ASKPASS_REQUIRE": "never",
            // Git Credential Manager fails instead of opening a sign-in window.
            "GCM_INTERACTIVE": "never",
            "LC_ALL": "C",
            // A status asked before every command never takes the index lock to save a refreshed index, so it
            // cannot make the user's own git command (or another shawn's merge) fail on index.lock.
            "GIT_OPTIONAL_LOCKS": "0",
            // shawn's own ":(exclude)" pathspecs keep their meaning whatever the user's shell exports.
            "GIT_LITERAL_PATHSPECS": "0",
        ]
        // File names in git's output as they are, not as octal escapes. A caller that passes its own settings
        // this way keeps them.
        if base["GIT_CONFIG_COUNT"] == nil {
            overrides["GIT_CONFIG_COUNT"] = "1"
            overrides["GIT_CONFIG_KEY_0"] = "core.quotePath"
            overrides["GIT_CONFIG_VALUE_0"] = "false"
        }
        // Never sit at an ssh passphrase or host-key prompt; a command the user set up is left alone.
        if base["GIT_SSH_COMMAND"] == nil {
            overrides["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=5"
        }
        return overrides
    }

    func run(_ arguments: [String], in directory: URL?, timeout: TimeInterval?) async -> ProcessResult {
        guard let git = ToolLocator.git(environment: environment) else {
            return ProcessResult(exitCode: ExitCode.notFound, stdout: "", stderr: "", launchError: "git is not available (the command line developer tools are not installed)")
        }
        let overrides = Self.nonInteractiveOverrides(base: environment.baseEnvironment)
        return await launcher.capture(ProcessRequest(git, arguments, environment: environment.processEnvironment(overrides: overrides),
                                                     currentDirectory: directory, timeout: timeout))
    }
}

/// Why a git command did not work, in one line.
struct GitFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let message: String
    /// The remote never answered: git ran out of time, or the network or the host could not be reached. That passes by
    /// itself. Anything else (a refused ssh key, missing credentials, a missing repository, git itself failing) is an
    /// answer that waiting does not change.
    let noAnswer: Bool

    var description: String { message }

    /// git's first `fatal:`/`error:` line (the cause; later lines are advice), preceded by the line just before it unless
    /// that one is advice too: ssh and the server print the real cause there (`git@github.com: Permission denied
    /// (publickey).`, `remote: Repository not found.`), and git's own line then only says it could not read from the
    /// remote. Or that git ran out of time.
    init(_ result: ProcessResult, timeout: TimeInterval?) {
        if result.timedOut {
            let seconds = timeout.map { $0 >= 1 ? "\(Int($0))" : String(format: "%.1f", $0) } ?? "?"
            message = "no answer within \(seconds) seconds"
            noAnswer = true
            return
        }
        if let launchError = result.launchError {
            message = launchError
            noAnswer = false
            return
        }
        let stderr = ANSI.strip(result.stderr)
        // ssh ends its lines with \r\n, which Swift counts as one Character: splitting on "\n" alone would not split them.
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let index = lines.firstIndex(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }) {
            let cause = lines[index]
            if index > 0, !Self.isAdvice(lines[index - 1]) {
                let before = lines[index - 1]
                message = before + (before.last.map { ".!?".contains($0) } == true ? " " : "; ") + cause
            } else {
                message = cause
            }
        } else {
            let tail = result.tail(1)
            message = tail.isEmpty ? "git exited with status \(result.exitCode)" : tail
        }
        let lowered = stderr.lowercased()
        noAnswer = Self.noAnswerSigns.contains { lowered.contains($0) }
    }

    private static func isAdvice(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.hasPrefix("hint:") || lowered.hasPrefix("warning:")
    }

    /// What git, curl (https remotes) and ssh print when the network or the host is not there, lowercased.
    static let noAnswerSigns = [
        "could not resolve",                    // curl: host or proxy; ssh: hostname
        "temporary failure in name resolution",
        "failed to connect",                    // curl
        "couldn't connect to server",           // curl
        "connect to host",                      // ssh: connect to host github.com port 22: <why>
        "connection refused",
        "connection reset",
        "connection closed by",                 // ssh, before authenticating
        "kex_exchange_identification",          // ssh, before authenticating
        "network is unreachable",
        "network is down",
        "no route to host",
        "host is down",
        "timed out",                            // operation / connection / resolving timed out
        "the remote end hung up unexpectedly",
    ]
}

/// What `git ls-remote --symref` reported.
struct RemoteRefs: Equatable, Sendable {
    /// `ref → sha` (`refs/heads/master`, `refs/tags/shawn-v1.2.0`, `HEAD`).
    var refs: [String: String] = [:]
    /// Where symbolic refs point (`HEAD → refs/heads/main`).
    var symrefs: [String: String] = [:]

    /// The branch the remote's HEAD names: its default branch, when the server said.
    var defaultBranch: String? {
        guard let target = symrefs["HEAD"], target.hasPrefix("refs/heads/") else { return nil }
        return String(target.dropFirst("refs/heads/".count))
    }

    static func parse(_ lines: [String]) -> RemoteRefs {
        var parsed = RemoteRefs()
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            if fields[0].hasPrefix("ref: ") {
                parsed.symrefs[fields[1]] = String(fields[0].dropFirst("ref: ".count))
            } else {
                parsed.refs[fields[1]] = fields[0]
            }
        }
        return parsed
    }
}

/// Typed git operations on one checkout.
struct GitRepo: Sendable {
    let root: URL
    let git: any GitClient

    func run(_ arguments: [String], timeout: TimeInterval? = 30) async -> ProcessResult {
        await git.run(arguments, in: root, timeout: timeout)
    }

    /// Trimmed stdout, or nil when git failed.
    func output(_ arguments: [String], timeout: TimeInterval? = 30) async -> String? {
        let result = await run(arguments, timeout: timeout)
        return result.succeeded ? result.output : nil
    }

    func head() async -> String? {
        await output(["rev-parse", "--verify", "-q", "HEAD"])
    }

    /// The checked-out branch, or nil on a detached HEAD.
    func currentBranch() async -> String? {
        await output(["symbolic-ref", "--short", "-q", "HEAD"])
    }

    /// Changes to tracked files (staged or not), conflicts included. Untracked files never block a fast-forward
    /// by themselves: git refuses the merge when one is in the way (see `fastForward`).
    func hasTrackedChanges() async -> Bool {
        let result = await run(["status", "--porcelain", "--untracked-files=no"])
        return !result.succeeded || !result.output.isEmpty
    }

    /// Untracked files under `pathspecs` (git-ignored ones excluded), or nil when git failed.
    func untrackedFiles(under pathspecs: [String]) async -> [String]? {
        let result = await run(["status", "--porcelain", "-z", "--untracked-files=all", "--"] + pathspecs)
        guard result.succeeded else { return nil }
        return Self.statusEntries(result.stdout).filter { $0.code == "??" }.map(\.path)
    }

    func remoteName(for branch: String) async -> String {
        await output(["config", "--get", "branch.\(branch).remote"]).flatMap { $0.isEmpty ? nil : $0 } ?? "origin"
    }

    /// The refs matching `patterns` on `remote` (a name or URL), and where its symbolic refs point.
    func lsRemote(_ remote: String, patterns: [String], timeout: TimeInterval) async -> Result<RemoteRefs, GitFailure> {
        await Self.lsRemote(git: git, in: root, remote: remote, patterns: patterns, timeout: timeout)
    }

    static func lsRemote(git: any GitClient, in directory: URL?, remote: String, patterns: [String], timeout: TimeInterval) async -> Result<RemoteRefs, GitFailure> {
        let result = await git.run(["ls-remote", "--symref", remote] + patterns, in: directory, timeout: timeout)
        guard result.succeeded else { return .failure(GitFailure(result, timeout: timeout)) }
        return .success(RemoteRefs.parse(result.lines))
    }

    func hasCommit(_ sha: String) async -> Bool {
        await run(["cat-file", "-e", "\(sha)^{commit}"]).succeeded
    }

    func isAncestor(_ ancestor: String, of descendant: String) async -> Bool {
        await run(["merge-base", "--is-ancestor", ancestor, descendant]).succeeded
    }

    func fetch(_ remote: String, branch: String, timeout: TimeInterval) async -> ProcessResult {
        await run(["fetch", "--quiet", "--no-tags", remote, "refs/heads/\(branch)"], timeout: timeout)
    }

    /// `git merge --ff-only`, refusing (instead of git's default of overwriting) when the incoming commits add a
    /// file that exists here untracked, even a git-ignored one: that file is the user's, not upstream's.
    func fastForward(to revision: String, timeout: TimeInterval) async -> ProcessResult {
        await run(["merge", "--ff-only", "--no-overwrite-ignore", "--quiet", revision], timeout: timeout)
    }

    /// The files a refused merge listed as in its way ("… would be overwritten by merge:"). git prints each name after a
    /// tab exactly as it is (never quoted), so only the tab is dropped. Spaces and quotes belong to the name.
    static func filesInTheWay(_ result: ProcessResult) -> [String] {
        var files: [String] = []
        var listing = false
        for line in result.stderr.components(separatedBy: "\n") {
            if line.hasPrefix("error: ") && line.contains("would be overwritten by merge") {
                listing = true
            } else if listing, line.hasPrefix("\t") {
                files.append(String(line.dropFirst()))
            } else {
                listing = false
            }
        }
        return files
    }

    /// True when anything under `pathspecs` differs between two commits. False when git cannot say.
    func changed(from: String, to: String, under pathspecs: [String]) async -> Bool {
        // Exit status 1 means "they differ"; anything else is "the same" or an error.
        await run(["diff", "--quiet", from, to, "--"] + pathspecs).exitCode == 1
    }

    func commitCount(from: String, to: String) async -> Int? {
        await output(["rev-list", "--count", "\(from)..\(to)"]).flatMap(Int.init)
    }

    /// The commit a local tag points at, or nil when this checkout does not have the tag.
    func tagCommit(_ tag: String) async -> String? {
        await output(["rev-parse", "-q", "--verify", "refs/tags/\(tag)^{commit}"])
    }

    func branchExists(_ branch: String) async -> Bool {
        await run(["rev-parse", "-q", "--verify", "refs/heads/\(branch)"]).succeeded
    }

    /// `git branch -m old new`, then makes `new` track `remote`'s branch of the same name (what GitHub suggests
    /// after a default branch is renamed). The rename carries the branch's other settings along.
    func renameBranch(_ old: String, to new: String, tracking remote: String) async -> ProcessResult {
        let renamed = await run(["branch", "-m", old, new])
        guard renamed.succeeded else { return renamed }
        let remoteSet = await run(["config", "branch.\(new).remote", remote])
        guard remoteSet.succeeded else { return remoteSet }
        return await run(["config", "branch.\(new).merge", "refs/heads/\(new)"])
    }

    /// One string identifying the content of `paths` at `revision` (their git object ids, `-` for a missing
    /// one), so "did these files change" is a string comparison. This is the `sourceTree` of the build
    /// provenance contract that scripts/build-app.sh and scripts/release.sh compute the same way.
    func contentID(of paths: [String], at revision: String) async -> String? {
        var ids: [String] = []
        for path in paths {
            let result = await run(["rev-parse", "-q", "--verify", "\(revision):\(path)"])
            ids.append(result.succeeded ? result.output : "-")
        }
        return ids.allSatisfy { $0 == "-" } ? nil : ids.joined(separator: ",")
    }

    /// Files with staged changes.
    func stagedFiles() async -> [String] {
        let result = await run(["diff", "--cached", "--name-only", "-z"])
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\0").map(String.init)
    }

    /// `git status --porcelain` paths (tracked and untracked) under `path`.
    func changedFiles(under path: String) async -> [String] {
        let result = await run(["status", "--porcelain", "-z", "--untracked-files=all", "--", path])
        guard result.succeeded else { return [] }
        return Self.statusEntries(result.stdout).map(\.path)
    }

    /// The `XY path` entries of `git status --porcelain -z`. With -z git ends every name with a NUL and never quotes
    /// it (without it, a name with a quote, a backslash, a tab or a space comes C-quoted, whatever core.quotePath
    /// says). A rename or a copy (R or C) is followed by its old name, which is skipped.
    private static func statusEntries(_ stdout: String) -> [(code: String, path: String)] {
        var entries: [(code: String, path: String)] = []
        var fields = stdout.split(separator: "\0")[...]
        while let field = fields.popFirst() {
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            entries.append((code, String(field.dropFirst(3))))
            if code.contains("R") || code.contains("C") { _ = fields.popFirst() }
        }
        return entries
    }
}
