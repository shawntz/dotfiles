import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

final class DispatcherTests: XCTestCase {
    private let cli = """
    commands:
      hello:
        section: Greetings
        summary: Say hello
        usage: "[name]"
        run: echo hello "$@"
      install:
        summary: A YAML command hidden by the built-in
        run: echo should never run
      tool:
        section: Greetings
        summary: Launch a tool
        exec: [mytool, --flag]
    """

    private func makeHarness(_ cli: String? = nil) -> Harness {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - ok: one\n"], cli: cli ?? self.cli)
        return Harness(sandbox: sandbox, config: config)
    }

    func testGlobalFlagsAreReadUpToTheCommand() throws {
        let invocation = try Dispatcher.parseGlobals(["--no-update", "--no-color", "--config", "/x", "claude", "--no-color", "-p", "hi"], environment: [:])
        XCTAssertTrue(invocation.options.noUpdate)
        XCTAssertTrue(invocation.options.noColor)
        XCTAssertEqual(invocation.options.configPath?.path, "/x")
        XCTAssertEqual(invocation.command, "claude")
        XCTAssertEqual(invocation.arguments, ["--no-color", "-p", "hi"], "flags after the command belong to it")

        XCTAssertTrue(try Dispatcher.parseGlobals(["hello"], environment: ["SHAWN_NO_UPDATE": "1"]).options.noUpdate)
        XCTAssertFalse(try Dispatcher.parseGlobals(["hello"], environment: ["SHAWN_NO_UPDATE": "0"]).options.noUpdate)
        XCTAssertEqual(try Dispatcher.parseGlobals(["--config=/y"], environment: [:]).options.configPath?.path, "/y")
        XCTAssertThrowsError(try Dispatcher.parseGlobals(["--no-updat", "x"], environment: [:])) { error in
            XCTAssertEqual("\(error)", "unknown option --no-updat. Did you mean --no-update?")
        }
    }

    func testBuiltinWinsOverYAMLCommandOfTheSameName() async {
        let harness = makeHarness()
        let code = await harness.run(["install", "--only", "nope", "--dry-run"])
        XCTAssertEqual(code, ExitCode.usage)
        XCTAssertTrue(harness.err.plain.contains("there is no step 'nope'"), harness.err.plain)
        XCTAssertTrue(harness.replacer.requests.isEmpty, "the YAML 'install' must never run")
    }

    func testYAMLCommandRunsThroughBash() async {
        let harness = makeHarness()
        let code = await harness.run(["hello", "Shawn's", "Mac"])
        XCTAssertEqual(code, 0)
        let request = try! XCTUnwrap(harness.replacer.last)
        XCTAssertEqual(request.path, "/bin/bash")
        XCTAssertEqual(request.argv, ["bash", "-c", "echo hello \"$@\"", "shawn hello", "Shawn's", "Mac"])
        XCTAssertEqual(request.environment["SHAWN_COMMAND"], "hello")
        XCTAssertEqual(request.environment["SHAWN_BIN"], harness.context.shawnBinary.path)
        XCTAssertNotNil(request.environment["SHAWN_CONFIG"])
    }

    func testUnknownCommandSuggestsTheNearestNameAndExits64() async {
        let harness = makeHarness()
        let code = await harness.run(["helo"])
        XCTAssertEqual(code, 64)
        XCTAssertEqual(harness.err.plain, "✗ shawn: unknown command 'helo'. Did you mean 'hello'?\nRun 'shawn help' to see every command.\n")

        let builtin = harness.context
        XCTAssertEqual(Dispatcher.unknownCommand("instal", context: builtin), 64)
        XCTAssertTrue(harness.err.plain.contains("Did you mean 'install'?"))
    }

    func testUnknownGlobalOptionIsAUsageError() async {
        let harness = makeHarness()
        let code = await harness.run(["--bogus"])
        XCTAssertEqual(code, 64)
        XCTAssertTrue(harness.err.plain.contains("unknown option --bogus"))
    }

    func testVersionFlag() async {
        let harness = makeHarness()
        let code = await harness.run(["--version"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.out.text, "shawn \(ShawnCore.version)\n")
    }

    /// A harness on a Mac that runs the given macOS.
    private func harness(onMacOS major: Int, _ minor: Int, _ patch: Int) -> Harness {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - ok: one\n"], cli: cli)
        return Harness(sandbox: sandbox, config: config) {
            $0.operatingSystem = { OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch) }
        }
    }

