import Foundation
import ShawnCore

/// `ssh-key:` makes sure an SSH key exists (never replacing one) and keeps a marked
/// block for it in `~/.ssh/config`.
struct SSHKeyAction: Action {
    /// Private key path as written (`~/.ssh/id_ed25519`).
    let path: String
    let type: String
    let comment: String
    let manageConfig: Bool
    let hosts: [String]

    static let keygen = "/usr/bin/ssh-keygen"
    static let types = ["ed25519", "ecdsa", "rsa"]

    var title: String { path }
    var subtitle: String? { manageConfig ? "\(type) key + ~/.ssh/config" : "\(type) key" }

    static let descriptor = ActionDescriptor(
        kind: "ssh-key",
        summary: "Creates an SSH key if there is none (never overwrites) and keeps a marked block for it in ~/.ssh/config "
            + "(added at the end, so the settings already in the file keep priority; later it is updated wherever it is).",
        example: """
        - ssh-key: ~/.ssh/id_ed25519
          comment: "{{email}}"
          hosts: [github.com]
        """
    ) { parser in
        let path = parser.primaryString()
        let type = parser.options.oneOf("type", types, default: "ed25519")
        let comment = parser.options.string("comment", default: "{{email}}")
        let manageConfig = parser.options.bool("config", default: true)
        let hosts = parser.options.stringList("hosts")
        for host in hosts where host.isEmpty || host.contains(where: { $0 == " " || $0 == "\t" }) {
            parser.options.error("'hosts' entries must be host names without spaces (got '\(host)')", key: "hosts")
        }
        if path.hasSuffix(".pub") {
            parser.fail("'ssh-key' takes the PRIVATE key path (e.g. ~/.ssh/id_ed25519); the .pub file is written next to it")
        }
        return SSHKeyAction(path: path, type: type, comment: comment, manageConfig: manageConfig, hosts: hosts)
    }

    func validate(_ context: ValidationContext) -> [String] {
        context.unknownVariableMessages(in: path, field: "ssh-key") + context.unknownVariableMessages(in: comment, field: "comment")
    }

    // MARK: Paths

    private func keyURL(_ context: ActionContext) -> URL { context.path(path) }
    private func publicKeyURL(_ context: ActionContext) -> URL {
        let key = keyURL(context)
        return key.deletingLastPathComponent().appendingPathComponent(key.lastPathComponent + ".pub")
    }
    private func sshDirectory(_ context: ActionContext) -> URL { context.path("~/.ssh") }
    private func configURL(_ context: ActionContext) -> URL { context.path("~/.ssh/config") }

    // MARK: ~/.ssh/config block

    func markers(_ context: ActionContext) -> MarkedBlock {
        let name = keyURL(context).tildePath(home: context.environment.home)
        return MarkedBlock(begin: "# >>> shawn-dotfiles ssh-key \(name) >>>", end: "# <<< shawn-dotfiles ssh-key \(name) <<<")
    }

    /// The block goes at the end of ~/.ssh/config (see `MarkedBlock.apply`): ssh takes the first value
    /// it finds for each option, so the person's own settings, `IgnoreUnknown` included, stay in charge
    /// and these act as defaults. It starts with a `Host` line, so it never joins the stanza above it.
    func blockBody(_ context: ActionContext) -> [String] {
        let identity = Self.configValue(keyURL(context).tildePath(home: context.environment.home))
        var lines = ["# Managed by Shawn's Dotfiles: changes inside these markers are replaced on the next install."]
        for host in hosts {
            lines += ["Host \(host)", "  User git", "  IdentitiesOnly yes", ""]
        }
        lines += [
            "Host *",
            "  IgnoreUnknown UseKeychain",
            "  AddKeysToAgent yes",
            "  UseKeychain yes",
            "  IdentityFile \(identity)",
        ]
        return lines
    }

    private static func configValue(_ text: String) -> String {
        text.contains(" ") ? "\"\(text)\"" : text
    }

