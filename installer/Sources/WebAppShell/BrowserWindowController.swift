import AppKit
import WebKit

/// One window with one web view: the app's main window, or a pop-up the page opened.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate {
    enum Role {
        case main
        case popup
    }

    let role: Role
    let webView: WKWebView
    private unowned let session: WebAppSession
    private var titleObservation: NSKeyValueObservation?
    /// While the error page is up: the address that failed, which the window's commands act on instead.
    private var failedURL: URL?
    /// The load of the error page itself, so its commit does not count as leaving it.
    private var errorPageNavigation: WKNavigation?
    /// Set while the "Open in another app?" question is showing.
    private var isAskingToOpen = false
    /// Set when the user said no; the page that asked gets no more questions, so it cannot ask in a loop.
    private var declinedOpeningOnThisPage = false

    /// Zoom levels Safari steps through.
    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    init(role: Role, session: WebAppSession, webConfiguration: WKWebViewConfiguration, contentSize: NSSize) {
        self.role = role
        self.session = session
        let frame = NSRect(origin: .zero, size: contentSize)
        webView = WKWebView(frame: frame, configuration: webConfiguration)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 320, height: 240)
        window.title = session.configuration.name
        window.delegate = self
        window.contentView = webView
        if role == .main {
            window.collectionBehavior.insert(.fullScreenPrimary)
            let name = session.configuration.frameAutosaveName
            if !window.setFrameUsingName(name) { window.center() }
            window.setFrameAutosaveName(name)
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = session.pageZoom
        if let userAgent = session.configuration.userAgent {
            webView.customUserAgent = userAgent
        }
        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func updateTitle() {
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        window?.title = title.isEmpty ? session.configuration.name : title
    }

    /// `WKNavigationAction.buttonNumber` is a mask of mouse buttons (left 1, middle 4; not NSEvent's numbering),
    /// and 0 when no mouse was involved: a script calling `link.click()`, or the keyboard.
    private static let middleMouseButton = 1 << 2

    private static func wantsNewTab(_ action: WKNavigationAction) -> Bool {
        action.modifierFlags.contains(.command) || action.buttonNumber == middleMouseButton
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        session.windowDidClose(self)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            // A `download` link: judged by the frame it is in, since its address may be a blob: the page made.
            let source = navigationAction.sourceFrame
            switch session.policy.download(from: Self.address(of: source.securityOrigin), isMainFrame: source.isMainFrame) {
            case .download: decisionHandler(.download)
            case .cancel: decisionHandler(.cancel)
            }
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let disposition = session.policy.navigation(
            to: url,
            from: webView.url,
            isLinkClick: navigationAction.navigationType == .linkActivated,
            byMouse: navigationAction.buttonNumber != 0,
            isMainFrame: SitePolicy.isWholeWindow(targetFrameIsMain: navigationAction.targetFrame?.isMainFrame),
            fromMainFrame: navigationAction.sourceFrame.isMainFrame,
            inPopup: role == .popup,
            wantsNewTab: Self.wantsNewTab(navigationAction)
        )
        switch disposition {
        case .app, .popup:
            decisionHandler(.allow)
        case .browser:
            decisionHandler(.cancel)
            session.openExternally(url)
        case .ask:
            decisionHandler(.cancel)
            askBeforeOpening(url, requestedBy: navigationAction.sourceFrame)
        case .blocked:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        guard SitePolicy.isAttachment(contentDisposition: contentDisposition) || !navigationResponse.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }
        switch session.policy.download(from: navigationResponse.response.url, isMainFrame: navigationResponse.isForMainFrame) {
        case .download: decisionHandler(.download)
        case .cancel: decisionHandler(.cancel)
        }
    }

    /// `https://host:port` for a frame's origin; nil for an opaque one (a sandboxed frame, a data: page).
    private static func address(of origin: WKSecurityOrigin) -> URL? {
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port > 0 { components.port = origin.port }
        return components.url
    }

    /// Asks before another app opens an address the user did not click the page's own link to, as Safari does.
    /// `frame` is the frame that asked (WebKit's `sourceFrame`), which the question names.
    private func askBeforeOpening(_ url: URL, requestedBy frame: WKFrameInfo) {
        // A page that keeps redirecting gets one question at a time, not a stack of them.
        guard !isAskingToOpen, !declinedOpeningOnThisPage else { return }
        guard let appName = AskToOpen.appName(for: url) else { return }

        let alert = NSAlert()
        alert.messageText = AskToOpen.title(appName: appName)
        alert.informativeText = AskToOpen.message(opening: url, in: appName, requesterHost: frame.securityOrigin.host,
                                                  fromEmbeddedFrame: !frame.isMainFrame)
        // Cancel is the default, so a Return meant for the page cannot launch anything.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        isAskingToOpen = true
        presentAlert(alert) { [weak self] response in
            guard let self else { return }
            isAskingToOpen = false
            if response == .alertSecondButtonReturn {
                session.openExternally(url)
            } else {
                declinedOpeningOnThisPage = true
            }
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = session.downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = session.downloads
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        // Canceled loads, and loads that became downloads or went to another app, leave the page as it is.
        guard !ErrorPage.isIgnorable(domain: error.domain, code: error.code) else { return }
        let failed = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? session.configuration.url
        // No base URL: the error page must not run with the failed site's origin.
        errorPageNavigation = webView.loadHTMLString(ErrorPage.html(appName: session.configuration.name, url: failed,
                                                                    message: error.localizedDescription), baseURL: nil)
        failedURL = failed
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        declinedOpeningOnThisPage = false
        // Anything else that commits (Try Again, a link, Back) has replaced the error page.
        if navigation !== errorPageNavigation {
            errorPageNavigation = nil
            failedURL = nil
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process crashed (or was killed for memory); bring it back rather than show a blank window.
        reloadPage(nil)
    }

    // MARK: Windows the page asks for

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let disposition = session.policy.newWindow(
            for: url,
            from: webView.url,
            isLinkClick: navigationAction.navigationType == .linkActivated,
            wantsNewTab: Self.wantsNewTab(navigationAction),
            openPopups: session.popupCount
        )
        switch disposition {
        case .app:
            webView.load(navigationAction.request)
            return nil
        case .browser:
            if let url { session.openExternally(url) }
            return nil
        case .ask:
            if let url { askBeforeOpening(url, requestedBy: navigationAction.sourceFrame) }
            return nil
        case .blocked:
            return nil
        case .popup:
            return session.openPopup(configuration: configuration, features: windowFeatures, opener: self)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        // Sign-in pop-ups close themselves when they are done; the main window only closes when the user says so.
        if role == .popup { window?.close() }
    }

    // MARK: JavaScript panels

    private func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func panelTitle(for frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? session.configuration.name : "\(host) says"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = panelTitle(for: frame)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        presentAlert(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = panelTitle(for: frame)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        presentAlert(alert) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = panelTitle(for: frame)
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        presentAlert(alert) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: Uploads and permissions

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        session.permissions.decide(origin: origin, type: type, appName: session.configuration.name,
                                   window: window, completion: decisionHandler)
    }

    // MARK: Menu commands

    /// The page's address, or the failed site's while the error page (an about:blank document) stands in for it.
    private var pageAddress: URL? {
        ErrorPage.pageAddress(currentURL: webView.url, failedURL: failedURL)
    }

    @objc func reloadPage(_ sender: Any?) {
        if let target = ErrorPage.reloadTarget(currentURL: webView.url, failedURL: failedURL, homeURL: session.configuration.url) {
            webView.load(URLRequest(url: target))
        } else {
            webView.reload()
        }
    }

    @objc func goBackInHistory(_ sender: Any?) {
        webView.goBack()
    }

    @objc func goForwardInHistory(_ sender: Any?) {
        webView.goForward()
    }

    @objc func zoomInPage(_ sender: Any?) {
        session.pageZoom = Self.zoomSteps.first { $0 > webView.pageZoom + 0.001 } ?? Self.zoomSteps.last!
    }

    @objc func zoomOutPage(_ sender: Any?) {
        session.pageZoom = Self.zoomSteps.last { $0 < webView.pageZoom - 0.001 } ?? Self.zoomSteps.first!
    }

    @objc func resetPageZoom(_ sender: Any?) {
        session.pageZoom = 1
    }

    @objc func copyPageAddress(_ sender: Any?) {
        guard let url = pageAddress else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func openInDefaultBrowser(_ sender: Any?) {
        guard let url = pageAddress, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return NSSound.beep() }
        session.openExternally(url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackInHistory(_:)): return webView.canGoBack
        case #selector(goForwardInHistory(_:)): return webView.canGoForward
        case #selector(copyPageAddress(_:)), #selector(openInDefaultBrowser(_:)): return pageAddress != nil
        case #selector(zoomInPage(_:)): return webView.pageZoom < Self.zoomSteps.last!
        case #selector(zoomOutPage(_:)): return webView.pageZoom > Self.zoomSteps.first!
        default: return true
        }
    }
}
