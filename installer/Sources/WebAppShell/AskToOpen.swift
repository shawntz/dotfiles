import AppKit

/// The question a window asks before another app opens an address (a `.ask` decision), as Safari does.
enum AskToOpen {
    /// Longer addresses are cut, so a page cannot fill the alert with one.
    static let addressLimit = 200

    /// The app that would open `url`, by name; nil when no app on this Mac handles it (then nothing is asked).
    static func appName(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url)?.deletingPathExtension().lastPathComponent
    }

    static func title(appName: String) -> String {
        "Open \"\(appName)\"?"
    }

    /// Names whoever asked: the frame that made the request, which is not always the page in the window
    /// (a link in an embedded player card), and never the address itself (where a redirect has already moved
    /// the window's URL).
    ///
    /// - Parameters:
    ///   - requesterHost: the host of the requesting frame's origin; empty when it has none (a sandboxed frame,
    ///     a window where nothing has loaded yet).
    ///   - fromEmbeddedFrame: a frame inside the page asked, not the page itself.
    static func message(opening url: URL, in appName: String, requesterHost: String, fromEmbeddedFrame: Bool) -> String {
        var address = url.absoluteString
        if address.count > addressLimit { address = String(address.prefix(addressLimit)) + "…" }
        let requester: String
        switch (requesterHost.isEmpty, fromEmbeddedFrame) {
        case (false, false): requester = requesterHost
        case (false, true): requester = "\(requesterHost), embedded in this page,"
        case (true, false): requester = "This page"
        case (true, true): requester = "Something embedded in this page"
        }
        return "\(requester) wants to open \(address) in \(appName)."
    }
}
