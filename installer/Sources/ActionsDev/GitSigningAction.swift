import Foundation
import ShawnCore

/// `git-signing:` sets up SSH commit and tag signing with one public key, plus the allowed-signers
/// file git needs to verify those signatures locally.
struct GitSigningAction: Action {
    /// Public key path as written (`~/.ssh/id_ed25519.pub`).
    let publicKeyPath: String
    let email: String
    let commits: Bool
    let tags: Bool

    static let allowedSignersPath = "~/.config/git/allowed_signers"

    var title: String { "Git commit signing" }
    var subtitle: String? { "SSH key \(publicKeyPath)" }

    static let descriptor = ActionDescriptor(
        kind: "git-signing",
        summary: "Signs git commits and tags with an SSH key (gpg.format ssh) and keeps ~/.config/git/allowed_signers up to date.",
        example: """
        - git-signing: ~/.ssh/id_ed25519.pub
          email: "{{email}}"
        """
    ) { parser in
        let path = parser.primaryString()
        if !path.isEmpty, !path.hasSuffix(".pub") {
            parser.fail("'git-signing' takes the PUBLIC key path (ending in .pub), e.g. ~/.ssh/id_ed25519.pub")
        }
        return GitSigningAction(
            publicKeyPath: path,
            email: parser.options.string("email", default: "{{email}}"),
            commits: parser.options.bool("commits", default: true),
            tags: parser.options.bool("tags", default: true)
        )
    }

    func validate(_ context: ValidationContext) -> [String] {
        context.unknownVariableMessages(in: publicKeyPath, field: "git-signing") + context.unknownVariableMessages(in: email, field: "email")
    }

    /// The signer's email, which is `{{email}}` when the item does not set one: allowed_signers needs that answer.
    func impliedText(_ context: ValidationContext) -> [String] { [email] }

    /// The public key it signs with, which an `ssh-key` item before it may make.
    func usedFiles(_ context: ValidationContext) -> [String] { [publicKeyPath] }

    /// The git settings this item owns, in the order they are written.
    func settings(_ context: ActionContext) -> [(key: String, value: String, type: String?)] {
        [
            ("gpg.format", "ssh", nil),
            ("user.signingkey", context.path(publicKeyPath).path, nil),
            ("commit.gpgsign", commits ? "true" : "false", "bool"),
            ("tag.gpgsign", tags ? "true" : "false", "bool"),
            ("gpg.ssh.allowedSignersFile", context.path(Self.allowedSignersPath).path, nil),
        ]
    }

    private func currentSigners(_ context: ActionContext) -> String {
        FileManager.default.contents(atPath: context.path(Self.allowedSignersPath).path).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private struct Plan {
        /// Settings that read differently now, with every value each one currently has.
        var settings: [(key: String, value: String, current: [String?])] = []
        var signers: String?
    }

    private func plan(_ context: ActionContext, git: String, key: SSHPublicKey) async throws -> Plan {
        var plan = Plan()
        let config = try await GitGlobalConfig.read(git: git, context: context)
        for setting in settings(context) {
            let current = config.values(setting.key)
            // git reads the last value; booleans are compared the way git reads them.
            let reads = setting.type != nil && !current.isEmpty
                ? await GitTool.globalValue(setting.key, typed: setting.type, git: git, context: context)
                : current.last ?? nil
            if reads != setting.value { plan.settings.append((setting.key, setting.value, current)) }
        }
        let current = currentSigners(context)
        let updated = AllowedSigners.updated(current, email: context.expand(email), key: key)
        if updated != current { plan.signers = updated }
        return plan
    }

    func check(_ context: ActionContext) async -> CheckResult {
        guard let git = GitTool.locate(context.environment) else { return .needed("git is not installed yet") }
        let url = context.path(publicKeyPath)
        guard let key = try? SSHPublicKey.read(url, display: context.display(url)) else {
            return .needed("\(context.display(url)) does not exist yet")
        }
        let plan: Plan
        do {
            plan = try await self.plan(context, git: git, key: key)
        } catch {
            return .needed(InstallEngine.describe(error))
        }
        if plan.settings.isEmpty && plan.signers == nil { return .satisfied("signing with \(context.display(url))") }
        var parts = plan.settings.map(\.key)
        if plan.signers != nil { parts.append("allowed_signers") }
        return .needed("to update: \(parts.joined(separator: ", "))")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        guard let git = GitTool.locate(context.environment) else {
            if let outcome = DryRun.whenMissing("git", would: "turn on SSH commit signing", context) { return outcome }
            throw GitTool.missingError(for: "git signing setup")
        }
        let url = context.path(publicKeyPath)
        let key: SSHPublicKey
        do {
            key = try SSHPublicKey.read(url, display: context.display(url))
        } catch let error as ActionError where context.dryRun {
            // In a dry run the ssh-key item before this one only pretended to create the key.
            context.warn("[dry-run] \(error.message); a real run needs it to exist by now")
            return .done("would sign with \(context.display(url)), which does not exist yet")
        }

        let plan = try await self.plan(context, git: git, key: key)
        for setting in plan.settings {
            // Logs what an existing signing setup used, so it can be put back by hand.
            try await GitGlobalConfig.set(setting.key, to: setting.value, current: setting.current, git: git, context: context)
        }
        if let signers = plan.signers {
            try context.files.write(Data(signers.utf8), to: context.path(Self.allowedSignersPath), permissions: 0o644)
        }
        if plan.settings.isEmpty && plan.signers == nil { return .done("already set up") }
        let signed = [commits ? "commits" : nil, tags ? "tags" : nil].compactMap { $0 }.joined(separator: " and ")
        if signed.isEmpty { return .done("SSH signing configured with \(context.display(url)) (off by default)") }
        return .done("signing \(signed) with \(context.display(url))")
    }
}
