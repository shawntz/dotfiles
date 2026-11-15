import Foundation
import XCTest
@testable import ActionsPackages
import ShawnCore

/// A throwaway directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    init(_ name: String = "shawn-pkg-tests") {
        // /tmp (not the long per-user temp path) keeps paths short.
        url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String, permissions: Int? = nil) -> URL {
        let file = url.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: file)
        if let permissions {
            try! FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
        return file
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }

    func mkdir(_ relativePath: String) {
        try! FileManager.default.createDirectory(at: url.appendingPathComponent(relativePath), withIntermediateDirectories: true)
    }
}

/// Collects events/log lines from concurrent callbacks.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func add(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    var all: [Element] { lock.withLock { storage } }
}

/// Answers questions from a script and remembers what was asked.
final class ScriptedInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: String]
    private var asked: [Question] = []

    init(answers: [String: String] = [:]) {
        self.answers = answers
    }

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? { nil }

    func ask(_ question: Question) async -> String {
        lock.withLock {
            asked.append(question)
            return answers[question.title] ?? question.defaultOptionID
        }
    }

    var questions: [Question] { lock.withLock { asked } }
}

/// Never answers on its own, like the app's question sheet with nobody at the Mac. Like the app, it gives up
/// with the default option when its task is cancelled, and counts how often that happened.
final class SilentInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private var askedCount = 0
    private var withdrawnCount = 0

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? { nil }

    func ask(_ question: Question) async -> String {
        lock.withLock { askedCount += 1 }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        lock.withLock { withdrawnCount += 1 }
        return question.defaultOptionID
    }

    var asked: Int { lock.withLock { askedCount } }
    var withdrawn: Int { lock.withLock { withdrawnCount } }
}

/// Answers `answer` after `delay` seconds and cannot be interrupted (like a blocking terminal read).
final class LateInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: String
    private let delay: TimeInterval
    private var answeredCount = 0

    init(answer: String, after delay: TimeInterval) {
        self.answer = answer
        self.delay = delay
    }

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? { nil }

    func ask(_ question: Question) async -> String {
        let answer = self.answer
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume(returning: answer) }
        }
        lock.withLock { answeredCount += 1 }
        return result
    }

    var answered: Int { lock.withLock { answeredCount } }
}

/// Administrator rights that are always "ready"; the sandbox's fake sudo does the rest.
struct ReadySudo: SudoProviding {
    func ensureReady(reason: String) async throws {}
    var processEnvironment: [String: String] { [:] }
}

/// Waits (up to `timeout` seconds) for `condition` to hold; false if it never did.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// A fake Mac: a sandbox environment, shim executables that log their arguments, a fake sudo,
/// and `MacSystem` pointed at shims and sandbox locations.
final class Sandbox {
    let directory: TempDirectory
    var environment: SystemEnvironment
    var system: MacSystem
    let shared = SharedState()
    let events = Recorder<InstallEvent>()
    var interaction = ScriptedInteraction()
    /// Used instead of `interaction` when set (questions nobody answers, answers that come late).
    var otherInteraction: (any UserInteraction)?
    /// Administrator rights for contexts; a real `SudoSession` makes the password-helper rules apply.
    var sudo: any SudoProviding = ReadySudo()
    let config: InstallerConfig
    let step: StepConfig

    var root: URL { directory.url }
    var log: URL { root.appendingPathComponent("calls.log") }
    var brewPrefix: URL { environment.brewPrefix }
    var brewBin: URL { brewPrefix.appendingPathComponent("bin") }
    var systemBin: URL { root.appendingPathComponent("system-bin") }
    var applications: URL { environment.applicationsDirectory }
    var home: URL { environment.home }

