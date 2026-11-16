import Foundation
import ShawnCore

/// `- xcode: download` and `- xcode: finish` install full Xcode from the Mac App Store.
///
/// The download is about 3 GB, so `download` starts `sudo mas install` as background work and returns at
/// once; the rest of the install carries on (with the Command Line Tools kept selected, and Xcode's license
/// accepted the moment it lands, so Homebrew keeps working), and `finish` (near the end) waits for Xcode,
/// runs the first-launch setup and selects it. App Store sign-in cannot be automated.
struct XcodeAction: Action {
    enum Mode: String, CaseIterable {
        case download, finish
    }

    static let appStoreID = "497799835"
    static let storeURL = URL(string: "macappstore://apps.apple.com/us/app/xcode/id497799835?mt=12")!
    /// The id the download is registered under in `SharedState`.
    static let backgroundID = "xcode"
    /// Set by the background download once mas is done, whatever happened.
    static let outcomeKey = "pkg.xcode.download.outcome"
    static let defaultTimeoutMinutes: Double = 180
    /// What `xcodebuild -downloadPlatform` accepts.
    static let platformChoices = ["iOS", "watchOS", "tvOS", "visionOS"]

    let mode: Mode
    /// How long `finish` waits for Xcode to arrive, in seconds.
    let timeout: TimeInterval
    let platforms: [String]
    let system: MacSystem

    var title: String { mode == .download ? "Xcode" : "Finish setting up Xcode" }
    var subtitle: String? {
        switch mode {
        case .download:
            return "Mac App Store, downloads in the background"
        case .finish:
            return "license, first launch, select" + (platforms.isEmpty ? "" : ", \(platforms.joined(separator: "/")) simulators")
        }
    }
    var sudo: SudoNeed { .always }

    static func parse(_ parser: ItemParser, system: MacSystem) -> XcodeAction {
        let raw = parser.primaryString()
        let mode = Mode(rawValue: raw)
        if mode == nil && !raw.isEmpty {
            parser.fail("'xcode' takes 'download' or 'finish' (got '\(raw)')")
        }
        let options = parser.options
        let minutes = options.double("timeout_minutes")
        var platforms: [String] = []
        for name in options.stringList("platforms") {
            if let canonical = platformChoices.first(where: { $0.lowercased() == name.lowercased() }) {
                platforms.append(canonical)
            } else {
                options.error("'platforms' entries must be among \(platformChoices.joined(separator: ", ")) (got '\(name)')", key: "platforms")
            }
        }
        if mode == .download {
            if minutes != nil { options.error("'timeout_minutes' only applies to 'xcode: finish'", key: "timeout_minutes") }
            if !platforms.isEmpty { options.error("'platforms' only applies to 'xcode: finish'", key: "platforms") }
        }
        if let minutes, minutes <= 0 {
            options.error("'timeout_minutes' must be greater than 0", key: "timeout_minutes")
        }
        return XcodeAction(mode: mode ?? .download, timeout: (minutes ?? defaultTimeoutMinutes) * 60, platforms: platforms, system: system)
    }

    // MARK: Locations

    func appURL(_ context: ActionContext) -> URL {
        context.environment.applicationsDirectory.appendingPathComponent("Xcode.app")
    }

    func developerDirectory(_ context: ActionContext) -> URL {
        appURL(context).appendingPathComponent("Contents/Developer")
    }

    func xcodebuild(_ context: ActionContext) -> String {
        developerDirectory(context).appendingPathComponent("usr/bin/xcodebuild").path
    }

    func isInstalled(_ context: ActionContext) -> Bool {
        FileManager.default.isExecutableFile(atPath: xcodebuild(context))
    }

    private func developerEnvironment(_ context: ActionContext) -> [String: String] {
        ["DEVELOPER_DIR": developerDirectory(context).path]
    }

    private var waitMinutes: Int { max(1, Int((timeout / 60).rounded())) }

    // MARK: Check

    func check(_ context: ActionContext) async -> CheckResult {
        guard isInstalled(context) else { return .needed(mode == .download ? nil : "Xcode is not installed yet") }
        let version = Common.bundleVersion(of: appURL(context)).map { "Xcode \($0)" } ?? "Xcode"
        switch mode {
        case .download:
            return .satisfied("\(version) is installed")
        case .finish:
            let state = await setupState(context)
            return state.isComplete ? .satisfied("\(version) is set up") : .needed(state.summary)
        }
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        if let refusal = Common.sandboxRefusal(mode == .download ? "downloading Xcode" : "setting up Xcode", context, system: system) {
            return refusal
        }
        switch mode {
        case .download: return try await download(context)
        case .finish: return try await finish(context)
        }
    }

