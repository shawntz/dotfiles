import Foundation
import Observation
import ShawnCore
import ShawnFun
import ShawnSync

/// Everything the installer window shows, and the only thing that changes it.
///
/// The engine runs on a background task; its events arrive here in order (batched by `EventPump`)
/// and are applied on the main actor. Tests drive the same state machine by calling `apply(_:)`.
@MainActor
@Observable
final class InstallerModel {
    enum Phase: Equatable {
        case loading
        case configError
        case welcome
        case customize
        case running
        case finished
    }

    enum Outcome: Equatable {
        case success
        case failures(Int)
        case stopped
    }

    struct LoadFailure: Error, Equatable {
        let message: String
        let issues: [ConfigIssue]
    }

    /// The callout for an item that is waiting on the person.
    struct ActiveAttention: Equatable {
        let itemID: String
        let attention: Attention
    }

    struct Settings {
        var mode: RunMode = .live
        /// The built-in simulation config and kinds: the engine always runs dry and the UI says so.
        var isSimulation = false
        var assumeFresh = false
        /// `--ask`: the first real run that needs the config's questions asks them again, offering the saved answers.
        var askAgain = false
        var autoStart = false
        /// Pause after each dry-run command (the `--demo` pace).
        var dryRunDelay: TimeInterval = 0
        var logCapacity = LogBuffer.defaultCapacity
        /// Seconds between speech-bubble lines while something is happening.
        var quipInterval: TimeInterval = 8
    }

    // MARK: Dependencies

    @ObservationIgnored let registry: ActionRegistry
    @ObservationIgnored let environment: SystemEnvironment
    @ObservationIgnored let resolveOptions: ConfigResolveOptions
    @ObservationIgnored let settings: Settings
    @ObservationIgnored var desktop: DesktopActions
    @ObservationIgnored var keepAwake: KeepAwake
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored let interaction = InteractionBridge()
    /// Called once each time a run finishes (the app uses it to quit after a confirmed mid-run quit).
    @ObservationIgnored var onRunFinished: (() -> Void)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Held from the start of a real run until it ends (see `KeepAwake`).
    @ObservationIgnored private var keepAwakeToken: (any NSObjectProtocol)?
    @ObservationIgnored private var promptSerial = 0
    /// True while a real run started with `askAgain` has questions to ask and has not gotten past them yet.
    @ObservationIgnored private var isAskingAgain = false
    /// Set once a real run with `askAgain` has gotten past its questions, so `--ask` asks again only once.
    @ObservationIgnored private var hasAskedAgain = false
    @ObservationIgnored private var itemsByID: [String: PlannedItem] = [:]
    @ObservationIgnored private var stepIDByItemID: [String: String] = [:]

    // MARK: Config

    private(set) var phase: Phase = .loading
    private(set) var plan: InstallPlan?
    private(set) var fun: FunConfig = .fallback
    private(set) var appName = "Shawn's Dotfiles"
    private(set) var tagline: String?
    private(set) var configSource: ConfigSource?
    /// What happened while choosing the config, plus non-fatal warnings. Shown on the welcome screen.
    private(set) var notes: [String] = []
    private(set) var loadFailure: LoadFailure?

    // MARK: Choices

    private(set) var selection = Selection()
    var dryRun: Bool

    // MARK: Run state

    private(set) var stepStatuses: [String: StepStatus] = [:]
    private(set) var itemStatuses: [String: ItemStatus] = [:]
    private(set) var currentStepID: String?
    private(set) var currentItemID: String?
    private(set) var log: LogBuffer
    private(set) var attention: ActiveAttention?
    /// True once the current attention code has been put on the clipboard.
    private(set) var attentionCodeCopied = false
    private(set) var followUps: [FollowUp] = []
    private(set) var summary: InstallSummary?
    private(set) var totalItems = 0
    private(set) var runStartedAt: Date?
    private(set) var runEndedAt: Date?
    /// Whether the run on screen is (or was) a dry run, as chosen when it started.
    private(set) var runIsDryRun = false
    /// Whether the run on screen writes its lines to a log file. A dry run (and so the simulation) writes none,
    /// and neither does a real run whose log file could not be created (known once it has finished).
    private(set) var runWritesLogFile = false
    /// Whether a run in this session put lines in the LOG panel that no log file holds. The panel keeps its
    /// lines from run to run (a dry run's narration stays above the real run that follows it), so from then on
    /// the lines it trims may be ones no file has.
    private var logHasUnfiledLines = false
    private(set) var isStopping = false
    private(set) var runCount = 0
    /// Password, question and text prompts, oldest first; the first one is on screen.
    private(set) var prompts: [PendingPrompt] = []
    /// The finished screen shows the run's log in place of the failures and follow-ups. A dry run opens on
    /// it (its narration of what would happen is the point of it); the person can switch either way.
    var showsLogOnFinishedScreen = false

