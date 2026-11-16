import Foundation
import ShawnCore

/// `open: Hammerspoon` opens an app, a file or a URL with `/usr/bin/open`.
struct OpenAction: Action {
    let target: String
    let background: Bool
    let arguments: [String]

    var title: String { "Open \(target)" }
    var subtitle: String? { "open " + Shell.join(openArguments(target: target, expandedPath: target, extra: arguments)) }
    /// Opening something is never "already done", so health checks leave it out.
    var isCheckable: Bool { false }

    static let descriptor = ActionDescriptor(
        kind: "open",
        summary: "Open an app (by name or path), a file or a URL. Runs every time; there is nothing to check.",
        example: """
        - open: Hammerspoon
        - open: https://github.com/settings/keys
          background: false            # bring it to the front (default: open in the background)
        - open: Karabiner-Elements
          args: [--hidden]             # passed to the app
        """,
        make: { parser in
            OpenAction(target: parser.primaryString(),
                       background: parser.options.bool("background", default: true),
                       arguments: parser.options.stringList("args"))
        }
    )

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, [("open", target)] + arguments.map { ("args", $0) })
    }

    /// `-g -a "Google Chrome" --args …`, `-g /path`, or `-g https://…`.
    func openArguments(target: String, expandedPath: String, extra: [String]) -> [String] {
        var result = background ? ["-g"] : []
        if Naming.looksLikeURL(target) {
            result.append(target)
        } else if Naming.looksLikePath(target) {
            result.append(expandedPath)
        } else {
            result += ["-a", target]
        }
        if !extra.isEmpty { result += ["--args"] + extra }
        return result
    }

    func check(_ context: ActionContext) async -> CheckResult {
        .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let expanded = context.expand(target)
        let arguments = openArguments(target: expanded, expandedPath: context.path(expanded).path, extra: self.arguments.map(context.expand))
        let environment = context.environment
        var executable = "/usr/bin/open"
        if environment.isSandbox && !context.dryRun {
            // A sandbox must never launch real apps: only a stand-in `open` placed on the sandbox's PATH is run.
            guard let resolved = environment.resolveExecutable("open"), resolved != executable else {
                context.info("sandbox: not running open \(Shell.join(arguments))")
                return .skipped("sandbox: apps are not opened")
            }
            executable = resolved
        }
        do {
            try await context.runChecked(Command(executable, arguments).labeled("open " + Shell.join(arguments)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ActionError("could not open \(expanded): \(InstallEngine.describe(error))",
                              hint: Naming.looksLikeURL(expanded) ? "check the URL" : "check that \(expanded) is installed")
        }
        return .done(context.dryRun ? "would open \(expanded)" : "opened \(expanded)")
    }
}

/// `manual: Sign in to Dropbox` is something only a person can do. Adds it to the end-of-run checklist; never fails.
///
/// With a `check:`, the check decides whether it is done. Without one, nothing can tell, so the reminder is handed
/// out once per Mac: it is recorded in `~/.shawn/state/reminders.json`, and later runs (`shawn sync`, the app opened
/// again) report it as already shown instead of putting the same to-do back on the list every time. RETRY FAILED and
/// RESUME in the app that showed it list it again, because the app's checklist shows only its latest run.
struct ManualAction: Action {
    let task: String
    let detail: String?
    let url: String?
    let checkScript: String?

    var title: String { task }
    var subtitle: String? { detail }
    /// Without a `check:` there is no way to tell whether the person did it; health checks leave it out.
    var isCheckable: Bool { checkScript != nil }

    static let descriptor = ActionDescriptor(
        kind: "manual",
        summary: "A step only a person can do: added to the end-of-run checklist with an optional deep link (once per Mac unless it has a check:); never fails.",
        example: """
        - manual: Allow Hammerspoon in Accessibility
          detail: System Settings → Privacy & Security → Accessibility → turn on Hammerspoon
          url: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
          check: test -d ~/.hammerspoon   # optional; exit 0 means it is already done (without one: shown once)
        """,
        make: { try make($0) }
    )

    private static func make(_ parser: ItemParser) throws -> any Action {
        let task = parser.primaryString()
        let options = parser.options
        let detail = options.string("detail")
        let url = options.string("url")
        let check = options.string("check")
        if let url, URL(string: url) == nil || !Naming.looksLikeURL(url) {
            options.error("'url' must be a full URL such as https://… or x-apple.systempreferences:… (got '\(url)')", key: "url")
        }
        if let check, check.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options.error("'check' must not be empty", key: "check")
        }
        return ManualAction(task: task, detail: detail, url: url, checkScript: check)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, [("manual", task), ("detail", detail), ("url", url), ("check", checkScript)])
    }

    func check(_ context: ActionContext) async -> CheckResult {
        guard let checkScript else {
            let reminders = ReminderLog(environment: context.environment)
            return reminders.wasShownEarlier(reminder(context), step: context.step.id) ? .satisfied("already shown") : .needed(nil)
        }
        let command = Command.shell(context.expand(checkScript)).readOnly().timeout(30)
        guard let result = try? await context.commands.run(command), result.succeeded else { return .needed(nil) }
        return .satisfied("already done")
    }

    /// The reminder as the checklist shows it.
    func reminder(_ context: ActionContext) -> ReminderLog.Reminder {
        ReminderLog.Reminder(title: context.expand(task), detail: detail.map(context.expand), url: url.map(context.expand))
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let reminder = reminder(context)
        context.followUp(reminder.title, detail: reminder.detail, url: reminder.url.flatMap { URL(string: $0) })
        context.info("added to your checklist: \(reminder.title)")
        if checkScript == nil && !context.dryRun {
            ReminderLog(environment: context.environment).record(reminder, step: context.step.id, context: context)
        }
        return .needsAttention(reminder.title)
    }
}

