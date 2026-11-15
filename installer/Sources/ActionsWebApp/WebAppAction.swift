import CoreGraphics
import Foundation
import ShawnCore

/// Builds `<to>/<Name>.app`: a copy of WebAppShell, an Info.plist naming the site, an icon, an ad-hoc signature.
///
/// The bundle is assembled and signed in a scratch folder and only then moved into place, so a failure
/// part-way never leaves a half-built app where Finder, the Dock or Spotlight can see it.
struct WebAppAction: Action {
    let spec: WebAppSpec
    let fetcher: any WebAppFetching

    static let codesign = "/usr/bin/codesign"
    static let iconutil = "/usr/bin/iconutil"
    /// Sent when fetching pages and icons, so sites serve what Safari would get.
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    var title: String { spec.name }
    var subtitle: String? { spec.url }

    // MARK: Validation

    func validate(_ context: ValidationContext) -> [String] {
        var problems: [String] = []
        for (field, text) in spec.templatedFields {
            problems += context.unknownVariableMessages(in: text, field: field)
        }
        if spec.url.contains("{{") {
            let expanded = context.vars.expand(spec.url)
            if context.vars.unknownVariables(in: spec.url).isEmpty, let problem = WebAppRules.urlProblem(expanded) {
                problems.append(problem)
            }
        }
        if let icon = spec.icon, !icon.lowercased().hasPrefix("https://") {
            let path = context.vars.expand(icon)
            if !context.configPathExists(path) {
                problems.append("icon file '\(path)' does not exist in the config directory (web-app icons go in config/\(WebAppRules.iconFolder)/)")
            } else if context.configPathIsDirectory(path) {
                problems.append("icon '\(path)' is a folder, not an image file")
            }
        }
        return problems
    }

    // MARK: Resolving

    func resolve(_ context: ActionContext) throws -> ResolvedWebApp {
        let urlText = context.expand(spec.url)
        guard let url = WebAppRules.webURL(urlText) else {
            throw ActionError("'url' is not an https address: \(urlText)", hint: "Use a full address such as https://x.com")
        }
        let bundleIdentifier = spec.bundleID.map(context.expand) ?? WebAppRules.defaultBundleID(for: spec.name)
        if let problem = WebAppRules.bundleIDProblem(bundleIdentifier) {
            throw ActionError(problem)
        }
        var hosts: [String] = []
        for entry in spec.hosts {
            let expanded = context.expand(entry)
            guard let host = WebAppRules.normalizedHost(expanded) else {
                throw ActionError("'hosts' entry '\(expanded)' is not a host name", hint: "Write host names like twitter.com")
            }
            if !hosts.contains(host) { hosts.append(host) }
        }

        let icon: ResolvedWebApp.Icon
        if let raw = spec.icon.map(context.expand) {
            if raw.lowercased().hasPrefix("https://") {
                guard let iconURL = WebAppRules.webURL(raw) else { throw ActionError("'icon' is not a valid https address: \(raw)") }
                icon = .remote(iconURL)
            } else {
                icon = .file(context.configURL(raw), display: raw)
            }
        } else {
            icon = .automatic
        }

        let directory = context.path(spec.to)
        return ResolvedWebApp(
            name: spec.name,
            url: url,
            bundleURL: directory.appendingPathComponent("\(spec.name).app"),
            bundleIdentifier: bundleIdentifier,
            userAgent: spec.userAgent.map(context.expand),
            width: spec.width,
            height: spec.height,
            hosts: hosts,
            icon: icon
        )
    }

    /// The `ShawnWebAppIcon` value a bundle built from the current config should carry.
    func iconRecord(for app: ResolvedWebApp) throws -> String {
        switch app.icon {
        case .automatic:
            return "auto"
        case .remote(let url):
            return WebAppInfoPlist.iconRecord(remote: url)
        case .file(let url, let display):
            return "file:\(display)#\(Digest.sha256(try readIconFile(url, display: display)))"
        }
    }

