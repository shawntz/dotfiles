import CryptoKit
import Foundation
import ShawnCore

/// Fetching, checking and unpacking downloaded installers.
enum Downloader {
    // MARK: Fetch

    /// Downloads `url` into `<cache>/downloads/` and returns the file; the caller removes it with `discard`.
    /// In a dry run only the curl command is narrated and the would-be path is returned.
    static func fetch(_ url: URL, fileName: String, _ context: ActionContext, system: MacSystem) async throws -> URL {
        let directory = context.environment.cacheDirectory.appendingPathComponent("downloads")
        let file = directory.appendingPathComponent("\(UUID().uuidString.prefix(8).lowercased())-\(fileName)")
        if !context.dryRun { try context.files.ensureDirectory(directory) }
        let command = Command(system.curl, ["-fL", "--retry", "3", "-o", file.path, url.absoluteString])
            .labeled("curl -fL --retry 3 -o \(context.display(file)) \(url.absoluteString)")
        do {
            try await context.runChecked(command)
        } catch is CancellationError {
            discard(file, context)
            throw CancellationError()
        } catch {
            discard(file, context)
            throw ActionError("Could not download \(url.absoluteString): \(Common.describe(error))",
                              hint: "check the network connection and that the address still works, then run the installer again")
        }
        return file
    }

    /// Removes a downloaded file (or a partial one).
    static func discard(_ file: URL, _ context: ActionContext) {
        Common.removeScratch(file, context)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyChecksum(of file: URL, expected: String, source: String) throws {
        let actual = try sha256(of: file)
        guard actual == expected.lowercased() else {
            throw ActionError("The download from \(source) does not match its sha256 (expected \(expected.lowercased()), got \(actual))",
                              hint: "the file changed upstream or was damaged. Run the installer again, and if it still differs, update 'sha256:' only after checking the new file")
        }
    }

    // MARK: Disk images

    /// Mounts a disk image read-only at a private mount point, out of sight of Finder.
    static func attach(_ image: URL, _ context: ActionContext, system: MacSystem) async throws -> URL {
        let mountPoint = try Common.makeScratchDirectory(context, prefix: "mount")
        let command = Command(system.hdiutil, ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, image.path])
        let result: CommandResult
        do {
            result = try await context.run(command)
        } catch {
            Common.removeScratch(mountPoint, context)
            throw error
        }
        guard result.succeeded else {
            Common.removeScratch(mountPoint, context)
            throw ActionError("Could not open the disk image: \(result.tail(3))",
                              hint: "the download may be damaged or not a disk image. Run the installer again, or set 'type:' on the item")
        }
        return mountPoint
    }

    /// Detaches the image (forcing it if a plain detach fails) and removes the mount point.
    /// Runs to completion even when the item has been cancelled.
    static func detach(_ mountPoint: URL, _ context: ActionContext, system: MacSystem) async {
        await Common.uncancellable {
            do {
                var result = try await context.run(Command(system.hdiutil, ["detach", mountPoint.path]))
                if !result.succeeded {
                    result = try await context.run(Command(system.hdiutil, ["detach", "-force", mountPoint.path]))
                }
                if result.succeeded {
                    Common.removeScratch(mountPoint, context)
                } else {
                    context.warn("Could not detach the disk image at \(mountPoint.path) (\(result.tail(2))). Eject it in Finder.")
                }
            } catch {
                context.warn(ActionError.sentences("Could not detach the disk image at \(mountPoint.path): \(Common.describe(error))", "eject it in Finder."))
            }
        }
    }

    // MARK: Finding the app

