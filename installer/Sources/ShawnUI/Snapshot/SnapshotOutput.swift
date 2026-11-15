import Foundation
import ShawnCore

/// What an item prints in a snapshot's LOG panel, by its kind, in the words the engine and the tools it runs
/// use (compare `shawn install --dry-run`). A real run shows the commands, file changes and notes, plus the
/// tool's own output; a dry run shows the commands and file changes with `[dry-run]` in front.
@MainActor
enum SnapshotOutput {
    /// Kinds that download something, so their output has a progress bar while they run. `sim-install` is the
    /// built-in simulation's stand-in for a package (`--simulate`).
    static let downloadKinds: Set<String> = ["brew", "cask", "mas", "download", "npm", "clone", "xcode", "sim-install"]
    /// Kinds that stop and wait for the person (a sign-in, a code). In snapshots they are never already done,
    /// so the sheet or callout they bring up always has a running item to belong to.
    static let waitingKinds: Set<String> = ["github", "mas", "xcode"]
    /// Kinds that put a reminder on the checklist and end needing you, as `manual:` does in a real run.
    /// `sim-manual` is the built-in simulation's stand-in.
    static let reminderKinds: Set<String> = ["manual", "sim-manual"]

    /// Whether the snapshots find this item already done: every fourth one, except the kinds that wait for you
    /// and the items the engine runs every time.
    static func endsAlreadyDone(_ item: PlannedItem, index: Int) -> Bool {
        index % 4 == 2 && !waitingKinds.contains(item.config.kind) && !runsEveryTime(item)
    }

    /// Items the engine runs on every run, because nothing can tell whether they are done.
    static func runsEveryTime(_ item: PlannedItem) -> Bool {
        let options = item.config.options
        switch item.config.kind {
        case "open": return true
        case "script": return options["check"] == nil && options["creates"] == nil
        case "download": return options["replace"]?.bool == true
        default: return false
        }
    }

    /// Why an item found already done is done, in the words its action uses where they do not depend on the
    /// Mac. Nil where the action's reason names something only a real Mac has (a path, an account, a version).
    static func alreadyDoneReason(for item: PlannedItem) -> String? {
        let options = item.config.options
        switch item.config.kind {
        case "manual", "sim-manual": return options["check"] == nil ? "already shown" : "already done"
        case "copy": return "up to date"
        case "json-merge": return "already merged"
        case "mkdir": return "exists"
        case "symlink": return "link in place"
        case "defaults": return (options["set"]?.map?.entries.count).map { "all \($0) set" }
        case "dock": return "Dock already set up"
        case "login-item": return "opens at login"
        case "ssh-key": return "key exists"
        case "script": return options["check"] == nil ? nil : "its check passes"
        case "brew", "cask", "tap", "npm", "xcode-clt", "homebrew", "rosetta": return "installed"
        case let kind where kind.hasPrefix("sim-"): return "already installed"
        default: return nil
        }
    }

    /// The checklist entry a reminder adds: its title, with the detail and the link the config gives it. Nil for
    /// every other kind.
    static func followUp(for item: PlannedItem, in step: PlannedStep? = nil) -> FollowUp? {
        guard reminderKinds.contains(item.config.kind) else { return nil }
        let options = item.config.options
        // Text that still names a {{variable}} would show its braces, so it is left out.
        let detail = options["detail"]?.string.flatMap { $0.contains("{{") ? nil : $0 }
        let url = options["url"]?.string.flatMap { $0.contains("{{") ? nil : URL(string: $0) }
        // The engine titles the entry with the reminder's own text, whatever `name:` the item shows under.
        let task = item.config.value.string.flatMap { $0.contains("{{") ? nil : $0 }
        return FollowUp(id: "snapshot-\(item.id)", title: task ?? item.title, detail: detail, url: url, stepID: step?.id)
    }

    /// What the item prints from its start until its work is done.
    static func start(_ item: PlannedItem, model: InstallerModel) -> [InstallEvent] {
        lines(for: item, model: model).map { .log($0) }
    }

