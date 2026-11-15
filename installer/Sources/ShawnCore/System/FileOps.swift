import Foundation

/// What a file operation did (or, in a dry run, would do).
public enum FileChange: Equatable, Sendable {
    /// Already in the desired state.
    case unchanged
    case created
    /// An existing item was replaced; `backup` is where the old one went.
    case replaced(backup: URL?)

    public var didChange: Bool { self != .unchanged }
}

public struct FileOpsError: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// What to do about it, when the refusal has its own answer (a linked folder too big to unfold). Callers that
    /// add a general hint use this one instead.
    public let hint: String?

    public init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    public var description: String {
        guard let hint, !hint.isEmpty else { return message }
        return ActionError.sentences(message, hint)
    }
}

/// File changes with three guarantees: nothing is overwritten without a
/// backup, nothing is touched when it is already right, and nothing is
/// touched at all in a dry run.
public struct FileOps: Sendable {
    public static let defaultExcludes: Set<String> = [".DS_Store", ".git", ".gitkeep"]

    public let environment: SystemEnvironment
    public let dryRun: Bool
    private let log: @Sendable (LogLine) -> Void
    /// A linked folder with more files or bytes than this is refused rather than copied (see `unfoldSymlinkedAncestors`).
    public var unfoldFileLimit = 2_000
    public var unfoldByteLimit = 64 * 1024 * 1024

    public init(environment: SystemEnvironment, dryRun: Bool = false, log: @escaping @Sendable (LogLine) -> Void = { _ in }) {
        self.environment = environment
        self.dryRun = dryRun
        self.log = log
    }

    private var fileManager: FileManager { .default }

    private func display(_ url: URL) -> String {
        PathExpansion.abbreviate(url.path, home: environment.home)
    }

    private func note(_ text: String) {
        log(LogLine(dryRun ? "[dry-run] \(text)" : text, style: .info))
    }

    // MARK: Inspection (always read-only)

