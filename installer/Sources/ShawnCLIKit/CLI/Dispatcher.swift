import Foundation
import ShawnCore

/// Turns `shawn [global flags] <command> [arguments]` into a running command.
///
/// Order of business: global flags → self-update (unless the command is one that must stay fast or
/// the user opted out) → built-in command → YAML command → "did you mean".
/// The self-update runs BEFORE the command is looked up, so a command added to `cli.yaml` on another
/// Mac is found on the very call that pulled it in.
enum Dispatcher {
    /// Commands that never wait for the network.
    static let neverSelfUpdate: Set<String> = ["statusline", "shell-init", "completions", "__askpass", "update"]

    static let globalOptions: [OptionSpec] = [
        OptionSpec("no-update", "Skip shawn's own update check and the tool update before claude/codex/grok (also right after a YAML command: shawn claude --no-update)"),
        OptionSpec("no-color", "Plain output without colours (also: NO_COLOR=1)"),
        OptionSpec("config", value: "DIR", "Use this config directory"),
        OptionSpec("version", "Print the version"),
    ]

    struct Invocation: Equatable {
        var options = GlobalOptions()
        var command: String?
        var arguments: [String] = []
        var printVersion = false
        var printHelp = false
    }

    /// Reads global flags up to the first non-flag word (the command).
    static func parseGlobals(_ arguments: [String], environment: [String: String]) throws -> Invocation {
        var invocation = Invocation()
        invocation.options.noUpdate = environment["SHAWN_NO_UPDATE"] == "1"
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-"), argument != "-" else { break }
            switch argument {
            case "--no-update": invocation.options.noUpdate = true
            case "--no-color": invocation.options.noColor = true
            case "--version", "-v": invocation.printVersion = true
            case "--help", "-h": invocation.printHelp = true
            case "--config":
                guard index + 1 < arguments.count else { throw ArgumentError(message: "--config needs a directory") }
                index += 1
                invocation.options.configPath = URL(fileURLWithPath: arguments[index])
            default:
                if argument.hasPrefix("--config=") {
                    invocation.options.configPath = URL(fileURLWithPath: String(argument.dropFirst("--config=".count)))
                } else {
                    let name = argument.drop { $0 == "-" }
                    let suggestion = Suggest.closest(to: String(name), in: globalOptions.map(\.name)).map { ". Did you mean --\($0)?" } ?? ""
                    throw ArgumentError(message: "unknown option \(argument)\(suggestion)")
                }
            }
            index += 1
        }
        if index < arguments.count {
            invocation.command = arguments[index]
            invocation.arguments = Array(arguments[(index + 1)...])
        }
        return invocation
    }

    static func run(arguments: [String], context: CLIContext) async -> Int32 {
        let invocation: Invocation
        do {
            invocation = try parseGlobals(arguments, environment: context.environment.baseEnvironment)
        } catch {
            context.fail("shawn: \(error)")
            return ExitCode.usage
        }
        context.globals = invocation.options
        if invocation.options.noColor {
            context.terminal.color = false
            context.terminal.stderrColor = false
        }
        if invocation.printVersion {
            context.out.line("shawn \(ShawnCore.version)")
            return ExitCode.ok
        }

        let name = invocation.printHelp ? "help" : (invocation.command ?? "help")
        let commandArguments = invocation.printHelp ? [invocation.command].compactMap { $0 } : invocation.arguments
        // `shawn claude --no-update` skips shawn's own update too, not just claude's (the YAML command strips the flag).
        // The command may not exist yet (the update could bring it), so anything that is not a built-in qualifies.
        if Builtins.find(name) == nil, commandArguments.first == "--no-update" {
            context.globals.noUpdate = true
        }

        if shouldSelfUpdate(name, context: context) {
            let outcome = await SelfUpdateRunner.automatic(context: context)
            switch outcome {
            case .continue:
                break
            case .configChanged:
                context.invalidateConfig()
            case .restart(let binary):
                let request = SelfUpdateRunner.restartRequest(binary: binary, arguments: context.arguments, context: context)
                if case .failed(let code) = context.services.replacer.replace(request) {
                    context.warn("shawn: updated, but could not restart (\(String(cString: strerror(code)))); this run uses the previous version")
                } else {
                    return ExitCode.ok
                }
            }
        }

        if let builtin = Builtins.find(name) {
            return await builtin.run(commandArguments, context: context)
        }
        if let command = context.cli.command(named: name) {
            return await YAMLCommandRunner.run(command, arguments: commandArguments, context: context)
        }
        return unknownCommand(name, context: context)
    }

    /// `--no-update` / `SHAWN_NO_UPDATE=1` skip both updates; `SHAWN_NO_SELF_UPDATE=1` only this one.
    static func shouldSelfUpdate(_ name: String, context: CLIContext) -> Bool {
        if neverSelfUpdate.contains(name) { return false }
        if context.globals.noUpdate { return false }
        let environment = context.environment.baseEnvironment
        if environment["SHAWN_NO_SELF_UPDATE"] == "1" { return false }
        // Loop guard: the process we re-executed after an update never updates again.
        if environment[SelfUpdateRunner.reexecMarker] != nil { return false }
        return !context.cli.selfUpdate.skip.contains(name)
    }

    static func unknownCommand(_ name: String, context: CLIContext) -> Int32 {
        let candidates = Array(Builtins.names.filter { !$0.hasPrefix("_") }) + context.cli.commands.map(\.name)
        var message = "shawn: unknown command '\(name)'"
        if let suggestion = Suggest.closest(to: name, in: candidates) {
            message += ". Did you mean '\(suggestion)'?"
        }
        context.fail(message)
        context.err.line("Run 'shawn help' to see every command.")
        return ExitCode.usage
    }
}
