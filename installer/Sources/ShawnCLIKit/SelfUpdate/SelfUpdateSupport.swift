import CryptoKit
import Darwin
import Foundation
import ShawnCore
import ShawnSync

// MARK: - Clock

protocol Clock: Sendable {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

extension Date {
    /// True when `self` lies less than a day before `now`. A time after `now` does not count. It was stored while the
    /// clock was ahead (a date set by hand, a VM snapshot), and would otherwise hold until the clock got there.
    func isLessThanADay(before now: Date) -> Bool {
        let age = now.timeIntervalSince(self)
        return age >= 0 && age < 24 * 3600
    }
}

// MARK: - State (~/.shawn/state)

/// What the self-updater remembers between runs (`~/.shawn/state/self-update.json`).
struct SelfUpdateState: Codable, Equatable, Sendable {
    var lastCheck: Date?
    /// Remote branch head seen last time.
    var lastRemoteCommit: String?
    /// Newest `shawn-v*` tag seen.
    var latestTag: String?
    /// Source content id whose build failed (so every call does not retry a multi-minute build).
    var failedBuildTree: String?
    /// A release tag whose download failed or was rejected, and when: automatic runs leave it alone for a day.
    var failedRelease: String?
    var failedReleaseAt: Date?
    /// The newest release when this Mac's macOS is too old for it: its tag and the macOS it needs, as its
    /// manifest said. Later runs then neither fetch the manifest again nor take it for a failed download.
    var releaseTooNew: ReleaseTooNew?
    /// The once-a-day notes by topic, with the reason each one gave and when it was said. Only the topics the last
    /// finished check raised are kept, so a reason that went away and came back is said again at once.
    var noted: [String: Noted]?
    /// Config fetched from GitHub when there is no checkout (preferred over `~/.shawn/config`).
    var remoteConfigRoot: String?
    /// One-line description of the last check, for `shawn version`.
    var lastResult: String?
    /// The topics the run in progress raised. They are not saved.
    var raised: Set<String> = []

    struct ReleaseTooNew: Codable, Equatable, Sendable {
        var tag: String
        var minimumMacOS: Int
    }

    struct Noted: Codable, Equatable, Sendable {
        /// What tells this reason apart from another of the same topic. It is the note's text, or a shorter form of
        /// it (the kind of reason, or a git failure without its numbers).
        var reason: String
        var at: Date
    }

    private enum CodingKeys: String, CodingKey {
        case lastCheck, lastRemoteCommit, latestTag, failedBuildTree, failedRelease, failedReleaseAt, releaseTooNew, noted, remoteConfigRoot, lastResult
    }

    /// The state to save after a check that got an answer from the remote. It forgets the notes on topics this run
    /// did not raise, because their reason went away.
    func keepingRaisedNotes() -> SelfUpdateState {
        var kept = self
        let notes = (noted ?? [:]).filter { raised.contains($0.key) }
        kept.noted = notes.isEmpty ? nil : notes
        return kept
    }
}

/// What the installed binary was built from, as far as anyone recorded.
enum BuildProvenance: Equatable, Sendable {
    /// The content id (`GitRepo.contentID`) of its sources, and the commit when known.
    case known(sourceTree: String, commit: String?)
    /// Nobody recorded it: an installer without build-info.json, a binary copied in by hand, a release
    /// whose manifest has no sourceTree.
    case unknown
}

protocol SelfUpdateStateStoring: Sendable {
    func load() -> SelfUpdateState
    func save(_ state: SelfUpdateState)
    /// Source content id the installed binary was built from (`sourceTree` in `cli.json`), nil when unknown.
    func installedSourceTree() -> String?
    /// Records a newly installed binary in `cli.json`, keeping whatever else the installer wrote there.
    /// `.unknown` removes `sourceTree` and `commit`, and a nil `version` removes `version`: they described the
    /// binary that was just replaced. `source` is where the new binary came from (a file or an address).
    func recordInstall(_ provenance: BuildProvenance, version: String?, source: String, date: Date)
    /// Tries to become the one shawn that updates right now (never waits).
    func lockUpdates() -> UpdateLock.Attempt
}

/// JSON files under `~/.shawn/state/`.
struct FileStateStore: SelfUpdateStateStoring {
    let directory: URL

