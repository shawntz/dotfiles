import XCTest
@testable import ShawnCore

final class RegistryAndPlanTests: XCTestCase {
    private func plan(_ steps: [String: String], log: FakeAction.Log = .init()) throws -> (InstallPlan, TempDirectory) {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, steps: steps)
        let config = try ConfigLoader.load(from: root).config
        return (InstallPlan.build(config: config, registry: FakeAction.registry(log: log), environment: .testSandbox(directory)), directory)
    }

    func testResolvesKindsOptionsAndCommonKeys() throws {
        let (plan, _) = try plan(["01.yaml": """
        id: one
        title: One
        items:
          - ok: eza
            flavor: grape
            name: Fancy ls
            note: replaces ls
          - ok: extra
            optional: true
        """])
        XCTAssertFalse(plan.hasErrors, "\(plan.issues)")
        let items = plan.steps[0].items
        XCTAssertEqual(items.map(\.id), ["one/0", "one/1"])
        XCTAssertEqual(items[0].title, "Fancy ls", "name: overrides the action's title")
        XCTAssertEqual(items[0].config.note, "replaces ls")
        XCTAssertEqual(items[0].config.kind, "ok")
        XCTAssertEqual(items[0].config.options.keys, ["flavor"], "common keys and the kind key are not options")
        XCTAssertTrue(items[0].enabledByDefault)
        XCTAssertFalse(items[1].enabledByDefault)
        XCTAssertEqual(items[1].title, "extra")
    }

    /// A clone item's title is its repository, which the shipped config writes as "{{dotfiles_repo}}". The app and
    /// the CLI printed the braces.
    func testTitlesShowVariablesFilledIn() throws {
        let (plan, _) = try plan(["01.yaml": """
        id: one
        title: One
        items:
          - ok: "{{editor}}"
          - ok: thing
            name: Set up {{editor}} in {{home}}
          - ok: "{{nobody}} stays as written"
        """])
        let items = plan.steps[0].items
        XCTAssertEqual(items[0].title, "nvim")
        XCTAssertTrue(items[1].title.hasPrefix("Set up nvim in /"), items[1].title)
        XCTAssertFalse(items[1].title.contains("{{"), items[1].title)
        XCTAssertEqual(items[2].title, "{{nobody}} stays as written", "an unknown variable is left for validation to report")
    }

    func testReportsUnknownKindMisplacedKindUnknownOptionAndValidation() throws {
        let (plan, _) = try plan(["01.yaml": """
        id: one
        title: One
        items:
          - okk: typo
          - flavor: grape
            ok: misplaced
          - ok: fine
            flavour: grape
          - ok:
          - invalid: thing
          - ok: good
        """])
        let text = plan.errors.map(\.description).joined(separator: "\n")
        XCTAssertTrue(text.contains("unknown item kind 'okk'") && text.contains("Did you mean 'ok'"), text)
        XCTAssertTrue(text.contains("put 'ok:' first"), text)
        XCTAssertTrue(text.contains("unknown key 'flavour'") && text.contains("Did you mean 'flavor'"), text)
        XCTAssertTrue(text.contains("item 4 (ok): 'ok' needs a value"), text)
        XCTAssertTrue(text.contains("item 5 (invalid): payload file is missing"), text)
        XCTAssertTrue(text.contains("steps/01.yaml:"), text)
        // Broken items are dropped; valid ones (and ones that only fail validation) stay.
        XCTAssertEqual(plan.steps[0].items.map(\.title), ["thing", "good"])
    }

    func testSelectionDefaultsAndOverrides() throws {
        let (plan, _) = try plan([
            "01.yaml": "id: one\ntitle: One\nitems:\n  - ok: a\n  - ok: b\n    optional: true\n",
            "02.yaml": "id: two\ntitle: Two\nenabled: false\nitems:\n  - ok: c\n",
        ])
        var selection = Selection.defaults(for: plan)
        XCTAssertEqual(selection.enabledItems(in: plan).map(\.title), ["a"])

        let optionalItem = try XCTUnwrap(plan.item("one/1"))
        selection.setItem(optionalItem, enabled: true)
        selection.setStep("two", enabled: true)
        XCTAssertEqual(selection.enabledItems(in: plan).map(\.title), ["a", "b", "c"])

        selection.setItem(optionalItem, enabled: false)
        XCTAssertTrue(selection.itemOverrides.isEmpty, "returning to the default clears the override")
        XCTAssertEqual(Selection.only(steps: ["two"], in: plan).enabledItems(in: plan).map(\.title), ["c"])
    }
}

final class InstallEngineTests: XCTestCase {
    private struct Harness {
        let engine: InstallEngine
        let plan: InstallPlan
        let log: FakeAction.Log
        let directory: TempDirectory
        let environment: SystemEnvironment
    }