    private func readIconFile(_ url: URL, display: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ActionError("cannot read the icon file '\(display)' (looked at \(url.path))",
                              hint: "Put the image in config/\(WebAppRules.iconFolder)/ and write 'icon: \(WebAppRules.iconFolder)/<file>', or remove 'icon:' to use the site's own icon")
        }
        return data
    }

    // MARK: Check

    func check(_ context: ActionContext) async -> CheckResult {
        let app: ResolvedWebApp
        let expected: [String: Any]
        do {
            app = try resolve(context)
            guard let shell = WebAppShellLocator.locate(in: context.environment) else {
                return .needed("WebAppShell is missing")
            }
            guard let shellData = FileManager.default.contents(atPath: shell.path) else {
                return .needed("cannot read \(context.display(shell))")
            }
            expected = WebAppInfoPlist.make(app, shellDigest: Digest.sha256(shellData), iconRecord: try iconRecord(for: app))
        } catch {
            return .needed(InstallEngine.describe(error))
        }

        let display = context.display(app.bundleURL)
        guard context.files.exists(app.bundleURL) else { return .needed("not built yet") }
        guard let actual = WebAppInfoPlist.read(bundle: app.bundleURL), WebAppInfoPlist.isGenerated(actual) else {
            return .needed("\(display) exists but was not made by this installer")
        }
        if case .remote(let iconURL) = app.icon, let fallback = WebAppInfoPlist.iconFallback(remote: iconURL, in: actual) {
            var asBuilt = expected
            asBuilt[WebAppInfoPlist.iconKey] = WebAppInfoPlist.fallbackIconRecord(remote: iconURL, fallback)
            if let problem = await bundleProblem(app, expected: asBuilt, actual: actual, context: context) {
                return .needed(problem)
            }
            let failed = fallback == .unreachable ? "could not be downloaded" : "could not be used"
            return .needed("the icon at \(iconURL.absoluteString) \(failed) when \(app.name).app was built; it will be tried again")
        }
        if let problem = await bundleProblem(app, expected: expected, actual: actual, context: context) {
            return .needed(problem)
        }
        return .satisfied("up to date")
    }

    /// Why the bundle on disk is not the one `expected` describes, or nil when it is, complete and validly signed.
    private func bundleProblem(_ app: ResolvedWebApp, expected: [String: Any], actual: [String: Any],
                               context: ActionContext) async -> String? {
        let display = context.display(app.bundleURL)
        let differences = WebAppInfoPlist.differences(expected: expected, actual: actual)
        if !differences.isEmpty {
            return "\(differences.joined(separator: ", ")) changed since it was built"
        }
        guard FileManager.default.isExecutableFile(atPath: app.executableURL.path),
              FileManager.default.fileExists(atPath: app.iconFileURL.path) else {
            return "\(display) is incomplete"
        }
        guard await context.commands.succeeds(Self.codesign, ["--verify", "--strict", app.bundleURL.path], timeout: 60) else {
            return "\(display) has a missing or broken code signature"
        }
        return nil
    }

    // MARK: Run

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let app = try resolve(context)
        guard let shell = WebAppShellLocator.locate(in: context.environment) else {
            if context.dryRun {
                // Outside the app bundle the shell only exists once the CLI step has run for real.
                context.info("[dry-run] would build \(context.display(app.bundleURL)) for \(app.url.absoluteString)")
                return .done("would be built")
            }
            throw WebAppShellLocator.missingError(context)
        }
        let display = context.display(app.bundleURL)
        let replacing = context.files.exists(app.bundleURL)
        if replacing {
            guard let info = WebAppInfoPlist.read(bundle: app.bundleURL), WebAppInfoPlist.isGenerated(info) else {
                throw ActionError("\(display) already exists and was not made by Shawn's Dotfiles, so it was left alone",
                                  hint: "Move or rename that app, or give this web app another name or a different 'to:' folder")
            }
        }

        let scratch = context.environment.temporaryDirectory.appendingPathComponent("shawn-webapp-\(UUID().uuidString.prefix(8))")
        let staged = scratch.appendingPathComponent("\(app.name).app")
        let iconset = scratch.appendingPathComponent("\(WebAppInfoPlist.iconFileName).iconset")
        let packIcon = Command(Self.iconutil, ["-c", "icns", "-o", staged.appendingPathComponent("Contents/Resources/\(WebAppInfoPlist.iconFileName).icns").path, iconset.path])
            .labeled("iconutil -c icns \(WebAppInfoPlist.iconFileName).iconset")
        let sign = Command(Self.codesign, ["--force", "--sign", "-", staged.path])
            .labeled("codesign --force --sign - \(Shell.quote("\(app.name).app"))")

        if context.dryRun {
            context.info("[dry-run] would \(replacing ? "rebuild" : "build") \(display) for \(app.url.absoluteString) from \(context.display(shell))")
            context.info("[dry-run] icon: \(app.icon.description)")
            try context.files.ensureDirectory(app.bundleURL.deletingLastPathComponent())
            try await context.runChecked(packIcon)
            try await context.runChecked(sign)
            return .done("would \(replacing ? "rebuild" : "build") \(display)")
        }

        guard let shellData = FileManager.default.contents(atPath: shell.path) else {
            throw ActionError("cannot read \(context.display(shell))", hint: "Check the file's permissions, or rebuild WebAppShell")
        }
        let shellDigest = Digest.sha256(shellData)

        var downloadedIcon: Result<CGImage, RemoteIconFailure>?
        if case .remote(let iconURL) = app.icon {
            let download = await downloadIcon(iconURL, userAgent: app.userAgent ?? Self.defaultUserAgent)
            downloadedIcon = download
            if case .failure(let failure) = download, replacing,
               let current = WebAppInfoPlist.read(bundle: app.bundleURL),
               WebAppInfoPlist.iconFallback(remote: iconURL, in: current) == failure.fallback,
               await bundleProblem(app, expected: WebAppInfoPlist.make(app, shellDigest: shellDigest,
                                                                      iconRecord: WebAppInfoPlist.fallbackIconRecord(remote: iconURL, failure.fallback)),
                                   actual: current, context: context) == nil {
                // Rebuilding would only make the same app again: the icon was the one thing missing, and it still is, for the same reason.
                let address = iconURL.absoluteString
                switch failure.fallback {
                case .unreachable:
                    context.warn("the icon at \(address) still cannot be downloaded (\(failure.reason)); \(display) was left as it is")
                    return .needsAttention("\(display) keeps a stand-in icon because \(address) still cannot be downloaded. Check the address in 'icon:', or remove 'icon:' to use the site's own icon")
                case .unusable:
                    context.warn("the image at \(address) still cannot be used (\(failure.reason)); \(display) was left as it is")
                    return .needsAttention("\(display) keeps a stand-in icon because the image at \(address) cannot be used (\(failure.reason)). Point 'icon:' at a PNG, JPEG or ICNS image, or remove 'icon:' to use the site's own icon")
                }
            }
        }

        context.info("\(replacing ? "rebuilding" : "building") \(display) for \(app.url.absoluteString)")
        let icon = try await makeIcon(for: app, downloaded: downloadedIcon, context: context)

        let fileManager = FileManager.default
        var keepScratch = false
        defer {
            // Scratch space only, so a leftover is harmless; it is kept only when it holds the user's previous app.
            if !keepScratch { try? fileManager.removeItem(at: scratch) }
        }
        do {
            try fileManager.createDirectory(at: staged.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staged.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let executable = staged.appendingPathComponent("Contents/MacOS/\(app.name)")
            try shellData.write(to: executable)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try IconRenderer.writeIconset(icon.image, to: iconset)
        } catch {
            throw ActionError("could not assemble \(app.name).app in \(scratch.path): \(InstallEngine.describe(error))",
                              hint: "Check free disk space and that the temporary folder is writable")
        }
        try await context.runChecked(packIcon)

        let info = WebAppInfoPlist.make(app, shellDigest: shellDigest, iconRecord: icon.record, iconOrigin: icon.origin)
        do {
            try WebAppInfoPlist.serialize(info).write(to: staged.appendingPathComponent("Contents/Info.plist"))
        } catch {
            throw ActionError("could not write \(app.name).app's Info.plist: \(InstallEngine.describe(error))")
        }
        try await context.runChecked(sign)

        try install(staged, at: app.bundleURL, scratch: scratch, keepScratch: &keepScratch, context: context)
        context.success("\(replacing ? "updated" : "installed") \(display)")
        return .done(replacing ? "rebuilt" : "built")
    }

    /// Moves the finished bundle into place, putting the previous one back if that fails.
    ///
    /// `move` is FileManager's: across volumes (a `to:` on another disk) it copies, and a copy can fail part-way.
    /// `keepScratch` is set when the previous app could only be left in `scratch`, so the caller must not delete it.
    func install(_ staged: URL, at destination: URL, scratch: URL, keepScratch: inout Bool, context: ActionContext,
                 move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let display = context.display(destination)
        let folder = context.display(destination.deletingLastPathComponent())
        let hint = "Check that you can write to \(folder), or set 'to: ~/Applications' for this web app"
        try context.files.ensureDirectory(destination.deletingLastPathComponent())
        guard context.files.exists(destination) else {
            do {
                try move(staged, destination)
            } catch {
                let leftover = removePartialCopy(at: destination, after: error, context: context)
                throw ActionError("could not install \(display): \(InstallEngine.describe(error))\(leftover.map { "; \($0)" } ?? "")", hint: hint)
            }
            return
        }

        let previous = scratch.appendingPathComponent("previous.app")
        do {
            try move(destination, previous)
        } catch {
            throw ActionError("could not replace \(display): \(InstallEngine.describe(error))", hint: hint)
        }
        do {
            try move(staged, destination)
        } catch {
            let leftover = removePartialCopy(at: destination, after: error, context: context)
            do {
                try move(previous, destination)
            } catch let restoreError {
                var failure = "could not install the new \(display) (\(InstallEngine.describe(error))) nor put the old one back (\(InstallEngine.describe(restoreError)))"
                if let leftover { failure += "; \(leftover)" }
                let instead = "move it back to \(folder) by hand, or run the installer again to build it afresh"
                // The scratch folder is deleted when this returns, so the old app is moved somewhere that lasts.
                let saved: URL
                do {
                    saved = try saveAside(previous, named: destination.lastPathComponent, context: context, move: move)
                } catch let saveError {
                    keepScratch = true
                    throw ActionError("\(failure); it could not be saved elsewhere either (\(InstallEngine.describe(saveError)))",
                                      hint: "The previous app is in \(previous.path), which is temporary; \(instead)")
                }
                throw ActionError(failure, hint: "The previous app was saved to \(context.display(saved)); \(instead)")
            }
            throw ActionError("could not install the new \(display); the previous version is still there: \(InstallEngine.describe(error))", hint: hint)
        }
    }

    /// After a failed move into `destination` (which was empty), removes the part of the new app it left there.
    /// Returns what to tell the user when that is not possible.
    private func removePartialCopy(at destination: URL, after moveError: Error, context: ActionContext) -> String? {
        // "Already exists" means something else got there first, and that is not ours to delete.
        if (moveError as? CocoaError)?.code == .fileWriteFileExists || !context.files.exists(destination) { return nil }
        do {
            try FileManager.default.removeItem(at: destination)
            return nil
        } catch {
            return "an incomplete copy is left at \(context.display(destination)) (\(InstallEngine.describe(error))); delete it"
        }
    }

    /// Moves `bundle` into this run's backup folder, which outlives the temporary folder, and returns where it went.
    private func saveAside(_ bundle: URL, named name: String, context: ActionContext, move: (URL, URL) throws -> Void) throws -> URL {
        let folder = context.environment.backupDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = (name as NSString).deletingPathExtension
        var target = folder.appendingPathComponent(name)
        var counter = 2
        while context.files.exists(target) {
            target = folder.appendingPathComponent("\(stem) \(counter).app")
            counter += 1
        }
        try move(bundle, target)
        return target
    }

    // MARK: Icon

    struct Icon {
        /// The finished 1024 px icon.
        let image: CGImage
        /// `ShawnWebAppIcon` for the Info.plist.
        let record: String
        /// `ShawnWebAppIconOrigin`: what the artwork really came from.
        let origin: String
    }

    /// Why a configured icon address gave no icon: it could not be fetched, or what it served cannot be used.
    struct RemoteIconFailure: Error {
        let fallback: WebAppInfoPlist.IconFallback
        let reason: String
    }

    /// Configured icon → the site's own icon → a letter tile.
    ///
    /// `downloaded` is the result of fetching a configured icon address when the caller already did.
    func makeIcon(for app: ResolvedWebApp, downloaded: Result<CGImage, RemoteIconFailure>? = nil, context: ActionContext) async throws -> Icon {
        let userAgent = app.userAgent ?? Self.defaultUserAgent
        switch app.icon {
        case .file(let url, let display):
            let data = try readIconFile(url, display: display)
            do {
                let image = try IconRenderer.normalise(IconRenderer.decode(data))
                return Icon(image: image, record: "file:\(display)#\(Digest.sha256(data))", origin: "file:\(display)")
            } catch {
                throw ActionError("the icon '\(display)' cannot be used: \(InstallEngine.describe(error))",
                                  hint: "Use a PNG, JPEG or ICNS image, or remove 'icon:' to use the site's own icon")
            }
        case .remote(let url):
            let result: Result<CGImage, RemoteIconFailure>
            if let downloaded {
                result = downloaded
            } else {
                result = await downloadIcon(url, userAgent: userAgent)
            }
            switch result {
            case .success(let image):
                context.info("icon: \(url.absoluteString)")
                return Icon(image: image, record: WebAppInfoPlist.iconRecord(remote: url), origin: "url:\(url.absoluteString)")
            case .failure(let failure):
                // Recorded with what went wrong, so the next run tries again and says why.
                context.warn("could not use the icon at \(url.absoluteString) (\(failure.reason)); using the site's own icon for now")
                let standIn = try await discoveredIcon(for: app, userAgent: userAgent, context: context)
                return Icon(image: standIn.image, record: WebAppInfoPlist.fallbackIconRecord(remote: url, failure.fallback), origin: standIn.origin)
            }
        case .automatic:
            return try await discoveredIcon(for: app, userAgent: userAgent, context: context)
        }
    }

    /// A configured icon address, fetched and made into a 1024 px icon.
    ///
    /// The two ways it fails are told apart: a different address helps when the download fails, a different
    /// image when what came back is no use (an SVG, a web page sent in its place).
    private func downloadIcon(_ url: URL, userAgent: String) async -> Result<CGImage, RemoteIconFailure> {
        let resource: FetchedResource
        do {
            resource = try await fetcher.fetch(url, userAgent: userAgent, maxBytes: IconDiscovery.iconLimit, timeout: IconDiscovery.timeout)
        } catch {
            return .failure(RemoteIconFailure(fallback: .unreachable, reason: InstallEngine.describe(error)))
        }
        do {
            return .success(try IconRenderer.normalise(IconRenderer.decode(resource.data)))
        } catch {
            return .failure(RemoteIconFailure(fallback: .unusable, reason: InstallEngine.describe(error)))
        }
    }

    private func discoveredIcon(for app: ResolvedWebApp, userAgent: String, context: ActionContext) async throws -> Icon {
        if let found = await IconDiscovery.find(for: app.url, fetcher: fetcher, userAgent: userAgent, log: { context.info($0) }) {
            do {
                let image = try IconRenderer.normalise(found.image)
                context.info("icon: \(found.url.absoluteString)")
                return Icon(image: image, record: "auto", origin: "site:\(found.url.absoluteString)")
            } catch {
                context.info("the site's icon at \(found.url.absoluteString) cannot be used (\(InstallEngine.describe(error)))")
            }
        }
        context.info("icon: a letter tile for \(app.name)")
        return Icon(image: try IconRenderer.letterTile(for: app.name), record: "auto", origin: "letter")
    }
}
