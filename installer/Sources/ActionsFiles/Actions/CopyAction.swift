import Foundation
import ShawnCore

/// `copy: zsh/zshrc` installs a payload file or directory from `config/files/`.
struct CopyAction: Action {
    /// Path under `config/files/`.
    let source: String
    /// Destination path (`~` and `{{vars}}` allowed). A trailing `/` means "into this folder".
    let destination: String
    let mode: Int?
    let backup: Bool
    /// Directories only: mirror exactly (true) or merge into what is there (false). Excluded names are not part of
    /// the mirror either way: whatever the destination holds under them stays.
    let replace: Bool?
    let ifMissing: Bool
    let template: Bool
    let exclude: [String]

    var title: String { destination }
    var subtitle: String? { "from files/\(source)" + (template ? " (template)" : "") }

    static let descriptor = ActionDescriptor(
        kind: "copy",
        summary: "Copy a file or folder from config/files/ into place (backs up what it replaces; optional {{vars}} templating).",
        example: """
        - copy: zsh/zshrc               # config/files/zsh/zshrc
          to: ~/.zshrc
        - copy: karabiner               # a whole folder
          to: ~/.config/karabiner
          mode: "0700"                  # folder: the folder's own permissions; file: the file's
          exclude: [karabiner.json]     # names to leave out (and to leave alone in ~/.config/karabiner)
          replace: false                # false = merge (default), true = mirror exactly
        - copy: git/ignore
          to: ~/.config/git/ignore
          template: true                # expand {{vars}} in the text
          if_missing: true              # never overwrite an existing file
        """,
        make: { try make($0) }
    )

    private static func make(_ parser: ItemParser) throws -> any Action {
        let source = parser.primaryString()
        let options = parser.options
        let destination = options.requiredString("to")
        let mode = options.fileMode("mode")
        let backup = options.bool("backup", default: true)
        let replace = options.bool("replace")
        let ifMissing = options.bool("if_missing", default: false)
        let template = options.bool("template", default: false)
        let exclude = options.stringList("exclude")
        if source.hasPrefix("/") || source.split(separator: "/").contains("..") {
            parser.fail("'copy' takes a path inside config/files/ (no leading '/' or '..'), got '\(source)'")
        }
        return CopyAction(source: source, destination: destination, mode: mode, backup: backup, replace: replace,
                          ifMissing: ifMissing, template: template, exclude: exclude)
    }

    func validate(_ context: ValidationContext) -> [String] {
        var problems = Validation.unknownVariables(context, [("copy", source), ("to", destination)])
        let relative = "files/" + context.vars.expand(source)
        if !context.configPathExists(relative) {
            problems.append("payload \(relative) does not exist in the config")
        } else if !context.configPathIsDirectory(relative) {
            if replace != nil { problems.append("'replace' only applies when copying a folder (files/\(source) is a file)") }
            if !exclude.isEmpty { problems.append("'exclude' only applies when copying a folder (files/\(source) is a file)") }
        }
        return problems
    }

    // MARK: Paths

    struct Paths {
        let source: URL
        let destination: URL
    }

    func paths(_ context: ActionContext) -> Paths {
        let source = context.config.filesDirectory.appendingPathComponent(context.expand(self.source))
        var destination = context.path(self.destination)
        if self.destination.hasSuffix("/") { destination = destination.appendingPathComponent(source.lastPathComponent) }
        return Paths(source: source, destination: destination)
    }

    var excluded: Set<String> { FileOps.defaultExcludes.union(exclude) }

