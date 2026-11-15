import Foundation

/// One `--option` a built-in command understands (also used for help and zsh completions).
struct OptionSpec: Sendable, Equatable {
    /// Long name without dashes: `dry-run`.
    let name: String
    let short: Character?
    /// Name shown for the option's value (`DIR`), nil for a flag.
    let value: String?
    let help: String

    init(_ name: String, short: Character? = nil, value: String? = nil, _ help: String) {
        self.name = name
        self.short = short
        self.value = value
        self.help = help
    }

    var display: String {
        var text = "--\(name)"
        if let short { text = "-\(short), " + text }
        if let value { text += " \(value)" }
        return text
    }
}

struct ParsedArguments: Sendable, Equatable {
    var flags: Set<String> = []
    var values: [String: [String]] = [:]
    var positionals: [String] = []
    /// Options not in the spec, kept in order (only when the parser was asked to keep them).
    var extra: [(name: String, value: String?)] = []

    func has(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name]?.last }

    /// Every value given for `name`, with comma-separated lists split (`--only a,b --only c`).
    func list(_ name: String) -> [String] {
        (values[name] ?? []).flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
    }

    static func == (lhs: ParsedArguments, rhs: ParsedArguments) -> Bool {
        lhs.flags == rhs.flags && lhs.values == rhs.values && lhs.positionals == rhs.positionals
            && lhs.extra.map { "\($0.name)=\($0.value ?? "")" } == rhs.extra.map { "\($0.name)=\($0.value ?? "")" }
    }
}

struct ArgumentError: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum ArgumentParser {
    /// Parses `arguments` against `options`. `-h`/`--help` are always understood (flag `help`).
    /// `--name=value`, `--name value`, `-x value` and `--` (end of options) are supported.
    static func parse(_ arguments: [String], options: [OptionSpec], keepUnknown: Bool = false) throws -> ParsedArguments {
        var result = ParsedArguments()
        var index = 0
        var onlyPositionals = false
        let byName = Dictionary(uniqueKeysWithValues: options.map { ($0.name, $0) })

        func take(_ spec: OptionSpec, inline: String?, display: String) throws {
            guard spec.value != nil else {
                if inline != nil { throw ArgumentError(message: "\(display) does not take a value") }
                result.flags.insert(spec.name)
                return
            }
            if let inline {
                result.values[spec.name, default: []].append(inline)
            } else if index + 1 < arguments.count {
                index += 1
                result.values[spec.name, default: []].append(arguments[index])
            } else {
                throw ArgumentError(message: "\(display) needs a value (\(spec.value ?? "VALUE"))")
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if onlyPositionals || argument == "-" || !argument.hasPrefix("-") {
                result.positionals.append(argument)
            } else if argument == "--" {
                onlyPositionals = true
            } else if argument == "-h" || argument == "--help" {
                result.flags.insert("help")
            } else if argument.hasPrefix("--") {
                let body = String(argument.dropFirst(2))
                let name = body.split(separator: "=", maxSplits: 1).first.map(String.init) ?? body
                let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
                if let spec = byName[name] {
                    try take(spec, inline: inline, display: "--\(name)")
                } else if keepUnknown {
                    if let inline {
                        result.extra.append((name, inline))
                    } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                        index += 1
                        result.extra.append((name, arguments[index]))
                    } else {
                        result.extra.append((name, nil))
                    }
                } else {
                    let suggestion = Suggest.closest(to: name, in: options.map(\.name)).map { ". Did you mean --\($0)?" } ?? ""
                    throw ArgumentError(message: "unknown option --\(name)\(suggestion)")
                }
            } else {
                // One or more short flags: -n, -yv, or -m "message".
                let letters = Array(argument.dropFirst())
                for (position, letter) in letters.enumerated() {
                    guard let spec = options.first(where: { $0.short == letter }) else {
                        throw ArgumentError(message: "unknown option -\(letter)")
                    }
                    if spec.value != nil {
                        let rest = String(letters[(position + 1)...])
                        try take(spec, inline: rest.isEmpty ? nil : rest, display: "-\(letter)")
                        break
                    }
                    result.flags.insert(spec.name)
                }
            }
            index += 1
        }
        return result
    }
}

/// "Did you mean …?"
enum Suggest {
    static func closest(to word: String, in candidates: [String]) -> String? {
        let lowered = word.lowercased()
        let prefixed = candidates.filter { $0.hasPrefix(lowered) && !lowered.isEmpty }
        if prefixed.count == 1 { return prefixed[0] }
        var best: (candidate: String, distance: Int)?
        for candidate in Set(candidates).sorted() {
            let distance = editDistance(lowered, candidate.lowercased())
            let limit = max(1, min(word.count, candidate.count) / 3)
            if distance <= limit, distance < (best?.distance ?? Int.max) {
                best = (candidate, distance)
            }
        }
        return best?.candidate
    }

    /// Levenshtein distance where swapping two neighbouring letters counts as one edit.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs), right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var rows = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in 0...left.count { rows[i][0] = i }
        for j in 0...right.count { rows[0][j] = j }
        for i in 1...left.count {
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                var best = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
                if i > 1, j > 1, left[i - 1] == right[j - 2], left[i - 2] == right[j - 1] {
                    best = min(best, rows[i - 2][j - 2] + 1)
                }
                rows[i][j] = best
            }
        }
        return rows[left.count][right.count]
    }
}

/// Exit statuses, following sysexits(3) where one fits.
enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 64
    static let unavailable: Int32 = 69
    static let notFound: Int32 = 127
    static let cannotExecute: Int32 = 126
    static let interrupted: Int32 = 130
}