    private func currentConfig(_ context: ActionContext) throws -> Data {
        let url = configURL(context)
        guard context.files.exists(url) else { return Data() }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ActionError("Cannot read \(context.display(url))", hint: "Check its permissions (it should be readable by you, mode 600)")
        }
        return data
    }

    /// The config file as it should be, or nil when it already is. Bytes, not text, so the person's
    /// lines stay exactly as they are whatever encoding they were saved in.
    private func updatedConfig(_ context: ActionContext) throws -> Data? {
        let current = try currentConfig(context)
        let updated: Data
        do {
            updated = try markers(context).apply(body: blockBody(context), to: current)
        } catch let error as MarkedBlock.Unbalanced {
            throw ActionError("\(context.display(configURL(context))) has a damaged Shawn's Dotfiles block: \(error.description)",
                              hint: "Delete the partial block (the lines between and including the markers), then run this again")
        }
        return updated == current ? nil : updated
    }

    // MARK: Action

    func check(_ context: ActionContext) async -> CheckResult {
        let key = keyURL(context)
        guard context.files.exists(key) else { return .needed("no key at \(context.display(key)) yet") }
        guard context.files.exists(publicKeyURL(context)) else { return .needed("\(context.display(publicKeyURL(context))) is missing") }
        if manageConfig {
            do {
                if try updatedConfig(context) != nil { return .needed("~/.ssh/config block needs updating") }
            } catch {
                return .needed(InstallEngine.describe(error))
            }
        }
        return .satisfied("key exists")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let key = keyURL(context)
        let publicKey = publicKeyURL(context)
        var did: [String] = []

        try context.files.ensureDirectory(sshDirectory(context), permissions: 0o700)

        if context.files.exists(key) {
            if !context.files.exists(publicKey) {
                try await restorePublicKey(context, key: key, publicKey: publicKey)
                did.append("\(context.dryRun ? "would restore" : "restored") \(context.display(publicKey))")
            } else {
                context.info("\(context.display(key)) already exists; leaving it alone")
            }
        } else {
            try await generate(context, key: key, publicKey: publicKey)
            did.append("\(context.dryRun ? "would create" : "created") \(context.display(key))")
        }

        if manageConfig, let updated = try updatedConfig(context) {
            try context.files.write(updated, to: configURL(context), permissions: 0o600)
            did.append("\(context.dryRun ? "would update" : "updated") ~/.ssh/config")
        }
        return .done(did.isEmpty ? "already set up" : did.joined(separator: "; "))
    }

    private func generate(_ context: ActionContext, key: URL, publicKey: URL) async throws {
        // A .pub without its private key is stale; ssh-keygen would silently overwrite it.
        if context.files.exists(publicKey) { try context.files.backUp(publicKey) }
        var arguments = ["-t", type, "-a", "100"]
        if type == "rsa" { arguments += ["-b", "4096"] }
        arguments += ["-N", "", "-C", context.expand(comment), "-f", key.path, "-q"]
        let result = try await context.commands.run(Command(Self.keygen, arguments).timeout(120))
        if result.wasDryRun { return }
        guard result.succeeded, context.files.exists(key), context.files.exists(publicKey) else {
            throw ActionError("ssh-keygen could not create \(context.display(key)): \(result.tail(3))",
                              hint: "Check that \(context.display(key.deletingLastPathComponent())) is writable, then run this again")
        }
        try setPermissions(0o600, on: key, context: context)
        try setPermissions(0o644, on: publicKey, context: context)
    }

    /// Derives the missing .pub from an unencrypted private key (`ssh-keygen -y` only reads the key).
    private func restorePublicKey(_ context: ActionContext, key: URL, publicKey: URL) async throws {
        let probe = Command(Self.keygen, ["-y", "-P", "", "-f", key.path]).timeout(30).readOnly()
        let result = try await context.commands.run(probe)
        guard result.succeeded, SSHPublicKey(line: result.stdout) != nil else {
            throw ActionError("\(context.display(key)) exists but \(context.display(publicKey)) is missing and cannot be derived (the key may have a passphrase)",
                              hint: "Run `ssh-keygen -y -f \(context.display(key)) > \(context.display(publicKey))` yourself, then run this again")
        }
        try context.files.write(Data(result.stdout.utf8), to: publicKey, permissions: 0o644)
    }

    private func setPermissions(_ mode: Int, on url: URL, context: ActionContext) throws {
        guard !context.dryRun, context.files.permissions(of: url) != mode else { return }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
