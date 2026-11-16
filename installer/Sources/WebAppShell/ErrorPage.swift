import Foundation

/// The page shown when the site cannot be reached, with a way to try again, and the rules around it.
enum ErrorPage {
    /// WKWebView reports policy interruptions in legacy WebKit's domain, not in `WKError.errorDomain`.
    static let webKitErrorDomain = "WebKitErrorDomain"
    /// `WebKitErrorFrameLoadInterruptedByPolicyChange`: the response became a download, or the navigation was
    /// canceled by the policy (sent to another app, asked about, refused).
    static let frameLoadInterruptedByPolicyChange = 102
    /// `WebKitErrorPlugInWillHandleLoad`: a plug-in (a PDF or media view) took the load over.
    static let plugInWillHandleLoad = 204

    /// True for failures that are not the site being unreachable, so the page the user was on stays.
    static func isIgnorable(domain: String, code: Int) -> Bool {
        switch domain {
        case NSURLErrorDomain:
            return code == NSURLErrorCancelled
        case webKitErrorDomain:
            return code == frameLoadInterruptedByPolicyChange || code == plugInWillHandleLoad
        default:
            return false
        }
    }

    /// What Reload loads instead of reloading the current page, or nil to reload it.
    ///
    /// The error page is `about:blank` as far as WebKit knows, so while it is up (`failedURL` is set) Reload
    /// tries the site again; before anything has loaded it opens the app's own address.
    static func reloadTarget(currentURL: URL?, failedURL: URL?, homeURL: URL) -> URL? {
        failedURL ?? (currentURL == nil ? homeURL : nil)
    }

    /// The address Copy Page Address and Open in Default Browser use: the site the error page stands in for.
    static func pageAddress(currentURL: URL?, failedURL: URL?) -> URL? {
        failedURL ?? currentURL
    }

    static func html(appName: String, url: URL, message: String) -> String {
        let host = escape(url.host ?? url.absoluteString)
        // A JSON string is a valid JavaScript string literal; escaped slashes keep "</script>" out of it.
        let retryTarget = (try? JSONSerialization.data(withJSONObject: url.absoluteString, options: [.fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"about:blank\""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(appName))</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, system-ui, sans-serif; display: grid; place-items: center; min-height: 90vh; margin: 0; }
          main { max-width: 28rem; text-align: center; padding: 2rem; }
          h1 { font-size: 1.4rem; margin-bottom: .5rem; }
          p { opacity: .7; line-height: 1.4; }
          button { font: inherit; padding: .45rem 1.2rem; border-radius: .5rem; border: 1px solid #8884; background: #8881; cursor: pointer; }
        </style></head>
        <body><main>
          <h1>Can't reach \(host)</h1>
          <p>\(escape(message))</p>
          <button id="retry">Try Again</button>
        </main>
        <script>document.getElementById("retry").onclick = () => { location.href = \(retryTarget); };</script>
        </body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
