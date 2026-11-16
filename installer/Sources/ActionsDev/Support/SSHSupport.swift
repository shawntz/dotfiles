import CryptoKit
import Foundation
import ShawnCore

/// An OpenSSH public key line: `<type> <base64> [comment]`.
struct SSHPublicKey: Equatable, Sendable {
    let type: String
    let base64: String
    let comment: String?

    /// `type base64` without the comment, which is what GitHub stores and what allowed_signers needs.
    var material: String { "\(type) \(base64)" }

    /// Parses one line; nil unless the base64 blob really encodes a key of the stated type.
    init?(line: String) {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard fields.count >= 2, Self.isKeyType(fields[0]), let blob = Data(base64Encoded: fields[1]),
              Self.embeddedType(in: blob) == fields[0] else { return nil }
        type = fields[0]
        base64 = fields[1]
        comment = fields.count > 2 ? fields[2...].joined(separator: " ") : nil
    }

    static func isKeyType(_ text: String) -> Bool {
        text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-sha2-") || text.hasPrefix("sk-ssh-") || text.hasPrefix("sk-ecdsa-")
    }

    /// The key type recorded at the start of the wire-format blob (uint32 length + name).
    private static func embeddedType(in blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, length <= 64, bytes.count >= 4 + length else { return nil }
        return String(bytes: bytes[4..<(4 + length)], encoding: .utf8)
    }

    /// `SHA256:<unpadded base64>`, the form `ssh-keygen -l` prints.
    var fingerprint: String {
        let digest = SHA256.hash(data: Data(base64Encoded: base64) ?? Data())
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    /// Reads a `.pub` file, with errors a person can act on.
    static func read(_ url: URL, display: String) throws -> SSHPublicKey {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ActionError("The public key \(display) does not exist",
                              hint: "Put an ssh-key item for it earlier in the config (or create the key), then run this again")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let key = SSHPublicKey(line: String(line)) else {
            throw ActionError("\(display) is not an OpenSSH public key",
                              hint: "It should be one line like 'ssh-ed25519 AAAA… comment'; point the item at the .pub file")
        }
        return key
    }
}

/// GitHub's SSH host keys, pinned so `known_hosts` is only ever seeded with keys that match
/// the fingerprints GitHub publishes (docs.github.com "GitHub's SSH key fingerprints").
enum GitHubHostKeys {
    static let host = "github.com"
    static let fingerprintsURL = URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints")!

    static let pinned: [String: String] = [
        "ssh-ed25519": "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
        "ecdsa-sha2-nistp256": "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
        "ssh-rsa": "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
    ]

    enum Verdict: Equatable {
        case trusted([SSHPublicKey])
        case rejected(String)
    }

    /// All-or-nothing: one unexpected key means the source cannot be trusted.
    static func verify(_ keys: [SSHPublicKey]) -> Verdict {
        guard !keys.isEmpty else { return .rejected("no host keys were returned") }
        for key in keys where pinned[key.type] != key.fingerprint {
            return .rejected("the \(key.type) key has fingerprint \(key.fingerprint), which is not one GitHub publishes")
        }
        var seen = Set<String>()
        return .trusted(keys.filter { seen.insert($0.material).inserted })
    }

    /// Keys from `gh api meta --jq '.ssh_keys[]'` (one `type base64` per line).
    static func parseMeta(_ text: String) -> [SSHPublicKey] {
        text.split(separator: "\n").compactMap { SSHPublicKey(line: String($0)) }
    }

    /// Keys from `ssh-keyscan` output (`host type base64` lines; `#` lines are comments).
    static func parseKeyscan(_ text: String, host: String) -> [SSHPublicKey] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2, !fields[0].hasPrefix("#"), fields[0] == host else { return nil }
            return SSHPublicKey(line: fields[1])
        }
    }
}

/// A block of lines owned by the installer inside a file the user also edits,
/// delimited by marker comments. Everything outside the markers is kept byte for byte.
struct MarkedBlock {
    let begin: String
    let end: String

    struct Unbalanced: Error, CustomStringConvertible {
        let description: String
    }