    /// File contents to write: the payload bytes, or its text with `{{vars}}` expanded. Binary files are never templated.
    func contents(of url: URL, context: ActionContext) throws -> Data {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ActionError("cannot read \(url.path)")
        }
        guard template, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return data }
        return Data(context.expand(text).utf8)
    }

    // MARK: Check & run

    func check(_ context: ActionContext) async -> CheckResult {
        let paths = paths(context)
        let files = context.files
        guard files.exists(paths.source) else { return .needed("payload files/\(source) is missing") }
        if ifMissing && files.exists(paths.destination) { return .satisfied("exists, and if_missing leaves it alone") }
        do {
            if files.isDirectory(paths.source) {
                if let folder = folderInTheWay(paths, files: files) {
                    return .needed("\(context.display(folder.destination)) is a folder, not a \(folder.isLink ? "link" : "file")")
                }
                let matches = template
                    ? try TemplatedTree(source: paths.source, excluding: excluded, action: self, context: context)
                        .matches(paths.destination, exact: replace ?? false, files: files)
                    : files.directoryMatches(source: paths.source, destination: paths.destination, exact: replace ?? false, excluding: excluded)
                let modeMatches = mode.map { files.permissions(of: paths.destination) == $0 } ?? true
                return matches && modeMatches ? .satisfied("up to date") : .needed(files.exists(paths.destination) ? "differs" : "not copied yet")
            }
            // A file payload is never written over a folder (or a link to one): see `run`.
            if files.isDirectory(paths.destination) { return .needed("\(context.display(paths.destination)) is a folder, not a file") }
            let data = try contents(of: paths.source, context: context)
            let permissions = mode ?? files.permissions(of: paths.source)
            if files.fileMatches(data, at: paths.destination, permissions: permissions) { return .satisfied("up to date") }
            return .needed(files.exists(paths.destination) ? "differs" : "not copied yet")
        } catch {
            return .needed(InstallEngine.describe(error))
        }
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let paths = paths(context)
        let files = context.files
        guard files.exists(paths.source) else {
            throw ActionError("payload files/\(source) is missing from the config", hint: "add it under config/files/ or fix the 'copy:' path")
        }
        if ifMissing && files.exists(paths.destination) {
            return .done("kept the existing \(context.display(paths.destination)) (if_missing)")
        }
        let shown = context.display(paths.destination)
        do {
            if files.isDirectory(paths.source) {
                if let folder = folderInTheWay(paths, files: files) {
                    let entry = "the \(folder.isLink ? "link" : "file") files/\(source)/\(folder.relative)"
                    throw ActionError("\(context.display(folder.destination)) is a folder; copying \(entry) there would replace it",
                                      hint: "move or rename that folder, or set 'replace: true' to make \(shown) an exact copy of files/\(source)")
                }
                // A mirror first takes away what the payload folder does not have; then both modes write the payload in.
                let removed = replace == true
                    ? try removeExtras(from: paths.destination, keeping: Set(files.files(in: paths.source, excluding: excluded)), context: context)
                    : 0
                let written: Int
                if template {
                    written = try TemplatedTree(source: paths.source, excluding: excluded, action: self, context: context)
                        .install(to: paths.destination, backup: backup, context: context)
                } else {
                    written = try files.installDirectory(from: paths.source, to: paths.destination, replace: false,
                                                         backup: backup, excluding: excluded)
                }
                // In a dry run the folder may not exist yet; its creation was already narrated.
                if let mode, !(context.dryRun && !files.isDirectory(paths.destination)) {
                    try files.ensureDirectory(paths.destination, permissions: mode)
                }
                return .done(Self.summary(written: written, removed: removed, destination: shown, source: source, dryRun: context.dryRun))
            }
            // Writing a file where a folder is would back the whole folder up (or, with `backup: false`, delete it).
            // That is nearly always a missing file name or trailing `/` in `to:`, so it is refused.
            if files.isDirectory(paths.destination) {
                throw ActionError("\(shown) is a folder; copying the file files/\(source) there would replace it",
                                  hint: "use 'to: \(shown)/' to copy it into the folder, or give the full path of the file")
            }
            let data = try contents(of: paths.source, context: context)
            let change = try files.write(data, to: paths.destination, permissions: mode ?? files.permissions(of: paths.source), backup: backup)
            return .done(context.describe(change, paths.destination))
        } catch let error as ActionError {
            throw error
        } catch {
            throw context.fileError(error, doing: "copy files/\(source) to \(shown)")
        }
    }

    /// A folder at the destination where a folder payload has a file or a link.
    struct FolderInTheWay {
        /// The payload entry, relative to the payload folder.
        let relative: String
        let destination: URL
        let isLink: Bool
    }

    /// Merge mode leaves alone whatever the payload does not have, so it never writes a payload file where the
    /// destination holds a folder: that would move the whole folder to the backups or, with `backup: false`, delete
    /// it. A link to a folder counts as a folder, as for a file payload; only a payload link may replace a link.
    /// A mirror (`replace: true`) is asked to make the destination exactly the payload, so it replaces the folder.
    func folderInTheWay(_ paths: Paths, files: FileOps) -> FolderInTheWay? {
        // A destination that is not a real folder (missing, a file, a link) is replaced whole: nothing inside it is written over.
        guard replace != true, files.isDirectory(paths.destination), !files.isSymlink(paths.destination) else { return nil }
        for relative in files.files(in: paths.source, excluding: excluded) {
            let destination = paths.destination.appendingPathComponent(relative)
            guard files.isDirectory(destination) else { continue }
            let isLink = files.isSymlink(paths.source.appendingPathComponent(relative))
            if isLink && files.isSymlink(destination) { continue }
            return FolderInTheWay(relative: relative, destination: destination, isLink: isLink)
        }
        return nil
    }

    /// "copied 2 files to ~/.config/kb and removed 1 not in files/kb", or "~/.config/kb up to date".
    static func summary(written: Int, removed: Int, destination: String, source: String, dryRun: Bool) -> String {
        if written == 0 && removed == 0 { return "\(destination) up to date" }
        let copy = dryRun ? "would copy" : "copied"
        let remove = dryRun ? "remove" : "removed"
        if written == 0 {
            return "\(dryRun ? "would remove" : "removed") \(counted(removed, "file")) not in files/\(source) from \(destination)"
        }
        let copied = "\(copy) \(counted(written, "file")) to \(destination)"
        return removed == 0 ? copied : "\(copied) and \(remove) \(removed) not in files/\(source)"
    }

    /// `replace: true`: removes the files under `destination` that the payload folder does not have (backed up
    /// unless `backup: false`), then any folder that left empty. Names in `excluded` (`exclude:`, `.git`,
    /// `.DS_Store`) are not part of the mirror, and `check` ignores them too, so they stay where they are.
    /// Returns how many files were (or, in a dry run, would be) removed.
    func removeExtras(from destination: URL, keeping wanted: Set<String>, context: ActionContext) throws -> Int {
        let files = context.files
        // Only a real folder is pruned. A link or a file in its place is replaced whole by the install that follows.
        guard files.isDirectory(destination), !files.isSymlink(destination) else { return 0 }
        // Below a linked folder (stow-style), the link is swapped for a real folder first, so nothing is removed
        // from the checkout it points into. In a dry run that is only narrated, and nothing is removed anyway.
        if files.symlinkedAncestor(of: destination) != nil {
            try files.ensureDirectory(destination)
        }
        let extras = files.files(in: destination, excluding: excluded).filter { !wanted.contains($0) }
        for relative in extras {
            try files.remove(destination.appendingPathComponent(relative), backup: backup)
        }
        if !context.dryRun {
            try removeEmptiedFolders(after: extras, in: destination, keeping: wanted, files: files)
        }
        return extras.count
    }

    /// Folders whose last file the mirror just removed, deepest first. A folder the payload also has, or one still
    /// holding something (an excluded `.DS_Store`, say), is kept.
    private func removeEmptiedFolders(after removed: [String], in destination: URL, keeping wanted: Set<String>, files: FileOps) throws {
        var payloadFolders = Set<String>()
        for relative in wanted {
            var folder = (relative as NSString).deletingLastPathComponent
            while !folder.isEmpty {
                payloadFolders.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        var candidates = Set<String>()
        for relative in removed {
            var folder = (relative as NSString).deletingLastPathComponent
            while !folder.isEmpty, !payloadFolders.contains(folder) {
                candidates.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        for folder in candidates.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let url = destination.appendingPathComponent(folder)
            guard files.isDirectory(url), !files.isSymlink(url),
                  (try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty else { continue }
            try files.remove(url, backup: false)
        }
    }
}

/// A payload folder with `{{vars}}` expanded in its text files, installed with the same rules as
/// `FileOps.installDirectory` in merge mode (for a mirror, `CopyAction.removeExtras` runs first).
struct TemplatedTree {
    enum Content {
        case file(Data, permissions: Int?)
        case link(String)
    }

    let entries: [(relative: String, content: Content)]
    let excluding: Set<String>

    init(source: URL, excluding: Set<String>, action: CopyAction, context: ActionContext) throws {
        self.excluding = excluding
        var entries: [(relative: String, content: Content)] = []
        for relative in context.files.files(in: source, excluding: excluding) {
            let url = source.appendingPathComponent(relative)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                entries.append((relative, .link(target)))
            } else {
                entries.append((relative, .file(try action.contents(of: url, context: context), permissions: context.files.permissions(of: url))))
            }
        }
        self.entries = entries
    }

    func matches(_ destination: URL, exact: Bool, files: FileOps) -> Bool {
        guard files.isDirectory(destination), !files.isSymlink(destination) else { return false }
        for entry in entries {
            let url = destination.appendingPathComponent(entry.relative)
            switch entry.content {
            case .file(let data, let permissions):
                if !files.fileMatches(data, at: url, permissions: permissions) { return false }
            case .link(let target):
                if !files.symlinkMatches(at: url, target: target) { return false }
            }
        }
        return !exact || files.files(in: destination, excluding: excluding) == entries.map(\.relative)
    }

    /// Writes every entry into `destination`, leaving anything else there alone. Returns the number of files that changed.
    func install(to destination: URL, backup: Bool, context: ActionContext) throws -> Int {
        let files = context.files
        if matches(destination, exact: false, files: files) { return 0 }
        // A file or link where the folder should be is moved aside (or removed with `backup: false`).
        let wrongKind = files.isSymlink(destination) || (files.exists(destination) && !files.isDirectory(destination))
        if wrongKind {
            try files.remove(destination, backup: backup)
        }
        if wrongKind && context.dryRun {
            // The old item is still on disk in a dry run, so the folder cannot be checked for; only say what would happen.
            context.info("[dry-run] mkdir \(context.display(destination))")
        } else {
            try files.ensureDirectory(destination)
        }
        var changed = 0
        for entry in entries {
            let url = destination.appendingPathComponent(entry.relative)
            switch entry.content {
            case .file(let data, let permissions):
                if try files.write(data, to: url, permissions: permissions, backup: backup).didChange { changed += 1 }
            case .link(let target):
                if try files.symlink(at: url, pointingTo: target, backup: backup).didChange { changed += 1 }
            }
        }
        return changed
    }
}
