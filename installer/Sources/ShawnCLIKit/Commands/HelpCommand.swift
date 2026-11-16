import Foundation
import ShawnCore
import ShawnFun

struct HelpCommand: BuiltinCommand {
    let name = "help"
    let section = BuiltinSection.shell
    let summary = "This screen, or details for one command"
    let usage = "[command]"

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        if let target = arguments.first, target != "-h", target != "--help" {
            if let builtin = Builtins.find(target) {
                Self.printUsage(of: builtin, context: context)
                return ExitCode.ok
            }
            if let command = context.cli.command(named: target) {
                Self.printUsage(of: command, context: context)
                return ExitCode.ok
            }
            return Dispatcher.unknownCommand(target, context: context)
        }
        for line in Self.screen(context: context, seed: Int.random(in: 0..<10_000)) {
            context.out.line(line)
        }
        return ExitCode.ok
    }

    /// The whole help screen. `seed` picks the quip (tests pass a fixed one).
    static func screen(context: CLIContext, seed: Int) -> [String] {
        let style = context.style
        let fun = context.fun
        var lines: [String] = [""]
        lines += Painter.banner(fun.header, style: style, width: context.terminal.width, tagline: context.lightConfig()?.meta.tagline)
        lines.append("")
        let speaker = fun.sprite(fun.speaker)?.name ?? "LSP"
        lines.append("  " + style.fg(Palette.star, "\"\(fun.line(for: .launch, seed: seed))\"") + style.muted("  \(speaker)"))
        lines.append("")

        let groups = commandGroups(context: context)
        let nameWidth = (groups.flatMap { $0.entries.map { TextWidth.of($0.name) } }.max() ?? 8) + 3
        let summaryWidth = max(20, context.terminal.width - nameWidth - 4)
        for group in groups {
            lines.append(style.heading(group.section))
            for entry in group.entries {
                let summary = TextWidth.truncate(entry.summary, to: summaryWidth)
                lines.append("  " + style.accent(TextWidth.pad(entry.name, to: nameWidth)) + summary)
            }
            lines.append("")
        }
        lines.append(style.muted("shawn help <command> for details · --no-color for plain output"))
        lines.append(style.muted("--no-update (or SHAWN_NO_UPDATE=1) skips shawn's own update and the tool's:"))
        lines.append(style.muted("  shawn --no-update claude, or shawn claude --no-update"))
        lines.append(style.muted("SHAWN_NO_SELF_UPDATE=1 skips only shawn's own update"))
        let issues = context.cliWithIssues.issues.filter { $0.severity == .error }
        if !issues.isEmpty {
            lines.append(style.warn("cli.yaml has \(issues.count) problem\(issues.count == 1 ? "" : "s"); run 'shawn config validate' to see them"))
        }
        return lines
    }

    struct Group {
        var section: String
        var entries: [(name: String, summary: String)]
    }

    /// YAML sections first (in the order they appear in cli.yaml), then the built-in sections.
    static func commandGroups(context: CLIContext) -> [Group] {
        var groups: [Group] = []
        func add(_ section: String, _ name: String, _ summary: String) {
            if let index = groups.firstIndex(where: { $0.section == section }) {
                groups[index].entries.append((name, summary))
            } else {
                groups.append(Group(section: section, entries: [(name, summary)]))
            }
        }
        let builtinNames = Builtins.names
        for command in context.cli.commands where !builtinNames.contains(command.name) {
            add(command.section, command.name, command.summary)
        }
        for section in BuiltinSection.order {
            for command in Builtins.all where command.section == section && !command.hidden {
                add(section, command.name, command.summary)
            }
        }
        return groups
    }

    // MARK: Usage of one command

    static func printUsage(of command: any BuiltinCommand, context: CLIContext) {
        let style = context.style
        let out = context.out
        out.line(style.bold("usage: shawn \(command.name)\(command.usage.isEmpty ? "" : " " + command.usage)"))
        if !command.aliases.isEmpty { out.line(style.muted("   aka: " + command.aliases.map { "shawn \($0)" }.joined(separator: ", "))) }
        out.line("")
        out.line("  " + command.summary)
        if let details = command.details {
            out.line("")
            for line in TextWidth.wrap(details, width: min(88, context.terminal.width - 4)) { out.line("  " + line) }
        }
        if !command.subcommands.isEmpty {
            out.line("")
            let width = (command.subcommands.map { $0.name.count }.max() ?? 0) + 3
            for sub in command.subcommands {
                out.line("  " + style.accent(TextWidth.pad(sub.name, to: width)) + sub.summary)
            }
        }
        if !command.options.isEmpty {
            out.line("")
            out.line(style.heading("options"))
            let width = (command.options.map { $0.display.count }.max() ?? 0) + 3
            for option in command.options {
                out.line("  " + style.accent(TextWidth.pad(option.display, to: width)) + option.help)
            }
        }
    }

    static func printUsage(of command: CLIConfig.Command, context: CLIContext) {
        let style = context.style
        let out = context.out
        let synopsis: String
        switch command.action {
        case .exec(let parts):
            if case .text(let program)? = parts.first {
                synopsis = command.usage ?? "[\(program) arguments…]"
            } else {
                synopsis = command.usage ?? ""
            }
        case .run:
            synopsis = command.usage ?? ""
        }
        out.line(style.bold("usage: shawn \(command.name)\(synopsis.isEmpty ? "" : " " + synopsis)"))
        out.line("")
        out.line("  " + command.summary)
        if let help = command.help {
            out.line("")
            for line in help.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
                out.line("  " + line)
            }
        }
        if case .exec(let parts) = command.action {
            out.line("")
            if let update = command.update {
                out.line("  " + style.muted("updates first:") + " \(update)  " + style.muted("(skip with shawn \(command.name) --no-update or SHAWN_NO_UPDATE=1; both also skip shawn's own update)"))
            }
            let argv = YAMLCommandRunner.execArguments(parts, userArguments: [], vars: context.templateVars())
            out.line("  " + style.muted("launches:") + " " + Shell.join(argv) + " " + style.muted("[your arguments]"))
        }
        out.line("")
        out.line(style.muted("  defined in \(command.source)"))
    }
}
