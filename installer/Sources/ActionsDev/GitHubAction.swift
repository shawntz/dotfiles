import Foundation
import ShawnCore

/// `github:` signs in to a GitHub host with gh's device flow, makes sure the token has the
/// scopes the rest needs, points git at gh for HTTPS credentials, seeds known_hosts and uploads
/// an SSH key for authentication and/or signing. Follows `research/gh-auth-flow.md`.
struct GitHubAction: Action {
    let host: String
    let gitProtocol: String
    let extraScopes: [String]
    /// Public key path as written; nil = no upload.
    let keyPath: String?
    /// `authentication` and/or `signing`.
    let uploadTypes: [String]
    let keyTitle: String
    let seedKnownHosts: Bool
    let setupGit: Bool
    /// How long the person gets to finish the browser sign-in (GitHub's device codes live 15 minutes).
    var deviceFlowTimeout: TimeInterval = 15 * 60
    /// gh gives up by itself when the code expires. It is only stopped if it is still running this
    /// long after that, so its own clean exit is normally what ends an abandoned sign-in.
    var deviceFlowGrace: TimeInterval = 60

    static let uploadKinds = ["authentication", "signing"]

    var title: String { "GitHub (\(host))" }

    var subtitle: String? {
        guard keyPath != nil, !uploadTypes.isEmpty else { return "sign in with gh (\(gitProtocol))" }
        return "sign in with gh (\(gitProtocol)), upload \(uploadTypes.joined(separator: " + ")) key"
    }

    static let descriptor = ActionDescriptor(
        kind: "github",
        summary: "Signs in to GitHub with gh (one-time code in the browser), adds missing token scopes, runs gh auth setup-git, seeds known_hosts and uploads an SSH key for authentication and signing.",
        example: """
        - github: github.com
          protocol: ssh
          key: ~/.ssh/id_ed25519.pub
          upload: [authentication, signing]
        """
    ) { parser in
        let host = parser.primaryString()
        if !host.isEmpty, host.contains(where: { "/:@ \t".contains($0) }) {
            parser.fail("'github' takes a host name such as github.com (no scheme, user or path), got '\(host)'")
        }
        let gitProtocol = parser.options.oneOf("protocol", ["ssh", "https"], default: "ssh")
        let scopes = parser.options.stringList("scopes").flatMap(OAuthScopes.split)
        let key = parser.options.string("key")
        var upload = parser.options.stringList("upload")
        for type in upload where !uploadKinds.contains(type) {
            parser.options.error("'upload' entries must be authentication or signing (got '\(type)')", key: "upload")
        }
        if parser.options.has("upload") {
            if key == nil, !upload.isEmpty { parser.options.error("'upload' needs 'key:' (the public key to upload)", key: "upload") }
        } else if key != nil {
            upload = uploadKinds
        }
        if let key, !key.hasSuffix(".pub") {
            parser.options.error("'key' must be the PUBLIC key (ending in .pub), e.g. ~/.ssh/id_ed25519.pub", key: "key")
        }
        return GitHubAction(
            host: host,
            gitProtocol: gitProtocol,
            extraScopes: scopes,
            keyPath: key,
            uploadTypes: upload.filter(uploadKinds.contains),
            keyTitle: parser.options.string("title", default: "{{hostname}}"),
            seedKnownHosts: parser.options.bool("known_hosts", default: true),
            setupGit: parser.options.bool("setup_git", default: true)
        )
    }

    func validate(_ context: ValidationContext) -> [String] {
        context.unknownVariableMessages(in: host, field: "github")
            + context.unknownVariableMessages(in: keyPath ?? "", field: "key")
            + context.unknownVariableMessages(in: keyTitle, field: "title")
    }

    // MARK: Scopes

    /// What the token must allow: uploading needs write:*, and write:* also covers the listing pre-check.
    var neededScopes: [String] {
        var scopes: [String] = []
        if keyPath != nil && uploadTypes.contains("authentication") { scopes.append("write:public_key") }
        if keyPath != nil && uploadTypes.contains("signing") { scopes.append("write:ssh_signing_key") }
        return scopes + extraScopes
    }