    var stateFile: URL { directory.appendingPathComponent("self-update.json") }
    /// Shared with the installer's `shawn-cli` item, which writes `{version, installedAt, source}` and, when the app
    /// was built from committed sources, `{sourceTree, commit}` from its build-info.json.
    var installFile: URL { directory.appendingPathComponent("cli.json") }
    var lockFile: URL { directory.appendingPathComponent("self-update.lock") }

    func load() -> SelfUpdateState {
        guard let data = FileManager.default.contents(atPath: stateFile.path) else { return SelfUpdateState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SelfUpdateState.self, from: data)) ?? SelfUpdateState()
    }

    func save(_ state: SelfUpdateState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state) else { return }
        write(data, to: stateFile)
    }

    func installRecord() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: installFile.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func installedSourceTree() -> String? {
        guard let tree = installRecord()["sourceTree"] as? String, !tree.isEmpty else { return nil }
        return tree
    }

    func recordInstall(_ provenance: BuildProvenance, version: String?, source: String, date: Date) {
        var record = installRecord()
        switch provenance {
        case .known(let sourceTree, let commit):
            record["sourceTree"] = sourceTree
            if let commit { record["commit"] = commit } else { record.removeValue(forKey: "commit") }
        case .unknown:
            record.removeValue(forKey: "sourceTree")
            record.removeValue(forKey: "commit")
        }
        if let version { record["version"] = version } else { record.removeValue(forKey: "version") }
        record["source"] = source
        record["updatedAt"] = ISO8601DateFormatter().string(from: date)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        write(data, to: installFile)
    }

    func lockUpdates() -> UpdateLock.Attempt {
        UpdateLock.acquire(at: lockFile)
    }

    private func write(_ data: Data, to url: URL) {
        // State is a cache: failing to save it only means the next run checks again.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        } catch {
            return
        }
    }
}

// MARK: - One updater at a time

/// An exclusive `flock` on `~/.shawn/state/self-update.lock`, held while one shawn checks, pulls, rebuilds or
/// downloads. Another shawn started meanwhile does not wait (a rebuild takes minutes, and it would only repeat
/// the work): it skips its update and runs the command with the binary it has. The lock file says who holds it
/// and what it is doing, so the second shawn can say so.
final class UpdateLock: @unchecked Sendable {
    enum Activity: String, Sendable {
        case checking
        case pulling
        case rebuilding
        case downloading

        var phrase: String {
            switch self {
            case .checking: return "checking for updates"
            case .pulling: return "pulling new commits"
            case .rebuilding: return "rebuilding itself"
            case .downloading: return "downloading a new release"
            }
        }
    }

    enum Attempt: Sendable {
        case acquired(UpdateLock)
        /// Another process holds it; its pid and activity when the lock file said.
        case busy(pid: Int32?, activity: Activity?)
        /// The lock file cannot be opened (an unwritable state directory).
        case unavailable(String)
    }

