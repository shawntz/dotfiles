import Foundation

/// The non-window entry points: `--print-config`, `--check-url`, `--check-error`, `--help`.
///
/// They exist so the installer, its tests and a curious human can see exactly what a generated app
/// will do without opening it.
enum ShellCommandLine {
    enum Request: Equatable {
        /// No recognised flag: open the window.
        case launch
        case printConfig
        /// Addresses to classify, optionally as seen from a page other than the app's home, and with the
        /// embedded frame the frame kinds come from.
        case checkURLs([String], from: String?, frame: String?)
        /// A load failure to classify, optionally for an address other than the app's home.
        case checkError(domain: String, code: Int, url: String?)
        case help
        case usageError(String)
    }

    static let usage = """
    usage: WebAppShell [--print-config | --check-url URL... [--from PAGE] [--frame FRAME] | --check-error DOMAIN CODE [URL] | --help]

    A site-specific browser. Inside a generated .app it reads the ShawnWebApp* keys of the bundle's
    Info.plist. Run bare, it reads the same settings from the environment: SHAWN_WEBAPP_URL (required),
    SHAWN_WEBAPP_NAME, SHAWN_WEBAPP_HOSTS (comma-separated), SHAWN_WEBAPP_USER_AGENT,
    SHAWN_WEBAPP_WIDTH and SHAWN_WEBAPP_HEIGHT.

      --print-config        print the resolved configuration and web view settings as JSON and exit
      --check-url URL...    print what each kind of navigation to each address does and exit: open it in
                            the app, the browser (or the app for its scheme), a popup, ask first, or block it;
                            for a file, download or cancel. --from PAGE judges link clicks as if made on
                            PAGE instead of the app's URL. For an address another app opens, "question"
                            is what the window asks first; --frame FRAME names the embedded frame (an ad,
                            a player card) the frame kinds come from
      --check-error DOMAIN CODE [URL]
                            print whether a failed load of URL (default: the app's URL) with that NSError
                            domain and code shows the error page, and what Reload then loads; then exit
      --help                show this help
    """

