import Foundation
import ShawnCore

/// `dock:` sets the Dock's apps (in order), folders and settings, written straight into `com.apple.dock`.
///
/// Tiles use the minimal format Apple's own default Dock and dockutil write (see research/apps-dock-system.md):
/// `tile-data.file-data {_CFURLString: <POSIX path>, _CFURLStringType: 0}` plus `file-label` and `file-type`.
/// The Dock fills in bookmarks, bundle ids and dates itself when it restarts, and rewrites the path as a
/// `file://` URL, so comparisons normalize both spellings.
struct DockAction: Action {
    struct AppEntry: Sendable, Equatable {
        /// The app, then its fallbacks: names (`Google Chrome`) or paths. The first one found is used, unless a
        /// later one that is also installed is already in the Dock.
        let candidates: [String]
    }

    struct FolderEntry: Sendable, Equatable {
        let path: String
        /// Dock `showas`: 0 auto, 1 fan, 2 grid, 3 list.
        let view: Int
        /// Dock `displayas`: 0 stack, 1 folder.
        let display: Int
        /// Dock `arrangement`: 1 name, 2 date added, 3 modified, 4 created, 5 kind.
        let sort: Int
    }

    static let domainName = "com.apple.dock"
    static let views = ["auto": 0, "fan": 1, "grid": 2, "list": 3]
    static let displays = ["stack": 0, "folder": 1]
    static let sorts = ["name": 1, "added": 2, "modified": 3, "created": 4, "kind": 5]

    let apps: [AppEntry]
    let folders: [FolderEntry]
    let settings: [(key: String, value: PlistValue)]
    let clear: Bool
    /// How long to wait for a brand-new account's Dock to finish setting itself up before writing over it.
    var seedTimeout: TimeInterval = 30

    var title: String { "Dock" }

    var subtitle: String? {
        var parts = [counted(apps.count, "app")]
        if !folders.isEmpty { parts.append(counted(folders.count, "folder")) }
        if !settings.isEmpty { parts.append(counted(settings.count, "setting")) }
        if clear { parts.append("nothing else") }
        return parts.joined(separator: ", ")
    }

    static let descriptor = ActionDescriptor(
        kind: "dock",
        summary: "Lay out the Dock: apps in order (missing ones are skipped), folders, and com.apple.dock settings; restarts the Dock once.",
        example: """
        - dock:
            apps:
              - Google Chrome
              - {app: Aero Dogfood, fallback: Aero}   # first one installed (one already in the Dock stays)
              - ~/Applications/Carbon.app
            folders:
              - {path: ~/Developer, view: grid, display: folder, sort: name}
            settings:
              autohide: true
              tilesize: 128            # stored as a float, like the Dock does
            clear: true                # remove everything not listed (default)
        """,
        make: { try make($0) }
    )