    public func exists(_ url: URL) -> Bool {
        // Counts dangling symlinks too.
        (try? url.checkResourceIsReachable()) == true || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    public func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    public func permissions(of url: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// True when `destination` is a regular file with the same bytes (and permissions, if given).
    public func fileMatches(_ data: Data, at destination: URL, permissions: Int? = nil) -> Bool {
        guard !isDirectory(destination), let existing = fileManager.contents(atPath: destination.path), existing == data else { return false }
        if let permissions, self.permissions(of: destination) != permissions { return false }
        return true
    }

    public func fileMatches(source: URL, destination: URL, permissions: Int? = nil) -> Bool {
        guard let data = fileManager.contents(atPath: source.path) else { return false }
        return fileMatches(data, at: destination, permissions: permissions ?? self.permissions(of: source))
    }

    /// Relative paths of every regular file under `directory` (symlinks are listed, not followed).
    public func files(in directory: URL, excluding: Set<String> = FileOps.defaultExcludes) -> [String] {
        // The path enumerator hands back paths relative to `directory`. The URL enumerator hands back resolved
        // URLs, which do not start with `directory` when it is reached through a link or spelled in another
        // letter case, so every entry of such a folder used to be dropped.
        guard let enumerator = fileManager.enumerator(atPath: directory.path) else { return [] }
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var result: [String] = []
        while let relative = enumerator.nextObject() as? String {
            // lstat describes the entry itself, so a link to a folder is not a folder here.
            var info = stat()
            let isRealDirectory = lstat(base + relative, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            if excluding.contains((relative as NSString).lastPathComponent) {
                // Only for directories: on a plain file this call would skip the rest of its parent.
                if isRealDirectory { enumerator.skipDescendants() }
                continue
            }
            if !isRealDirectory { result.append(relative) }
        }
        return result.sorted()
    }

    /// True when every file under `source` exists identically under `destination`.
    /// With `exact`, `destination` may not contain anything extra either.
    public func directoryMatches(source: URL, destination: URL, exact: Bool = false, excluding: Set<String> = FileOps.defaultExcludes) -> Bool {
        guard isDirectory(destination), !isSymlink(destination) else { return false }
        let sourceFiles = files(in: source, excluding: excluding)
        for relative in sourceFiles {
            let from = source.appendingPathComponent(relative)
            let to = destination.appendingPathComponent(relative)
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: from.path) {
                if (try? fileManager.destinationOfSymbolicLink(atPath: to.path)) != target { return false }
            } else if !fileMatches(source: from, destination: to) {
                return false
            }
        }
        if exact && files(in: destination, excluding: excluding) != sourceFiles { return false }
        return true
    }

    public func symlinkMatches(at link: URL, target: String) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == target
    }

    // MARK: Folders that are really links

    /// The outermost folder between `url` and the home directory that is a symbolic link, if any.
    public func symlinkedAncestor(of url: URL) -> URL? {
        let home = environment.home.standardizedFileURL.path
        var current = url.standardizedFileURL.deletingLastPathComponent()
        var outermost: URL?
        while current.path.hasPrefix(home + "/") {
            if isSymlink(current) { outermost = current }
            current = current.deletingLastPathComponent()
        }
        return outermost
    }

    /// Stow-style setups link whole config folders (`~/.config/ghostty`, `~/.hammerspoon`) into a dotfiles
    /// checkout. Writing "inside" such a folder would really write into that checkout, dirtying it and leaving
    /// the config linked. So before writing below a linked folder, the link is swapped for a real folder holding
    /// the same files (the link itself goes to the backups). Big linked folders are refused rather than copied.
    private func unfoldSymlinkedAncestors(of url: URL) throws {
        var passes = 0
        while let link = symlinkedAncestor(of: url) {
            passes += 1
            let target = link.resolvingSymlinksInPath()
            let targetIsDirectory = isDirectory(target)
            if targetIsDirectory, !isSmallEnoughToUnfold(target) {
                throw FileOpsError("\(display(link)) is a link to \(display(target)), which is too big to copy automatically",
                                   hint: "replace the link with a real folder (or point this item somewhere else) and run this again")
            }
            note("\(display(link)) is a link to \(display(target)); replacing it with a real folder holding the same files")
            // In a dry run the link stays, so there is nothing further to resolve; real runs loop for nested links.
            if dryRun || passes > 16 { return }
            try backUp(link)
            try fileManager.createDirectory(at: link, withIntermediateDirectories: true)
            if targetIsDirectory {
                for name in try fileManager.contentsOfDirectory(atPath: target.path) where name != ".DS_Store" {
                    try fileManager.copyItem(at: target.appendingPathComponent(name), to: link.appendingPathComponent(name))
                }
            }
        }
    }

    private func isSmallEnoughToUnfold(_ directory: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return true }
        var files = 0
        var bytes = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += values?.fileSize ?? 0
            if files > unfoldFileLimit || bytes > unfoldByteLimit { return false }
        }
        return true
    }

    // MARK: Changes

    @discardableResult
    public func ensureDirectory(_ url: URL, permissions: Int? = nil) throws -> FileChange {
        try unfoldSymlinkedAncestors(of: url)
        if isDirectory(url) {
            // A link to a folder counts as the folder being there, but its target is someone else's to chmod.
            if isSymlink(url) { return .unchanged }
            if let permissions, self.permissions(of: url) != permissions {
                note("chmod \(String(permissions, radix: 8)) \(display(url))")
                if !dryRun { try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                return .replaced(backup: nil)
            }
            return .unchanged
        }
        if exists(url) {
            throw FileOpsError("\(display(url)) exists but is not a directory")
        }
        note("mkdir \(display(url))")
        if !dryRun {
            var attributes: [FileAttributeKey: Any] = [:]
            if let permissions { attributes[.posixPermissions] = permissions }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes.isEmpty ? nil : attributes)
        }
        return .created
    }

    /// Moves an existing file, directory or symlink into this run's backup folder.
    @discardableResult
    public func backUp(_ url: URL) throws -> URL? {
        guard exists(url) else { return nil }
        let path = url.standardizedFileURL.path
        let homePath = environment.home.standardizedFileURL.path
        let relative = path.hasPrefix(homePath + "/") ? String(path.dropFirst(homePath.count + 1)) : "_root" + path
        let target = backupLocation(for: relative)
        note("backing up \(display(url)) → \(display(target))")
        if !dryRun {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: target)
        }
        return target
    }

    /// A free spot for `relative` inside the backup folder, reached through real folders only.
    ///
    /// The backups hold earlier items as they were, links included: once a linked folder has been unfolded, its link
    /// sits at the same relative path the files below it map to. Resolving through it would put the next backup
    /// wherever the link points (back into a dotfiles checkout) or fail on a dangling relative link. So any folder
    /// on the way that is not a real folder is passed by for a numbered sibling (`.config/ghostty.2/config`), and
    /// the item itself gets a numbered name when its spot is taken (`config.2`).
    private func backupLocation(for relative: String) -> URL {
        var location = environment.backupDirectory
        // Once part of the path does not exist, nothing below it can either.
        var isFree = false
        let components = relative.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            var candidate = location.appendingPathComponent(component)
            var suffix = 1
            while !isFree {
                guard let kind = itemKind(at: candidate) else {
                    isFree = true
                    break
                }
                if kind == .realDirectory && !isLast { break }
                suffix += 1
                candidate = location.appendingPathComponent("\(component).\(suffix)")
            }
            location = candidate
        }
        return location
    }

    private enum ItemKind { case realDirectory, other }

    /// What is at `url` itself, without following a link there (nil: nothing, not even a dangling link).
    private func itemKind(at url: URL) -> ItemKind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT == S_IFDIR ? .realDirectory : .other
    }

    /// Writes `data` to `destination`, creating parent directories.
    @discardableResult
    public func write(_ data: Data, to destination: URL, permissions: Int? = nil, backup: Bool = true) throws -> FileChange {
        if symlinkedAncestor(of: destination) == nil, fileMatches(data, at: destination, permissions: permissions) { return .unchanged }
        try unfoldSymlinkedAncestors(of: destination)

        let existed = exists(destination)
        // An atomic write creates a brand-new file; without this, replacing a 0600 file would quietly make it 0644.
        let permissions = permissions ?? (existed && !isDirectory(destination) ? self.permissions(of: destination) : nil)
        var backupLocation: URL?
        if existed {
            if backup {
                backupLocation = try backUp(destination)
            } else if !dryRun {
                try fileManager.removeItem(at: destination)
            }
        }
        note("\(existed ? "update" : "write") \(display(destination))")
        if !dryRun {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            if let permissions {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            }
        }
        return existed ? .replaced(backup: backupLocation) : .created
    }

    /// Copies one file. Permissions default to the source file's.
    @discardableResult
    public func installFile(from source: URL, to destination: URL, permissions: Int? = nil, backup: Bool = true) throws -> FileChange {
        guard let data = fileManager.contents(atPath: source.path) else {
            throw FileOpsError("cannot read \(source.path)")
        }
        return try write(data, to: destination, permissions: permissions ?? self.permissions(of: source), backup: backup)
    }

    /// Copies a directory tree.
    ///
    /// - `replace: false` merges: files from `source` are written into `destination`, anything else there is left alone.
    /// - `replace: true` mirrors: an existing, different `destination` is backed up whole and recreated from `source`.
    ///
    /// Returns the number of files that changed.
    @discardableResult
    public func installDirectory(from source: URL, to destination: URL, replace: Bool = false, backup: Bool = true,
                                 excluding: Set<String> = FileOps.defaultExcludes) throws -> Int {
        guard isDirectory(source) else {
            throw FileOpsError("\(source.path) is not a directory")
        }
        if symlinkedAncestor(of: destination) == nil,
           directoryMatches(source: source, destination: destination, exact: replace, excluding: excluding) { return 0 }
        try unfoldSymlinkedAncestors(of: destination)

        var cleared = false
        if replace, exists(destination) {
            if backup {
                try backUp(destination)
            } else {
                note("remove \(display(destination))")
                if !dryRun { try fileManager.removeItem(at: destination) }
            }
            cleared = true
        } else if isSymlink(destination) || (exists(destination) && !isDirectory(destination)) {
            // A file or symlink where the directory should be.
            if backup {
                try backUp(destination)
            } else {
                note("remove \(display(destination))")
                if !dryRun { try fileManager.removeItem(at: destination) }
            }
            cleared = true
        }

        var changed = 0
        if dryRun && cleared {
            // The old item is still on disk in a dry run, so only say what would happen.
            note("mkdir \(display(destination))")
        } else {
            try ensureDirectory(destination)
        }
        for relative in files(in: source, excluding: excluding) {
            let from = source.appendingPathComponent(relative)
            let to = destination.appendingPathComponent(relative)
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: from.path) {
                if try symlink(at: to, pointingTo: target, backup: backup && !replace).didChange { changed += 1 }
            } else if try installFile(from: from, to: to, backup: backup && !replace).didChange {
                changed += 1
            }
        }
        return changed
    }

    /// Creates (or repoints) a symbolic link. `target` is stored verbatim, so it may be relative.
    @discardableResult
    public func symlink(at link: URL, pointingTo target: String, backup: Bool = true) throws -> FileChange {
        if symlinkedAncestor(of: link) == nil, symlinkMatches(at: link, target: target) { return .unchanged }
        try unfoldSymlinkedAncestors(of: link)
        let existed = exists(link)
        var backupLocation: URL?
        if existed {
            if backup && !isSymlink(link) {
                backupLocation = try backUp(link)
            } else {
                note("remove \(display(link))")
                if !dryRun { try fileManager.removeItem(at: link) }
            }
        }
        note("link \(display(link)) → \(target)")
        if !dryRun {
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        return existed ? .replaced(backup: backupLocation) : .created
    }

    /// Removes a file, directory or symlink, backing it up first unless told otherwise.
    @discardableResult
    public func remove(_ url: URL, backup: Bool = true) throws -> FileChange {
        guard exists(url) else { return .unchanged }
        if backup {
            return .replaced(backup: try backUp(url))
        }
        note("remove \(display(url))")
        if !dryRun { try fileManager.removeItem(at: url) }
        return .replaced(backup: nil)
    }
}
