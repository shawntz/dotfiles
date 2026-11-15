import Foundation
import ShawnCore

/// Which files of a tree listing make up the config, and where each one goes.
struct FetchPlan: Equatable, Sendable {
    struct File: Equatable, Sendable {
        /// Path inside the config directory, e.g. `steps/01-bootstrap.yaml`.
        let relativePath: String
        /// Path inside the repo, e.g. `installer/config/steps/01-bootstrap.yaml`.
        let repoPath: String
        let sha: String
        let size: Int?
        let executable: Bool
    }

    static let maxFiles = 5_000
    static let maxBytes = 256 * 1024 * 1024

    var files: [File] = []
    var directories: [String] = []
    /// Entries left out on purpose (symlinks, submodules), for the user.
    var notes: [String] = []

    /// Builds the plan for the subtree at `configPath` (empty = the whole repo).
    ///
    /// Any entry whose path could escape the destination (`..`, absolute, empty components) makes the
    /// whole listing untrustworthy, so it is refused outright rather than skipped.
    static func make(tree: GitTree, configPath: String, repo: String, commit: String) throws -> FetchPlan {
        var plan = FetchPlan()
        let prefix = Array((configPath.isEmpty ? "" : configPath + "/").utf8)
        var skippedLinks: [String] = []
        var skippedModules: [String] = []
        var totalBytes = 0

        for entry in tree.tree {
            guard isSafeRelativePath(entry.path) else { throw RemoteConfigError.unsafePath(entry.path) }
            // Bytes, as git and the file system compare paths: `String.hasPrefix` compares Characters, so
            // it misses a name under the config path that starts with a combining mark.
            let path = Array(entry.path.utf8)
            guard path.count > prefix.count, path.starts(with: prefix) else { continue }
            // The prefix ends in an ASCII `/`, so the rest is whole UTF-8 sequences.
            let relative = String(decoding: path[prefix.count...], as: UTF8.self)

            switch entry.type {
            case "tree":
                plan.directories.append(relative)
            case "commit":
                skippedModules.append(relative)
            case "blob" where entry.mode == "120000":
                skippedLinks.append(relative)
            case "blob":
                guard GitHubAPI.isCommitSHA(entry.sha.lowercased()) else {
                    throw RemoteConfigError.unexpectedResponse(what: "the file list of \(repo) at \(commit.prefix(7))")
                }
                totalBytes += entry.size ?? 0
                plan.files.append(File(relativePath: relative, repoPath: entry.path, sha: entry.sha.lowercased(),
                                       size: entry.size, executable: entry.mode == "100755"))
            default:
                continue
            }
        }

        guard !plan.files.isEmpty else {
            throw RemoteConfigError.missingDirectory(repo: repo, path: configPath, commit: commit)
        }
        guard plan.files.contains(where: { $0.relativePath == ConfigLoader.metaFileName }) else {
            throw RemoteConfigError.notAConfig(path: configPath, commit: commit)
        }
        guard plan.files.count <= maxFiles, totalBytes <= maxBytes else {
            throw RemoteConfigError.tooLarge(files: plan.files.count, bytes: totalBytes)
        }
        if !skippedLinks.isEmpty {
            plan.notes.append("Skipped symlinks in the remote config (they are not downloaded): \(skippedLinks.sorted().joined(separator: ", ")).")
        }
        if !skippedModules.isEmpty {
            plan.notes.append("Skipped git submodules in the remote config (they are not downloaded): \(skippedModules.sorted().joined(separator: ", ")).")
        }
        return plan
    }

    /// Relative, no `.`/`..`/empty components, no NUL.
    ///
    /// Components are split on the `/` byte, exactly as the file system splits them. Splitting the String
    /// would compare Characters, and a combining mark right after a slash merges with it into one
    /// Character, hiding that component boundary (and a `..` before it) from the check.
    static func isSafeRelativePath(_ path: String) -> Bool {
        let slash = UInt8(ascii: "/"), dot = UInt8(ascii: ".")
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.first != slash, !bytes.contains(0) else { return false }
        return bytes.split(separator: slash, omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && !component.elementsEqual([dot]) && !component.elementsEqual([dot, dot])
        }
    }
}