    func testAnOlderMacOSGetsOneLineAndNothingRuns() async {
        for arguments in [["hello"], ["--version"], ["--bogus"], ["install", "--dry-run"], []] {
            let harness = harness(onMacOS: 26, 7, 2)
            let code = await harness.run(arguments)
            XCTAssertEqual(code, 69, "\(arguments)")
            XCTAssertEqual(harness.err.plain, "✗ shawn needs macOS 27 or later. This Mac runs macOS 26.7.2.\n", "\(arguments)")
            XCTAssertEqual(harness.out.text, "", "\(arguments)")
            XCTAssertTrue(harness.events.all.isEmpty, "no command and no restart: \(harness.events.all)")
        }
    }

    /// The update check asks git, and the fake git keeps every call, so it shows whether the check ran.
    func testAnOlderMacOSDoesNotLookForAnUpdate() async {
        let (control, controlGit) = selfUpdatingHarness()
        do { let code = await control.run(["hello"]); XCTAssertEqual(code, 0) }
        XCTAssertFalse(controlGit.calls.isEmpty, "on a macOS that is new enough, the update check asks git")

        let (harness, git) = selfUpdatingHarness(macOS: (26, 7, 2))
        let code = await harness.run(["hello"])
        XCTAssertEqual(code, 69)
        XCTAssertEqual(git.commandLines, [], "no update check")
        XCTAssertTrue(harness.events.all.isEmpty, "and no command: \(harness.events.all)")
        XCTAssertEqual(harness.err.plain, "✗ shawn needs macOS 27 or later. This Mac runs macOS 26.7.2.\n")
    }

    func testTheMinimumMacOSAndNewerRunAsUsual() async {
        for (major, minor) in [(27, 0), (28, 3)] {
            let harness = harness(onMacOS: major, minor, 0)
            let code = await harness.run(["--version"])
            XCTAssertEqual(code, 0, "macOS \(major).\(minor)")
            XCTAssertEqual(harness.out.text, "shawn \(ShawnCore.version)\n")
            XCTAssertEqual(harness.err.plain, "")
        }
    }