    init(_ name: String = "pkg") {
        directory = TempDirectory("shawn-\(name)")
        let root = directory.url
        environment = SystemEnvironment.sandbox(root: root, baseEnvironment: [
            "SHIM_LOG": root.appendingPathComponent("calls.log").path,
            "LANG": "en_US.UTF-8",
        ])
        for url in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        directory.mkdir("system-bin")
        directory.mkdir("homebrew/bin")

        var system = MacSystem()
        let bin = root.appendingPathComponent("system-bin")
        system.softwareupdate = bin.appendingPathComponent("softwareupdate").path
        system.xcodeSelect = bin.appendingPathComponent("xcode-select").path
        system.pkgutil = bin.appendingPathComponent("pkgutil").path
        system.installer = bin.appendingPathComponent("installer").path
        system.open = bin.appendingPathComponent("open").path
        system.pgrep = bin.appendingPathComponent("pgrep").path
        system.commandLineTools = root.appendingPathComponent("system/Library/Developer/CommandLineTools")
        system.cltPlaceholder = root.appendingPathComponent("system/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress")
        system.rosettaRuntime = root.appendingPathComponent("system/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        system.isRealMachine = false
        system.timing = MacSystem.Timing(softwareUpdateAttempts: 2, softwareUpdateRetryDelay: 0, cltInstallTimeout: 30,
                                         cltDialogPollInterval: 0.05, cltDialogTimeout: 3, xcodePollInterval: 0.05)
        self.system = system
        directory.mkdir("system/tmp")

        config = InstallerConfig(root: root.appendingPathComponent("config"),
                                 meta: ConfigMeta(schema: 1, name: "Test Dotfiles", vars: ["flavor": "grape", "email": "lsp@example.com"]),
                                 steps: [], source: .local(root.path))
        step = StepConfig(id: "packages", title: "Packages", file: "steps/01-packages.yaml")

        // sudo: log, drop the flags, mark the child as "root", run it.
        let sudo = directory.write("system-bin/sudo", """
        #!/bin/bash
        echo "sudo $*" >> "$SHIM_LOG"
        while [ $# -gt 0 ]; do
          case "$1" in -A|-k|-E) shift ;; --) shift; break ;; *) break ;; esac
        done
        export RUN_AS_ROOT=1
        exec "$@"

        """, permissions: 0o755)
        environment.sudoPath = sudo.path
    }

    // MARK: Shims

    /// Writes an executable that logs `[root ]<name> <args>` to calls.log, then runs `body`.
    @discardableResult
    func shim(_ name: String, at directory: URL? = nil, _ body: String = "exit 0") -> URL {
        let url = (directory ?? systemBin).appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "#!/bin/bash\necho \"${RUN_AS_ROOT:+root }\(name) $*\" >> \"$SHIM_LOG\"\n\(body)\n"
        try! Data(script.utf8).write(to: url)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// `<brew args> | askpass=set|unset` for every fake brew call, in order.
    var brewAskpass: [String] {
        directory.read("brew-askpass.txt")?.split(separator: "\n").map(String.init) ?? []
    }

    /// Every logged call, in order.
    var calls: [String] {
        (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }

    /// Logged calls that start with `prefix` (e.g. "brew install").
    func calls(_ prefix: String) -> [String] {
        calls.filter { $0.hasPrefix(prefix) }
    }

    func clearCalls() {
        try? FileManager.default.removeItem(at: log)
    }

    /// A fake Homebrew at `<sandbox>/homebrew/bin/brew` that changes the sandbox the way the real one would.
    ///
    /// - `brew install --formula X` creates `Cellar/X/1.0`; a script at `<prefix>/pending/X` becomes `bin/X`.
    /// - `brew install --cask X` creates `Caskroom/X/1.0`, and `<apps>/<name>` if `<prefix>/cask-apps/X` names an app.
    /// - A file `<prefix>/fail/<name>` makes installing that name fail; `<prefix>/fail/update` fails `brew update`.
    /// - A file `<prefix>/cask-needs-sudo/<token>` makes that cask run `sudo [-A] -- pkg-installer <token>` the way
    ///   Homebrew runs a cask's .pkg (`-A` only when SUDO_ASKPASS is set).
    /// - The environment of the last call is saved to `<sandbox>/brew-env.txt`; every call appends
    ///   `<args> | askpass=<set|unset>` to `<sandbox>/brew-askpass.txt`.
    func installFakeBrew() {
        let prefix = brewPrefix.path
        shim("brew", at: brewBin, """
        env | grep -E '^(HOMEBREW_|CI=|SUDO_ASKPASS=)' | sort > "\(root.path)/brew-env.txt"
        if [ -n "$SUDO_ASKPASS" ]; then askpass=set; else askpass=unset; fi
        echo "$* | askpass=$askpass" >> "\(root.path)/brew-askpass.txt"
        prefix="\(prefix)"
        case "$1" in
          --version) echo "Homebrew 7.0.13" ;;
          update)
            if [ -f "$prefix/fail/update" ]; then echo "Error: Failed to update" >&2; exit 1; fi
            echo "Already up-to-date." ;;
          tap)
            user="${2%%/*}"; repo="${2##*/}"
            mkdir -p "$prefix/Library/Taps/$(echo "$user" | tr A-Z a-z)/homebrew-$(echo "$repo" | tr A-Z a-z)" ;;
          trust)
            mkdir -p "$HOME/.homebrew"
            printf '{"trustedtaps":["%s"]}\\n' "$(echo "$2" | tr A-Z a-z)" > "$HOME/.homebrew/trust.json"
            echo "Trusted tap: $2" ;;
          install)
            shift
            kind=formula
            if [ "$1" = "--cask" ]; then kind=cask; fi
            shift
            name="$1"; short="${name##*/}"
            if [ -f "$prefix/fail/$short" ]; then cat "$prefix/fail/$short" >&2; exit 1; fi
            if [ "$kind" = formula ]; then
              mkdir -p "$prefix/Cellar/$short/1.0"
              if [ -f "$prefix/pending/$short" ]; then cp "$prefix/pending/$short" "$prefix/bin/$short"; chmod +x "$prefix/bin/$short"; fi
            else
              if [ -f "$prefix/cask-needs-sudo/$short" ]; then
                flags=""; if [ -n "$SUDO_ASKPASS" ]; then flags="-A"; fi
                if ! "\(systemBin.path)/sudo" $flags -- "\(systemBin.path)/pkg-installer" "$short"; then
                  echo "Error: Failure while executing; sudo exited with 1." >&2; exit 1
                fi
              fi
              mkdir -p "$prefix/Caskroom/$short/1.0"
              if [ -f "$prefix/cask-apps/$short" ]; then mkdir -p "\(applications.path)/$(cat "$prefix/cask-apps/$short")/Contents"; fi
            fi
            echo "==> Installed $name" ;;
          *) echo "unexpected brew call: $*" >&2; exit 64 ;;
        esac
        """)
    }

    /// xcode-select that remembers `-s`/`--switch` and runs `dialog` for `--install`.
    func installXcodeSelect(dialog: String = "exit 1") {
        let state = root.appendingPathComponent("system/xcode-select-path").path
        shim("xcode-select", """
        case "$1" in
          -p) if [ -f "\(state)" ]; then cat "\(state)"; else echo "xcode-select: error: unable to get active developer directory" >&2; exit 2; fi ;;
          -s|--switch) echo "$2" > "\(state)" ;;
          --install) \(dialog) ;;
        esac
        """)
    }

    /// softwareupdate that only lists the tools while the placeholder exists, and "installs" them on -i.
    func installSoftwareUpdate(listing: String = SoftwareUpdateFixtures.real, installSucceeds: Bool = true) {
        directory.write("fixtures/su.txt", listing)
        let clt = system.commandLineTools.path
        shim("softwareupdate", """
        case "$1" in
          -l)
            echo "Software Update Tool" >&2
            if [ -f "\(system.cltPlaceholder.path)" ]; then cat "\(root.path)/fixtures/su.txt"; else echo "No new software available."; fi ;;
          -i)
            \(installSucceeds ? "" : "echo 'Error downloading' >&2; exit 1")
            mkdir -p "\(clt)/usr/bin"
            printf '#!/bin/sh\\n' > "\(clt)/usr/bin/git"; printf '#!/bin/sh\\n' > "\(clt)/usr/bin/clang"
            chmod +x "\(clt)/usr/bin/git" "\(clt)/usr/bin/clang"
            touch "\(clt)/.receipt"
            echo "Installed $2" ;;
        esac
        """)
        installPkgutil()
        installXcodeSelect()
    }

    /// pkgutil: `--check-signature` passes; `--pkg-info` succeeds once the fake Command Line Tools are installed.
    func installPkgutil() {
        shim("pkgutil", """
        case "$1" in
          --check-signature) echo 'Status: signed by a developer certificate issued by Apple for distribution' ;;
          *) [ -f "\(system.commandLineTools.path)/.receipt" ] ;;
        esac
        """)
    }

    /// curl that "downloads" Homebrew.pkg / install.sh, an installer that creates a working brew.
    /// With `scriptUsesSudo`, install.sh needs administrator rights the way the real one does on a fresh Mac
    /// (`sudo -A` when SUDO_ASKPASS is set; it runs `pkg-installer homebrew-prefix` as root).
    func installHomebrewInstallers(packageInstalls: Bool = true, scriptUsesSudo: Bool = false) {
        installFakeBrew()
        let brew = brewBin.appendingPathComponent("brew")
        let staged = root.appendingPathComponent("staged-brew")
        try! FileManager.default.moveItem(at: brew, to: staged)
        let elevate = """
        if [ -n "$SUDO_ASKPASS" ]; then flags=-A; else flags=""; fi
        "\(systemBin.path)/sudo" $flags -- "\(systemBin.path)/pkg-installer" homebrew-prefix || { echo "Insufficient permissions to install Homebrew" >&2; exit 1; }

        """
        let script = directory.write("fixtures/install.sh", """
        echo "==> Installing Homebrew"
        \(scriptUsesSudo ? elevate : "")cp "\(staged.path)" "\(brew.path)"
        echo "NONINTERACTIVE=$NONINTERACTIVE"

        """)
        system.curl = shim("curl", """
        out=""; while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; shift; fi; shift; done
        case "$out" in
          *Homebrew.pkg) echo "pkg bytes" > "$out" ;;
          *install.sh) cp "\(script.path)" "$out" ;;
        esac
        """).path
        installPkgutil()
        system.spctl = shim("spctl", "echo accepted >&2").path
        shim("installer", packageInstalls
            ? "cp \"\(staged.path)\" \"\(brew.path)\"; echo 'installer: The install was successful.'"
            : "echo 'installer: Error - the package is for arm64 only' >&2; exit 1")
    }

    // MARK: Parsing and contexts

    func registry() -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(PackageActions.descriptors(system: system))
        return registry
    }

    /// Parses one item written as YAML (without the leading "- ").
    func resolve(_ yaml: String) -> Result<(item: ItemConfig, action: any Action), ConfigError> {
        let value = try! YAML.parse(yaml)!
        let raw = RawItem(map: value.map!, source: SourceRef(file: step.file, line: 1))
        return registry().resolve(raw, stepID: step.id, index: 0)
    }

    func parse(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) throws -> (item: ItemConfig, action: any Action) {
        switch resolve(yaml) {
        case .success(let resolved): return resolved
        case .failure(let error):
            XCTFail("unexpected config error: \(error)", file: file, line: line)
            throw error
        }
    }

    /// The error messages for YAML that should not parse.
    func errors(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        switch resolve(yaml) {
        case .success:
            XCTFail("expected '\(yaml)' to be rejected", file: file, line: line)
            return []
        case .failure(let error):
            return error.issues.map(\.message)
        }
    }

    func validate(_ resolved: (item: ItemConfig, action: any Action)) -> [String] {
        let context = ValidationContext(config: config, item: resolved.item, vars: ActionContext.makeVars(config: config, environment: environment))
        return resolved.action.validate(context)
    }

    func context(_ item: ItemConfig, dryRun: Bool = false) -> ActionContext {
        let events = self.events
        return ActionContext(config: config, environment: environment, options: RunOptions(dryRun: dryRun), step: step, item: item,
                             sudo: sudo, interaction: otherInteraction ?? interaction, shared: shared, emit: { events.add($0) })
    }

    // MARK: Administrator rights

    /// A sudo that, like the real one without a terminal, gets the password from the askpass helper
    /// (and fails when it is not told where that helper is).
    func installAskpassSudo() {
        environment.sudoPath = directory.write("system-bin/sudo", """
        #!/bin/bash
        echo "sudo $*" >> "$SHIM_LOG"
        if [ -z "$SUDO_ASKPASS" ]; then echo "sudo: a terminal is required to read the password" >&2; exit 1; fi
        password="$("$SUDO_ASKPASS" "[sudo] password:")"
        if [ "$password" != "open sesame" ]; then echo "Sorry, try again." >&2; exit 1; fi
        validate=0
        while [ $# -gt 0 ]; do
          case "$1" in -A|-k|-E) shift ;; -v) validate=1; shift ;; --) shift; break ;; *) break ;; esac
        done
        if [ "$validate" = 1 ]; then exit 0; fi
        export RUN_AS_ROOT=1
        exec "$@"

        """, permissions: 0o755).path
    }

    /// Switches contexts to a real, unlocked `SudoSession` (password "open sesame") behind the askpass sudo.
    @discardableResult
    func useRealSudo() async throws -> SudoSession {
        installAskpassSudo()
        let session = SudoSession(environment: environment, interaction: NonInteractive(password: "open sesame"))
        try await session.ensureReady(reason: "tests")
        sudo = session
        return session
    }

    /// A context for an action built directly rather than parsed.
    func context(kind: String = "test", index: Int = 0, dryRun: Bool = false) -> ActionContext {
        context(ItemConfig(stepID: step.id, index: index, kind: kind, value: .string("x"), options: YAMLMap(), source: SourceRef(file: step.file)), dryRun: dryRun)
    }

    // MARK: Driving actions

    /// Parses, checks and (if needed) runs an item, like the engine does.
    func run(_ yaml: String, dryRun: Bool = false, file: StaticString = #filePath, line: UInt = #line) async throws -> (check: CheckResult, outcome: ActionOutcome?) {
        let resolved = try parse(yaml, file: file, line: line)
        let context = context(resolved.item, dryRun: dryRun)
        let check = await resolved.action.check(context)
        if check.isSatisfied { return (check, nil) }
        return (check, try await resolved.action.run(context))
    }

    func check(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) async throws -> CheckResult {
        let resolved = try parse(yaml, file: file, line: line)
        return await resolved.action.check(context(resolved.item))
    }

    // MARK: Events

    var logLines: [LogLine] {
        events.all.compactMap { if case .log(let line) = $0 { return line } else { return nil } }
    }

    var logText: String { logLines.map(\.text).joined(separator: "\n") }

    var followUps: [FollowUp] {
        events.all.compactMap { if case .followUp(let followUp) = $0 { return followUp } else { return nil } }
    }

    var attentions: [Attention?] {
        events.all.compactMap { if case .attention(_, let attention) = $0 { return attention } else { return nil } }
    }

    /// Every file and directory under the sandbox (minus the call log), for "nothing changed" assertions.
    func snapshot() -> [String] {
        let base = root.resolvingSymlinksInPath().path
        var result: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let path = url.resolvingSymlinksInPath().path
            guard path != log.resolvingSymlinksInPath().path else { continue }
            result.append(String(path.dropFirst(base.count)))
        }
        return result.sorted()
    }
}

extension ActionOutcome {
    var isDone: Bool { if case .done = self { return true } else { return false } }
}

extension CheckResult {
    var reason: String? {
        switch self {
        case .satisfied(let reason), .needed(let reason): return reason
        }
    }
}

/// Creates an executable file (and its parent directories).
func makeExecutable(_ url: URL, _ contents: String = "#!/bin/sh\nexit 0\n") {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(contents.utf8).write(to: url)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// The path with every symlink resolved (`/tmp/x` → `/private/tmp/x`), as `pwd -P` prints it.
func physicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