    private let mutex = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func acquire(at url: URL) -> Attempt {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .unavailable("could not create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        // Close-on-exec, so the restarted binary and every git or swift child we spawn never hold it.
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .unavailable("could not open \(url.path): \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            defer { close(descriptor) }
            guard code == EWOULDBLOCK else { return .unavailable("could not lock \(url.path): \(String(cString: strerror(code)))") }
            return holder(of: descriptor)
        }
        let lock = UpdateLock(descriptor: descriptor)
        lock.announce(.checking)
        return .acquired(lock)
    }

    /// What the holder wrote: `<pid> <activity>`.
    private static func holder(of descriptor: Int32) -> Attempt {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        let text = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        let pid = fields.first.flatMap { Int32($0) }
        let activity = fields.count > 1 ? Activity(rawValue: fields[1]) : nil
        return .busy(pid: pid, activity: activity)
    }

    /// Tells a concurrent shawn what this one is doing.
    func announce(_ activity: Activity) {
        mutex.withLock {
            guard descriptor >= 0 else { return }
            let bytes = Array("\(getpid()) \(activity.rawValue)\n".utf8)
            _ = ftruncate(descriptor, 0)
            _ = pwrite(descriptor, bytes, bytes.count, 0)
        }
    }

    func release() {
        mutex.withLock {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    /// "another shawn (pid 4242) is rebuilding itself".
    static func describe(pid: Int32?, activity: Activity?) -> String {
        "another shawn" + (pid.map { " (pid \($0))" } ?? "") + " is " + (activity?.phrase ?? "updating")
    }
}

// MARK: - Building from source

struct BuildFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let message: String

    var description: String { message }
}

protocol Builder: Sendable {
    /// Builds `product` in the Swift package at `package` and returns the built executable.
    func build(package: URL, product: String, timeout: TimeInterval) async -> Result<URL, BuildFailure>
}

/// `swift build -c release --product shawn` in the checkout.
struct SwiftBuilder: Builder {
    let launcher: any ProcessLaunching
    let environment: SystemEnvironment

    func build(package: URL, product: String, timeout: TimeInterval) async -> Result<URL, BuildFailure> {
        guard let swift = ToolLocator.find("swift", environment: environment) else {
            return .failure(BuildFailure(message: "swift is not installed (it comes with Xcode or the command line developer tools)"))
        }
        let variables = environment.processEnvironment()
        let build = await launcher.capture(ProcessRequest(swift, ["build", "-c", "release", "--product", product],
                                                          environment: variables, currentDirectory: package, timeout: timeout))
        if build.timedOut { return .failure(BuildFailure(message: "the build took longer than \(Int(timeout / 60)) minutes")) }
        guard build.succeeded else { return .failure(BuildFailure(message: build.tail(2))) }
        let binPath = await launcher.capture(ProcessRequest(swift, ["build", "-c", "release", "--product", product, "--show-bin-path"],
                                                            environment: variables, currentDirectory: package, timeout: 120))
        // SwiftPM may also print "waiting for another instance…"; the path is the last absolute line.
        let directory = binPath.lines.last { $0.hasPrefix("/") } ?? binPath.output
        let binary = URL(fileURLWithPath: directory).appendingPathComponent(product)
        guard binPath.succeeded, FileManager.default.isExecutableFile(atPath: binary.path) else {
            return .failure(BuildFailure(message: "the build finished but \(product) was not found at \(binary.path)"))
        }
        return .success(binary)
    }
}

// MARK: - Releases

/// `shawn-cli.json`, published with every `shawn-v*` release.
struct ReleaseManifest: Equatable, Sendable {
    var version: String
    var sha256: String
    var url: URL
    /// The content id (`GitRepo.contentID`) of the sources the release was built from, when it recorded one.
    var sourceTree: String?
    var commit: String?
    /// The major version of the oldest macOS the binary runs on, when the release says. The binary checks it
    /// itself when it starts (`MinimumMacOS`), so one installed on an older macOS would refuse every command.
    var minimumMacOS: Int?

    init(version: String, sha256: String, url: URL, sourceTree: String? = nil, commit: String? = nil, minimumMacOS: Int? = nil) {
        self.version = version
        self.sha256 = sha256
        self.url = url
        self.sourceTree = sourceTree
        self.commit = commit
        self.minimumMacOS = minimumMacOS
    }

    static func parse(_ data: Data) throws -> ReleaseManifest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String,
              let sha = object["sha256"] as? String,
              let urlText = object["url"] as? String, let url = URL(string: urlText) else {
            throw BuildFailure(message: "shawn-cli.json is missing version, sha256 or url")
        }
        func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return ReleaseManifest(version: version, sha256: sha.lowercased(), url: url, sourceTree: text("sourceTree"), commit: text("commit"),
                               minimumMacOS: object["minimumMacOS"] as? Int)
    }

    var provenance: BuildProvenance {
        sourceTree.map { .known(sourceTree: $0, commit: commit) } ?? .unknown
    }
}

protocol ReleaseSource: Sendable {
    func manifest(repo: String, tag: String, timeout: TimeInterval) async throws -> ReleaseManifest
    /// The whole body of `url`, within `timeout` seconds in all (not just between packets).
    func download(_ url: URL, timeout: TimeInterval) async throws -> Data
}

/// GitHub release assets over HTTPS.
struct GitHubReleaseSource: ReleaseSource {
    func manifest(repo: String, tag: String, timeout: TimeInterval) async throws -> ReleaseManifest {
        let url = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/shawn-cli.json")!
        return try ReleaseManifest.parse(try await download(url, timeout: timeout))
    }

