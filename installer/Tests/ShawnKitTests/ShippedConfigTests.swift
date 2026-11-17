import XCTest
@testable import ShawnKit

/// Records the text questions the engine asks, and answers none.
private final class TextRequests: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    var asked: [String] { lock.withLock { ids } }

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? { nil }
    func ask(_ question: Question) async -> String { question.defaultOptionID }

    func askText(_ request: TextRequest) async -> String? {
        lock.withLock { ids.append(request.id) }
        return nil
    }
}

/// Whole-system checks against the real `config/` directory with every real item kind.
/// These are what CI runs on a pull request that edits the YAML.
final class ShippedConfigTests: XCTestCase {
    /// `installer/config`, found relative to this file.
    static let configDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ShawnKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // installer
        .appendingPathComponent("config")

    /// Kinds that only touch files under the (sandboxed) home directory, so they can really run in a test.
    static let sandboxSafeKinds: Set<String> = [
        "copy", "mkdir", "symlink", "json-merge", "defaults", "dock", "login-item", "manual", "git-config", "ssh-key", "git-signing",
    ]

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("shawn-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSandbox() throws -> SystemEnvironment {
        let environment = SystemEnvironment.sandbox(root: root)
        for directory in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return environment
    }

    private func loadPlan(environment: SystemEnvironment) throws -> InstallPlan {
        let loaded = try ConfigLoader.load(from: Self.configDirectory)
        return InstallPlan.build(config: loaded.config, registry: ShawnKit.makeRegistry(), environment: environment, extraIssues: loaded.warnings)
    }

