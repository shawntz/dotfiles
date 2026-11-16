import Foundation
@testable import ShawnSync

/// One canned HTTP answer.
struct CannedResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
    var delay: TimeInterval = 0

    static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> CannedResponse {
        CannedResponse(status: status, headers: headers, body: Data(text.utf8))
    }
}

/// In-memory web server keyed by exact URL. Records every request; unknown URLs answer 404.
/// When a canned response has an `ETag` and the request's `If-None-Match` matches it, answers 304.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var routes: [String: CannedResponse] = [:]
    private var failures: [String: URLError] = [:]
    private var recorded: [Request] = []
    private var inFlight = 0
    private var peak = 0

    func set(_ url: String, _ response: CannedResponse) {
        lock.withLock { routes[url] = response }
    }

    func update(_ url: String, _ change: (inout CannedResponse) -> Void) {
        lock.withLock {
            var response = routes[url] ?? CannedResponse()
            change(&response)
            routes[url] = response
        }
    }

    func fail(_ url: String, with error: URLError) {
        lock.withLock { failures[url] = error }
    }

    var requests: [Request] { lock.withLock { recorded } }
    var urls: [String] { requests.map(\.url.absoluteString) }
    var maxConcurrentRequests: Int { lock.withLock { peak } }

    func clearRequests() {
        lock.withLock { recorded.removeAll() }
    }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let key = url.absoluteString
        let (route, failure): (CannedResponse?, URLError?) = lock.withLock {
            recorded.append(Request(url: url, headers: headers))
            inFlight += 1
            peak = max(peak, inFlight)
            return (routes[key], failures[key])
        }
        defer { lock.withLock { inFlight -= 1 } }
        if let delay = route?.delay, delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if let failure { throw failure }
        guard var response = route else {
            return (Data("Not Found".utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        if let etag = response.headers["ETag"], headers["If-None-Match"] == etag {
            response = CannedResponse(status: 304, headers: ["ETag": etag])
        }
        return (response.body, HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!)
    }
}

/// Never answers the requests it is told to hang on, and ignores cancellation while doing so, which is the
/// worst case for a deadline. `release()` lets the abandoned work unwind at the end of a test.
final class HangingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<(Data, HTTPURLResponse), Error>] = []
    private var released = false
    private let answering: FakeTransport?
    private let hangsOn: @Sendable (URL) -> Bool

    init(answering: FakeTransport? = nil, hangsOn: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.answering = answering
        self.hangsOn = hangsOn
    }

    var hangingCount: Int { lock.withLock { waiting.count } }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        if !hangsOn(url), let answering {
            return try await answering.get(url, headers: headers, timeout: timeout)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumeNow = lock.withLock {
                if !released { waiting.append(continuation) }
                return released
            }
            if resumeNow { continuation.resume(throwing: URLError(.cancelled)) }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            defer { waiting.removeAll() }
            return waiting
        }
        for continuation in pending { continuation.resume(throwing: URLError(.cancelled)) }
    }
}

/// A repo on the fake GitHub: serves the ref lookup, the recursive tree and raw files at one commit.
struct FakeRepo {
    struct File {
        let path: String
        let contents: Data
        let executable: Bool
    }

    let repo: String
    let commit: String
    var files: [File] = []
    /// Raw tree entries added verbatim (symlinks, submodules, hostile paths).
    var extraEntries: [[String: Any]] = []
    /// Blobs listed in the tree exactly as given (no directory entries are derived for them) and served
    /// with their real blob SHA, so nothing but the code under test keeps a hostile path off the disk.
    var listedBlobs: [File] = []
    var truncated = false

    init(repo: String = "octo/dots", commit: String = FakeRepo.commitSHA("first")) {
        self.repo = repo
        self.commit = commit
    }

    /// A deterministic 40-character commit name.
    static func commitSHA(_ label: String) -> String {
        GitHubAPI.gitBlobHash(Data(label.utf8), likeSHA: String(repeating: "0", count: 40))
    }

    mutating func add(_ path: String, _ contents: String, executable: Bool = false) {
        files.append(File(path: path, contents: Data(contents.utf8), executable: executable))
    }

    mutating func addListedBlob(_ path: String, _ contents: String) {
        listedBlobs.append(File(path: path, contents: Data(contents.utf8), executable: false))
    }

    /// The standard remote config used by most tests, under `installer/config`, plus a file outside it.
    static func standard(commit: String = FakeRepo.commitSHA("first"), name: String = "Remote Dotfiles",
                         schema: Int = 1, extraStep: String? = nil) -> FakeRepo {
        var repo = FakeRepo(commit: commit)
        repo.add("README.md", "# not part of the config\n")
        repo.add("installer/config/installer.yaml", metaYAML(name: name, schema: schema))
        repo.add("installer/config/steps/01-base.yaml", "id: base\ntitle: Base\nitems:\n  - ok: remote thing\n")
        repo.add("installer/config/steps/02-more.yaml", "id: more\ntitle: More\nitems:\n  - note-only: hello\n    text: hi\n")
        repo.add("installer/config/files/bin/hello.sh", "#!/bin/sh\necho hi\n", executable: true)
        repo.add("installer/config/files/readme with spaces.txt", "plain text\n")
        if let extraStep {
            repo.add("installer/config/steps/03-extra.yaml", extraStep)
        }
        return repo
    }

    var commitURL: String { "https://api.github.com/repos/\(repo)/commits/" }
    var treeURL: String { "https://api.github.com/repos/\(repo)/git/trees/\(commit)?recursive=1" }

    func rawURL(_ path: String) -> String {
        "https://raw.githubusercontent.com/\(repo)/\(commit)/\(GitHubAPI.encodePath(path))"
    }

    func treeJSON() -> Data {
        var entries: [[String: Any]] = []
        var directories = Set<String>()
        for file in files {
            var parts = file.path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                directories.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        for directory in directories.sorted() {
            entries.append(["path": directory, "mode": "040000", "type": "tree", "sha": FakeRepo.commitSHA(directory)])
        }
        for file in files + listedBlobs {
            entries.append([
                "path": file.path,
                "mode": file.executable ? "100755" : "100644",
                "type": "blob",
                "sha": GitHubAPI.gitBlobHash(file.contents, likeSHA: commit),
                "size": file.contents.count,
            ])
        }
        entries += extraEntries
        let object: [String: Any] = ["sha": commit, "url": treeURL, "tree": entries, "truncated": truncated]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Serves this repo on `transport`, with `ref` resolving to `commit`.
    func serve(on transport: FakeTransport, ref: String = "main") {
        transport.set(commitURL + GitHubAPI.encodePath(ref),
                      .text(commit, headers: ["ETag": "\"\(commit)\"", "Content-Type": "application/vnd.github.sha; charset=utf-8"]))
        transport.set(treeURL, CannedResponse(status: 200, headers: ["Content-Type": "application/json"], body: treeJSON()))
        for file in files + listedBlobs {
            transport.set(rawURL(file.path), CannedResponse(status: 200, headers: [:], body: file.contents))
        }
    }
}
