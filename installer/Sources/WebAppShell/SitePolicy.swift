import Foundation

/// Decides which addresses belong to the web app and which belong in the default browser.
///
/// The rules are deliberately few, so they can be predicted (and checked with `--check-url`):
/// - A host "is in the app" when it is on the same site as the app's URL (`mobile.x.com` and `x.com`)
///   or matches one of the configured extra hosts (`twimg.com` also covers `abs.twimg.com`).
/// - Clicking a link to anywhere else opens the default browser, unless the link stays on the site of
///   the page it was clicked on (a sign-in provider's own pages, reached through a redirect).
/// - Navigations nobody clicked (server redirects, form posts, script) stay in the app, because
///   sign-in flows bounce through other sites (accounts.google.com, appleid.apple.com) and come back.
/// - Pop-up windows opened by script (OAuth sign-ins) are in-app child windows, and anything may load inside them.
///   WebKit only lets script open one during a click (`WebViewSetup`), and no more than `popupLimit` stay open.
/// - Addresses another app handles (`mailto:`, `zoommtg:`, `vnc:`) open there unasked only from a click on a link
///   in the page; otherwise the user is asked first, and an embedded frame cannot open one by itself at all.
///   A link inside an embedded frame is not the page's own, even when it targets the whole window or a new one.
/// - Only the page, or a frame on the app's own sites, may save a file to Downloads.
struct SitePolicy: Equatable {
    /// Where a navigation should happen.
    enum Disposition: String {
        /// In the window that asked.
        case app
        /// In the user's default browser (or the app that handles the scheme, for `mailto:` and friends).
        case browser
        /// In a new in-app child window.
        case popup
        /// In the app that handles the scheme, once the user says so.
        case ask
        /// Nowhere: the request is dropped.
        case blocked
    }

    /// What happens to a response WebKit would save as a file rather than show.
    enum DownloadDisposition: String {
        case download
        case cancel
    }

    /// Pop-up windows open at once; sign-in pop-ups close themselves, so more than this is a page misbehaving.
    static let popupLimit = 5

    /// The registrable domain of the app's own URL, e.g. `carbonapp.co` for `https://my.carbonapp.co`.
    let homeSite: String
    /// Normalised extra hosts; each also covers its subdomains.
    let extraHosts: [String]

    init(homeURL: URL, extraHosts: [String]) {
        homeSite = Self.site(ofHost: homeURL.host ?? "")
        self.extraHosts = extraHosts.compactMap(Self.normalizedHostPattern)
    }

    // MARK: Decisions

    /// True when an http(s) address should load inside the app.
    func isInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host, !rawHost.isEmpty else { return false }
        let host = Self.normalizedHost(rawHost)
        if Self.site(ofHost: host) == homeSite { return true }
        return extraHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// True when both are web addresses on the same site.
    static func isSameSite(_ url: URL, as other: URL?) -> Bool {
        guard let other, let host = url.host, let otherHost = other.host,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["http", "https"].contains(other.scheme?.lowercased() ?? "") else { return false }
        return site(ofHost: host) == site(ofHost: otherHost)
    }

    /// A navigation inside an existing window.
    ///
    /// - Parameters:
    ///   - page: the page the navigation starts from (nil before anything has loaded).
    ///   - isLinkClick: a link was activated (as opposed to a redirect, form post, reload or script setting `location`).
    ///   - byMouse: ...with a mouse button. WebKit reports a script's `link.click()` (and the keyboard) as a link
    ///     activation too, only without a button; the difference matters for addresses another app opens.
    ///   - isMainFrame: the navigation replaces the whole page (or opens a new window: `isWholeWindow`) rather than
    ///     an embedded frame.
    ///   - fromMainFrame: the page itself asked for it, rather than a frame embedded in it (an ad, a player card);
    ///     WebKit's `sourceFrame`. It only matters for addresses another app opens.
    ///   - inPopup: the window is a pop-up opened by the page.
    ///   - wantsNewTab: the click was a ⌘-click or middle click.
    func navigation(to url: URL, from page: URL? = nil, isLinkClick: Bool, byMouse: Bool = true, isMainFrame: Bool = true,
                    fromMainFrame: Bool = true, inPopup: Bool = false, wantsNewTab: Bool = false) -> Disposition {
        guard let scheme = url.scheme?.lowercased() else { return .app }
        if Self.inPageSchemes.contains(scheme) { return .app }
        guard scheme == "http" || scheme == "https" else {
            if Self.neverHandedOver.contains(scheme) { return .blocked }
            // Script in an ad or embed, or on a page reached by redirect, must not launch Screen Sharing or
            // Finder's server connection unseen: only the user clicking the page's own link counts as asking.
            // A frame's link that targets the whole window (`_top`) or a new one (`_blank`) is still the frame's.
            let userClicked = isLinkClick && byMouse
            if isMainFrame && fromMainFrame { return userClicked ? .browser : .ask }
            return userClicked ? .ask : .blocked
        }
        // Embedded frames (players, captchas, payment forms) never take over a window.
        if !isMainFrame { return .app }
        if isLinkClick && wantsNewTab { return .browser }
        if inPopup || isInApp(url) || Self.isSameSite(url, as: page) { return .app }
        return isLinkClick ? .browser : .app
    }