    // MARK: Download

    private func download(_ context: ActionContext) async throws -> ActionOutcome {
        if !context.dryRun, isInstalled(context) { return .done("already installed") }
        if await context.shared.backgroundTask(Self.backgroundID) != nil { return .done("already downloading in the background") }

        if context.dryRun {
            context.info("[dry-run] would make sure you are signed in to the App Store, then download in the background")
            try await keepCommandLineToolsSelected(context)
            try await context.run(Command(AppStore.expectedMasPath(context), ["install", Self.appStoreID]).asRoot())
            return .done(nil)
        }

        let found: String?
        do {
            found = try await AppStore.ensureMas(context)
        } catch {
            if Common.isStop(error) { throw error }
            context.warn("Could not install mas: \(Common.describe(error))")
            return try await openStoreInstead(context, detail: "mas could not be installed with Homebrew (\(Common.describe(error))), so the App Store page was opened instead.")
        }
        guard let mas = found else {
            return try await openStoreInstead(context, detail: "mas could not be installed, so the App Store page was opened instead.")
        }
        let signIn = try await AppStore.confirmSignIn(context, url: Self.storeURL, timeout: system.timing.appStoreQuestionTimeout)
        guard signIn == .confirmed else {
            context.followUp("Install Xcode from the App Store", detail: signIn.followUpDetail, url: Self.storeURL)
            return .skipped(signIn.skipReason)
        }

        try await keepCommandLineToolsSelected(context)
        let action = self
        let task = Task<ActionOutcome, Error> {
            let outcome = await action.downloadInBackground(mas: mas, context)
            await context.shared.set(Self.outcomeKey, outcome)
            return outcome
        }
        await context.shared.startBackground(Self.backgroundID, task)
        context.info("Xcode (about 3 GB) is downloading in the background; the rest of the install carries on.")
        return .done("downloading in the background")
    }

    /// When mas cannot start the download: the App Store page, and a checklist entry. Xcode may then land while
    /// the install is still running, just as with mas.
    private func openStoreInstead(_ context: ActionContext, detail: String) async throws -> ActionOutcome {
        try await keepCommandLineToolsSelected(context)
        try await Common.open([Self.storeURL.absoluteString], context, system: system)
        context.followUp("Install Xcode from the App Store", detail: detail, url: Self.storeURL)
        return .needsAttention("opened Xcode in the App Store. Click Get there")
    }

