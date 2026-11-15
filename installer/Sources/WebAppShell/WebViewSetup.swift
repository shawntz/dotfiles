import AppKit
import WebKit

/// The WebKit settings every window starts from. WebKit hands pop-ups a copy of their opener's
/// configuration, so they inherit these too.
@MainActor
enum WebViewSetup {
    static func configuration() -> WKWebViewConfiguration {
        let web = WKWebViewConfiguration()
        web.applicationNameForUserAgent = SafariUserAgent.applicationName()
        web.preferences.isElementFullscreenEnabled = true
        // macOS lets script open windows unasked by default. Like Safari's pop-up blocker, allow window.open
        // only while the user is clicking: sign-in pop-ups a button opens still work, load-time ones do not.
        web.preferences.javaScriptCanOpenWindowsAutomatically = false
        return web
    }

    /// What `--print-config` adds about those settings, read back from a configuration built the same way.
    static func report() -> [String: Any] {
        let web = configuration()
        return [
            "popupsRequireUserGesture": !web.preferences.javaScriptCanOpenWindowsAutomatically,
            "popupLimit": SitePolicy.popupLimit,
        ]
    }
}

enum SafariUserAgent {
    /// Appended to WebKit's own user agent so sites treat the app like Safari (some sign-in pages refuse
    /// "embedded browsers" otherwise). Follows the installed Safari's version.
    static func applicationName() -> String {
        let version = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        return "Version/\(version ?? "18.0") Safari/605.1.15"
    }
}