    func download(_ url: URL, timeout: TimeInterval) async throws -> Data {
        // A request's timeoutInterval is only the longest silence between packets, so a trickling connection
        // could hold the user's command for hours. The resource timeout bounds the whole transfer.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        configuration.timeoutIntervalForRequest = min(timeout, 30)
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "shawn-cli"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError where error.code == .timedOut {
            throw BuildFailure(message: "\(url.lastPathComponent) did not download within \(Int(timeout)) seconds")
        } catch let error as URLError {
            throw BuildFailure(message: "\(url.lastPathComponent): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BuildFailure(message: "\(url.lastPathComponent): HTTP \(http.statusCode)")
        }
        return data
    }
}

enum Checksum {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Remote config (no checkout)

protocol RemoteConfigRefreshing: Sendable {
    /// Fetches the latest config from GitHub into the cache and returns its directory, or nil.
    func refresh(timeout: TimeInterval) async -> URL?
}

/// Uses the shared resolver, so the CLI and the installer cache remote config the same way.
struct ResolverRemoteConfig: RemoteConfigRefreshing {
    let registry: ActionRegistry
    let environment: SystemEnvironment
    let bundle: Bundle

    func refresh(timeout: TimeInterval) async -> URL? {
        let options = ConfigResolveOptions(allowRemote: true, remoteTimeout: timeout)
        guard let resolved = try? await ConfigResolver.resolve(options: options, registry: registry, environment: environment, bundle: bundle),
              case .remote = resolved.config.source else { return nil }
        return resolved.config.root
    }
}

// MARK: - Versions

enum VersionNumber {
    static let tagPrefix = "shawn-v"

    /// `shawn-v1.2.0` → `1.2.0`.
    static func fromTag(_ tag: String) -> String? {
        let name = tag.hasPrefix("refs/tags/") ? String(tag.dropFirst("refs/tags/".count)) : tag
        guard name.hasPrefix(tagPrefix), !name.hasSuffix("^{}") else { return nil }
        let version = String(name.dropFirst(tagPrefix.count))
        return components(version).isEmpty ? nil : version
    }

    static func components(_ version: String) -> [Int] {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        let parts = core.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }

    /// True when `lhs` is a newer version than `rhs`.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = components(lhs), b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The newest `shawn-v*` tag among ls-remote refs.
    static func latestTag(in refs: [String: String]) -> (tag: String, version: String)? {
        var best: (tag: String, version: String)?
        for ref in refs.keys {
            guard let version = fromTag(ref) else { continue }
            if best == nil || isNewer(version, than: best!.version) {
                best = (String(ref.dropFirst("refs/tags/".count)), version)
            }
        }
        return best
    }
}

// MARK: - Replacing the binary

enum BinaryReplacement {
    /// The file an update writes: the installed path itself, or the file it links to, so a link the user made
    /// (`~/.local/bin/shawn → …`) stays a link instead of quietly becoming a copy.
    static func destination(for url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    /// Why the binary at `url` must not be replaced in place, or nil when it can be. Judged by where it really
    /// is, so a link into a build directory counts as the development build it is.
    static func refusal(for url: URL) -> String? {
        let target = destination(for: url)
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        let subject = isLink ? "it links to \(target.path), which is" : "it is"
        if target.path.contains(".app/Contents/") { return "\(subject) inside an app bundle (update the app instead)" }
        if target.path.contains("/.build/") { return "\(subject) a development build in \(target.deletingLastPathComponent().path)" }
        let folder = target.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: folder) {
            return isLink ? "it links into \(folder), which is not writable" : "\(folder) is not writable"
        }
        return nil
    }

    /// Writes the new binary next to the file being replaced, then renames it over that file, so the path always
    /// holds a complete binary (a running process keeps its already-open file).
    static func replace(_ installed: URL, with data: Data) throws {
        let target = destination(for: installed)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).update-\(getpid())")
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o755]) else {
            throw BuildFailure(message: "could not write \(staging.path)")
        }
        guard rename(staging.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staging)
            throw BuildFailure(message: "could not replace \(target.path): \(reason)")
        }
    }

    static func replace(_ installed: URL, withContentsOf source: URL) throws {
        guard let data = FileManager.default.contents(atPath: source.path) else {
            throw BuildFailure(message: "could not read \(source.path)")
        }
        try replace(installed, with: data)
    }
}
