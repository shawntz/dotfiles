import AppKit
import WebKit

@MainActor
enum WebAppLauncher {
    /// Starts the app, or explains why it cannot and quits.
    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let configuration: WebAppConfiguration
        do {
            configuration = try WebAppConfiguration.current()
        } catch {
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This web app"
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "\(name) can't open"
            alert.informativeText = "\(error)\n\nRebuild it with \"shawn install --only webapps\"."
            application.activate()
            alert.runModal()
            exit(1)
        }
        let delegate = AppDelegate(session: WebAppSession(configuration: configuration))
        application.delegate = delegate
        application.run()
        exit(0)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session: WebAppSession

    init(session: WebAppSession) {
        self.session = session
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(appName: session.configuration.name, delegate: self)
        session.openMainWindow()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "\(session.configuration.url.absoluteString)\nA standalone web app made by Shawn's Dotfiles.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: session.configuration.name, .credits: credits])
    }

    @objc func resetMediaPermissions(_ sender: Any?) {
        session.permissions.reset()
    }
}

/// The app's shared state: its configuration, its windows, downloads and remembered permissions.
@MainActor
final class WebAppSession {
    let configuration: WebAppConfiguration
    let policy: SitePolicy
    let downloads = DownloadCoordinator()
    let permissions: MediaPermissionStore
    private(set) var mainWindow: BrowserWindowController?
    private var popups: [BrowserWindowController] = []
    private let defaults = UserDefaults.standard
    private static let zoomKey = "ShawnWebAppPageZoom"

    init(configuration: WebAppConfiguration) {
        self.configuration = configuration
        policy = configuration.policy
        permissions = MediaPermissionStore(defaults: UserDefaults.standard)
    }

    /// The page zoom every window uses; remembered between launches.
    var pageZoom: CGFloat {
        get {
            let stored = defaults.double(forKey: Self.zoomKey)
            return stored > 0 ? CGFloat(stored) : 1
        }
        set {
            defaults.set(Double(newValue), forKey: Self.zoomKey)
            for controller in [mainWindow].compactMap({ $0 }) + popups {
                controller.webView.pageZoom = newValue
            }
        }
    }

    /// Pop-up windows open now (`SitePolicy.popupLimit` caps them).
    var popupCount: Int { popups.count }

    func openMainWindow() {
        let web = WebViewSetup.configuration()
        // The persistent store keeps the user signed in between launches.
        web.websiteDataStore = .default()
        let controller = BrowserWindowController(role: .main, session: self, webConfiguration: web,
                                                 contentSize: NSSize(width: configuration.width, height: configuration.height))
        mainWindow = controller
        controller.showWindow(nil)
        controller.webView.load(URLRequest(url: configuration.url))
    }

    /// A pop-up the page asked for (`window.open`). WebKit requires the web view to use its configuration.
    func openPopup(configuration web: WKWebViewConfiguration, features: WKWindowFeatures,
                   opener: BrowserWindowController) -> WKWebView {
        let width = features.width.map { CGFloat($0.doubleValue) } ?? 520
        let height = features.height.map { CGFloat($0.doubleValue) } ?? 680
        let controller = BrowserWindowController(role: .popup, session: self, webConfiguration: web,
                                                 contentSize: NSSize(width: max(width, 320), height: max(height, 240)))
        popups.append(controller)
        if let parent = opener.window, let window = controller.window {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2))
        }
        controller.showWindow(nil)
        return controller.webView
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        switch controller.role {
        case .main:
            // The app is its one window: closing it quits, pop-ups included.
            NSApp.terminate(nil)
        case .popup:
            popups.removeAll { $0 === controller }
        }
    }

    func openExternally(_ url: URL) {
        if !NSWorkspace.shared.open(url) { NSSound.beep() }
    }
}