    /// What the item has printed `progress` (0 to 1) of the way through: its start, then its download's
    /// progress bar once the bar has a block to draw.
    static func inProgress(_ item: PlannedItem, progress: Double, model: InstallerModel) -> [InstallEvent] {
        let filled = Int(progress * Double(barWidth))
        guard downloads(item), !model.runIsDryRun, filled > 0 else { return start(item, model: model) }
        return start(item, model: model) + [.log(bar(filled: min(barWidth, filled), percent: progress * 100, item: item))]
    }

    /// The last line of a download that finished: its full bar. Nothing for other kinds or a dry run.
    static func end(_ item: PlannedItem, model: InstallerModel) -> [InstallEvent] {
        guard downloads(item), !model.runIsDryRun else { return [] }
        return [.log(bar(filled: barWidth, percent: 100, item: item))]
    }

    /// The item's main command as it appears after `$ `, for a failure message; its title when it runs none.
    static func command(_ item: PlannedItem, model: InstallerModel) -> String {
        let commands = lines(for: item, model: model).filter { $0.style == .command }.map(\.text)
        guard let first = commands.first else { return item.title }
        return String(first.drop { $0 != "$" }.dropFirst(2))
    }

    /// `xcode: finish` sets up the Xcode that `xcode: download` fetched, so only the download has a bar.
    static func downloads(_ item: PlannedItem) -> Bool {
        downloadKinds.contains(item.config.kind) && !(item.config.kind == "xcode" && item.config.value.string == "finish")
    }

    private static let barWidth = 40

    private static func bar(filled: Int, percent: Double, item: PlannedItem) -> LogLine {
        let text = String(repeating: "#", count: filled) + String(repeating: " ", count: barWidth - filled)
            + String(format: "  %.1f%%", percent)
        return LogLine(text, style: .stdout, itemID: item.id, isProgress: filled < barWidth)
    }

    // MARK: Lines by kind

