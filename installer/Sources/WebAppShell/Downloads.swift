import AppKit
import WebKit

/// Saves downloads to ~/Downloads (never overwriting) and shows each finished one in Finder.
@MainActor
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }
        let destination = DownloadNaming.uniqueDestination(for: suggestedFilename, in: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        destinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let destination = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let destination = destinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Download failed"
        alert.informativeText = [destination?.lastPathComponent, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        alert.runModal()
    }
}

enum DownloadNaming {
    /// `report.pdf`, then `report 2.pdf`, `report 3.pdf` and so on: whichever does not exist yet.
    static func uniqueDestination(for suggestedFilename: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        var name = suggestedFilename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }

        let candidate = folder.appendingPathComponent(name)
        if !exists(candidate) { return candidate }
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var counter = 2
        while true {
            let numbered = pathExtension.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(pathExtension)"
            let url = folder.appendingPathComponent(numbered)
            if !exists(url) { return url }
            counter += 1
        }
    }
}