    private static func make(_ parser: ItemParser) throws -> any Action {
        guard parser.primary.map != nil else {
            if parser.primary.isNull, ["apps", "folders", "settings", "clear"].contains(where: parser.options.has) {
                parser.fail("indent 'apps:', 'folders:', 'settings:' and 'clear:' under 'dock:' (they belong to its mapping)")
                parser.options.allow("apps", "folders", "settings", "clear")
            } else {
                parser.fail("'dock' must be a mapping with 'apps:', 'folders:' and/or 'settings:'")
            }
            return DockAction(apps: [], folders: [], settings: [], clear: true)
        }
        guard let reader = parser.primaryReader() else { return DockAction(apps: [], folders: [], settings: [], clear: true) }

        var apps: [AppEntry] = []
        for (index, element) in reader.list("apps").enumerated() {
            if let name = element.string, !name.isEmpty {
                apps.append(AppEntry(candidates: [name]))
            } else if let map = element.map {
                let entry = MapReader(map: map, source: reader.source, context: "\(reader.context) → apps[\(index + 1)]", collector: reader.collector)
                let app = entry.requiredString("app")
                let fallbacks = entry.stringList("fallback")
                entry.finish()
                if !app.isEmpty { apps.append(AppEntry(candidates: [app] + fallbacks)) }
            } else {
                reader.error("'apps' entry \(index + 1) must be an app name, a path, or {app: …, fallback: …}", key: "apps")
            }
        }

        var folders: [FolderEntry] = []
        for folder in reader.readers("folders") {
            let path = folder.requiredString("path")
            let view = folder.oneOf("view", Array(views.keys).sorted(), default: "auto")
            let display = folder.oneOf("display", Array(displays.keys).sorted(), default: "folder")
            let sort = folder.oneOf("sort", Array(sorts.keys).sorted(), default: "name")
            folder.finish()
            if !path.isEmpty {
                folders.append(FolderEntry(path: path, view: views[view] ?? 0, display: displays[display] ?? 1, sort: sorts[sort] ?? 1))
            }
        }

        let settings = DefaultsAction.preferenceValues(reader, key: "settings", domain: domainName, required: false)
        for key in settings.map(\.key) where ["persistent-apps", "persistent-others"].contains(key) {
            reader.error("set '\(key)' with 'apps:' / 'folders:', not under 'settings:'", key: "settings")
        }
        let clear = reader.bool("clear", default: true)
        if apps.isEmpty && folders.isEmpty && settings.isEmpty && !reader.collector.hasErrors {
            reader.error("'dock' needs at least one of 'apps:', 'folders:' or 'settings:'")
        }
        reader.finish()
        return DockAction(apps: apps, folders: folders, settings: settings, clear: clear)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, apps.flatMap { $0.candidates.map { ("apps", $0) } } + folders.map { ("folders.path", $0.path) })
    }

    // MARK: Resolution

    /// Where app names are looked up, in order.
    static func searchDirectories(_ environment: SystemEnvironment) -> [URL] {
        [
            environment.applicationsDirectory,
            MachinePaths.system("/System/Applications", in: environment),
            MachinePaths.system("/System/Applications/Utilities", in: environment),
            environment.userApplicationsDirectory,
            environment.applicationsDirectory.appendingPathComponent("Utilities"),
        ]
    }

    /// The installed app for one name or path, or nil.
    static func locateApp(_ text: String, context: ActionContext) -> URL? {
        let expanded = context.expand(text)
        if Naming.looksLikePath(expanded) {
            let url = context.path(expanded)
            return context.files.isDirectory(url) ? url.standardizedFileURL : nil
        }
        let bundleName = expanded.hasSuffix(".app") ? expanded : expanded + ".app"
        for directory in searchDirectories(context.environment) {
            let candidate = directory.appendingPathComponent(bundleName)
            if context.files.isDirectory(candidate) { return candidate.standardizedFileURL }
        }
        return nil
    }

    struct Layout {
        var apps: [URL] = []
        var folders: [(url: URL, entry: FolderEntry)] = []
        /// Human-readable notes about entries that were left out.
        var skipped: [String] = []
    }

    /// Resolves names and paths against this Mac. Missing apps and folders are left out, never an error.
    /// When several candidates of one entry are installed (Aero and Aero Dogfood), the one already among the Dock's
    /// `current` apps is kept, so a re-run never swaps a tile the user has for another build; otherwise the first
    /// installed one is used. With `narrate`, a fallback being used is mentioned in the log.
    func layout(_ context: ActionContext, current: [String: PlistValue], narrate: Bool) -> Layout {
        var layout = Layout()
        let inDock = Set((current["persistent-apps"]?.array ?? []).compactMap { tile -> String? in
            if case .file(let path) = Self.identity(of: tile) { return path }
            return nil
        })
        for entry in apps {
            let installed = entry.candidates.compactMap { candidate in Self.locateApp(candidate, context: context).map { (candidate, $0) } }
            guard let firstInstalled = installed.first else {
                let tried = entry.candidates.joined(separator: " or ")
                layout.skipped.append("\(tried) is not installed")
                continue
            }
            let (chosen, found) = installed.first { inDock.contains(Self.canonicalPath($0.1.path)) } ?? firstInstalled
            if narrate, let preferred = entry.candidates.first, chosen != preferred {
                if firstInstalled.0 == preferred {
                    context.info("keeping \(Naming.appName(found.path)), which is already in the Dock (\(preferred) is installed too)")
                } else {
                    context.info("\(preferred) is not installed; using \(Naming.appName(found.path)) instead")
                }
            }
            let identity = Self.canonicalPath(found.path)
            if !layout.apps.contains(where: { Self.canonicalPath($0.path) == identity }) { layout.apps.append(found) }
        }
        for entry in folders {
            let url = context.path(entry.path).standardizedFileURL
            guard context.files.isDirectory(url) else {
                layout.skipped.append("folder \(context.display(url)) does not exist")
                continue
            }
            layout.folders.append((url, entry))
        }
        return layout
    }

    // MARK: Tiles

    /// What a tile points at, normalized so the Dock's own `file://` spelling compares equal to a plain path.
    enum TileIdentity: Equatable {
        case file(String)
        case folder(path: String, view: Int?, display: Int?, sort: Int?)
        case other(String)
    }

    static func appTile(_ url: URL) -> PlistValue {
        .dict([
            "tile-data": .dict([
                "file-data": .dict(["_CFURLString": .string(url.path), "_CFURLStringType": .int(0)]),
                "file-label": .string(Naming.appName(url.path)),
                "file-type": .int(41),
            ]),
            "tile-type": .string("file-tile"),
        ])
    }

    static func folderTile(_ url: URL, _ entry: FolderEntry) -> PlistValue {
        .dict([
            "tile-data": .dict([
                "arrangement": .int(entry.sort),
                "directory": .int(1),
                "displayas": .int(entry.display),
                "file-data": .dict(["_CFURLString": .string(url.path), "_CFURLStringType": .int(0)]),
                "file-label": .string(url.lastPathComponent),
                "file-type": .int(2),
                "showas": .int(entry.view),
            ]),
            "tile-type": .string("directory-tile"),
        ])
    }

    static func identity(of tile: PlistValue) -> TileIdentity {
        let type = tile.dict?["tile-type"]?.string ?? "file-tile"
        guard let data = tile.dict?["tile-data"]?.dict, let location = location(of: tile) else {
            return .other(type)
        }
        let path = canonicalPath(location)
        if type == "directory-tile" || data["directory"]?.int == 1 {
            return .folder(path: path, view: data["showas"]?.int, display: data["displayas"]?.int, sort: data["arrangement"]?.int)
        }
        return .file(path)
    }

    /// The path a tile points at, as the Dock spells it: `file:///Applications/Google%20Chrome.app/` and
    /// `/Applications/Google Chrome.app` both give `/Applications/Google Chrome.app`.
    static func location(of tile: PlistValue) -> String? {
        guard let fileData = tile.dict?["tile-data"]?.dict?["file-data"]?.dict, let location = fileData["_CFURLString"]?.string else { return nil }
        if fileData["_CFURLStringType"]?.int == 15 || location.hasPrefix("file://"), let url = URL(string: location), url.isFileURL {
            return url.path
        }
        return location
    }

    /// Where a path really leads, which is what tiles are compared by. Since macOS 13 `/Applications/Safari.app` is a
    /// link into the Safari cryptex, and the Dock's own Safari tile names the cryptex path; both are the same Safari.
    /// New tiles still use the path as found (`appTile`), the way Apple's default Dock spells it.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func identity(of url: URL, _ entry: FolderEntry) -> TileIdentity {
        .folder(path: canonicalPath(url.path), view: entry.view, display: entry.display, sort: entry.sort)
    }

    /// The new contents of one Dock section, or nil when it already matches.
    static func section(current: [PlistValue], wanted: [(identity: TileIdentity, tile: PlistValue)], clear: Bool,
                        samePlace: (TileIdentity, TileIdentity) -> Bool) -> [PlistValue]? {
        // Worked out once per tile: an identity resolves links on disk.
        let currentIdentities = current.map(identity(of:))
        if clear {
            guard currentIdentities != wanted.map(\.identity) else { return nil }
            // Keep a tile the Dock already knows (its bookmark and GUID) when it points at the same thing.
            return wanted.map { item in
                currentIdentities.firstIndex(of: item.identity).map { current[$0] } ?? item.tile
            }
        }
        var result = current
        var resultIdentities = currentIdentities
        var changed = false
        for item in wanted where !currentIdentities.contains(item.identity) {
            if let index = resultIdentities.firstIndex(where: { samePlace($0, item.identity) }) {
                result[index] = item.tile
                resultIdentities[index] = item.identity
            } else {
                result.append(item.tile)
                resultIdentities.append(item.identity)
            }
            changed = true
        }
        return changed ? result : nil
    }

    /// Two folder tiles for the same path are one place, whatever their view settings.
    static func samePlace(_ lhs: TileIdentity, _ rhs: TileIdentity) -> Bool {
        if case .folder(let left, _, _, _) = lhs, case .folder(let right, _, _, _) = rhs { return left == right }
        return lhs == rhs
    }

    /// Everything to write, given the Dock's current preferences.
    func changes(current: [String: PlistValue], layout: Layout, context: ActionContext) -> [PreferenceChange] {
        var changes: [PreferenceChange] = []
        let wantedApps = layout.apps.map { (identity: TileIdentity.file(Self.canonicalPath($0.path)), tile: Self.appTile($0)) }
        if let apps = Self.section(current: current["persistent-apps"]?.array ?? [], wanted: wantedApps, clear: clear, samePlace: Self.samePlace) {
            changes.append(PreferenceChange(key: "persistent-apps", value: .array(apps)))
        }
        let wantedFolders = layout.folders.map { (identity: Self.identity(of: $0.url, $0.entry), tile: Self.folderTile($0.url, $0.entry)) }
        if let others = Self.section(current: current["persistent-others"]?.array ?? [], wanted: wantedFolders, clear: clear, samePlace: Self.samePlace) {
            changes.append(PreferenceChange(key: "persistent-others", value: .array(others)))
        }
        let wantedSettings = settings.map { ($0.key, $0.value.mapStrings(context.expand)) }
        changes += Preferences.differences(current: current, wanted: wantedSettings)
        return changes
    }

    // MARK: Check & run

    func check(_ context: ActionContext) async -> CheckResult {
        let domain = PreferenceDomain(Self.domainName)
        let current: [String: PlistValue]
        do {
            current = try await Preferences.store(for: context).read(domain)
        } catch {
            return .needed("could not read the Dock's preferences: \(InstallEngine.describe(error))")
        }
        let layout = layout(context, current: current, narrate: false)
        let pending = changes(current: current, layout: layout, context: context)
        if pending.isEmpty { return .satisfied("Dock already set up") }
        return .needed("to change: \(pending.map(\.key).joined(separator: ", "))")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let domain = PreferenceDomain(Self.domainName)
        let store = Preferences.store(for: context)
        var current = try await store.read(domain)
        if !context.environment.isSandbox && !context.dryRun {
            current = try await Self.waitForDockSetup(store: store, current: current, timeout: seedTimeout, context: context)
        }
        let layout = layout(context, current: current, narrate: true)
        for note in layout.skipped { context.warn("Dock: skipping \(note)") }

        let pending = changes(current: current, layout: layout, context: context)
        let skippedNote = layout.skipped.isEmpty ? "" : " (skipped \(layout.skipped.count) missing)"
        guard !pending.isEmpty else { return .done("Dock already set up\(skippedNote)") }

        try savePrevious(current, before: pending, context: context)
        for change in pending {
            switch change.key {
            case "persistent-apps":
                context.info("Dock apps: \(layout.apps.map { Naming.appName($0.path) }.joined(separator: ", "))")
            case "persistent-others":
                context.info("Dock folders: \(layout.folders.map { context.display($0.url) }.joined(separator: ", "))")
            default:
                context.info("Dock \(change.key): \(current[change.key].map(\.description) ?? "unset") → \(change.value)")
            }
        }
        try await store.write(pending, to: domain, asRoot: false)
        await ProcessRestarter().restart(["Dock"], context: context)
        let verb = context.dryRun ? "would set up" : "set up"
        return .done("\(verb) \(counted(layout.apps.count, "app")), \(counted(layout.folders.count, "folder"))\(skippedNote)")
    }

    /// The Dock is rewritten in place, so the layout being replaced is kept: its apps and folders go into the log,
    /// and the whole `com.apple.dock` domain is saved to this run's backups folder, from where
    /// `defaults import com.apple.dock <file>` followed by `killall Dock` brings it back. Only the first Dock change
    /// of a run is saved: that copy is the Dock from before the run. Fails, changing nothing, if it cannot be saved.
    func savePrevious(_ current: [String: PlistValue], before pending: [PreferenceChange], context: ActionContext) throws {
        let keys = Set(pending.map(\.key))
        if keys.contains("persistent-apps") {
            let names = (current["persistent-apps"]?.array ?? []).compactMap { tile -> String? in
                tile.dict?["tile-data"]?.dict?["file-label"]?.string ?? Self.location(of: tile).map(Naming.appName)
            }
            context.info("Dock apps were: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        if keys.contains("persistent-others") {
            let folders = (current["persistent-others"]?.array ?? []).compactMap { Self.location(of: $0) }
            context.info("Dock folders were: \(folders.isEmpty ? "none" : folders.map { context.display(URL(fileURLWithPath: $0)) }.joined(separator: ", "))")
        }

        let saved = context.environment.backupDirectory.appendingPathComponent("Library/Preferences/\(Self.domainName).plist")
        guard !current.isEmpty, !context.files.exists(saved) else { return }
        do {
            try context.files.write(try PlistValue.encode(current, format: .xml), to: saved, permissions: 0o600, backup: false)
        } catch {
            throw ActionError("could not save the current Dock to \(context.display(saved)) before changing it, so it was left as it is: \(InstallEngine.describe(error))",
                              hint: "check that ~/.shawn/backups can be written to, then run this step again")
        }
        if !context.dryRun {
            context.info("saved the previous Dock to \(context.display(saved)) (to go back: defaults import \(Self.domainName) <that file>, then killall Dock)")
        }
    }

    /// On a brand-new account the Dock fills in its default tiles right after login; writing before it has
    /// (its `mod-count` is still below 2) gets overwritten. Waits up to `timeout` and returns the latest values.
    static func waitForDockSetup(store: any PreferencesStore, current: [String: PlistValue], timeout: TimeInterval,
                                 context: ActionContext) async throws -> [String: PlistValue] {
        var values = current
        guard (values["mod-count"]?.int ?? 0) < 2 else { return values }
        context.info("waiting for the Dock to finish setting itself up…")
        let deadline = Date().addingTimeInterval(timeout)
        while (values["mod-count"]?.int ?? 0) < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            values = try await store.read(PreferenceDomain(domainName))
        }
        return values
    }
}
