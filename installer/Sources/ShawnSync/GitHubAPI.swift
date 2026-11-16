import CryptoKit
import Foundation

/// A point in time every request of one fetch must finish by.
struct Deadline: Sendable {
    let seconds: TimeInterval
    let end: Date

    init(seconds: TimeInterval, start: Date = Date()) {
        self.seconds = seconds
        self.end = start.addingTimeInterval(seconds)
    }

    /// Time left for the next request; throws once the deadline has passed.
    func remaining() throws -> TimeInterval {
        let left = end.timeIntervalSinceNow
        guard left > 0 else { throw RemoteConfigError.timedOut(seconds: seconds) }
        return left
    }
}

/// `GET /repos/{repo}/git/trees/{commit}?recursive=1`, the fields we use.
struct GitTree: Decodable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        let path: String
        let mode: String
        let type: String
        let sha: String
        let size: Int?
    }

    let sha: String?
    let tree: [Entry]
    let truncated: Bool?
}

/// The few GitHub endpoints remote config uses, unauthenticated.
struct GitHubAPI: Sendable {
    static let apiBase = "https://api.github.com"
    static let rawBase = "https://raw.githubusercontent.com"
    static let apiVersion = "2022-11-28"

    enum CommitAnswer: Equatable, Sendable {
        case commit(String, etag: String?)
        /// The `If-None-Match` ETag still matches: the ref has not moved.
        case notModified
    }

    let repo: String
    let transport: any HTTPTransport
    let deadline: Deadline

    // MARK: URLs

    func commitURL(ref: String) -> URL {
        URL(string: "\(Self.apiBase)/repos/\(repo)/commits/\(Self.encodePath(ref))")!
    }

    func treeURL(commit: String) -> URL {
        URL(string: "\(Self.apiBase)/repos/\(repo)/git/trees/\(commit)?recursive=1")!
    }

    func rawURL(commit: String, path: String) -> URL {
        URL(string: "\(Self.rawBase)/\(repo)/\(commit)/\(Self.encodePath(path))")!
    }

    /// Percent-encodes every character outside RFC 3986's unreserved set, keeping `/` as the separator.
    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        allowed.insert("/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    // MARK: Requests

    /// Resolves a branch, tag or (abbreviated) commit to a full commit SHA.
    ///
    /// The `application/vnd.github.sha` media type answers with the bare SHA. Passing the ETag of a
    /// previous answer turns an unchanged ref into an empty 304. GitHub exempts 304s from the rate limit
    /// only for authorized requests; these are unauthenticated, so every lookup, 304 or not, uses one of
    /// the 60 requests an hour this network gets.
    func resolveCommit(ref: String, ifNoneMatch etag: String?) async throws -> CommitAnswer {
        var headers = ["Accept": "application/vnd.github.sha", "X-GitHub-Api-Version": Self.apiVersion]
        if let etag { headers["If-None-Match"] = etag }
        let what = "the commit of '\(ref)'"
        let (data, response) = try await transport.get(commitURL(ref: ref), headers: headers, timeout: deadline.remaining())
        if response.statusCode == 304, etag != nil { return .notModified }
        if response.statusCode == 404 || response.statusCode == 422 {
            throw RemoteConfigError.refNotFound(repo: repo, ref: ref)
        }
        try Self.requireSuccess(response, data: data, what: what)
        guard let commit = Self.parseCommit(data) else { throw RemoteConfigError.unexpectedResponse(what: what) }
        return .commit(commit, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    func tree(commit: String) async throws -> GitTree {
        let what = "the file list of \(repo) at \(commit.prefix(7))"
        let headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": Self.apiVersion]
        let (data, response) = try await transport.get(treeURL(commit: commit), headers: headers, timeout: deadline.remaining())
        try Self.requireSuccess(response, data: data, what: what)
        do {
            return try JSONDecoder().decode(GitTree.self, from: data)
        } catch {
            throw RemoteConfigError.unexpectedResponse(what: what)
        }
    }

    /// Downloads one file at a pinned commit and checks it against the blob SHA from the tree listing.
    func blob(commit: String, path: String, sha: String) async throws -> Data {
        let (data, response) = try await transport.get(rawURL(commit: commit, path: path), headers: [:], timeout: deadline.remaining())
        if let limit = Self.rateLimit(response) { throw limit }
        guard response.statusCode == 200 else {
            throw RemoteConfigError.downloadFailed(path: path, reason: "HTTP \(response.statusCode)")
        }
        guard Self.gitBlobHash(data, likeSHA: sha) == sha.lowercased() else {
            throw RemoteConfigError.checksumMismatch(path: path)
        }
        return data
    }

    // MARK: Response helpers

    static func requireSuccess(_ response: HTTPURLResponse, data: Data, what: String) throws {
        if (200..<300).contains(response.statusCode) { return }
        if let limit = rateLimit(response) { throw limit }
        throw RemoteConfigError.httpStatus(response.statusCode, what: what, message: errorMessage(data))
    }

    /// GitHub signals its primary limit with `x-ratelimit-remaining: 0` (403 or 429) and secondary
    /// limits with `retry-after`.
    static func rateLimit(_ response: HTTPURLResponse) -> RemoteConfigError? {
        guard response.statusCode == 403 || response.statusCode == 429 else { return nil }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        guard remaining == "0" || retryAfter != nil || response.statusCode == 429 else { return nil }
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) }
        return .rateLimited(resetsAt: remaining == "0" ? reset : nil, retryAfter: retryAfter)
    }

    /// The `message` field of a GitHub error body, if there is one.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String, !message.isEmpty else { return nil }
        return message
    }

    /// The bare SHA body, or the `sha` field when a proxy or old API ignored the media type.
    static func parseCommit(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isCommitSHA(text) { return text }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sha = (object["sha"] as? String)?.lowercased(), isCommitSHA(sha) {
            return sha
        }
        return nil
    }

    /// A full SHA-1 (40) or SHA-256 (64) object name in lowercase hex.
    static func isCommitSHA(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Git's object name for a blob: hash of `blob <size>\0<content>`, SHA-256 for 64-character names.
    static func gitBlobHash(_ data: Data, likeSHA sha: String) -> String {
        var object = Data("blob \(data.count)\0".utf8)
        object.append(data)
        if sha.count == 64 {
            return SHA256.hash(data: object).map { String(format: "%02x", $0) }.joined()
        }
        return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    }
}