    // MARK: Speech bubble

    private(set) var quipSeed: Int
    private(set) var quipsInPhase = 0
    private enum RecentEvent { case none, success, skipped, failure }
    private var recentEvent = RecentEvent.none

    init(registry: ActionRegistry, environment: SystemEnvironment, resolveOptions: ConfigResolveOptions = ConfigResolveOptions(),
         settings: Settings = Settings(), dryRun: Bool = false, desktop: DesktopActions = .none,
         keepAwake: KeepAwake = .none, quipSeed: Int = 0, now: @escaping () -> Date = Date.init) {
        self.registry = registry
        self.environment = environment
        self.resolveOptions = resolveOptions
        self.settings = settings
        self.dryRun = dryRun
        self.desktop = desktop
        self.keepAwake = keepAwake
        self.quipSeed = quipSeed
        self.now = now
        self.log = LogBuffer(capacity: settings.logCapacity)
        interaction.presenter = self
    }

    // MARK: - Loading

    /// Resolves the config (and its `fun/`) off the main thread, then shows the welcome or error screen.
    func loadConfig() {
        setPhase(.loading)
        let registry = registry
        let environment = environment
        let options = resolveOptions
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<LoadedConfig, LoadFailure> in
                do {
                    let resolved = try await ConfigResolver.resolve(options: options, registry: registry, environment: environment)
                    let fun = FunConfig.load(from: resolved.config)
                    return .success(LoadedConfig(resolved: resolved, fun: fun.fun, funIssues: fun.issues))
                } catch let error as ConfigResolveError {
                    return .failure(LoadFailure(message: error.message, issues: error.issues))
                } catch {
                    return .failure(LoadFailure(message: InstallEngine.describe(error), issues: []))
                }
            }.value
            switch outcome {
            case .success(let loaded): configure(loaded.resolved, fun: loaded.fun, funIssues: loaded.funIssues)
            case .failure(let failure): showLoadFailure(failure)
            }
        }
    }

    struct LoadedConfig: Sendable {
        let resolved: ResolvedConfig
        let fun: FunConfig
        let funIssues: [ConfigIssue]
    }

    /// Shows a loaded config. `extraNotes` come first (e.g. "simulation").
    func configure(_ resolved: ResolvedConfig, fun: FunConfig, funIssues: [ConfigIssue] = [], extraNotes: [String] = []) {
        let plan = resolved.plan
        self.plan = plan
        self.fun = fun
        appName = plan.config.meta.name
        tagline = plan.config.meta.tagline
        configSource = plan.config.source
        loadFailure = nil
        notes = extraNotes + resolved.notes + (plan.warnings + funIssues).map(\.description)
        itemsByID = Dictionary(plan.allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stepIDByItemID = Dictionary(plan.steps.flatMap { step in step.items.map { ($0.id, step.id) } }, uniquingKeysWith: { first, _ in first })
        selection = Selection.defaults(for: plan)
        setPhase(.welcome)
        if settings.autoStart { start() }
    }

    func showLoadFailure(_ failure: LoadFailure) {
        loadFailure = failure
        plan = nil
        setPhase(.configError)
    }

    // MARK: - Derived

    var steps: [PlannedStep] { plan?.steps ?? [] }
    var isRunning: Bool { phase == .running }
    var activePrompt: PendingPrompt? { prompts.first }
    /// Prompts are only shown while a run is in progress and not being stopped.
    var acceptsPrompts: Bool { phase == .running && !isStopping }

    var enabledItemCount: Int {
        guard let plan else { return 0 }
        return selection.enabledItems(in: plan).count
    }

    var canStart: Bool {
        guard plan != nil, runTask == nil, enabledItemCount > 0 else { return false }
        return phase == .welcome || phase == .customize || phase == .finished
    }

    var currentStep: PlannedStep? { currentStepID.flatMap { plan?.step($0) } }
    var currentItem: PlannedItem? { currentItemID.flatMap { itemsByID[$0] } }

    func item(_ id: String) -> PlannedItem? { itemsByID[id] }

    var outcome: Outcome? {
        guard let summary else { return nil }
        if summary.wasCancelled { return .stopped }
        let failed = failures.count
        return failed > 0 ? .failures(failed) : .success
    }

    /// Items that failed in this run, in plan order, with their messages. (An item interrupted by STOP is
    /// `.cancelled`, which is not a failure.)
    var failures: [(item: PlannedItem, message: String)] {
        steps.flatMap(\.items).compactMap { item in
            guard case .failed(let message) = itemStatuses[item.id] else { return nil }
            return (item, message)
        }
    }

    /// Items that got all the way through in this run (not the one a STOP interrupted).
    var finishedItemCount: Int {
        itemStatuses.values.filter(\.isComplete).count
    }

    /// Selected items this run did not get through: after a STOP, the interrupted item and everything after it.
    var unfinishedItemCount: Int {
        itemStatuses.values.filter { $0 != .disabled && !$0.isComplete }.count
    }

    var progressFraction: Double {
        guard totalItems > 0 else { return phase == .finished ? 1 : 0 }
        return min(1, Double(finishedItemCount) / Double(totalItems))
    }

    func elapsed(at date: Date) -> TimeInterval {
        if let summary, phase == .finished { return summary.duration }
        guard let start = runStartedAt else { return 0 }
        return max(0, (runEndedAt ?? date).timeIntervalSince(start))
    }

    func status(of item: PlannedItem) -> ItemStatus {
        if let status = itemStatuses[item.id] { return status }
        guard let step = plan?.step(item.config.stepID) else { return .pending }
        return selection.isEnabled(step: step) && selection.isEnabled(item: item) ? .pending : .disabled
    }

    func status(of step: PlannedStep) -> StepStatus {
        stepStatuses[step.id] ?? (selection.isEnabled(step: step) ? .pending : .disabled)
    }

    /// How a step is drawn and read out. Once the run is over, a step it never reached is "not started"
    /// (not "waiting"). A step the engine closed as `.stopped` keeps a real failure visible: the engine's
    /// `.stopped` carries no count, so the failures are counted from the items.
    func look(of step: PlannedStep) -> StatusLook {
        let status = status(of: step)
        switch status {
        case .stopped:
            let items = step.items.map { self.status(of: $0) }
            let failed = items.filter(\.isFailure).count
            if failed > 0 { return StatusLook("✗", .red, StepStatus.failedLabel(failed) + ", stopped part-way") }
            // Stopped before any of its items had a turn (the stop was noticed between steps).
            if !items.contains(where: { $0.isComplete || $0 == .cancelled }) { return .notStarted }
            return status.look
        case .pending where phase == .finished:
            return .notStarted
        default:
            return status.look
        }
    }

    /// How an item is drawn and read out; like `look(of step:)`, one the run never reached is "not started".
    func look(of item: PlannedItem) -> StatusLook {
        let status = status(of: item)
        if status == .pending, phase == .finished { return .notStarted }
        // A reminder ends with its own title as the message. The row shows the title already, so it says where
        // the reminder went (the terminal leaves the repeat out, see InstallRenderer).
        if case .needsAttention(let message) = status, message == item.title {
            return ItemStatus.needsAttention("on your checklist").look
        }
        return status.look
    }

    /// Enabled items in `step` and how many of them got all the way through in this run.
    func progress(of step: PlannedStep) -> (finished: Int, total: Int) {
        let enabled = step.items.filter { status(of: $0) != .disabled }
        let finished = enabled.filter { status(of: $0).isComplete }.count
        return (finished, enabled.count)
    }

    /// What the LOG line says when the run left no log file.
    var missingLogFileNote: String {
        // The engine never writes a log file for a dry run, sandboxed or not.
        runIsDryRun ? "a dry run writes no log file" : "no log file was written"
    }

    /// The line above the LOG panel once its oldest lines have been trimmed; nil while none have been. It says
    /// they are in the log file only when every run this session showed there wrote one: after RUN FOR REAL…
    /// the trimmed lines start with the dry run's, and no file holds those.
    var droppedLinesNote: String? {
        let dropped = log.droppedCount
        guard dropped > 0 else { return nil }
        if !runWritesLogFile { return "… \(dropped) earlier lines are no longer shown (\(missingLogFileNote))" }
        if logHasUnfiledLines { return "… \(dropped) earlier lines are no longer shown (this run's lines are also in the log file)" }
        return "… \(dropped) earlier lines are in the log file"
    }

    var configSourceLine: String {
        if settings.isSimulation { return "config: built-in simulation" }
        switch configSource {
        case .remote(let repo, let ref, let commit)?: return "config: \(repo)@\(ref) (\(commit.prefix(7)))"
        case .bundled?: return "config: bundled with the app"
        case .local(let path)?: return "config: " + PathExpansion.abbreviate(path, home: FileManager.default.homeDirectoryForCurrentUser)
        case nil: return ""
        }
    }

    // MARK: - Selection

    var isSelectionEditable: Bool { phase == .welcome || phase == .customize || phase == .finished }

    func isEnabled(_ step: PlannedStep) -> Bool { selection.isEnabled(step: step) }

    func isEnabled(_ item: PlannedItem) -> Bool { selection.isEnabled(item: item) }

    func setStep(_ step: PlannedStep, enabled: Bool) {
        guard isSelectionEditable else { return }
        selection.setStep(step.id, enabled: enabled)
    }

    func setItem(_ item: PlannedItem, enabled: Bool) {
        guard isSelectionEditable else { return }
        selection.setItem(item, enabled: enabled)
    }

    /// Items in `step` that are checked (whether or not the step itself is on).
    func selectedItemCount(in step: PlannedStep) -> Int {
        step.items.filter { selection.isEnabled(item: $0) }.count
    }

    func showCustomize() {
        guard phase == .welcome else { return }
        setPhase(.customize)
    }

    func closeCustomize() {
        guard phase == .customize else { return }
        setPhase(.welcome)
    }

    // MARK: - Running

    /// Starts a run with the current selection. Also RETRY FAILED / RESUME: every action checks before it
    /// acts, so the second run skips whatever already finished.
    func start() {
        guard canStart, let plan else { return }
        // `--fresh` (and `--demo`) skip the checks on the first run only. A later run is a retry, a resume or
        // the real run after a dry run, and the finished screen promises those skip what is already done.
        let fresh = settings.assumeFresh && runCount == 0
        // `--ask` asks again in the first real run that gets past its questions. A dry run before it says what that
        // run will ask. A run that needs no answer, or one stopped before or at a question, leaves `--ask` for the
        // next run. RETRY FAILED and RESUME after it keep the answers just given instead of asking a third time.
        let askAgain = settings.askAgain && !hasAskedAgain
        let options = RunOptions(dryRun: dryRun || settings.isSimulation, assumeFresh: fresh,
                                 dryRunDelay: dryRun ? settings.dryRunDelay : 0, askAgain: askAgain)
        isAskingAgain = askAgain && !options.dryRun && !plan.questions(for: selection.enabledItems(in: plan)).isEmpty
        // The engine writes no log file for a dry run, and the simulation always runs dry.
        beginRun(writesLogFile: !options.dryRun)
        if fresh {
            log.note("Fresh run: every item runs, even if it is already done.")
        } else if settings.assumeFresh {
            log.note("Not a fresh run this time: items that are already done are skipped.")
        }
        // A real install runs for a long time and is usually left alone; idle sleep would pause it part-way.
        if !options.dryRun && settings.mode == .live { beginKeepingAwake() }
        let engine = InstallEngine(plan: plan, environment: environment, options: options, interaction: interaction)
        let selection = self.selection
        let pump = EventPump { [weak self] events in self?.apply(events) }
        // `run` rather than `events(selection:)`: cancelling the run must still deliver the engine's own
        // final `.runFinished` summary, and cancelling an `events` stream's consumer would drop it.
        runTask = Task.detached(priority: .userInitiated) {
            await engine.run(selection: selection) { event in pump.push(event) }
        }
    }

    /// STOP: cancels the engine, answers any open prompt with "no", and waits for the engine's final summary.
    func stop() {
        guard phase == .running, !isStopping else { return }
        isStopping = true
        // Cancel first. The engine resumes the moment a prompt is answered, and cancelling does not reach every
        // prompt (the password is asked from a task of its own), so an answer given before the cancel lets the
        // waiting item go on and run as if nobody had pressed STOP.
        runTask?.cancel()
        resolveAllPrompts()
        log.note("Stopping. Letting the current item wind down…", style: .warning)
    }

    /// After a dry run: back to the welcome screen with DRY RUN off, keeping the plan and the selection, so
    /// the real run is one START away and the config is not fetched again (it could have moved on).
    func setUpRealRun() {
        guard phase == .finished, runTask == nil else { return }
        dryRun = false
        setPhase(.welcome)
    }

    /// Whether idle sleep is being held off (only while a real run is in progress).
    var isKeepingAwake: Bool { keepAwakeToken != nil }

    private func beginKeepingAwake() {
        guard keepAwakeToken == nil else { return }
        keepAwakeToken = keepAwake.begin("\(appName) is installing; keeping the Mac awake until it finishes")
    }

    /// Lets the Mac sleep again. Called when the run ends however it ends (finished, stopped, quit).
    func stopKeepingAwake() {
        guard let token = keepAwakeToken else { return }
        keepAwakeToken = nil
        keepAwake.end(token)
    }

    func apply(_ events: [InstallEvent]) {
        for event in events { apply(event) }
    }

    func apply(_ event: InstallEvent) {
        switch event {
        case .runStarted(let total):
            // A run driven by events alone (tests, snapshots) is as dry as the DRY RUN switch says.
            if phase != .running { beginRun(writesLogFile: !dryRun) }
            totalItems = total

        case .stepStatus(let stepID, let status):
            stepStatuses[stepID] = status
            switch status {
            case .running:
                currentStepID = stepID
            case .done:
                if stepID == currentStepID { noteRecent(.success) }
            default:
                break
            }

        case .itemStatus(let itemID, let status):
            itemStatuses[itemID] = status
            // The engine settles every question before it reports on an item it takes, so `--ask` is used up now.
            if isAskingAgain, status != .disabled {
                isAskingAgain = false
                hasAskedAgain = true
            }
            switch status {
            case .checking, .running:
                currentItemID = itemID
                if let stepID = stepIDByItemID[itemID] { currentStepID = stepID }
            case .failed:
                noteRecent(.failure)
            case .skipped:
                noteRecent(.skipped)
            default:
                break
            }

        case .log(let line):
            log.append(line, itemTitle: line.itemID.flatMap { itemsByID[$0]?.title })

        case .attention(let itemID, let newValue):
            if let newValue {
                let candidate = ActiveAttention(itemID: itemID, attention: newValue)
                guard candidate != attention else { return }
                attention = candidate
                attentionCodeCopied = false
                performAttentionSideEffects(candidate)
            } else if attention?.itemID == itemID {
                attention = nil
                attentionCodeCopied = false
            }

        case .followUp(let followUp):
            if !followUps.contains(where: { $0.id == followUp.id }) { followUps.append(followUp) }

        case .runFinished(let summary):
            stopKeepingAwake()
            self.summary = summary
            if summary.logFile == nil { noteRunWritesNoLogFile() }
            for followUp in summary.followUps where !followUps.contains(where: { $0.id == followUp.id }) {
                followUps.append(followUp)
            }
            runEndedAt = now()
            currentItemID = nil
            attention = nil
            attentionCodeCopied = false
            resolveAllPrompts()
            isStopping = false
            runTask = nil
            // A dry run's narration is all it produces; show it unless something failed and wants reading first.
            showsLogOnFinishedScreen = runIsDryRun && failures.isEmpty
            setPhase(.finished)
            let callback = onRunFinished
            onRunFinished = nil
            callback?()
        }
    }

    private func beginRun(writesLogFile: Bool) {
        runCount += 1
        runWritesLogFile = true
        if !writesLogFile { noteRunWritesNoLogFile() }
        stepStatuses = [:]
        itemStatuses = [:]
        if let plan {
            for step in plan.steps {
                let stepOn = selection.isEnabled(step: step)
                stepStatuses[step.id] = stepOn ? .pending : .disabled
                for item in step.items {
                    itemStatuses[item.id] = stepOn && selection.isEnabled(item: item) ? .pending : .disabled
                }
            }
            totalItems = selection.enabledItems(in: plan).count
        }
        currentStepID = nil
        currentItemID = nil
        attention = nil
        attentionCodeCopied = false
        followUps = []
        summary = nil
        runStartedAt = now()
        runEndedAt = nil
        isStopping = false
        recentEvent = .none
        runIsDryRun = dryRun
        showsLogOnFinishedScreen = false
        if runCount > 1 { log.note("──────── run \(runCount)\(dryRun ? " (dry run)" : "") ────────") }
        setPhase(.running)
    }

    /// No file holds the lines of the run on screen; they stay in the LOG panel above any run that follows.
    private func noteRunWritesNoLogFile() {
        runWritesLogFile = false
        logHasUnfiledLines = true
    }

    // MARK: - Prompts

    func enqueue(_ kind: PendingPrompt.Kind) {
        promptSerial += 1
        let prompt = PendingPrompt(id: promptSerial, kind: kind)
        guard acceptsPrompts else {
            prompt.resolveWithDefault()
            return
        }
        prompts.append(prompt)
        let id = prompt.id
        let removeWhenAnswered: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.removePrompt(id: id) }
        }
        switch kind {
        case .password(_, let gate): gate.whenResolved(removeWhenAnswered)
        case .question(_, let gate): gate.whenResolved(removeWhenAnswered)
        case .text(_, let gate): gate.whenResolved(removeWhenAnswered)
        }
    }

    func submitPassword(_ password: String) {
        guard let prompt = prompts.first, case .password(_, let gate) = prompt.kind else { return }
        removePrompt(id: prompt.id)
        gate.resolve(password)
    }

    /// Cancel on the password sheet: the engine is told the password was declined.
    func cancelPassword() {
        guard let prompt = prompts.first, case .password(_, let gate) = prompt.kind else { return }
        removePrompt(id: prompt.id)
        gate.resolve(nil)
    }

    func answer(optionID: String) {
        guard let prompt = prompts.first, case .question(_, let gate) = prompt.kind else { return }
        removePrompt(id: prompt.id)
        gate.resolve(optionID)
    }

    /// CONTINUE on the text sheet. The engine gets the reply as typed: it trims it, an empty reply takes the
    /// offered answer, and a reply that does not fit the question's format comes back as a new sheet with the
    /// reason. The engine saves the answer it accepts; the model keeps no copy.
    func submitText(_ text: String) {
        guard let prompt = prompts.first, case .text(_, let gate) = prompt.kind else { return }
        removePrompt(id: prompt.id)
        gate.resolve(text)
    }

    /// SKIP on the text sheet: the engine keeps the saved answer when it offered one (`--ask`). Otherwise the question
    /// stays unanswered for this run, and the items that need it wait.
    func skipText() {
        guard let prompt = prompts.first, case .text(_, let gate) = prompt.kind else { return }
        removePrompt(id: prompt.id)
        gate.resolve(nil)
    }

    /// Where the engine keeps the answers, as the text sheet names it (`~/.shawn/answers.json`).
    var answersFileDisplayPath: String {
        PathExpansion.abbreviate(AnswerStore(environment: environment).url.path, home: environment.home)
    }

    private func removePrompt(id: Int) {
        prompts.removeAll { $0.id == id }
    }

    private func resolveAllPrompts() {
        let open = prompts
        prompts.removeAll()
        for prompt in open { prompt.resolveWithDefault() }
    }

    // MARK: - Desktop

    private func performAttentionSideEffects(_ active: ActiveAttention) {
        guard settings.mode.performsAutomaticDesktopActions else { return }
        if let code = active.attention.code, !code.isEmpty {
            desktop.copyToPasteboard(code)
            attentionCodeCopied = true
        }
        if let url = active.attention.url { desktop.open(url) }
    }

    func copyAttentionCode() {
        guard let code = attention?.attention.code else { return }
        desktop.copyToPasteboard(code)
        attentionCodeCopied = true
    }

    func openAttentionURL() {
        guard let url = attention?.attention.url else { return }
        desktop.open(url)
    }

    func open(_ url: URL) {
        desktop.open(url)
    }

    func revealLogFile() {
        guard let url = summary?.logFile else { return }
        desktop.reveal(url)
    }

    func copyLog() {
        desktop.copyToPasteboard(log.plainText)
    }

    /// Narrates a desktop action instead of performing it (simulation mode).
    func narrate(_ text: String) {
        log.note(text, style: .info)
    }

    // MARK: - Speech bubble

    var quipMoment: Moment {
        switch phase {
        case .loading:
            return .launch
        case .configError:
            return .failure
        case .welcome, .customize:
            if dryRun { return .dryRun }
            return quipsInPhase == 0 ? .launch : .idle
        case .running:
            if let prompt = prompts.first {
                if prompt.isPassword { return .password }
                return prompt.textRequest != nil ? .question : .waiting
            }
            if attention != nil { return .waiting }
            if isStopping { return .cancelled }
            switch recentEvent {
            case .failure: return .failure
            case .skipped: return .skipped
            case .success: return .success
            case .none: break
            }
            if runIsDryRun && quipsInPhase == 0 { return .dryRun }
            return .working
        case .finished:
            switch outcome {
            case .stopped?: return .cancelled
            case .failures?: return .finishedWithFailures
            // A dry run installed nothing, so no "we did it!": it was a rehearsal.
            case .success?, nil: return runIsDryRun ? .dryRun : .finished
            }
        }
    }

    /// What the speaker says right now. Deterministic for a given state and seed.
    var quip: String {
        let moment = quipMoment
        return fun.line(for: moment, stepID: moment == .working ? currentStepID : nil, seed: quipSeed)
    }

    /// Moves the speech bubble on to its next line.
    func advanceQuip() {
        quipSeed &+= 1
        quipsInPhase += 1
        recentEvent = .none
    }

    private func noteRecent(_ event: RecentEvent) {
        switch (recentEvent, event) {
        case (.failure, _): return
        case (.skipped, .success): return
        default: recentEvent = event
        }
    }

    private func setPhase(_ newPhase: Phase) {
        guard newPhase != phase else { return }
        phase = newPhase
        quipsInPhase = 0
    }

    /// The character for the current moment: the running step's mascot, otherwise the speaker.
    var mascot: Sprite? {
        if phase == .running, let mascot = currentStep?.config.mascot { return fun.sprite(mascot) }
        return fun.sprite(nil)
    }

    var speaker: Sprite? { fun.sprite(nil) }

    /// Every sprite, speaker first, then in the order the steps use them.
    var lineup: [Sprite] {
        var ordered: [Sprite] = []
        var seen = Set<String>()
        func add(_ sprite: Sprite?) {
            guard let sprite, seen.insert(sprite.id).inserted else { return }
            ordered.append(sprite)
        }
        add(fun.sprites[fun.speaker])
        for step in steps { add(step.config.mascot.flatMap { fun.sprites[$0] }) }
        for id in fun.sprites.keys.sorted() { add(fun.sprites[id]) }
        return ordered
    }
}
