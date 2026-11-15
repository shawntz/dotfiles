import Foundation
import ShawnCore

/// One account entry from `gh auth status --json hosts`.
struct GitHubAccount: Equatable, Sendable {
    /// `success`, `error` or `timeout`.
    let state: String
    let login: String?
    let scopes: [String]
    let gitProtocol: String?
    let error: String?

    var isSignedIn: Bool { state == "success" }
}

/// What `gh` says about one host.
enum GitHubAuthState: Equatable, Sendable {
    /// gh ran but its answer could not be read (too old for `--json`, crashed, ...).
    case unreadable(String)
    case signedOut
    case account(GitHubAccount)
}

enum GitHubStatusParser {
    private struct Document: Decodable {
        let hosts: [String: [Entry]]
    }

    private struct Entry: Decodable {
        let state: String
        let active: Bool?
        let login: String?
        let scopes: String?
        let gitProtocol: String?
        let error: String?
    }

    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    /// The active account for `host` (nil when gh knows no account there).
    static func parse(_ json: String, host: String) throws -> GitHubAccount? {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        } catch {
            throw Malformed(description: "unexpected `gh auth status --json hosts` output: \(String(json.prefix(200)))")
        }
        let entries = document.hosts.first(where: { $0.key.caseInsensitiveCompare(host) == .orderedSame })?.value ?? []
        guard let entry = entries.first(where: { $0.active == true }) ?? entries.first else { return nil }
        return GitHubAccount(
            state: entry.state,
            login: entry.login.flatMap { $0.isEmpty ? nil : $0 },
            scopes: OAuthScopes.split(entry.scopes ?? ""),
            gitProtocol: entry.gitProtocol.flatMap { $0.isEmpty ? nil : $0 },
            error: entry.error
        )
    }
}

/// GitHub OAuth scope arithmetic: `admin:x` implies `write:x` and `read:x`, `write:x` implies `read:x`,
/// and a few top-level scopes cover their sub-scopes (`repo` → `repo:status`, `public_repo`, ...).
enum OAuthScopes {
    /// Always granted by `gh auth login`, so never worth asking for.
    static let ghDefaults: Set<String> = ["repo", "read:org", "gist"]

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    static func covers(_ granted: [String], _ required: String) -> Bool {
        let have = Set(granted)
        if have.contains(required) { return true }
        let parts = required.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let (level, resource) = (parts[0], parts[1])
            if level == "read" && (have.contains("write:\(resource)") || have.contains("admin:\(resource)")) { return true }
            if level == "write" && have.contains("admin:\(resource)") { return true }
            if have.contains(parts[0]) && ["repo", "user", "project", "codespace"].contains(parts[0]) { return true }
        }
        if required == "public_repo" && have.contains("repo") { return true }
        return false
    }

    static func missing(required: [String], granted: [String]) -> [String] {
        var seen = Set<String>()
        return required.filter { seen.insert($0).inserted && !covers(granted, $0) }
    }
}

/// Picks the one-time code, URL and result out of `gh auth login|refresh` output, one line at a time.
///
/// Fed from the process pump thread, read afterwards from the action, hence the lock.
final class DeviceFlowWatcher: @unchecked Sendable {
    struct Prompt: Equatable {
        let code: String?
        let url: URL?
    }

    private static let codePattern = try! NSRegularExpression(pattern: "(?:First copy your one-time code: |One-time code \\()([A-Z0-9]{4}-[A-Z0-9]{4})")
    private static let urlPattern = try! NSRegularExpression(pattern: "Open this URL to continue in your web browser: (https?://\\S+)")
    private static let loginPattern = try! NSRegularExpression(pattern: "Logged in as (\\S+)")
    private static let failurePattern = try! NSRegularExpression(pattern: "^failed to authenticate via web browser: (.*)$")
    private static let envTokenPattern = try! NSRegularExpression(pattern: "The value of the (\\S+) environment variable is being used for authentication")
    private static let networkPattern = try! NSRegularExpression(pattern: "^error connecting to (\\S+)")

    private let lock = NSLock()
    private var code: String?
    private var url: URL?
    private var _login: String?
    private var _failure: String?
    private var _plainText = false

    var login: String? { lock.withLock { _login } }
    var failure: String? { lock.withLock { _failure } }
    var savedInPlainText: Bool { lock.withLock { _plainText } }