    private func harness(_ steps: [String: String], options: RunOptions = RunOptions()) throws -> Harness {
        let directory = TempDirectory()
        let log = FakeAction.Log()
        let root = makeConfig(in: directory, steps: steps)
        let config = try ConfigLoader.load(from: root).config
        let environment = SystemEnvironment.testSandbox(directory)
        let plan = InstallPlan.build(config: config, registry: FakeAction.registry(log: log), environment: environment)
        XCTAssertFalse(plan.hasErrors, "\(plan.issues)")
        let engine = InstallEngine(plan: plan, environment: environment, options: options)
        return Harness(engine: engine, plan: plan, log: log, directory: directory, environment: environment)
    }

    private static let mixed = [
        "01.yaml": """
        id: one
        title: One
        items:
          - ok: first
            follow_up: Sign in to Dropbox
          - present: second
          - boom: third
          - manual: fourth
          - ok: fifth
            optional: true
        """,
        "02.yaml": "id: two\ntitle: Two\nitems:\n  - ok: sixth\n",
    ]

    func testRunsEverythingReportsStatusesAndKeepsGoingAfterAFailure() async throws {
        let harness = try harness(Self.mixed)
        let events = Recorder<InstallEvent>()
        let summary = await harness.engine.run(selection: .defaults(for: harness.plan)) { events.add($0) }

        XCTAssertEqual(summary.done, 2)
        XCTAssertEqual(summary.alreadyDone, 1)
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.failures.map(\.title), ["third"])
        XCTAssertEqual(summary.failures.first?.message, "kaboom")
        XCTAssertFalse(summary.succeeded)
        XCTAssertEqual(summary.followUps.map(\.title), ["Sign in to Dropbox"])
        XCTAssertEqual(summary.followUps.first?.stepID, "one")

        // 'second' is already present so it is checked but never run; 'fifth' is optional so it is never touched.
        XCTAssertEqual(harness.log.all, [
            "check:first", "run:first:dryRun=false",
            "check:second",
            "check:third", "run:third:dryRun=false",
            "check:fourth", "run:fourth:dryRun=false",
            "check:sixth", "run:sixth:dryRun=false",
        ])