/// `<cacheDirectory>/config/<commit>/`: one complete config directory per commit.
///
/// A commit directory only ever appears by renaming a fully downloaded staging directory into place,
/// so it is either complete or absent; nothing inside it is modified afterwards.
struct ConfigCache: Sendable {
    static let stagingPrefix = ".staging-"
    static let refsFileName = "refs.json"
    /// Staging directories older than this were abandoned by a crashed or killed run.
    static let abandonedStagingAge: TimeInterval = 3600

    struct KnownRef: Codable, Equatable, Sendable {
        let etag: String
        let commit: String
    }

    let root: URL

    init(environment: SystemEnvironment) {
        root = environment.cacheDirectory.appendingPathComponent("config")
    }

    func directory(commit: String) -> URL {
        root.appendingPathComponent(commit)
    }

    /// The cached config for `commit`, when it is there.
    func existingDirectory(commit: String) -> URL? {
        let directory = directory(commit: commit)
        return ConfigLoader.isConfigDirectory(directory) ? directory : nil
    }

    func makeStaging(commit: String) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("\(Self.stagingPrefix)\(commit.prefix(12))-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    /// Removes a staging directory that was not installed (failure, timeout, or another process won).
    func discard(_ staging: URL) {
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        // Best effort: a leftover staging directory is invisible to readers and is cleaned up by `prune`.
        try? FileManager.default.removeItem(at: staging)
    }

    /// Atomically renames a complete staging directory to the commit's directory.
    func install(_ staging: URL, commit: String) throws -> URL {
        let fileManager = FileManager.default
        let destination = directory(commit: commit)
        if fileManager.fileExists(atPath: destination.path), existingDirectory(commit: commit) == nil {
            // Not something this code produced (it always contains installer.yaml); replace it.
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            // Another process finished the same commit first; its copy is just as complete.
            if let existing = existingDirectory(commit: commit) { return existing }
            throw error
        }
        markUsed(commit: commit)
        return destination
    }

    /// Records that `commit` was just used, so pruning keeps the most recently used ones.
    func markUsed(commit: String) {
        // Only affects which old commits get pruned first; failing to touch it is harmless.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory(commit: commit).path)
    }

    /// Keeps the `count` most recently used commits (always including `protecting`) and removes
    /// abandoned staging directories. Best effort: pruning must never fail a fetch.
    func prune(keeping count: Int, protecting commit: String) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        var commits: [(name: String, used: Date)] = []
        for name in names {
            let url = root.appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if name.hasPrefix(Self.stagingPrefix) {
                if modified.timeIntervalSinceNow < -Self.abandonedStagingAge { try? fileManager.removeItem(at: url) }
                continue
            }
            guard name != commit, GitHubAPI.isCommitSHA(name) else { continue }
            commits.append((name, modified))
        }
        let keepOthers = max(count - 1, 0)
        for stale in commits.sorted(by: { $0.used > $1.used }).dropFirst(keepOthers) {
            try? fileManager.removeItem(at: root.appendingPathComponent(stale.name))
        }
    }

    // MARK: Ref → commit memory (for conditional requests)

    private var refsFile: URL { root.appendingPathComponent(Self.refsFileName) }

    private func readRefs() -> [String: KnownRef] {
        guard let data = try? Data(contentsOf: refsFile),
              let refs = try? JSONDecoder().decode([String: KnownRef].self, from: data) else { return [:] }
        return refs
    }

    func knownRef(repo: String, ref: String) -> KnownRef? {
        readRefs()["\(repo)@\(ref)"]
    }

    /// Remembers the ETag GitHub gave for `ref`, so the next lookup can be conditional and an unchanged ref
    /// is answered with an empty 304. That saves the response body, not rate limit: GitHub counts
    /// unauthenticated 304s against the 60-an-hour limit like any other request. Losing this file only
    /// means the next lookup is unconditional, so a failed write is deliberately not reported.
    func remember(repo: String, ref: String, etag: String, commit: String) {
        var refs = readRefs()
        refs["\(repo)@\(ref)"] = KnownRef(etag: etag, commit: commit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(refs) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: refsFile, options: .atomic)
    }
}
