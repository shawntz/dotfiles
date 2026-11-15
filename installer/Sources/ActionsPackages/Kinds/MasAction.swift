import Foundation
import ShawnCore

/// `- mas: 937984704` with `name: Amphetamine` installs a Mac App Store app.
struct MasAction: Action, PackageProviding {
    /// The numeric App Store id.
    let id: String
    /// The app's name, which is also how it is found in Applications.
    let appName: String
    let system: MacSystem

    var title: String { appName }
    var subtitle: String? { "Mac App Store · \(id)" }
    var sudo: SudoNeed { .always }
    var packageRef: PackageRef { PackageRef(manager: .mas, name: id, label: appName) }

    static func parse(_ parser: ItemParser, system: MacSystem) -> MasAction {
        let id = parser.item.value.string ?? ""
        if id.isEmpty || !id.allSatisfy(\.isASCII) || !id.allSatisfy(\.isNumber) {
            parser.fail("'mas' must be the app's numeric App Store id, e.g. 'mas: 937984704' (got '\(id)')")
        }
        let name = parser.item.name ?? ""
        if name.isEmpty {
            parser.fail("'mas' items need 'name:' with the app's name (e.g. 'name: Amphetamine'); it is how the installer finds the app in Applications")
        }
        return MasAction(id: id, appName: Common.appDisplayName(name), system: system)
    }

    var storeURL: URL { AppStore.pageURL(id: id) }

    private var followUpTitle: String { "Install \(appName) from the App Store" }

    func appURL(_ context: ActionContext) -> URL {
        context.environment.applicationsDirectory.appendingPathComponent(Common.appBundleName(appName))
    }

    func receiptURL(_ context: ActionContext) -> URL {
        appURL(context).appendingPathComponent("Contents/_MASReceipt")
    }

    func check(_ context: ActionContext) async -> CheckResult {
        if context.files.exists(receiptURL(context)) { return .satisfied("installed from the App Store") }
        if context.files.exists(appURL(context)) { return .needed("\(appName).app is there, but not from the App Store") }
        return .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let timeout = system.timing.masInstallTimeout
        if context.dryRun {
            context.info("[dry-run] would make sure you are signed in to the App Store")
            try await AppStore.install(id: id, name: appName, mas: AppStore.expectedMasPath(context), timeout: timeout, context)
            return .done(nil)
        }
        if context.files.exists(receiptURL(context)) { return .done("already installed") }
        if let refusal = Common.sandboxRefusal("installing \(appName) from the App Store", context, system: system) { return refusal }

        let found: String?
        do {
            found = try await AppStore.ensureMas(context)
        } catch {
            if Common.isStop(error) { throw error }
            context.warn("Could not install mas: \(Common.describe(error))")
            context.followUp(followUpTitle, detail: "mas (the App Store command line tool) could not be installed with Homebrew: \(Common.describe(error))", url: storeURL)
            return .needsAttention("mas could not be installed; install \(appName) from the App Store")
        }
        guard let mas = found else {
            context.followUp(followUpTitle, detail: "mas (the App Store command line tool) could not be installed, so this was left for you.", url: storeURL)
            return .needsAttention("mas is not installed (it comes from '- brew: mas'); install \(appName) from the App Store")
        }
        let signIn = try await AppStore.confirmSignIn(context, url: storeURL, timeout: system.timing.appStoreQuestionTimeout)
        guard signIn == .confirmed else {
            context.followUp(followUpTitle, detail: signIn.followUpDetail, url: storeURL)
            return .skipped(signIn.skipReason)
        }

        // mas prints nothing while the App Store waits for a password or Touch ID, so say what it may be waiting for.
        context.attention(Attention(
            title: "Installing \(appName) from the App Store",
            message: "If macOS asks for your Apple Account password or Touch ID, approve it. If this is still going after "
                + "\(Common.duration(timeout)), it is stopped and \(appName) goes on your checklist."
        ))
        defer { context.attention(nil) }
        do {
            try await AppStore.install(id: id, name: appName, mas: mas, timeout: timeout, context)
        } catch {
            if Common.isStop(error) { throw error }
            let reason = AppStore.explain(error)
            context.warn(reason)
            context.followUp(followUpTitle, detail: "mas could not install it: \(reason)", url: storeURL)
            return .needsAttention("install \(appName) from the App Store")
        }
        if !context.files.exists(receiptURL(context)) {
            context.warn("mas finished, but \(context.display(appURL(context))) has no App Store receipt. Check that 'name:' matches the app's name.")
        }
        return .done("installed")
    }
}