/// `~/.shawn/state/reminders.json`: the check-less reminders already handed out on this Mac, by step id, each as the
/// checklist showed it, with when and in which run:
/// `{"finish": [{"title": "Log out and back in", "detail": "…", "shownAt": "2026-11-15T09:30:00Z", "run": "20261115-093000"}]}`
/// (`detail` and `url` only when the reminder has them). `--fresh` shows them all again.
struct ReminderLog {
    /// A reminder as the checklist shows it. Two that differ in any part are different to-dos, even with one title.
    struct Reminder: Equatable {
        let title: String
        let detail: String?
        let url: String?
    }

    let url: URL
    /// `SystemEnvironment.runID`: new for every `shawn` command, while the installer app keeps one until it quits,
    /// for START, RETRY FAILED and RESUME alike.
    let runID: String

    init(environment: SystemEnvironment) {
        url = environment.stateDirectory.appendingPathComponent("state/reminders.json")
        runID = environment.runID
    }

    enum Contents {
        case missing
        case unreadable
        case record(JSONObject)
    }

    func load() -> Contents {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .missing }
        guard let object = (try? JSONParser.parse(data))?.object else { return .unreadable }
        return .record(object)
    }

    /// Whether an earlier run handed `reminder` out. One this run recorded does not count: the installer app empties
    /// its checklist for every RETRY FAILED or RESUME and lists only what that run hands out, so leaving it off
    /// would leave the person with "Nothing left for you to do".
    func wasShownEarlier(_ reminder: Reminder, step: String) -> Bool {
        guard case .record(let record) = load() else { return false }
        return Self.entries(record[step]).contains { Self.reminder(in: $0) == reminder && $0["run"] != .string(runID) }
    }

    /// The step's entries. Anything else under the step counts as none, and gives way to a list when the step records one.
    private static func entries(_ value: JSONValue?) -> [JSONObject] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(\.object)
    }

    private static func reminder(in entry: JSONObject) -> Reminder? {
        func text(_ key: String) -> String? {
            if case .string(let value)? = entry[key] { return value }
            return nil
        }
        guard let title = text("title") else { return nil }
        return Reminder(title: title, detail: text("detail"), url: text("url"))
    }

    /// Never fails the item: if the record cannot be written, the reminder simply comes back next time.
    func record(_ reminder: Reminder, step: String, context: ActionContext) {
        var record = JSONObject()
        // Only an unreadable file is backed up: otherwise the new record holds everything the old one did.
        var replacingUnreadable = false
        switch load() {
        case .missing: break
        case .record(let existing): record = existing
        case .unreadable:
            replacingUnreadable = true
            context.warn("\(context.display(url)) was not valid JSON; starting it again (the old copy goes to the backups folder)")
        }
        var entry = JSONObject(["title": .string(reminder.title)])
        if let detail = reminder.detail { entry["detail"] = .string(detail) }
        if let link = reminder.url { entry["url"] = .string(link) }
        entry["shownAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        entry["run"] = .string(runID)
        var entries = Self.entries(record[step])
        // Shown again (`--fresh`, a retry in the app): the entry says when, and in which run, it was shown last.
        if let index = entries.firstIndex(where: { Self.reminder(in: $0) == reminder }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        record[step] = .array(entries.map(JSONValue.object))
        do {
            try context.files.write(Data(JSONValue.object(record).rendered().utf8), to: url, permissions: 0o644, backup: replacingUnreadable)
        } catch {
            context.warn("could not record this reminder in \(context.display(url)) (\(InstallEngine.describe(error))); it will be shown again next time")
        }
    }
}

/// `login-item: Herdr` opens an app at login through a user LaunchAgent. Does not open it now.
struct LoginItemAction: Action {
    let app: String
    let bundleID: String?

    var title: String { "\(Naming.appName(app)) at login" }
    var subtitle: String? { "~/Library/LaunchAgents/\(Self.label(for: app)).plist" }

    static let descriptor = ActionDescriptor(
        kind: "login-item",
        summary: "Open an app at login (a LaunchAgent running 'open -g'). Does not launch it now.",
        example: """
        - login-item: Herdr
          bundle_id: dev.herdr.app       # optional; found by name otherwise
        """,
        make: { try make($0) }
    )

    private static func make(_ parser: ItemParser) throws -> any Action {
        let app = parser.primaryString()
        let bundleID = parser.options.string("bundle_id")
        if let bundleID, bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) == nil {
            parser.options.error("'bundle_id' must look like com.example.App (got '\(bundleID)')", key: "bundle_id")
        }
        if !app.isEmpty && Naming.slug(Naming.appName(app)).isEmpty {
            parser.fail("'login-item' needs an app name with at least one letter or digit")
        }
        return LoginItemAction(app: app, bundleID: bundleID)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, [("login-item", app), ("bundle_id", bundleID)])
    }

    /// `com.shawnschwartz.dotfiles.open.herdr`.
    static func label(for app: String) -> String {
        "\(ShawnCore.bundleIdentifierPrefix).dotfiles.open.\(Naming.slug(Naming.appName(app)))"
    }

    func plistURL(_ context: ActionContext) -> URL {
        context.environment.home.appendingPathComponent("Library/LaunchAgents/\(Self.label(for: context.expand(app))).plist")
    }

    /// The LaunchAgent: `open -g -b <bundle id>` (or `-a <app>`) once, at load.
    func agent(_ context: ActionContext) -> [String: PlistValue] {
        let expanded = context.expand(app)
        let target = Naming.looksLikePath(expanded) ? context.path(expanded).path : expanded
        let program: [String] = bundleID.map { ["/usr/bin/open", "-g", "-b", context.expand($0)] } ?? ["/usr/bin/open", "-g", "-a", target]
        return [
            "Label": .string(Self.label(for: expanded)),
            "ProgramArguments": .array(program.map(PlistValue.string)),
            "RunAtLoad": .bool(true),
        ]
    }

    func check(_ context: ActionContext) async -> CheckResult {
        let url = plistURL(context)
        guard let data = FileManager.default.contents(atPath: url.path) else { return .needed("no LaunchAgent yet") }
        guard let existing = try? PlistValue.decodeDictionary(data), existing == agent(context) else {
            return .needed("LaunchAgent differs")
        }
        return .satisfied("opens at login")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let url = plistURL(context)
        let change: FileChange
        do {
            change = try context.files.write(try PlistValue.encode(agent(context), format: .xml), to: url, permissions: 0o644, backup: true)
        } catch {
            throw context.fileError(error, doing: "write \(context.display(url))")
        }
        let name = Naming.appName(context.expand(app))
        switch change {
        case .unchanged: return .done("\(name) already opens at login")
        default: return .done(context.dryRun ? "would open \(name) at login" : "\(name) will open at login (from the next login)")
        }
    }
}