    /// The `isMainFrame` to judge a navigation by, from its target frame's `isMainFrame`. WebKit names no target
    /// frame for a link that opens a new window (`target="_blank"`), and asks about it before `newWindow` runs;
    /// it is judged as if it replaced the page.
    static func isWholeWindow(targetFrameIsMain: Bool?) -> Bool {
        targetFrameIsMain ?? true
    }

    /// A request for a new window: a `target="_blank"` link (`isLinkClick`) or `window.open`.
    ///
    /// `.app` here means "load it in the window that asked". The app has no tabs. `window.open` only gets
    /// here while the user is clicking, because WebKit blocks it otherwise (`WebViewSetup`).
    func newWindow(for url: URL?, from page: URL? = nil, isLinkClick: Bool, wantsNewTab: Bool = false,
                   openPopups: Int = 0) -> Disposition {
        let popup: Disposition = openPopups < Self.popupLimit ? .popup : .blocked
        guard let url, let scheme = url.scheme?.lowercased(), url.absoluteString != "about:blank" else {
            // A blank pop-up the page fills in itself: the usual start of an OAuth sign-in.
            return popup
        }
        if Self.inPageSchemes.contains(scheme) { return popup }
        guard scheme == "http" || scheme == "https" else {
            if Self.neverHandedOver.contains(scheme) { return .blocked }
            return isLinkClick ? .browser : .ask
        }
        if isLinkClick {
            let staysHere = isInApp(url) || Self.isSameSite(url, as: page)
            return staysHere && !wantsNewTab ? .app : .browser
        }
        return popup
    }

    /// A response WebKit would save as a file rather than show (an attachment, or a type it cannot display).
    ///
    /// `address` is the file's (or, for a `download` link, the linking frame's). The page itself may save files;
    /// an embedded frame only from the app's own sites, which is how many exports work, so an ad or embed cannot
    /// drop files into Downloads and bring Finder to the front without the user asking.
    func download(from address: URL?, isMainFrame: Bool) -> DownloadDisposition {
        if isMainFrame { return .download }
        guard let address, isInApp(address) else { return .cancel }
        return .download
    }

    /// True for a `Content-Disposition` header that asks for the response to be saved.
    static func isAttachment(contentDisposition: String?) -> Bool {
        contentDisposition?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") ?? false
    }

    /// Schemes that load content the page itself made; never handed to another app.
    static let inPageSchemes: Set<String> = ["about", "blob", "data", "javascript"]

    /// Never handed to another app, whoever asks: a `file:` address would open a local document or app.
    /// (WebKit already refuses them from web pages; this keeps the shell from depending on that.)
    static let neverHandedOver: Set<String> = ["file"]

    // MARK: Sites

    /// Second-level labels under country domains that are public suffixes themselves (`co.uk`, `com.au`).
    static let genericSecondLevelLabels: Set<String> = [
        "ac", "co", "com", "edu", "gen", "go", "gob", "gov", "gv", "info", "ltd", "mil", "ne", "net", "nhs", "nic",
        "nom", "or", "org", "plc", "sch", "web",
    ]

    /// Hosting platforms where every subdomain belongs to someone else (`alice.github.io` ≠ `bob.github.io`).
    static let sharedHostingSuffixes: Set<String> = [
        "appspot.com", "azurewebsites.net", "blogspot.com", "cloudfront.net", "firebaseapp.com", "fly.dev",
        "github.io", "gitlab.io", "glitch.me", "herokuapp.com", "netlify.app", "ngrok-free.app", "ngrok.io",
        "onrender.com", "pages.dev", "replit.app", "surge.sh", "vercel.app", "web.app", "workers.dev",
    ]

    /// The registrable domain ("site") of a host, the part a company actually owns.
    ///
    /// An approximation of the Public Suffix List that is right for ordinary sites: the last two labels,
    /// or three under country second-level domains (`bbc.co.uk`) and shared hosting platforms.
    static func site(ofHost rawHost: String) -> String {
        let host = normalizedHost(rawHost)
        if host.isEmpty || isIPAddress(host) || !host.contains(".") { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let topLevel = labels[labels.count - 1]
        let secondLevel = labels[labels.count - 2]
        if sharedHostingSuffixes.contains(lastTwo) || (topLevel.count == 2 && genericSecondLevelLabels.contains(secondLevel)) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    static func normalizedHost(_ host: String) -> String {
        var result = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    /// `twitter.com` for "Twitter.com", "*.twitter.com" or ".twitter.com"; nil when it is not a host name.
    static func normalizedHostPattern(_ text: String) -> String? {
        var host = normalizedHost(text)
        if host.hasPrefix("*.") { host.removeFirst(2) }
        while host.hasPrefix(".") { host.removeFirst() }
        guard !host.isEmpty, host.count <= 253 else { return nil }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }) else {
                return nil
            }
        }
        return host
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// This Mac: the only place plain http is accepted.
    static func isLoopback(_ host: String) -> Bool {
        let normalized = normalizedHost(host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized == "::1" || normalized.hasPrefix("127.")
    }
}