    /// What to ask for: admin:* matches gh's own advice and lets stale keys be deleted later.
    func requestedScopes(for needed: [String]) -> [String] {
        let mapped = needed.map { scope -> String in
            switch scope {
            case "write:public_key": return "admin:public_key"
            case "write:ssh_signing_key": return "admin:ssh_signing_key"
            default: return scope
            }
        }
        var seen = Set<String>()
        return mapped.filter { !OAuthScopes.ghDefaults.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Probes

    private var isGitHubDotCom: Bool { host.caseInsensitiveCompare(GitHubHostKeys.host) == .orderedSame }

    private func knownHostsURL(_ context: ActionContext) -> URL { context.path("~/.ssh/known_hosts") }

    private func hostIsKnown(_ context: ActionContext) async -> Bool {
        let url = knownHostsURL(context)
        guard context.files.exists(url) else { return false }
        // -F understands hashed entries; it only reads the file.
        let probe = Command(SSHKeyAction.keygen, ["-F", host, "-f", url.path]).timeout(30).readOnly()
        return (try? await context.commands.run(probe))?.succeeded == true
    }

    private func credentialHelperConfigured(git: String, context: ActionContext) async -> Bool {
        await GitTool.globalValues("credential.https://\(host).helper", git: git, context: context)
            .contains { $0.contains("auth git-credential") }
    }

    private func publicKey(_ context: ActionContext) throws -> SSHPublicKey? {
        guard let keyPath, !uploadTypes.isEmpty else { return nil }
        let url = context.path(keyPath)
        return try SSHPublicKey.read(url, display: context.display(url))
    }

    // MARK: Check

    func check(_ context: ActionContext) async -> CheckResult {
        guard let gh = GitHubCLI.locate(context.environment) else { return .needed("gh is not installed yet") }
        let account: GitHubAccount
        switch await gh.authState(host: host, context: context) {
        case .account(let found) where found.isSignedIn: account = found
        case .account(let found): return .needed("the saved \(host) login does not work (\(found.error ?? found.state))")
        case .signedOut: return .needed("not signed in to \(host)")
        case .unreadable(let why): return .needed("could not read gh's sign-in state: \(why)")
        }
        let missing = OAuthScopes.missing(required: neededScopes, granted: account.scopes)
        if !missing.isEmpty { return .needed("the \(host) token lacks \(missing.joined(separator: ", "))") }
        if account.gitProtocol != gitProtocol { return .needed("gh's git protocol for \(host) is not \(gitProtocol)") }
        if setupGit {
            guard let git = GitTool.locate(context.environment) else { return .needed("git is not installed yet") }
            if !(await credentialHelperConfigured(git: git, context: context)) { return .needed("git does not use gh for \(host) credentials yet") }
        }
        if seedKnownHosts && isGitHubDotCom {
            let known = await hostIsKnown(context)
            if !known { return .needed("\(host) is not in ~/.ssh/known_hosts") }
        }
        if keyPath != nil && !uploadTypes.isEmpty {
            guard let key = try? publicKey(context) else { return .needed("the public key does not exist yet") }
            for type in uploadTypes {
                guard let registered = await gh.registeredKeys(host: host, type: type, context: context), registered.contains(key.material) else {
                    return .needed("the \(type) key is not on \(host) yet")
                }
            }
        }
        return .satisfied("signed in as \(account.login ?? "?")")
    }

    // MARK: Run

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        guard let gh = GitHubCLI.locate(context.environment) else {
            if let outcome = DryRun.whenMissing("gh", would: "sign in to GitHub (\(host)) and set up its SSH key", context) { return outcome }
            throw GitHubCLI.missingError
        }
        var did: [String] = []
        var attention: [String] = []

        switch try await ensureSignedIn(gh, context: context) {
        case .timedOut:
            context.followUp("Sign in to GitHub (\(host))",
                             detail: "The one-time code expired before the sign-in finished. Run the installer again for a new code, or run `gh auth login --hostname \(host) --web --git-protocol \(gitProtocol)` in a terminal.",
                             url: URL(string: "https://\(host)/login/device"))
            return .needsAttention("GitHub sign-in was not finished within \(TimeLimit.describe(deviceFlowTimeout))")
        case .signedIn(let note):
            if let note { did.append(note) }
        }

        if setupGit { try await configureGitCredentials(gh, context: context, did: &did, attention: &attention) }
        if seedKnownHosts { try await seedHostKeys(gh, context: context, did: &did, attention: &attention) }
        try await uploadKeys(gh, context: context, did: &did)

        let summary = did.isEmpty ? "already set up" : did.joined(separator: "; ")
        if !attention.isEmpty { return .needsAttention(([summary] + attention).joined(separator: "; ")) }
        return .done(summary)
    }

    private enum SignIn {
        case signedIn(String?)
        case timedOut
    }

    /// Signs in (or adds missing scopes) and sets gh's git protocol for the host.
    private func ensureSignedIn(_ gh: GitHubCLI, context: ActionContext) async throws -> SignIn {
        var note: String?
        let state = await gh.authState(host: host, context: context, useCache: false)
        var account: GitHubAccount?

        switch state {
        case .unreadable(let why):
            throw ActionError("Could not read gh's sign-in state for \(host): \(why)",
                              hint: "Update gh (`brew upgrade gh`), then run this again")
        case .account(let found) where found.state == "timeout":
            throw ActionError("gh could not reach \(host) to check the saved login",
                              hint: "Check the internet connection, then run this again")
        case .account(let found) where found.isSignedIn:
            account = found
        case .account, .signedOut:
            account = nil
        }

        if let current = account {
            let missing = OAuthScopes.missing(required: neededScopes, granted: current.scopes)
            if !missing.isEmpty {
                let arguments = ["auth", "refresh", "--hostname", host, "--clipboard=false", "--scopes", requestedScopes(for: missing).joined(separator: ",")]
                switch try await deviceFlow(arguments, gh: gh, context: context, purpose: "permission update") {
                case .dryRun: return .signedIn("would add \(requestedScopes(for: missing).joined(separator: ", ")) to the \(host) login")
                case .timedOut: return .timedOut
                case .finished: note = "added \(requestedScopes(for: missing).joined(separator: ", ")) to the \(host) login"
                }
                account = nil
            }
        } else {
            var arguments = ["auth", "login", "--hostname", host, "--web", "--git-protocol", gitProtocol, "--skip-ssh-key", "--clipboard=false"]
            let scopes = requestedScopes(for: neededScopes)
            if !scopes.isEmpty { arguments += ["--scopes", scopes.joined(separator: ",")] }
            switch try await deviceFlow(arguments, gh: gh, context: context, purpose: "sign-in") {
            case .dryRun: return .signedIn("would sign in to \(host)")
            case .timedOut: return .timedOut
            case .finished(let login): note = "signed in as \(login ?? "?")"
            }
        }

        // After a login or refresh, believe gh's stored state rather than its exit code.
        let verified: GitHubAccount
        if let unchanged = account {
            verified = unchanged
        } else {
            await GitHubCLI.invalidate(host: host, context: context)
            guard case .account(let fresh) = await gh.authState(host: host, context: context, useCache: false), fresh.isSignedIn else {
                throw ActionError("gh finished, but \(host) still has no working login",
                                  hint: "Run `gh auth status --hostname \(host)` to see why, then run this again")
            }
            let stillMissing = OAuthScopes.missing(required: neededScopes, granted: fresh.scopes)
            guard stillMissing.isEmpty else {
                throw ActionError("The \(host) login is still missing \(stillMissing.joined(separator: ", "))",
                                  hint: "Run this again and approve every permission GitHub asks for")
            }
            verified = fresh
        }
        if verified.gitProtocol != gitProtocol {
            try await context.commands.runChecked(gh.command(["config", "set", "--host", host, "git_protocol", gitProtocol]).timeout(30))
            await GitHubCLI.invalidate(host: host, context: context)
        }
        return .signedIn(note)
    }

    private enum DeviceFlow {
        case finished(login: String?)
        case dryRun
        case timedOut
    }

    /// Runs `gh auth login|refresh`, surfacing the one-time code and URL as soon as gh prints them.
    private func deviceFlow(_ arguments: [String], gh: GitHubCLI, context: ActionContext, purpose: String) async throws -> DeviceFlow {
        let watcher = DeviceFlowWatcher()
        let host = self.host
        let waiting = TimeLimit.describe(deviceFlowTimeout)
        let command = gh.command(arguments).timeout(deviceFlowTimeout + deviceFlowGrace).watching { line, _ in
            guard let prompt = watcher.feed(line) else { return }
            context.attention(Self.attention(for: prompt, host: host, waiting: waiting))
        }
        // However this ends (finished, expired, failed, stopped), the code is no longer worth showing.
        defer { context.attention(nil) }

        let result: CommandResult
        do {
            result = try await context.commands.run(command)
        } catch let error as CommandError where error.isTimeout {
            // gh hung past its own deadline and was stopped; the code it showed has expired either way.
            return .timedOut
        }
        if result.wasDryRun { return .dryRun }

        if watcher.savedInPlainText {
            context.warn("gh could not use the keychain and saved the \(host) token in plain text in ~/.config/gh/hosts.yml")
        }
        guard result.succeeded else {
            let failure = watcher.failure ?? result.tail(3)
            // Nobody finished the sign-in in time: gh's own deadline, or GitHub's answer for an expired code.
            if Self.codeExpired(failure) { return .timedOut }
            throw ActionError("GitHub \(purpose) for \(host) failed: \(failure)",
                              hint: "Run this again for a new code, and approve the request in the browser with the right GitHub account")
        }
        return .finished(login: watcher.login)
    }

    /// gh's words for a one-time code that ran out: its local deadline, or GitHub's `expired_token` error.
    static func codeExpired(_ failure: String) -> Bool {
        failure.contains("context deadline exceeded") || failure.contains("expired_token")
    }

    static func attention(for prompt: DeviceFlowWatcher.Prompt, host: String, waiting: String) -> Attention {
        let message: String
        if let code = prompt.code {
            let place = prompt.url?.absoluteString ?? "https://\(host)/login/device"
            message = "Enter this code at \(place) and authorize GitHub CLI. Waiting up to \(waiting)."
            return Attention(title: "Sign in to GitHub (\(host))", message: message, code: code, url: prompt.url)
        }
        message = "Finish signing in to \(host) in the browser. Waiting up to \(waiting)."
        return Attention(title: "Sign in to GitHub (\(host))", message: message, code: nil, url: prompt.url)
    }

    // MARK: Steps after sign-in

    private func configureGitCredentials(_ gh: GitHubCLI, context: ActionContext, did: inout [String], attention: inout [String]) async throws {
        guard let git = GitTool.locate(context.environment) else {
            context.warn("git is not available yet, so `gh auth setup-git` was skipped")
            context.followUp("Let git use gh for \(host)", detail: "Once git is installed, run `gh auth setup-git --hostname \(host)`.")
            attention.append("gh auth setup-git skipped (no git)")
            return
        }
        if await credentialHelperConfigured(git: git, context: context) { return }
        let result = try await context.commands.runChecked(gh.command(["auth", "setup-git", "--hostname", host]).timeout(60))
        if !result.wasDryRun { did.append("git uses gh for \(host) credentials") }
    }

    private func seedHostKeys(_ gh: GitHubCLI, context: ActionContext, did: inout [String], attention: inout [String]) async throws {
        guard isGitHubDotCom else {
            // No pinned fingerprints for other hosts, so they are never trusted automatically.
            guard gitProtocol == "ssh", !(await hostIsKnown(context)) else { return }
            context.followUp("Add \(host)'s SSH host key",
                             detail: "Compare the fingerprints \(host) publishes with `ssh-keyscan \(host) | ssh-keygen -lf -`, then append the matching lines to ~/.ssh/known_hosts.",
                             url: URL(string: "https://\(host)/"))
            attention.append("\(host) host key needs checking by hand")
            return
        }
        if await hostIsKnown(context) { return }
        if context.dryRun {
            context.info("[dry-run] would add \(host)'s SSH host keys to ~/.ssh/known_hosts after checking their fingerprints")
            return
        }

        var keys: [SSHPublicKey] = []
        let meta = gh.command(["api", "--hostname", host, "meta", "--jq", ".ssh_keys[]"]).timeout(60).readOnly()
        if let result = try? await context.commands.run(meta), result.succeeded {
            keys = GitHubHostKeys.parseMeta(result.stdout)
        }
        if keys.isEmpty {
            let scan = Command("ssh-keyscan", ["-t", "ed25519,ecdsa,rsa", host]).timeout(20).readOnly()
            if let result = try? await context.commands.run(scan), result.succeeded {
                keys = GitHubHostKeys.parseKeyscan(result.stdout, host: host)
            }
        }

        switch GitHubHostKeys.verify(keys) {
        case .rejected(let reason):
            context.warn("Not adding \(host) to ~/.ssh/known_hosts: \(reason)")
            context.followUp("Check GitHub's SSH host keys",
                             detail: "The installer did not trust the keys it was given (\(reason)). Compare with GitHub's published fingerprints before connecting over SSH.",
                             url: GitHubHostKeys.fingerprintsURL)
            attention.append("\(host) host keys not added (\(reason))")
        case .trusted(let trusted):
            let url = knownHostsURL(context)
            try context.files.ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
            var text = FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += trusted.map { "\(host) \($0.material)" }.joined(separator: "\n") + "\n"
            try context.files.write(Data(text.utf8), to: url, permissions: 0o600)
            did.append("added \(host) to known_hosts")
        }
    }

    private func uploadKeys(_ gh: GitHubCLI, context: ActionContext, did: inout [String]) async throws {
        guard let keyPath, !uploadTypes.isEmpty else { return }
        let url = context.path(keyPath)
        let key: SSHPublicKey
        do {
            guard let found = try publicKey(context) else { return }
            key = found
        } catch let error as ActionError where context.dryRun {
            context.warn("[dry-run] \(error.message); a real run needs it to exist by now")
            return
        }

        let title = context.expand(keyTitle)
        var uploaded: [String] = []
        for type in uploadTypes {
            if let registered = await gh.registeredKeys(host: host, type: type, context: context), registered.contains(key.material) {
                context.info("\(context.display(url)) is already on \(host) as a\(type == "authentication" ? "n" : "") \(type) key")
                continue
            }
            let add = gh.command(["ssh-key", "add", url.path, "--type", type, "--title", title], host: host).timeout(120)
            let result = try await context.commands.run(add, hintIfTimedOut: "Check the internet connection, then run this again")
            if result.wasDryRun { continue }
            guard result.succeeded else {
                let scope = type == "signing" ? "admin:ssh_signing_key" : "admin:public_key"
                throw ActionError("Uploading \(context.display(url)) to \(host) as a \(type) key failed: \(result.tail(3))",
                                  hint: "Check the login has the \(scope) scope (`gh auth refresh -h \(host) -s \(scope)`), then run this again")
            }
            await context.shared.invalidate("dev.gh.keys.\(host.lowercased()).\(type)")
            uploaded.append(type)
        }
        if !uploaded.isEmpty { did.append("uploaded \(uploaded.joined(separator: " + ")) key") }
    }
}