        var itemStatuses: [String: [ItemStatus]] = [:]
        var stepStatuses: [String: [StepStatus]] = [:]
        var total: Int?
        var finished = false
        for event in events.all {
            switch event {
            case .runStarted(let count): total = count
            case .itemStatus(let id, let status): itemStatuses[id, default: []].append(status)
            case .stepStatus(let id, let status): stepStatuses[id, default: []].append(status)
            case .runFinished: finished = true
            default: break
            }
        }
        XCTAssertEqual(total, 5)
        XCTAssertTrue(finished)
        XCTAssertEqual(itemStatuses["one/0"], [.checking, .running, .done(nil)])
        XCTAssertEqual(itemStatuses["one/1"], [.checking, .alreadyDone("already there")])
        XCTAssertEqual(itemStatuses["one/2"], [.checking, .running, .failed("kaboom")])
        XCTAssertEqual(itemStatuses["one/3"], [.checking, .running, .needsAttention("click the button")])
        XCTAssertEqual(itemStatuses["one/4"], [.disabled])
        XCTAssertEqual(stepStatuses["one"], [.running, .finishedWithFailures(1)])
        XCTAssertEqual(stepStatuses["two"], [.running, .done])
    }

    func testLogLinesAreAttributedToTheirItemAndWrittenToTheLogFile() async throws {
        let harness = try harness(Self.mixed)
        let events = Recorder<InstallEvent>()
        let summary = await harness.engine.run(selection: .defaults(for: harness.plan)) { events.add($0) }
        let lines: [LogLine] = events.all.compactMap { if case .log(let line) = $0 { return line } else { return nil } }
        XCTAssertTrue(lines.contains { $0.text == "working on first" && $0.itemID == "one/0" })
        XCTAssertTrue(lines.contains { $0.style == .error && $0.text.contains("third: kaboom") && $0.itemID == "one/2" })

        let logFile = try XCTUnwrap(summary.logFile)
        let transcript = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(transcript.contains("working on first"), transcript)
        XCTAssertTrue(transcript.contains("run finished: 2 done, 1 already done"), transcript)
        XCTAssertTrue(logFile.path.hasPrefix(harness.environment.logsDirectory.path))
    }

    func testDryRunAndAssumeFreshArePassedThrough() async throws {
        let harness = try harness(["01.yaml": "id: one\ntitle: One\nitems:\n  - present: a\n  - ok: b\n"],
                                  options: RunOptions(dryRun: true, assumeFresh: true))
        let events = Recorder<InstallEvent>()
        let summary = await harness.engine.run(selection: .defaults(for: harness.plan)) { events.add($0) }
        XCTAssertTrue(summary.wasDryRun)
        XCTAssertEqual(summary.done, 2, "assumeFresh runs items even if they would report as present")
        XCTAssertEqual(harness.log.all, ["run:a:dryRun=true", "run:b:dryRun=true"])
        XCTAssertTrue(events.all.contains { if case .log(let line) = $0 { return line.text.contains("Dry run") } else { return false } })
    }

    func testDisabledStepIsSkippedEntirely() async throws {
        let harness = try harness(Self.mixed)
        var selection = Selection.defaults(for: harness.plan)
        selection.setStep("one", enabled: false)
        let events = Recorder<InstallEvent>()
        let summary = await harness.engine.run(selection: selection) { events.add($0) }
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(harness.log.all, ["check:sixth", "run:sixth:dryRun=false"])
        XCTAssertTrue(events.all.contains { if case .stepStatus("one", .disabled) = $0 { return true } else { return false } })
    }

    func testScanIsReadOnly() async throws {
        let harness = try harness(Self.mixed)
        let results = Recorder<(String, CheckResult)>()
        await harness.engine.scan(selection: .defaults(for: harness.plan)) { results.add(($0, $1)) }
        XCTAssertEqual(results.all.map(\.0), ["one/0", "one/1", "one/2", "one/3", "two/0"])
        XCTAssertEqual(results.all.filter { $0.1.isSatisfied }.map(\.0), ["one/1"])
        XCTAssertTrue(harness.log.all.allSatisfy { $0.hasPrefix("check:") }, "scan must never run an action")
    }

    func testCancellationStopsPromptlyAndMarksTheSummary() async throws {
        let harness = try harness(["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: a\n  - slow: b\n  - ok: c\n"])
        let started = Date()
        let task = Task { await harness.engine.run(selection: .defaults(for: harness.plan)) { _ in } }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        let summary = await task.value
        XCTAssertTrue(summary.wasCancelled)
        XCTAssertFalse(summary.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertFalse(harness.log.all.contains("run:c:dryRun=false"), "nothing after the canceled item may run")
    }

    func testStoppingMidItemIsNotAFailureAndTheStepIsNotCalledDone() async throws {
        let harness = try harness(["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: a\n  - slow: b\n  - ok: c\n"])
        let events = Recorder<InstallEvent>()
        let task = Task { await harness.engine.run(selection: .defaults(for: harness.plan)) { events.add($0) } }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        let summary = await task.value

        XCTAssertTrue(summary.wasCancelled)
        XCTAssertTrue(summary.failures.isEmpty, "an interrupted item is not a failure")
        var itemStatuses: [String: [ItemStatus]] = [:]
        var stepStatuses: [StepStatus] = []
        for event in events.all {
            if case .itemStatus(let id, let status) = event { itemStatuses[id, default: []].append(status) }
            if case .stepStatus("one", let status) = event { stepStatuses.append(status) }
        }
        XCTAssertEqual(itemStatuses["one/1"]?.last, .cancelled)
        XCTAssertNil(itemStatuses["one/2"], "the item after the interrupted one never starts")
        XCTAssertEqual(stepStatuses, [.running, .stopped])
    }

    func testStopNoticedBetweenItemsMarksTheStepStoppedOnlyIfSomethingWasLeft() async throws {
        // 'present' items finish instantly; the run is canceled before it starts, so nothing gets its turn.
        let harness = try harness(["01.yaml": "id: one\ntitle: One\nitems:\n  - present: a\n  - ok: b\n"])
        let events = Recorder<InstallEvent>()
        let task = Task { () -> InstallSummary in
            withUnsafeCurrentTask { $0?.cancel() }
            return await harness.engine.run(selection: .defaults(for: harness.plan)) { events.add($0) }
        }
        let summary = await task.value
        XCTAssertTrue(summary.wasCancelled)
        let stepStatuses: [StepStatus] = events.all.compactMap { if case .stepStatus("one", let status) = $0 { return status } else { return nil } }
        XCTAssertEqual(stepStatuses.last, .stopped)
        XCTAssertFalse(harness.log.all.contains { $0.hasPrefix("run:") })
    }

    func testLogFileSurvivesWriteErrors() throws {
        let directory = TempDirectory()
        let log = LogFile(directory: directory.url, runID: "full-disk", enabled: true)
        let url = try XCTUnwrap(log.url)
        log.record(.log(LogLine("before")))

        // Simulate a full disk: no file may grow beyond its current size.
        signal(SIGXFSZ, SIG_IGN)
        var original = rlimit()
        getrlimit(RLIMIT_FSIZE, &original)
        var tight = original
        tight.rlim_cur = 64
        setrlimit(RLIMIT_FSIZE, &tight)
        for index in 0..<50 { log.record(.log(LogLine("line \(index) that will not fit once the limit is reached"))) }
        setrlimit(RLIMIT_FSIZE, &original)
        signal(SIGXFSZ, SIG_DFL)

        log.record(.log(LogLine("after")))
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("before"))
        XCTAssertFalse(text.contains("after"), "after a write error the file is left alone rather than crashing the run")
    }

    func testEventStreamDeliversInOrderAndFinishes() async throws {
        let harness = try harness(["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: a\n"])
        var kinds: [String] = []
        for await event in harness.engine.events(selection: .defaults(for: harness.plan)) {
            switch event {
            case .runStarted: kinds.append("start")
            case .runFinished: kinds.append("finish")
            case .itemStatus(_, let status): kinds.append("item:\(status)")
            default: break
            }
        }
        XCTAssertEqual(kinds.first, "start")
        XCTAssertEqual(kinds.last, "finish")
        XCTAssertTrue(kinds.contains("item:done(nil)"))
    }

    func testContextPathAndTemplateHelpers() async throws {
        let harness = try harness(["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: a\n"])
        let step = harness.plan.steps[0]
        let context = ActionContext(config: harness.plan.config, environment: harness.environment, options: RunOptions(),
                                    step: step.config, item: step.items[0].config, sudo: nil,
                                    interaction: NonInteractive(), shared: SharedState(), emit: { _ in })
        let home = harness.environment.home.path
        XCTAssertEqual(context.path("~/Developer").path, home + "/Developer")
        XCTAssertEqual(context.path("{{home}}/x").path, home + "/x")
        XCTAssertEqual(context.path("relative/x").path, home + "/relative/x")
        XCTAssertEqual(context.path("/abs/x").path, "/abs/x")
        XCTAssertEqual(context.expand("{{editor}} on {{hostname}}"), "nvim on Sandbox Mac")
        XCTAssertEqual(context.display(URL(fileURLWithPath: home + "/.zshrc")), "~/.zshrc")
        XCTAssertEqual(context.configURL("files/zsh/zshrc").path, harness.plan.config.root.path + "/files/zsh/zshrc")
    }

    func testAnErrorAndItsHintReadAsTwoSentences() {
        XCTAssertEqual(ActionError("kaboom", hint: "try again later").description, "kaboom. Try again later")
        XCTAssertEqual(ActionError("it stopped!", hint: "try again later").description, "it stopped! Try again later")
        XCTAssertEqual(ActionError("kaboom", hint: "").description, "kaboom")

        // A tool that dies without printing anything (killed by a signal, a crashed helper) leaves
        // "<label>: <tool output>" ending in ": ". The colon goes, so the line never reads "failed: . If...".
        let silent = CommandResult(exitCode: 137, stdout: "", stderr: "").tail(3)
        XCTAssertEqual(ActionError.sentences("could not read the com.apple.dock preferences: \(silent)",
                                             "try 'defaults export com.apple.dock -' in Terminal to see what is wrong"),
                       "could not read the com.apple.dock preferences. Try 'defaults export com.apple.dock -' in Terminal to see what is wrong")
        let clone = ActionError("Cloning https://github.com/owner/repo.git failed: \(silent)",
                                hint: "if the repository is private, sign in with the github item first, then run this again")
        XCTAssertEqual(InstallEngine.describe(clone),
                       "Cloning https://github.com/owner/repo.git failed. If the repository is private, sign in with the github item first, then run this again")
        XCTAssertEqual(ActionError("could not read the preferences before changing them: \(silent)").description,
                       "could not read the preferences before changing them")
        XCTAssertEqual(ActionError.sentences(": ", "try again later"), "Try again later")

        // Output the tool did print stays as it printed it, without the spaces at the end of its last line.
        let printed = CommandResult(exitCode: 128, stdout: "", stderr: "fatal: repository not found  \n").tail(3)
        XCTAssertEqual(ActionError("Cloning x failed: \(printed)", hint: "check the name").description,
                       "Cloning x failed: fatal: repository not found. Check the name")
    }

    func testSharedStateCachesAndInvalidates() async {
        let shared = SharedState()
        let counter = Recorder<Int>()
        let first: [String] = await shared.cached("brew.formulae") { counter.add(1); return ["eza"] }
        let second: [String] = await shared.cached("brew.formulae") { counter.add(1); return ["never"] }
        XCTAssertEqual(first, ["eza"])
        XCTAssertEqual(second, ["eza"])
        await shared.invalidate(prefix: "brew.")
        let third: [String] = await shared.cached("brew.formulae") { counter.add(1); return ["fzf"] }
        XCTAssertEqual(third, ["fzf"])
        XCTAssertEqual(counter.all.count, 2)
    }
}