    private func regularFiles(under directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true || values?.isSymbolicLink == true {
                result.append(url.path.replacingOccurrences(of: directory.path + "/", with: ""))
            }
        }
        return result.sorted()
    }

    // MARK: Validity

    func testConfigLoadsAndEveryItemResolves() throws {
        let plan = try loadPlan(environment: try makeSandbox())
        XCTAssertTrue(plan.errors.isEmpty, "config errors:\n" + plan.errors.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(plan.warnings.isEmpty, "config warnings:\n" + plan.warnings.map(\.description).joined(separator: "\n"))
        XCTAssertFalse(plan.steps.isEmpty)
        for step in plan.steps {
            XCTAssertFalse(step.items.isEmpty, "step '\(step.id)' has no items")
            XCTAssertEqual(step.items.count, step.config.rawItems.count, "step '\(step.id)': some items failed to resolve")
        }
        let ids = plan.allItems.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "item ids must be unique")
    }

    func testFunAssetsLoadAndEveryMascotHasASprite() throws {
        let config = try ConfigLoader.load(from: Self.configDirectory).config
        let (fun, issues) = FunConfig.load(from: config)
        XCTAssertTrue(issues.isEmpty, "fun issues:\n" + issues.map(\.description).joined(separator: "\n"))
        XCTAssertFalse(fun.sprites.isEmpty, "no sprites in fun/sprites")
        XCTAssertNotNil(fun.sprites[fun.speaker], "the speaker '\(fun.speaker)' needs a sprite")
        for step in config.steps {
            if let mascot = step.mascot {
                XCTAssertNotNil(fun.sprites[mascot], "step '\(step.id)' uses mascot '\(mascot)' which has no sprite")
            }
            XCTAssertFalse(fun.lines(for: .working, stepID: step.id).isEmpty)
        }
        for moment in Moment.allCases {
            XCTAssertFalse((fun.moments[moment] ?? []).isEmpty, "no quips for moment '\(moment.rawValue)'")
        }
        let headerLines = fun.header.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertGreaterThan(headerLines.count, 3, "the header should be ASCII art, not one line")
        XCTAssertLessThanOrEqual(headerLines.map(\.count).max() ?? 0, 66, "the header must fit the window")
    }

    /// While a step runs, its own character says the line, next to its own sprite, at every step moment. The narrator
    /// speaks in the steps she hosts and in a step with no mascot.
    func testEveryStepCharacterSpeaksForItself() throws {
        let config = try ConfigLoader.load(from: Self.configDirectory).config
        let (fun, issues) = FunConfig.load(from: config)
        XCTAssertTrue(issues.isEmpty, "fun issues:\n" + issues.map(\.description).joined(separator: "\n"))
        XCTAssertFalse(fun.voices.isEmpty, "no voices in fun/voices")
        for step in config.steps {
            if let mascot = step.mascot, mascot != fun.speaker {
                XCTAssertNotNil(fun.voices[mascot], "step '\(step.id)' uses mascot '\(mascot)', which has no voice in fun/voices")
            }
            let character = step.mascot ?? fun.speaker
            for moment in Moment.stepMoments {
                let own = character == fun.speaker
                    ? fun.lines(for: moment, stepID: step.id)
                    : fun.voices[character]?.lines(for: moment, stepID: step.id) ?? []
                for seed in 0..<10 {
                    let said = fun.say(moment, stepID: step.id, mascot: step.mascot, seed: seed)
                    let context = "step '\(step.id)', \(moment.rawValue), seed \(seed)"
                    XCTAssertEqual(said.speakerID, character, context)
                    XCTAssertEqual(said.sprite?.id, character, context)
                    XCTAssertEqual(said.sprite, fun.sprites[character], context)
                    XCTAssertTrue(own.contains(said.text), "\(context): '\(said.text)' is not one of \(character)'s lines")
                }
            }
        }
    }

    /// Installers 1.0.1 and older fetch this config from GitHub and read fun/quotes.yaml and fun/sprites/ with a strict
    /// reader, so a key they do not know is an error on their welcome screen and fails their `shawn config validate`.
    /// New kinds of lines go in new files such as fun/voices/, which those installers never read.
    func testFunFilesStayReadableByReleasedInstallers() throws {
        let config = try ConfigLoader.load(from: Self.configDirectory).config
        let quotes = try XCTUnwrap(try config.loadYAML(FunConfig.quotesPath)?.map, "fun/quotes.yaml must be a mapping")
        XCTAssertTrue(Set(quotes.keys).isSubset(of: ["speaker", "about", "show_quotes", "moments", "steps"]), "quotes.yaml keys: \(quotes.keys)")
        XCTAssertEqual(quotes["speaker"]?.string, "lsp", "a new speaker would change the narrator of every released installer")
        let releasedMoments: Set<String> = ["launch", "password", "question", "idle", "working", "waiting", "success", "failure", "skipped",
                                            "dry_run", "finished", "finished_with_failures", "cancelled"]
        XCTAssertTrue(Set(quotes["moments"]?.map?.keys ?? []).isSubset(of: releasedMoments), "moments: \(quotes["moments"]?.map?.keys ?? [])")
        for entry in quotes["show_quotes"]?.list ?? [] {
            guard let quote = entry.map else { continue }
            XCTAssertTrue(Set(quote.keys).isSubset(of: ["text", "episode", "source", "note"]), "show_quotes entry keys: \(quote.keys)")
        }
        let steps = try XCTUnwrap(quotes["steps"]?.map, "quotes.yaml steps must stay a mapping")
        for entry in steps.entries {
            XCTAssertNotNil(entry.value.list, "steps: '\(entry.key)' must stay a list")
        }

        let spriteFiles = try FileManager.default.contentsOfDirectory(atPath: config.url(FunConfig.spritesDirectory).path)
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
            .sorted()
        XCTAssertFalse(spriteFiles.isEmpty)
        for name in spriteFiles {
            let sprite = try XCTUnwrap(try config.loadYAML("\(FunConfig.spritesDirectory)/\(name)")?.map, "\(name) must be a mapping")
            XCTAssertTrue(Set(sprite.keys).isSubset(of: ["id", "name", "frame_ms", "image", "palette", "frames"]), "\(name) keys: \(sprite.keys)")
            XCTAssertTrue(sprite["frames"] != nil || sprite["image"] != nil, "\(name) needs frames or an image")
        }
    }

    /// Anyone can use this config: it asks for the Git identity instead of naming a person. The git step's items
    /// that write the identity need those answers, so a run asks before it writes them.
    func testTheGitIdentityIsAskedForNotWrittenIntoTheConfig() throws {
        let config = try ConfigLoader.load(from: Self.configDirectory).config
        XCTAssertEqual(config.meta.ask.map(\.name), ["full_name", "email"])
        XCTAssertEqual(config.meta.ask.map(\.format), [.text, .email])
        for question in config.meta.ask {
            XCTAssertFalse(question.prompt.isEmpty)
            XCTAssertNil(question.defaultValue, "a literal default would put somebody's identity back into the config")
            let command = question.defaultCommand ?? ""
            XCTAssertTrue(command.contains("git config --global --get user."), "\(question.name) offers what git already has")
            // Questions come before the bootstrap step, so on a new Mac `git` is Apple's stub, which opens an install dialog.
            XCTAssertTrue(command.hasPrefix(#"tools=$(xcode-select -p 2>/dev/null) && [ -x "$tools/usr/bin/git" ] && git "#),
                          "\(question.name) runs git only when the developer tools have it: \(command)")
        }
        XCTAssertNil(config.meta.vars["full_name"])
        XCTAssertNil(config.meta.vars["email"])
        for (name, value) in config.meta.vars {
            XCTAssertFalse(value.contains("@"), "vars: '\(name)' looks like an email address")
        }

        let plan = try loadPlan(environment: try makeSandbox())
        let needs = Dictionary(plan.allItems.filter { $0.config.stepID == "git" }.map { ($0.config.kind + ":" + $0.title, plan.questions(for: $0).map(\.name)) },
                               uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(needs["git-config:Git identity & settings"], ["full_name", "email"])
        XCTAssertEqual(needs["ssh-key:~/.ssh/id_ed25519"], ["email"], "the key's comment is the email")
        XCTAssertEqual(needs["git-signing:Git commit signing"], ["email"], "allowed_signers names the email")
        XCTAssertEqual(needs["manual:Check your email on GitHub"], ["email"])
    }

    func testEveryItemKindIsDocumented() {
        let registry = ShawnKit.makeRegistry()
        XCTAssertGreaterThan(registry.kinds.count, 20)
        for kind in registry.kinds {
            let descriptor = registry.descriptor(for: kind)!
            XCTAssertFalse(descriptor.summary.isEmpty, "kind '\(kind)' needs a summary")
            XCTAssertTrue(descriptor.example.contains("\(kind):"), "kind '\(kind)' needs an example that uses it")
        }
    }

    /// Files that git would silently refuse to add would never reach a fresh clone or the remote-config fetch.
    func testNoConfigFileIsHiddenByGitignore() throws {
        let repository = Self.configDirectory.deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("not inside the git repository")
        }
        // Finder leaves .DS_Store in any folder someone has opened. git ignores it on purpose, the installer never
        // copies it, and scripts/check-config-gitignore.sh leaves it out too.
        let files = regularFiles(under: Self.configDirectory)
            .filter { ($0 as NSString).lastPathComponent != ".DS_Store" }
            .map { "installer/config/\($0)" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path, "check-ignore", "--stdin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(files.joined(separator: "\n").utf8))
        try input.fileHandleForWriting.close()
        let ignored = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        process.waitUntilExit()
        XCTAssertTrue(ignored.isEmpty, "these config files are ignored by a .gitignore and would never be committed:\n" + ignored.joined(separator: "\n"))
    }

    // MARK: Contracts between modules

    /// The installer's `shawn-cli` kind writes `~/.config/shawn/config.yaml`; the CLI reads it back through
    /// `ShawnSettings`. Two modules, one file format.
    func testSettingsWrittenByTheInstallerAreReadBackByTheCLI() async throws {
        var environment = try makeSandbox()
        let helpers = root.appendingPathComponent("helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let fakeShawn = "#!/bin/sh\nif [ \"$1\" = completions ]; then echo '#compdef shawn'; fi\n"
        for name in ["shawn", "WebAppShell"] {
            let url = helpers.appendingPathComponent(name)
            try Data(fakeShawn.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        environment.helpersDirectory = helpers

        let configRoot = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configRoot.appendingPathComponent("steps"), withIntermediateDirectories: true)
        try Data("name: Contract Test\nremote:\n  repo: shawntz/dotfiles\n  branch: master\n  path: installer/config\n".utf8)
            .write(to: configRoot.appendingPathComponent("installer.yaml"))
        try Data("id: cli\ntitle: CLI\nitems:\n  - shawn-cli: install\n    repo: ~/Developer/dotfiles\n".utf8)
            .write(to: configRoot.appendingPathComponent("steps/01-cli.yaml"))

        let config = try ConfigLoader.load(from: configRoot).config
        let plan = InstallPlan.build(config: config, registry: ShawnKit.makeRegistry(), environment: environment)
        XCTAssertFalse(plan.hasErrors, "\(plan.issues)")
        let summary = await InstallEngine(plan: plan, environment: environment).run(selection: .defaults(for: plan)) { _ in }
        XCTAssertTrue(summary.failures.isEmpty, "\(summary.failures)")

        let settings = ShawnSettings.load(environment: environment)
        XCTAssertEqual(settings.repoURL(environment: environment)?.path, environment.home.appendingPathComponent("Developer/dotfiles").path)
        XCTAssertEqual(settings.configPath, "installer/config")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: environment.localBin.appendingPathComponent("shawn").path))
        XCTAssertTrue(ConfigLoader.isConfigDirectory(ConfigLocator.installedConfigDirectory(environment: environment)),
                      "the CLI's fallback copy of the config must be loadable")
    }

    /// `shawn doctor` leaves out the items whose kind has nothing to look at (`Action.isCheckable` is false), so
    /// that a healthy Mac can pass. In the shipped config those are exactly the `open:` items and the `manual:`
    /// and `script:` items without a `check:` (or `creates:`). Anything else being uncheckable would hide a real
    /// gap from doctor; any of these being checkable would make doctor fail for ever.
    func testOnlyItemsWithNothingToLookAtAreLeftOutOfDoctor() throws {
        let plan = try loadPlan(environment: try makeSandbox())
        var uncheckable: [String: Int] = [:]
        for item in plan.allItems {
            let hasProbe = item.config.options["check"] != nil || item.config.options["creates"] != nil
            let expected: Bool
            switch item.config.kind {
            case "open": expected = false
            case "manual", "script": expected = hasProbe
            default: expected = true
            }
            XCTAssertEqual(item.action.isCheckable, expected, "\(item.id) (\(item.config.kind): \(item.title))")
            if !item.action.isCheckable { uncheckable[item.config.kind, default: 0] += 1 }
        }
        XCTAssertGreaterThan(uncheckable["open"] ?? 0, 0, "the config opens Karabiner and Hammerspoon; if that changed, update this test")
        XCTAssertGreaterThan(uncheckable["manual"] ?? 0, 0, "the config has reminders only a person can act on")
    }

    // MARK: Behavior

    /// A dry run of absolutely everything (optional items included) must fail nothing and write nothing.
    func testDryRunOfEveryItemFailsNothingAndWritesNothing() async throws {
        let environment = try makeSandbox()
        let plan = try loadPlan(environment: environment)
        XCTAssertFalse(plan.hasErrors)
        var selection = Selection()
        for item in plan.allItems { selection.setItem(item, enabled: true) }

        let questions = TextRequests()
        let engine = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: true, assumeFresh: true), interaction: questions)
        let summary = await engine.run(selection: selection) { _ in }

        XCTAssertTrue(summary.failures.isEmpty, "dry-run failures:\n" + summary.failures.map { "\($0.itemID) \($0.title): \($0.message)" }.joined(separator: "\n"))
        XCTAssertEqual(summary.total, plan.allItems.count)
        XCTAssertEqual(regularFiles(under: root), [], "a dry run must not create files")
        XCTAssertEqual(questions.asked, [], "a dry run asks nothing")
    }

    /// The file-based items are applied for real to a sandbox home; a second run must then find nothing to do.
    func testFileBasedItemsApplyToASandboxHomeAndAreIdempotent() async throws {
        var environment = try makeSandbox()
        environment.runID = "first"
        let plan = try loadPlan(environment: environment)
        XCTAssertFalse(plan.hasErrors)

        // The Dock step resolves app names against the Applications folder; give it something to find.
        for name in ["Google Chrome", "Spotify", "Slack", "Aero Dogfood", "Herdr", "Granola"] {
            try FileManager.default.createDirectory(at: environment.applicationsDirectory.appendingPathComponent("\(name).app/Contents"), withIntermediateDirectories: true)
        }

        var selection = Selection(disabledSteps: [])
        var chosen = 0
        for item in plan.allItems {
            let safe = Self.sandboxSafeKinds.contains(item.config.kind) && !item.config.optional
            selection.setItem(item, enabled: safe)
            if safe { chosen += 1 }
        }
        XCTAssertGreaterThan(chosen, 10, "expected the config to contain file-based items")

        // The answers a person gave on an earlier run, so the git step's identity items run too.
        try AnswerStore(environment: environment).save("Pat Example", for: "full_name")
        try AnswerStore(environment: environment).save("pat@example.com", for: "email")

        let first = await InstallEngine(plan: plan, environment: environment).run(selection: selection) { _ in }
        XCTAssertTrue(first.failures.isEmpty, "failures:\n" + first.failures.map { "\($0.itemID) \($0.title): \($0.message)" }.joined(separator: "\n"))
        XCTAssertGreaterThan(first.done, 5)
        XCTAssertEqual(first.followUps.filter { $0.id.hasPrefix("answer-") }, [], "every question has its answer")
        let gitconfig = try String(contentsOf: environment.home.appendingPathComponent(".gitconfig"), encoding: .utf8)
        XCTAssertTrue(gitconfig.contains("name = Pat Example") && gitconfig.contains("email = pat@example.com"), gitconfig)
        for file in [".gitconfig", ".ssh/id_ed25519.pub", ".config/git/allowed_signers"] {
            let text = try String(contentsOf: environment.home.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("{{"), "\(file) still holds a variable:\n\(text)")
        }

        environment.runID = "second"
        let second = await InstallEngine(plan: plan, environment: environment).run(selection: selection) { _ in }
        XCTAssertTrue(second.failures.isEmpty, "second-run failures:\n" + second.failures.map { "\($0.itemID) \($0.title): \($0.message)" }.joined(separator: "\n"))
        XCTAssertEqual(second.done, 0, "a second run should find everything already in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.stateDirectory.appendingPathComponent("backups/second").path),
                       "a second run must not back anything up")
    }
}