    /// The text with `body` placed between the markers: in place when the block exists (wherever the
    /// person has moved it), otherwise appended at the end of the file after a blank line. The end,
    /// because in files where the first value found wins (ssh_config), whatever the file already says
    /// must keep priority over the block.
    func apply(body: [String], to text: String) throws -> String {
        let block = [begin] + body + [end]
        if text.isEmpty { return block.joined(separator: "\n") + "\n" }

        var lines = text.components(separatedBy: "\n")
        let matches = { (line: String, marker: String) in line.trimmingCharacters(in: .whitespacesAndNewlines) == marker }
        let begins = lines.indices.filter { matches(lines[$0], begin) }
        let ends = lines.indices.filter { matches(lines[$0], end) }

        switch (begins.count, ends.count) {
        case (0, 0):
            // Line-wise rather than by Character, where "\r\n" would not count as ending in "\n".
            let endsWithNewline = (text as NSString).hasSuffix("\n")
            let lastLine = endsWithNewline ? lines[lines.count - 2] : lines[lines.count - 1]
            var head = endsWithNewline ? text : text + "\n"
            if !lastLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { head += "\n" }
            return head + block.joined(separator: "\n") + "\n"
        case (1, 1) where begins[0] < ends[0]:
            lines.replaceSubrange(begins[0]...ends[0], with: block)
            return lines.joined(separator: "\n")
        default:
            throw Unbalanced(description: "expected exactly one '\(begin)' line followed by one '\(end)' line, found \(begins.count) and \(ends.count)")
        }
    }

    /// `apply` on a file's bytes, whatever encoding the person saved it in (a Latin-1 comment is not
    /// UTF-8). Each byte is read as one character, so every line outside the block is written back
    /// exactly as it was; the block's own lines go in as UTF-8.
    func apply(body: [String], to data: Data) throws -> Data {
        let bytes = MarkedBlock(begin: Self.byteText(Data(begin.utf8)), end: Self.byteText(Data(end.utf8)))
        do {
            return Self.data(try bytes.apply(body: body.map { Self.byteText(Data($0.utf8)) }, to: Self.byteText(data)))
        } catch let error as Unbalanced {
            // It quotes the markers one character per byte; read those bytes back as the UTF-8 they are.
            throw Unbalanced(description: String(decoding: Self.data(error.description), as: UTF8.self))
        }
    }

    /// One character (U+0000 to U+00FF) per byte; `data(_:)` turns it back into the same bytes.
    private static func byteText(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: data.map { Unicode.Scalar($0) })
        return String(scalars)
    }

    private static func data(_ byteText: String) -> Data {
        Data(byteText.unicodeScalars.map { UInt8($0.value) })
    }
}

/// `~/.config/git/allowed_signers` maintenance (format: `principals [options] keytype base64 [comment]`).
enum AllowedSigners {
    static func line(email: String, key: SSHPublicKey) -> String {
        "\(email) namespaces=\"git\" \(key.material)"
    }

    /// Replaces the entry for this email + key with the canonical line (in place, dropping
    /// duplicates of it) or appends it. Every other line is left exactly as it was.
    static func updated(_ text: String, email: String, key: SSHPublicKey) -> String {
        let wanted = line(email: email, key: key)
        if text.isEmpty { return wanted + "\n" }

        var lines = text.components(separatedBy: "\n")
        var replaced = false
        var index = 0
        while index < lines.count {
            if let entry = Entry(line: lines[index]), entry.material == key.material,
               entry.principals.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                if replaced {
                    lines.remove(at: index)
                    continue
                }
                lines[index] = wanted
                replaced = true
            }
            index += 1
        }
        if replaced { return lines.joined(separator: "\n") }

        var result = text
        if !result.hasSuffix("\n") { result += "\n" }
        return result + wanted + "\n"
    }

    struct Entry {
        let principals: [String]
        let material: String

        init?(line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let tokens = Self.tokenize(trimmed)
            guard tokens.count >= 3,
                  let typeIndex = tokens.indices.dropFirst().first(where: { SSHPublicKey.isKeyType(tokens[$0]) }),
                  typeIndex + 1 < tokens.count else { return nil }
            principals = tokens[0].replacingOccurrences(of: "\"", with: "").split(separator: ",").map(String.init)
            material = "\(tokens[typeIndex]) \(tokens[typeIndex + 1])"
        }

        /// Splits on whitespace outside double quotes (options like `namespaces="git,file"`).
        static func tokenize(_ text: String) -> [String] {
            var tokens: [String] = []
            var current = ""
            var quoted = false
            for character in text {
                if character == "\"" { quoted.toggle() }
                if (character == " " || character == "\t") && !quoted {
                    if !current.isEmpty { tokens.append(current) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { tokens.append(current) }
            return tokens
        }
    }
}
