import Foundation
import ShawnCore

/// `- download: https://…/Thing.dmg` installs an app that is not in Homebrew or the App Store.
///
/// The file goes to the installer's cache with curl, is checked (sha256 if given; Gatekeeper and the
/// signing team unless `verify: false`) and only then copied into place. Disk images are always detached
/// and downloads always removed, also on failure or cancellation. An app being replaced is moved to the
/// run's backup folder first, and put back if the copy fails.
struct DownloadAction: Action {
    enum FileType: String, CaseIterable {
        case dmg, zip, pkg
    }

    /// As written; may contain `{{vars}}`.
    let url: String
    let type: FileType
    /// The app bundle's name, e.g. `Aero Dogfood.app`.
    let app: String?
    /// Where the app goes; default `{{applications}}`.
    let destination: String
    let sha256: String?
    let teamID: String?
    let verify: Bool
    let replace: Bool
    let launch: Bool
    let system: MacSystem

    var title: String {
        if let app { return Common.appDisplayName(app) }
        let name = Self.fileName(of: url)
        return (name as NSString).deletingPathExtension
    }
    var subtitle: String? { url }
    var sudo: SudoNeed { type == .pkg ? .always : .never }

    static func parse(_ parser: ItemParser, system: MacSystem) -> DownloadAction {
        let url = parser.primaryString()
        let options = parser.options
        if !url.isEmpty, !["https://", "http://", "file://", "{{"].contains(where: { url.hasPrefix($0) }) {
            parser.fail("'download' must be the address of a .dmg, .zip or .pkg (https://…), got '\(url)'")
        }
        let typeText = options.oneOf("type", ["auto"] + FileType.allCases.map(\.rawValue), default: "auto")
        var type = FileType(rawValue: typeText)
        if typeText == "auto" {
            type = detectType(url)
            if type == nil && !url.isEmpty {
                parser.fail("cannot tell from the address whether it is a dmg, zip or pkg; add 'type: dmg', 'type: zip' or 'type: pkg'")
            }
        }
        let app = options.string("app").map(Common.appBundleName)
        if let app, app.contains("/") {
            options.error("'app' is the app's name inside the download, like 'Aero Dogfood.app'; use 'to:' for where it goes", key: "app")
        }
        let destination = options.string("to", default: "{{applications}}")
        let sha256 = options.string("sha256")
        if let sha256, sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) == nil {
            options.error("'sha256' must be 64 hexadecimal characters", key: "sha256")
        }
        let teamID = options.string("team_id")
        if let teamID, teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) == nil {
            options.error("'team_id' must be a 10-character Developer ID team, like 'ZL4K35VM2L'", key: "team_id")
        }
        let verify = options.bool("verify", default: true)
        if !verify && teamID != nil {
            options.error("'team_id' is only checked when 'verify' is true; remove one of them", key: "team_id")
        }
        let replace = options.bool("replace", default: false)
        let launch = options.bool("launch", default: false)
        if launch && type == .pkg && app == nil {
            options.error("'launch: true' on a package needs 'app:' to know what to open", key: "launch")
        }
        return DownloadAction(url: url, type: type ?? .dmg, app: app, destination: destination, sha256: sha256, teamID: teamID,
                              verify: verify, replace: replace, launch: launch, system: system)
    }

    static func detectType(_ url: String) -> FileType? {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        switch (path.split(separator: "#").first.map(String.init) ?? path).lowercased().split(separator: ".").last {
        case "dmg": return .dmg
        case "zip": return .zip
        case "pkg", "mpkg": return .pkg
        default: return nil
        }
    }

    /// The last path component, made safe for a file name.
    static func fileName(of url: String) -> String {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let last = path.split(separator: "/").last.map(String.init) ?? "download"
        let decoded = last.removingPercentEncoding ?? last
        let safe = decoded.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" }
        return safe.isEmpty ? "download" : String(safe)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Common.unknownVariables(context, [("download", url), ("app", app), ("to", destination)])
    }

    // MARK: Paths

    private func destinationDirectory(_ context: ActionContext) -> URL {
        context.path(destination)
    }

    /// Where the app is (or will be): from `app:`, or remembered from an earlier run when the download had exactly one app.
    func installedAppURL(_ context: ActionContext) -> URL? {
        let name = app.map(context.expand) ?? (type == .pkg ? nil : DownloadRecord.appName(for: context.expand(url), context))
        return name.map { destinationDirectory(context).appendingPathComponent($0) }
    }

    // MARK: Check

    func check(_ context: ActionContext) async -> CheckResult {
        guard let appURL = installedAppURL(context) else { return .needed(nil) }
        guard context.files.exists(appURL) else { return .needed(nil) }
        if replace { return .needed("\(appURL.lastPathComponent) is there, but 'replace: true' installs it again") }
        return .satisfied("\(appURL.lastPathComponent) is already in \(context.display(appURL.deletingLastPathComponent()))")
    }

    // MARK: Run

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let source = context.expand(url)
        guard let remote = URL(string: source), remote.scheme != nil else {
            throw ActionError("'\(source)' is not a valid address", hint: "fix the address on this item")
        }
        if context.dryRun { return try await narrate(remote, context) }
        if !replace, let existing = installedAppURL(context), context.files.exists(existing) {
            return .done("\(existing.lastPathComponent) is already installed")
        }
        // Disk images and zips only write into 'to:'; a package installs wherever it likes, as root.
        if type == .pkg, let refusal = Common.sandboxRefusal("running a system-wide installer package", context, system: system) {
            return refusal
        }

        let file = try await Downloader.fetch(remote, fileName: Self.fileName(of: source), context, system: system)
        defer { Downloader.discard(file, context) }
        if let sha256 {
            try Downloader.verifyChecksum(of: file, expected: sha256, source: source)
            context.success("sha256 matches")
        }

        let placement: Placement
        switch type {
        case .dmg: placement = try await installFromImage(file, source: source, context)
        case .zip: placement = try await installFromArchive(file, source: source, context)
        case .pkg: placement = try await installPackage(file, context)
        }

        if launch, let installed = placement.app {
            try await Common.open(["-g", "-a", installed.path], context, system: system)
        }
        guard let installed = placement.app else { return .done("installed") }
        return .done(placement.isNew ? "installed \(installed.lastPathComponent)" : "\(installed.lastPathComponent) was already there")
    }

    /// Where the app ended up, and whether this run put it there.
    private struct Placement {
        let app: URL?
        let isNew: Bool
    }

    /// What a dry run shows: the same commands, with placeholders for what only the download would reveal.
    private func narrate(_ remote: URL, _ context: ActionContext) async throws -> ActionOutcome {
        let file = try await Downloader.fetch(remote, fileName: Self.fileName(of: remote.absoluteString), context, system: system)
        if sha256 != nil { context.info("[dry-run] would check the sha256") }
        let appName = app.map(context.expand) ?? "<the app inside>"
        let target = destinationDirectory(context).appendingPathComponent(appName)
        let checks = verify ? "Gatekeeper" + (teamID.map { " and team \($0)" } ?? "") : nil
        switch type {
        case .dmg:
            let mountPoint = context.environment.temporaryDirectory.appendingPathComponent("shawn-mount")
            try await context.run(Command(system.hdiutil, ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, file.path]))
            if let checks { context.info("[dry-run] would check \(appName) with \(checks)") }
            try await context.run(Command(system.ditto, [mountPoint.appendingPathComponent(appName).path, target.path]))
            try await context.run(Command(system.hdiutil, ["detach", mountPoint.path]))
        case .zip:
            let scratch = context.environment.temporaryDirectory.appendingPathComponent("shawn-unzip")
            try await context.run(Command(system.ditto, ["-x", "-k", file.path, scratch.path]))
            if let checks { context.info("[dry-run] would check \(appName) with \(checks)") }
            try await context.run(Command(system.ditto, [scratch.appendingPathComponent(appName).path, target.path]))
        case .pkg:
            if let checks { context.info("[dry-run] would check the package's signature with \(checks)") }
            try await context.run(Command(system.installer, ["-pkg", file.path, "-target", "/"]).asRoot())
        }
        if launch { try await context.run(Command(system.open, ["-g", "-a", target.path])) }
        return .done(nil)
    }

    private func installFromImage(_ image: URL, source: String, _ context: ActionContext) async throws -> Placement {
        let mountPoint = try await Downloader.attach(image, context, system: system)
        do {
            let appName = try Downloader.findApp(in: mountPoint, named: app.map(context.expand), source: "the disk image")
            let placement = try await place(mountPoint.appendingPathComponent(appName), source: source, context)
            await Downloader.detach(mountPoint, context, system: system)
            return placement
        } catch {
            await Downloader.detach(mountPoint, context, system: system)
            throw error
        }
    }

    private func installFromArchive(_ archive: URL, source: String, _ context: ActionContext) async throws -> Placement {
        let scratch = try Common.makeScratchDirectory(context, prefix: "unzip")
        defer { Common.removeScratch(scratch, context) }
        let unpack = try await context.run(Command(system.ditto, ["-x", "-k", archive.path, scratch.path]))
        guard unpack.succeeded else {
            throw ActionError("Could not unpack the zip archive: \(unpack.tail(3))",
                              hint: "the download may be damaged or not a zip archive. Run the installer again, or set 'type:' on the item")
        }
        let appName = try Downloader.findApp(in: scratch, named: app.map(context.expand), source: "the zip archive")
        return try await place(scratch.appendingPathComponent(appName), source: source, context)
    }

    private func installPackage(_ package: URL, _ context: ActionContext) async throws -> Placement {
        if verify {
            try await Downloader.verifyPackage(package, displayName: title, teamID: teamID, context, system: system)
        }
        let appURL = installedAppURL(context)
        var backup: URL?
        if let appURL, replace, context.files.exists(appURL) {
            backup = try context.files.backUp(appURL)
        }
        do {
            try await context.runChecked(Command(system.installer, ["-pkg", package.path, "-target", "/"]).asRoot())
        } catch {
            if let appURL, let backup, !context.files.exists(appURL) { restore(backup, to: appURL, context) }
            throw error
        }
        if let appURL, !context.files.exists(appURL) {
            context.warn("The package installed, but \(context.display(appURL)) is not there. Check 'app:' and 'to:' on this item.")
        }
        return Placement(app: appURL, isNew: true)
    }

    /// Checks the app, then copies it into place (backing up a copy it replaces, and restoring that if the copy fails).
    private func place(_ app: URL, source: String, _ context: ActionContext) async throws -> Placement {
        if verify {
            try await Downloader.verifyApp(app, teamID: teamID, context, system: system)
        }
        let directory = destinationDirectory(context)
        try context.files.ensureDirectory(directory)
        let target = directory.appendingPathComponent(app.lastPathComponent)

        var backup: URL?
        if context.files.exists(target) {
            guard replace else {
                // Only reachable when the app's name was not known before downloading.
                try rememberAppName(app.lastPathComponent, source: source, context)
                context.info("\(target.lastPathComponent) is already there; leaving it alone ('replace: true' would install over it).")
                return Placement(app: target, isNew: false)
            }
            backup = try context.files.backUp(target)
        }

        do {
            try await context.runChecked(Command(system.ditto, [app.path, target.path]))
        } catch {
            removePartialCopy(target, backup: backup, context)
            if let backup { restore(backup, to: target, context) }
            throw error
        }
        try rememberAppName(app.lastPathComponent, source: source, context)
        return Placement(app: target, isNew: true)
    }

    private func removePartialCopy(_ target: URL, backup: URL?, _ context: ActionContext) {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            let failure = "Could not remove the half-copied \(context.display(target)): \(error.localizedDescription)"
            context.warn(backup.map { ActionError.sentences(failure, "the previous copy is in \(context.display($0))") } ?? failure)
        }
    }

    /// Puts an app that was backed up for replacing back where it was, after the replacement failed.
    private func restore(_ backup: URL, to target: URL, _ context: ActionContext) {
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.moveItem(at: backup, to: target)
            context.info("Put the previous \(target.lastPathComponent) back.")
        } catch {
            context.warn(ActionError.sentences("Could not put the previous \(target.lastPathComponent) back: \(error.localizedDescription)",
                                               "it is in \(context.display(backup))"))
        }
    }

    private func rememberAppName(_ name: String, source: String, _ context: ActionContext) throws {
        guard app == nil else { return }
        try DownloadRecord.remember(name, for: source, context)
    }
}

/// Which app each `download:` without `app:` turned out to contain, so later runs can tell it is installed.
/// Kept in `~/.shawn/state/downloads.json` as `{ "<url>": "<Name>.app" }`.
enum DownloadRecord {
    static func file(_ context: ActionContext) -> URL {
        context.environment.stateDirectory.appendingPathComponent("state/downloads.json")
    }

    static func load(_ context: ActionContext) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: file(context).path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    static func appName(for url: String, _ context: ActionContext) -> String? {
        load(context)[url]
    }

    static func remember(_ appName: String, for url: String, _ context: ActionContext) throws {
        var record = load(context)
        guard record[url] != appName else { return }
        record[url] = appName
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try context.files.write(data + Data("\n".utf8), to: file(context), backup: false)
    }
}