    private static func lines(for item: PlannedItem, model: InstallerModel) -> [LogLine] {
        let dryRun = model.runIsDryRun
        let config = item.config
        let value = config.value.string ?? item.title
        let options = config.options
        var lines: [LogLine] = []
        /// A command, as the command runner echoes it.
        func run(_ command: String) {
            lines.append(LogLine((dryRun ? "[dry-run] $ " : "$ ") + command, style: .command, itemID: item.id))
        }
        /// A file change, as FileOps notes it.
        func file(_ text: String) {
            lines.append(LogLine((dryRun ? "[dry-run] " : "") + text, style: .info, itemID: item.id))
        }
        /// A note from the installer, the same in a dry run.
        func note(_ text: String) { lines.append(LogLine(text, style: .info, itemID: item.id)) }
        /// The tool's own output, which a dry run never gets to.
        func output(_ text: String) { if !dryRun { lines.append(LogLine(text, style: .stdout, itemID: item.id)) } }

        switch config.kind {
        case "brew":
            run("brew install --formula \(value)")
            output("==> Fetching downloads for: \(lastComponent(value))")
        case "cask":
            run("brew install --cask \(value)")
            output("==> Fetching downloads for: \(lastComponent(value))")
        case "tap":
            run("brew tap \(value)")
        case "mas":
            run("sudo mas install \(value)")
            output("==> Downloading \(item.title)")
        case "xcode" where value == "finish":
            run("sudo xcodebuild -license accept")
            run("sudo xcodebuild -runFirstLaunch")
        case "xcode":
            run("sudo mas install 497799835")
            note("Xcode (about 3 GB) is downloading in the background; the rest of the install carries on.")
        case "xcode-clt":
            run("softwareupdate -l")
            run("sudo xcode-select --switch /Library/Developer/CommandLineTools")
        case "homebrew":
            run("NONINTERACTIVE=1 bash install.sh")
        case "npm":
            run("npm install -g \(value)")
        case "download":
            let fileName = URL(string: value)?.lastPathComponent ?? value
            run("curl -fL --retry 3 -o ~/Library/Caches/ShawnsDotfiles/downloads/\(fileName) \(value)")
        case "clone":
            let target = options["to"]?.string ?? "~/Developer/\(lastComponent(item.title))"
            run("git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=120 clone --progress -- https://github.com/\(item.title).git \(target)")
            output("Cloning into '\(target)'...")
        case "manual", "sim-manual":
            note("added to your checklist: \(item.title)")
        case "copy":
            let target = options["to"]?.string ?? "~/\(value)"
            let files = payloadFiles(value, model: model)
            if files.isEmpty {
                file("write \(target)")
            } else {
                file("mkdir \(target)")
                for name in files { file("write \(target)/\(name)") }
            }
        case "mkdir":
            file("mkdir \(value)")
        case "json-merge":
            file("update \(value)")
        case "script":
            let script = (options["run"]?.string ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = script.first(where: { !$0.isEmpty }) { run(script.count > 1 ? "\(first) …" : first) }
        case "defaults":
            for entry in options["set"]?.map?.entries ?? [] {
                guard let setting = defaultsArgument(entry.value) else { continue }
                note("\(value) \(entry.key): unset → \(setting.text)")
                run("defaults write \(value) \(entry.key) -\(setting.type) \(setting.text)")
            }
        case "dock":
            run("defaults import com.apple.dock -")
            run("killall Dock")
        case "open":
            run("open -g -a \(value)")
        case "claude-plugin":
            run("claude plugin install \(value) --scope user --json")
        case "webapp":
            let app = "/Applications/\(item.title).app"
            note("building \(app) for \(options["url"]?.string ?? "its site")")
            run("iconutil -c icns AppIcon.iconset")
            run("codesign --force --sign - \(item.title).app")
        case "skill":
            if let source = options["source"]?.string {
                run("npx --yes skills@latest add \(source) -g -s \(value) -y")
            } else {
                file("mkdir ~/.agents/skills/\(value)")
                file("write ~/.agents/skills/\(value)/SKILL.md")
                for agent in ["claude", "grok"] { file("link ~/.\(agent)/skills/\(value) → ../../.agents/skills/\(value)") }
            }
        case "ssh-key":
            run("ssh-keygen -t ed25519 -a 100 -N '' -f \(value) -q")
            file("update ~/.ssh/config")
        case "github":
            let gitProtocol = options["protocol"]?.string ?? "https"
            run("gh auth login --hostname \(value) --web --git-protocol \(gitProtocol) --skip-ssh-key --clipboard=false")
        case "git-signing":
            for (key, setting) in [("gpg.format", "ssh"), ("user.signingkey", value), ("commit.gpgsign", "true"), ("tag.gpgsign", "true")] {
                run("git config --global \(key) \(setting)")
            }
        case "git-config":
            for entry in config.value.map?.entries ?? [] {
                guard let setting = entry.value.string, !setting.contains("{{") else { continue }
                if entry.key == "include.path" {
                    note("adding include.path \(setting) at the end of ~/.gitconfig")
                    file("update ~/.gitconfig")
                } else {
                    run("git config --global \(entry.key) \(setting)")
                }
            }
        case "shawn-cli":
            for path in ["~/.local/bin/shawn", "~/.shawn/state/cli.json", "~/.config/shawn/config.yaml"] { file("write \(path)") }
            run("~/.local/bin/shawn completions zsh")
        case let kind where kind.hasPrefix("sim-"):
            // The simulation runs a command named by `command:` (else "simulate <title>") that prints `output:`.
            run(options["command"]?.string ?? "simulate \(item.title)")
            for line in options["output"]?.stringList ?? [] { output(line) }
        default:
            note("\(config.kind): \(item.title)")
        }
        return lines
    }

    private static func lastComponent(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// The files of a `copy:` folder, relative to it and sorted; empty when the payload is one file.
    private static func payloadFiles(_ source: String, model: InstallerModel) -> [String] {
        guard let root = model.plan?.config.filesDirectory.appendingPathComponent(source),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let prefix = root.standardizedFileURL.path + "/"
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && $0.lastPathComponent != ".DS_Store" }
            .map { String($0.standardizedFileURL.path.dropFirst(prefix.count)) }
            .sorted()
    }

    /// A `defaults write` type flag and value for a YAML value.
    private static func defaultsArgument(_ value: YAMLValue) -> (type: String, text: String)? {
        if let flag = value.bool { return ("bool", flag ? "true" : "false") }
        if let number = value.int { return ("int", String(number)) }
        if let number = value.double { return ("float", String(number)) }
        if let text = value.string { return ("string", text) }
        return nil
    }
}