    /// Homebrew refuses every command while the active developer directory is an Xcode whose license nobody has
    /// accepted, and the rest of the install (more brew) runs while Xcode downloads. With no valid selection (none
    /// at all, or a stale one), macOS falls back to /Applications/Xcode.app by itself the moment it lands, so the
    /// Command Line Tools are selected explicitly now; `finish` selects Xcode once its license is accepted.
    /// A full Xcode someone selected on purpose is left alone. Failing to select is only a warning.
    private func keepCommandLineToolsSelected(_ context: ActionContext) async throws {
        let tools = system.commandLineTools
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("usr/bin/git").path) else { return }
        if let selected = await context.capture(system.xcodeSelect, ["-p"]), Common.isFullXcode(selected) { return }
        let warning = "Could not select the Command Line Tools while Xcode downloads"
        let advice = "if Homebrew later says the Xcode license has not been accepted, run 'sudo xcodebuild -license accept'."
        do {
            let result = try await context.run(Command(system.xcodeSelect, ["--switch", tools.path]).asRoot())
            if !result.succeeded { context.warn("\(warning) (\(result.tail(2))); \(advice)") }
        } catch {
            if Common.isStop(error) { throw error }
            context.warn(ActionError.sentences("\(warning): \(Common.describe(error))", advice))
        }
    }

    private func downloadInBackground(mas: String, _ context: ActionContext) async -> ActionOutcome {
        do {
            try await AppStore.install(id: Self.appStoreID, name: "Xcode", mas: mas, timeout: system.timing.xcodeDownloadTimeout, context)
        } catch {
            if Common.isStop(error) { return .skipped("cancelled") }
            let reason = AppStore.explain(error)
            context.warn(ActionError.sentences(reason, "opening Xcode in the App Store instead."))
            do {
                try await Common.open([Self.storeURL.absoluteString], context, system: system)
            } catch {
                context.warn("Could not open the App Store: \(Common.describe(error))")
            }
            context.followUp("Install Xcode from the App Store", detail: ActionError.sentence(reason), url: Self.storeURL)
            return .needsAttention("mas could not download Xcode")
        }
        context.success("Xcode has downloaded.")
        await acceptLicenseOnArrival(context)
        return .done("downloaded")
    }

    /// Accepts the license as soon as Xcode is there, before anything selects it: Homebrew refuses to run while the
    /// active Xcode is unlicensed, and the rest of the install is still using it. `finish` tries again if this fails.
    private func acceptLicenseOnArrival(_ context: ActionContext) async {
        guard isInstalled(context), !(await probe(["-license", "check"], context)) else { return }
        let command = Command(xcodebuild(context), ["-license", "accept"]).env(developerEnvironment(context)).asRoot()
        do {
            let result = try await context.run(command)
            if result.succeeded {
                context.info("Accepted the Xcode license, so Homebrew keeps working with the new Xcode.")
            } else {
                context.warn("Could not accept the Xcode license yet (\(result.tail(2))); 'xcode: finish' tries again.")
            }
        } catch {
            if Common.isStop(error) { return }
            context.warn("Could not accept the Xcode license yet (\(Common.describe(error))); 'xcode: finish' tries again.")
        }
    }

    // MARK: Finish

    struct SetupState: Equatable {
        /// The active developer directory is this Xcode, or another full Xcode someone selected on purpose.
        var selected: Bool
        var licenseAccepted: Bool
        var firstLaunchDone: Bool
        var missingPlatforms: [String]
        /// The other full Xcode that stays selected (e.g. a beta), if any.
        var otherSelection: String? = nil

        var isComplete: Bool { selected && licenseAccepted && firstLaunchDone && missingPlatforms.isEmpty }

        var summary: String {
            var parts: [String] = []
            if !selected { parts.append("not selected") }
            if !licenseAccepted { parts.append("license not accepted") }
            if !firstLaunchDone { parts.append("first launch not run") }
            if !missingPlatforms.isEmpty { parts.append("missing \(missingPlatforms.joined(separator: ", ")) simulator") }
            return parts.joined(separator: ", ")
        }
    }

    /// What is left to do. A different full Xcode that is selected (a beta, an older version) counts as a
    /// deliberate choice and is kept: `xcode-select` is system-wide, and every sync would otherwise switch it back.
    /// The license and first launch are always checked for this Xcode, through DEVELOPER_DIR.
    func setupState(_ context: ActionContext) async -> SetupState {
        let developer = developerDirectory(context)
        var selected = false
        var otherSelection: String?
        if let selectedPath = await context.capture(system.xcodeSelect, ["-p"]) {
            if URL(fileURLWithPath: selectedPath).resolvingSymlinksInPath().path == developer.resolvingSymlinksInPath().path {
                selected = true
            } else if Common.isFullXcode(selectedPath) {
                selected = true
                otherSelection = selectedPath
            }
        }
        return SetupState(
            selected: selected,
            licenseAccepted: await probe(["-license", "check"], context),
            firstLaunchDone: await probe(["-checkFirstLaunchStatus"], context),
            missingPlatforms: await missingPlatforms(context),
            otherSelection: otherSelection
        )
    }

    /// Read-only `xcodebuild` question; anything but a clean exit counts as "not yet".
    private func probe(_ arguments: [String], _ context: ActionContext) async -> Bool {
        let command = Command(xcodebuild(context), arguments).env(developerEnvironment(context)).readOnly().timeout(120)
        do {
            return try await context.run(command).succeeded
        } catch {
            return false
        }
    }

    /// Requested simulator platforms with no available runtime, from `simctl list runtimes -j`.
    func missingPlatforms(_ context: ActionContext) async -> [String] {
        guard !platforms.isEmpty else { return [] }
        let simctl = developerDirectory(context).appendingPathComponent("usr/bin/simctl").path
        let command = Command(simctl, ["list", "runtimes", "-j"]).env(developerEnvironment(context)).readOnly().timeout(120)
        let output: String
        do {
            let result = try await context.run(command)
            guard result.succeeded else { return platforms }
            output = result.stdout
        } catch {
            return platforms
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let runtimes = object["runtimes"] as? [[String: Any]] else { return platforms }
        let available = Set(runtimes.filter { ($0["isAvailable"] as? Bool) != false }.compactMap { $0["platform"] as? String })
        // simctl calls visionOS "xrOS".
        return platforms.filter { platform in
            let names = platform == "visionOS" ? ["visionOS", "xrOS"] : [platform]
            return !names.contains(where: available.contains)
        }
    }

    private func finish(_ context: ActionContext) async throws -> ActionOutcome {
        if context.dryRun {
            context.info("[dry-run] would wait up to \(waitMinutes) minutes for Xcode to arrive")
            try await configure(context, state: SetupState(selected: false, licenseAccepted: false, firstLaunchDone: false, missingPlatforms: platforms))
            return .done(nil)
        }
        if !isInstalled(context), await context.shared.backgroundTask(Self.backgroundID) == nil, await AppStore.wasSkipped(context) {
            return .skipped("App Store apps were skipped, so Xcode was not downloaded")
        }
        guard try await waitForXcode(context) else {
            context.followUp("Finish installing Xcode",
                             detail: "Xcode was not in Applications after \(waitMinutes) minutes. Once it is, run the installer again and this step finishes the setup.",
                             url: Self.storeURL)
            return .needsAttention("Xcode has not arrived yet")
        }
        try await configure(context, state: await setupState(context))
        return .done(Common.bundleVersion(of: appURL(context)).map { "Xcode \($0) is ready" } ?? "Xcode is ready")
    }

    /// Waits for the background download to end and Xcode to be in Applications. False on timeout.
    private func waitForXcode(_ context: ActionContext) async throws -> Bool {
        let background = await context.shared.backgroundTask(Self.backgroundID)
        let deadline = Date().addingTimeInterval(timeout)
        let downloading = Attention(
            title: "Waiting for Xcode",
            message: "Xcode (about 3 GB) is downloading from the App Store. This step carries on by itself when it lands; it waits up to \(waitMinutes) minutes."
        )
        let manual = Attention(
            title: "Install Xcode from the App Store",
            message: "Click Get (or the download button) on Xcode in the App Store. This step carries on by itself once Xcode is in Applications; it waits up to \(waitMinutes) minutes.",
            url: Self.storeURL
        )
        var shown: Attention?
        defer { if shown != nil { context.attention(nil) } }

        while true {
            let outcome = await context.shared.value(Self.outcomeKey, as: ActionOutcome.self)
            let stillDownloading = background != nil && outcome == nil
            if !stillDownloading && isInstalled(context) { return true }
            let wanted = stillDownloading ? downloading : manual
            if wanted != shown {
                context.attention(wanted)
                shown = wanted
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            try await Common.pause(min(system.timing.xcodePollInterval, remaining))
        }
    }

    /// Accept the license, run the first-launch setup, select Xcode, fetch simulators: each only if needed.
    /// Selecting comes after the license (both go through DEVELOPER_DIR), so a failure or a stop in between
    /// never leaves an unlicensed Xcode active, which would make every brew command refuse to run.
    private func configure(_ context: ActionContext, state: SetupState) async throws {
        let developer = developerDirectory(context).path
        let environment = developerEnvironment(context)
        if !state.licenseAccepted {
            try await context.runChecked(Command(xcodebuild(context), ["-license", "accept"]).env(environment).asRoot())
        }
        if !state.firstLaunchDone {
            try await context.runChecked(Command(xcodebuild(context), ["-runFirstLaunch"]).env(environment).asRoot())
        }
        if !state.selected {
            try await context.runChecked(Command(system.xcodeSelect, ["-s", developer]).asRoot())
        } else if let other = state.otherSelection {
            context.info("Keeping the selected Xcode (\(other)); \(context.display(appURL(context))) is set up too. Switch with 'sudo xcode-select -s'.")
        }
        for platform in state.missingPlatforms {
            try await context.runChecked(Command(xcodebuild(context), ["-downloadPlatform", platform]).env(environment))
        }
    }
}
