import Foundation

/// A command implemented in Swift. Built-ins win over YAML commands of the same name.
protocol BuiltinCommand: Sendable {
    var name: String { get }
    var aliases: [String] { get }
    var section: String { get }
    var summary: String { get }
    /// Synopsis after `shawn <name>`, e.g. `[--dry-run] [--only step,…]`.
    var usage: String { get }
    /// Extra paragraphs for `shawn help <name>`.
    var details: String? { get }
    var options: [OptionSpec] { get }
    /// Fixed first arguments (`config path|show|…`), for help and completions.
    var subcommands: [(name: String, summary: String)] { get }
    /// Left out of the help list (still runnable and completable).
    var hidden: Bool { get }
    func run(_ arguments: [String], context: CLIContext) async -> Int32
}

extension BuiltinCommand {
    var aliases: [String] { [] }
    var usage: String { "" }
    var details: String? { nil }
    var options: [OptionSpec] { [] }
    var subcommands: [(name: String, summary: String)] { [] }
    var hidden: Bool { false }

    /// Parses arguments, printing usage for `-h` and a short error for mistakes.
    /// Returns nil when the command should stop with `exitCode`.
    func parse(_ arguments: [String], context: CLIContext, keepUnknown: Bool = false) -> (ParsedArguments?, Int32) {
        do {
            let parsed = try ArgumentParser.parse(arguments, options: options, keepUnknown: keepUnknown)
            if parsed.has("help") {
                HelpCommand.printUsage(of: self, context: context)
                return (nil, ExitCode.ok)
            }
            return (parsed, ExitCode.ok)
        } catch {
            context.fail("shawn \(name): \(error)")
            context.err.line("usage: shawn \(name)\(usage.isEmpty ? "" : " " + usage)")
            return (nil, ExitCode.usage)
        }
    }
}

/// Section titles for built-ins (YAML commands bring their own).
enum BuiltinSection {
    static let setup = "Set up this Mac"
    static let config = "Config & sync"
    static let projects = "Projects"
    static let fun = "Fun"
    static let shell = "Shell"

    static let order = [setup, config, projects, fun, shell]
}

enum Builtins {
    static let all: [any BuiltinCommand] = [
        HelpCommand(),
        VersionCommand(),
        InstallCommand(),
        DoctorCommand(),
        DriftCommand(),
        AddCommand(),
        PRCommand(),
        UpdateCommand(),
        UpgradeCommand(),
        ConfigCommand(),
        StatusLineCommand(),
        LSPCommand(),
        QuoteCommand(),
        PartyCommand(),
        BannerCommand(),
        ProjectsCommand(),
        CloneCommand(),
        NewCommand(),
        ShellInitCommand(),
        CompletionsCommand(),
    ]

    static func find(_ name: String) -> (any BuiltinCommand)? {
        all.first { $0.name == name || $0.aliases.contains(name) }
    }

    /// Every name and alias a built-in answers to.
    static var names: Set<String> {
        Set(all.flatMap { [$0.name] + $0.aliases })
    }
}