    /// Returns the new prompt when this line changed what the person has to do.
    func feed(_ rawLine: String) -> Prompt? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return lock.withLock {
            if let match = Self.capture(Self.codePattern, in: line), match != code {
                code = match
                return Prompt(code: code, url: url)
            }
            if let match = Self.capture(Self.urlPattern, in: line), let parsed = URL(string: match), parsed != url {
                url = parsed
                return Prompt(code: code, url: url)
            }
            if let match = Self.capture(Self.loginPattern, in: line) {
                _login = match
            } else if line.hasSuffix("Authentication credentials saved in plain text") {
                _plainText = true
            } else if let match = Self.capture(Self.failurePattern, in: line) {
                _failure = match
            } else if let match = Self.capture(Self.envTokenPattern, in: line) {
                _failure = "\(match) is set, so gh will not store a login (unset it and run again)"
            } else if let match = Self.capture(Self.networkPattern, in: line) {
                _failure = "could not connect to \(match); check the internet connection"
            }
            return nil
        }
    }

    private static func capture(_ pattern: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = pattern.firstMatch(in: line, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[captured])
    }
}

/// Runs `gh` with the environment `research/gh-auth-flow.md` prescribes: prompts, spinners,
/// colour and update checks off; tokens and host overrides from the parent removed.
struct GitHubCLI {
    let executable: String
    let environment: SystemEnvironment

    static let fixedEnvironment = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_SPINNER_DISABLED": "1",
        "NO_COLOR": "1",
    ]
    static let removedVariables = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
                                   "GH_HOST", "GH_FORCE_TTY", "CLICOLOR_FORCE", "GH_CONFIG_DIR"]

    static func locate(_ environment: SystemEnvironment) -> GitHubCLI? {
        environment.resolveExecutable("gh").map { GitHubCLI(executable: $0, environment: environment) }
    }

    static let missingError = ActionError("The GitHub CLI (gh) is not installed",
                                          hint: "Install it with the Homebrew packages step (brew: gh), then run this again")

    /// `host` sets `GH_HOST`, which is how `gh ssh-key` picks a host (it has no --hostname flag).
    func command(_ arguments: [String], host: String? = nil) -> Command {
        var variables = Self.fixedEnvironment
        if let host { variables["GH_HOST"] = host }
        // gh runs git for `auth setup-git`, so the same isolation applies.
        return ToolCommand.make(executable, arguments, unset: Self.removedVariables + GitTool.isolationVariables(environment),
                                set: variables, display: "gh")
    }

    private static func cacheKey(_ host: String) -> String { "dev.gh.auth.\(host.lowercased())" }

    static func invalidate(host: String, context: ActionContext) async {
        await context.shared.invalidate(cacheKey(host))
        await context.shared.invalidate(prefix: "dev.gh.keys.\(host.lowercased()).")
    }

    /// Sign-in state for one host. Only clean answers are cached (a later step may install gh or sign in).
    func authState(host: String, context: ActionContext, useCache: Bool = true) async -> GitHubAuthState {
        let key = Self.cacheKey(host)
        if useCache, let cached = await context.shared.value(key, as: GitHubAuthState.self) { return cached }
        let probe = command(["auth", "status", "--json", "hosts", "--active", "--hostname", host]).timeout(60).readOnly()
        let state: GitHubAuthState
        do {
            let result = try await context.commands.run(probe)
            guard result.succeeded else { return .unreadable(result.tail(3)) }
            if let account = try GitHubStatusParser.parse(result.stdout, host: host) {
                state = .account(account)
            } else {
                state = .signedOut
            }
        } catch {
            return .unreadable(InstallEngine.describe(error))
        }
        await context.shared.set(key, state)
        return state
    }

    /// Key material (`type base64`) registered on the account, or nil when the list cannot be read.
    func registeredKeys(host: String, type: String, context: ActionContext) async -> Set<String>? {
        let key = "dev.gh.keys.\(host.lowercased()).\(type)"
        if let cached = await context.shared.value(key, as: Set<String>.self) { return cached }
        let endpoint = type == "signing" ? "user/ssh_signing_keys?per_page=100" : "user/keys?per_page=100"
        let probe = command(["api", "--hostname", host, "--paginate", endpoint, "--jq", ".[].key"]).timeout(60).readOnly()
        guard let result = try? await context.commands.run(probe), result.succeeded else { return nil }
        let keys = Set(result.stdout.split(separator: "\n").compactMap { SSHPublicKey(line: String($0))?.material })
        await context.shared.set(key, keys)
        return keys
    }
}