    /// Only double-dash flags are ours; LaunchServices and Xcode add single-dash arguments of their own.
    static func parse(_ arguments: [String]) -> Request {
        let flags = arguments.filter { $0.hasPrefix("--") }
        guard let first = flags.first else { return .launch }
        switch first {
        case "--help":
            return .help
        case "--print-config":
            return flags.count == 1 ? .printConfig : .usageError("--print-config takes no other options")
        case "--check-url":
            var urls: [String] = []
            var page: String?
            var frame: String?
            var index = arguments.firstIndex(of: "--check-url")! + 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--from" || argument == "--frame" {
                    guard index + 1 < arguments.count else {
                        return .usageError(argument == "--from" ? "--from needs a page address" : "--frame needs a frame address")
                    }
                    if argument == "--from" { page = arguments[index + 1] } else { frame = arguments[index + 1] }
                    index += 2
                    continue
                }
                if argument.hasPrefix("--") { return .usageError("unknown option \(argument)") }
                urls.append(argument)
                index += 1
            }
            return urls.isEmpty ? .usageError("--check-url needs at least one address") : .checkURLs(urls, from: page, frame: frame)
        case "--check-error":
            let operands = Array(arguments[(arguments.firstIndex(of: "--check-error")! + 1)...])
            if let option = operands.first(where: { $0.hasPrefix("--") }) { return .usageError("unknown option \(option)") }
            guard (2...3).contains(operands.count) else {
                return .usageError("--check-error needs an error domain and a code, and optionally an address")
            }
            guard let code = Int(operands[1]) else { return .usageError("'\(operands[1])' is not an error code") }
            return .checkError(domain: operands[0], code: code, url: operands.count == 3 ? operands[2] : nil)
        default:
            return .usageError("unknown option \(first)")
        }
    }

    /// Runs a non-window request and returns the exit status, or nil when the app should launch.
    static func handle(_ request: Request,
                       loadConfiguration: () throws -> WebAppConfiguration = { try WebAppConfiguration.current() },
                       output: (String) -> Void = { print($0) },
                       errorOutput: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32? {
        switch request {
        case .launch:
            return nil
        case .help:
            output(usage)
            return 0
        case .usageError(let message):
            errorOutput("WebAppShell: \(message)\n\n\(usage)")
            return 64
        case .printConfig:
            do {
                // The command line runs on the main thread before AppKit starts, which WebKit's objects require.
                let settings = MainActor.assumeIsolated { WebViewSetup.report() }
                output(try json(loadConfiguration().report.merging(settings) { current, _ in current }))
                return 0
            } catch {
                errorOutput("WebAppShell: \(error)")
                return 1
            }
        case .checkURLs(let addresses, let page, let frame):
            return run(errorOutput: errorOutput) {
                let configuration = try loadConfiguration()
                let pageURL = try page.map { try parseAddress($0) } ?? configuration.url
                let frameURL = try frame.map { try parseAddress($0) }
                let reports = try addresses.map {
                    try decisions(for: parseAddress($0), from: pageURL, frame: frameURL, policy: configuration.policy)
                }
                output(try json(reports))
            }
        case .checkError(let domain, let code, let address):
            return run(errorOutput: errorOutput) {
                let configuration = try loadConfiguration()
                let failedURL = try address.map { try parseAddress($0) } ?? configuration.url
                output(try json(errorDecisions(domain: domain, code: code, failedURL: failedURL, homeURL: configuration.url)))
            }
        }
    }

    /// Exit status 1 for a configuration problem, 64 for a bad argument.
    private static func run(errorOutput: (String) -> Void, _ body: () throws -> Void) -> Int32 {
        do {
            try body()
            return 0
        } catch let error as WebAppConfigurationError {
            errorOutput("WebAppShell: \(error)")
            return 1
        } catch {
            errorOutput("WebAppShell: \(error)")
            return 64
        }
    }

    private struct AddressError: Error, CustomStringConvertible {
        let description: String
    }

    private static func parseAddress(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme != nil else {
            throw AddressError(description: "not an absolute address: \(text)")
        }
        return url
    }

    /// Every decision the window would make for `url`, keyed by the kind of navigation, and the question it asks
    /// first when one of them is `ask`. The `frame…` kinds come from an embedded frame on `frame` (nil: one with no
    /// site of its own, such as a sandboxed frame).
    static func decisions(for url: URL, from page: URL, frame: URL?, policy: SitePolicy) -> [String: Any] {
        let navigations: [String: SitePolicy.Disposition] = [
            "linkClick": policy.navigation(to: url, from: page, isLinkClick: true),
            "scriptedLinkClick": policy.navigation(to: url, from: page, isLinkClick: true, byMouse: false),
            "commandClick": policy.navigation(to: url, from: page, isLinkClick: true, wantsNewTab: true),
            "redirect": policy.navigation(to: url, from: page, isLinkClick: false),
            "linkClickInPopup": policy.navigation(to: url, from: page, isLinkClick: true, inPopup: true),
            "frame": policy.navigation(to: url, from: page, isLinkClick: false, isMainFrame: false, fromMainFrame: false),
            "frameLinkClick": policy.navigation(to: url, from: page, isLinkClick: true, isMainFrame: false, fromMainFrame: false),
            "frameScriptedLinkClick": policy.navigation(to: url, from: page, isLinkClick: true, byMouse: false, isMainFrame: false,
                                                        fromMainFrame: false),
            // A link in a frame with target="_top", or script in the frame setting top.location.
            "frameTopLinkClick": policy.navigation(to: url, from: page, isLinkClick: true, fromMainFrame: false),
            "frameTopNavigation": policy.navigation(to: url, from: page, isLinkClick: false, fromMainFrame: false),
            "frameBlankLinkClick": policy.navigation(to: url, from: page, isLinkClick: true,
                                                     isMainFrame: SitePolicy.isWholeWindow(targetFrameIsMain: nil), fromMainFrame: false),
            "targetBlankLink": policy.newWindow(for: url, from: page, isLinkClick: true),
            "windowOpen": policy.newWindow(for: url, from: page, isLinkClick: false),
            "windowOpenAtPopupLimit": policy.newWindow(for: url, from: page, isLinkClick: false, openPopups: SitePolicy.popupLimit),
        ]
        var report: [String: Any] = navigations.mapValues(\.rawValue)
        report["url"] = url.absoluteString
        report["site"] = SitePolicy.site(ofHost: url.host ?? "")
        report["inApp"] = policy.isInApp(url)
        report["download"] = policy.download(from: url, isMainFrame: true).rawValue
        report["frameDownload"] = policy.download(from: url, isMainFrame: false).rawValue
        // No app for it: the window drops the request without a question.
        if navigations.values.contains(.ask), let app = AskToOpen.appName(for: url) {
            func message(from requester: URL?, embedded: Bool) -> String {
                AskToOpen.message(opening: url, in: app, requesterHost: requester?.host?.lowercased() ?? "", fromEmbeddedFrame: embedded)
            }
            report["question"] = [
                "app": app,
                "title": AskToOpen.title(appName: app),
                "fromPage": message(from: page, embedded: false),
                "fromFrame": message(from: frame, embedded: true),
            ]
        } else {
            report["question"] = NSNull()
        }
        return report
    }

    /// What the window does when loading `failedURL` fails with this error.
    static func errorDecisions(domain: String, code: Int, failedURL: URL, homeURL: URL) -> [String: Any] {
        let showsErrorPage = !ErrorPage.isIgnorable(domain: domain, code: code)
        var report: [String: Any] = ["domain": domain, "code": code, "failedURL": failedURL.absoluteString, "showsErrorPage": showsErrorPage]
        if showsErrorPage {
            // WebKit sees the error page as about:blank; the window remembers what failed.
            let errorPage = URL(string: "about:blank")
            report["reloadLoads"] = ErrorPage.reloadTarget(currentURL: errorPage, failedURL: failedURL, homeURL: homeURL)?.absoluteString ?? NSNull()
            report["pageAddress"] = ErrorPage.pageAddress(currentURL: errorPage, failedURL: failedURL)?.absoluteString ?? NSNull()
        }
        return report
    }

    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