    func testHelpListsYAMLSectionsFirstThenBuiltins() async {
        let harness = makeHarness()
        let code = await harness.run([])
        XCTAssertEqual(code, 0)
        let text = harness.out.plain
        XCTAssertTrue(text.contains("SHAWN'S DOTFILES"), "fallback header when the config has no fun/")
        XCTAssertTrue(text.contains("tiny test"), "tagline")
        let groups = HelpCommand.commandGroups(context: harness.context)
        XCTAssertEqual(groups.first?.section, "Greetings")
        XCTAssertEqual(groups.first?.entries.map(\.name), ["hello", "tool"])
        XCTAssertFalse(groups.flatMap(\.entries).contains { $0.name == "install" && $0.summary.contains("hidden") })
        XCTAssertEqual(Array(groups.dropFirst().map(\.section)), BuiltinSection.order)
        // Aligned summaries: every command row has its summary in the same column.
        // "completions" is the longest name (11) + 3 spaces, after a 2-space indent: summaries start at column 16.
        let rows = text.components(separatedBy: "\n").filter { $0.hasPrefix("  hello") || $0.hasPrefix("  install") || $0.hasPrefix("  statusline") }
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertEqual(row.prefix(16).last, " ", row)
            XCTAssertNotEqual(row.dropFirst(16).first, " ", row)
        }
    }

    func testHelpForOneCommand() async {
        let harness = makeHarness()
        do { let code = await harness.run(["help", "hello"]); XCTAssertEqual(code, 0) }
        XCTAssertTrue(harness.out.plain.hasPrefix("usage: shawn hello [name]\n\n  Say hello\n"), harness.out.plain)
        XCTAssertTrue(harness.out.plain.contains("defined in cli.yaml:2"))

        let builtin = makeHarness()
        do { let code = await builtin.run(["help", "install"]); XCTAssertEqual(code, 0) }
        XCTAssertTrue(builtin.out.plain.contains("usage: shawn install [--dry-run]"))
        XCTAssertTrue(builtin.out.plain.contains("--only STEPS"))
        XCTAssertTrue(builtin.out.plain.contains("aka: shawn sync"))

        let unknown = makeHarness()
        do { let code = await unknown.run(["help", "nonsense"]); XCTAssertEqual(code, 64) }
    }

    func testDashHPrintsUsageForRunCommandsAndBuiltins() async {
        let harness = makeHarness()
        do { let code = await harness.run(["hello", "-h"]); XCTAssertEqual(code, 0) }
        XCTAssertTrue(harness.out.plain.hasPrefix("usage: shawn hello [name]"))
        XCTAssertTrue(harness.replacer.requests.isEmpty)

        let builtin = makeHarness()
        do { let code = await builtin.run(["drift", "--help"]); XCTAssertEqual(code, 0) }
        XCTAssertTrue(builtin.out.plain.hasPrefix("usage: shawn drift [--write] [--repo PATH]"))
    }

    func testBadOptionOnABuiltinIsAUsageError() async {
        let harness = makeHarness()
        do { let code = await harness.run(["install", "--dryrun"]); XCTAssertEqual(code, 64) }
        XCTAssertTrue(harness.err.plain.contains("unknown option --dryrun. Did you mean --dry-run?"), harness.err.plain)
        XCTAssertTrue(harness.err.plain.contains("usage: shawn install"))
    }

    func testSelfUpdateIsSkippedForFastCommandsAndOptOuts() {
        let harness = makeHarness("self_update:\n  skip: [hello]\ncommands: {}\n")
        let context = harness.context
        XCTAssertFalse(Dispatcher.shouldSelfUpdate("statusline", context: context))
        XCTAssertFalse(Dispatcher.shouldSelfUpdate("completions", context: context))
        XCTAssertFalse(Dispatcher.shouldSelfUpdate("shell-init", context: context))
        XCTAssertFalse(Dispatcher.shouldSelfUpdate("hello", context: context), "skip list from cli.yaml")
        XCTAssertTrue(Dispatcher.shouldSelfUpdate("help", context: context))
        XCTAssertTrue(Dispatcher.shouldSelfUpdate("claude", context: context))
        context.globals.noUpdate = true
        XCTAssertFalse(Dispatcher.shouldSelfUpdate("claude", context: context))
        context.globals.noUpdate = false
        context.environment.baseEnvironment[SelfUpdateRunner.reexecMarker] = "1"
        XCTAssertFalse(Dispatcher.shouldSelfUpdate("claude", context: context), "loop guard after a restart")
    }

    /// A harness whose self-update would run against a checkout (fake git records every call).
    private func selfUpdatingHarness(environment: [String: String] = [:], macOS: (Int, Int, Int)? = nil) -> (Harness, FakeGit) {
        var sandbox = Sandbox()
        for (key, value) in environment { sandbox.environment.baseEnvironment[key] = value }
        let checkout = sandbox.directory.url.appendingPathComponent("dotfiles")
        let cli = "commands:\n  hello:\n    summary: Say hello\n    run: echo hello\n  tool:\n    summary: A wrapper\n    update: tool update\n    exec: [mytool]\n"
        let config = makeConfig(in: sandbox.directory, at: "dotfiles/installer/config", steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - ok: one\n"], cli: cli)
        try! FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        sandbox.directory.write("home/.config/shawn/config.yaml", "dotfiles_repo: \(checkout.path)\nconfig_path: installer/config\n")
        sandbox.shim("mytool", "exit 0")
        let git = FakeGit()
        git.answer(["symbolic-ref"], stdout: "master")
        let harness = Harness(sandbox: sandbox, config: config) {
            $0.git = git
            if let (major, minor, patch) = macOS {
                $0.operatingSystem = { OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch) }
            }
        }
        return (harness, git)
    }

    /// `shawn tool --no-update` skips shawn's own update as well as the tool's (before: only the tool's).
    func testNoUpdateAfterAYAMLCommandSkipsBothUpdates() async throws {
        let (control, controlGit) = selfUpdatingHarness()
        _ = await control.run(["hello"])
        XCTAssertFalse(controlGit.calls.isEmpty, "without the flag the self-update asks git")

        let (harness, git) = selfUpdatingHarness()
        let code = await harness.run(["tool", "--no-update", "--flag"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(git.commandLines, [], "no self-update")
        XCTAssertFalse(harness.launcher.requests.contains { $0.arguments.last == "tool update" }, "no tool update")
        XCTAssertEqual(try XCTUnwrap(harness.replacer.last).argv, ["mytool", "--flag"], "the flag is not passed on")

        let (run, runGit) = selfUpdatingHarness()
        _ = await run.run(["hello", "--no-update"])
        XCTAssertEqual(runGit.commandLines, [])
        XCTAssertEqual(try XCTUnwrap(run.replacer.last).argv.last, "shawn hello", "a run: command does not get it either")

        // A built-in's own arguments are its business: `--no-update` there is not taken as the global flag.
        let (builtin, _) = selfUpdatingHarness()
        let builtinCode = await builtin.run(["doctor", "--no-update"])
        XCTAssertEqual(builtinCode, ExitCode.usage)
    }

    func testUpdateEnvironmentVariables() async throws {
        let (both, bothGit) = selfUpdatingHarness(environment: ["SHAWN_NO_UPDATE": "1"])
        _ = await both.run(["tool"])
        XCTAssertEqual(bothGit.commandLines, [])
        XCTAssertFalse(both.launcher.requests.contains { $0.arguments.last == "tool update" }, "SHAWN_NO_UPDATE=1 skips the tool update too")

        let (selfOnly, selfOnlyGit) = selfUpdatingHarness(environment: ["SHAWN_NO_SELF_UPDATE": "1"])
        _ = await selfOnly.run(["tool"])
        XCTAssertEqual(selfOnlyGit.commandLines, [])
        XCTAssertTrue(selfOnly.launcher.requests.contains { $0.arguments.last == "tool update" }, "SHAWN_NO_SELF_UPDATE=1 still updates the tool")

        let help = makeHarness()
        _ = await help.run(["help"])
        XCTAssertTrue(help.out.plain.contains("--no-update (or SHAWN_NO_UPDATE=1) skips shawn's own update and the tool's:\n"
                                              + "  shawn --no-update claude, or shawn claude --no-update\n"
                                              + "SHAWN_NO_SELF_UPDATE=1 skips only shawn's own update\n"), help.out.plain)
    }

    func testArgumentParser() throws {
        let options = [OptionSpec("dry-run", short: "n", "x"), OptionSpec("only", value: "STEPS", "x"), OptionSpec("message", short: "m", value: "TEXT", "x")]
        let parsed = try ArgumentParser.parse(["-n", "--only", "a,b", "--only=c", "pos", "-mHello", "--", "--not-an-option"], options: options)
        XCTAssertTrue(parsed.has("dry-run"))
        XCTAssertEqual(parsed.list("only"), ["a", "b", "c"])
        XCTAssertEqual(parsed.value("message"), "Hello")
        XCTAssertEqual(parsed.positionals, ["pos", "--not-an-option"])
        XCTAssertThrowsError(try ArgumentParser.parse(["--only"], options: options)) { XCTAssertEqual("\($0)", "--only needs a value (STEPS)") }
        XCTAssertThrowsError(try ArgumentParser.parse(["-x"], options: options)) { XCTAssertEqual("\($0)", "unknown option -x") }
        XCTAssertThrowsError(try ArgumentParser.parse(["--dry-run=yes"], options: options))
        let extra = try ArgumentParser.parse(["cask", "x", "--name", "Thing", "--optional", "--app=X.app"], options: [], keepUnknown: true)
        XCTAssertEqual(extra.extra.map { "\($0.name)=\($0.value ?? "nil")" }, ["name=Thing", "optional=nil", "app=X.app"])
    }

    func testSuggestions() {
        XCTAssertEqual(Suggest.closest(to: "cluade", in: ["claude", "codex"]), "claude")
        XCTAssertEqual(Suggest.closest(to: "cod", in: ["claude", "codex"]), "codex", "unique prefix")
        XCTAssertNil(Suggest.closest(to: "zzzzzz", in: ["claude", "codex"]))
    }
}