    /// The app bundle to install from an unpacked download: the named one, or the only one there is.
    static func findApp(in directory: URL, named: String?, source: String) throws -> String {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
                .sorted()
        } catch {
            throw ActionError("Could not look inside \(source): \(error.localizedDescription)", hint: "run the installer again")
        }
        let apps = entries.filter { $0.lowercased().hasSuffix(".app") }
        if let named {
            guard entries.contains(named) else {
                let found = apps.isEmpty ? "" : " (it has \(apps.joined(separator: ", ")))"
                throw ActionError("\(named) is not in \(source)\(found)", hint: "make 'app:' match the app inside the download")
            }
            return named
        }
        if apps.count == 1 { return apps[0] }
        if apps.isEmpty {
            let found = entries.isEmpty ? "" : " (found \(entries.prefix(5).joined(separator: ", ")))"
            let hint = entries.contains { $0.lowercased().hasSuffix(".pkg") }
                ? "it holds an installer package instead. Point the item at the .pkg itself with 'type: pkg'"
                : "check that the address still serves the app"
            throw ActionError("There is no app in \(source)\(found)", hint: hint)
        }
        throw ActionError("\(source) holds \(apps.count) apps (\(apps.joined(separator: ", ")))", hint: "add 'app:' naming the one to install")
    }

    // MARK: Verification

    /// Gatekeeper must accept the app (signed and notarized), and it must come from `teamID` when one is given.
    static func verifyApp(_ app: URL, teamID: String?, _ context: ActionContext, system: MacSystem) async throws {
        let name = app.lastPathComponent
        let assessment = try await context.run(Command(system.spctl, ["--assess", "--type", "execute", "-v", app.path]).readOnly())
        guard assessment.succeeded else {
            throw ActionError("Gatekeeper rejected \(name): \(oneLine(assessment.tail(3)))",
                              hint: "it is not signed and notarized by an identified developer; if you trust it anyway, set 'verify: false' on this item")
        }
        if let teamID {
            let signature = try await context.run(Command(system.codesign, ["-dv", "--verbose=2", app.path]).readOnly())
            let actual = teamIdentifier(inCodesignOutput: signature.stderr + "\n" + signature.stdout)
            guard actual == teamID else {
                throw ActionError("\(name) is signed by team \(actual ?? "(none)"), not \(teamID)",
                                  hint: "if the vendor really changed its signing team, update 'team_id:'; otherwise do not install this download")
            }
        }
        context.success("\(name) passed Gatekeeper" + (teamID.map { " and is signed by team \($0)" } ?? ""))
    }

    /// The package must carry a valid signature that Gatekeeper accepts for installation.
    static func verifyPackage(_ package: URL, displayName: String, teamID: String?, _ context: ActionContext, system: MacSystem) async throws {
        let signature = try await context.run(Command(system.pkgutil, ["--check-signature", package.path]).readOnly())
        guard signature.succeeded else {
            throw ActionError("\(displayName) is not properly signed: \(oneLine(signature.tail(3)))",
                              hint: "if you trust it anyway, set 'verify: false' on this item")
        }
        let assessment = try await context.run(Command(system.spctl, ["--assess", "--type", "install", "-v", package.path]).readOnly())
        guard assessment.succeeded else {
            throw ActionError("Gatekeeper rejected \(displayName): \(oneLine(assessment.tail(3)))",
                              hint: "it is not notarized by an identified developer; if you trust it anyway, set 'verify: false' on this item")
        }
        if let teamID {
            let actual = teamIdentifier(inPkgutilOutput: signature.stdout)
            guard actual == teamID else {
                throw ActionError("\(displayName) is signed by team \(actual ?? "(none)"), not \(teamID)",
                                  hint: "if the vendor really changed its signing team, update 'team_id:'; otherwise do not install this download")
            }
        }
        context.success("\(displayName) is signed and accepted by Gatekeeper")
    }

    /// `TeamIdentifier=G7HH3F8CAK` from `codesign -dv`; nil when unsigned or ad-hoc ("not set").
    static func teamIdentifier(inCodesignOutput text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }

    /// The team in `1. Developer ID Installer: Some Name (927JGANW46)` from `pkgutil --check-signature`.
    static func teamIdentifier(inPkgutilOutput text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("1."), let open = trimmed.lastIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close else { continue }
            return String(trimmed[trimmed.index(after: open)..<close])
        }
        return nil
    }

    private static func oneLine(_ text: String) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
    }
}
