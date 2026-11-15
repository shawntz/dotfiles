import Darwin
import Foundation

/// `~/.shawn/answers.json`: the answers to the config's questions (`ask:`) on this Mac, as one flat JSON object
/// of text values, `{"email": "jane@example.com", "full_name": "Jane Doe"}`. A person may edit it by hand.
///
/// Only the engine writes it, during a real run, one answer at a time. It is written pretty-printed with sorted
/// keys, mode 0600, by replacing the whole file at once (a link to the file is followed, so it stays a link).
public struct AnswerStore: Sendable {
    public static let fileName = "answers.json"

    public let environment: SystemEnvironment

    public init(environment: SystemEnvironment) {
        self.environment = environment
    }

    public var url: URL { environment.stateDirectory.appendingPathComponent(Self.fileName) }

    public enum Contents: Equatable, Sendable {
        case missing
        /// Not a JSON object whose values are all text. It counts as no answers and stays as it is until an answer is
        /// saved, which moves it to the run's backups first.
        case unreadable
        case answers([String: String])
    }

    public func load() -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = FileManager.default.contents(atPath: url.path),
              let answers = try? JSONDecoder().decode([String: String].self, from: data) else { return .unreadable }
        return .answers(answers)
    }

    /// Every value in the file, whatever it answers. Empty when the file is missing or unreadable.
    public var saved: [String: String] {
        if case .answers(let answers) = load() { return answers }
        return [:]
    }

    /// The saved answers to `questions` that still pass their format, by variable name. An answer that no longer
    /// passes (a hand edit, a format added later) counts as not answered.
    public func answers(for questions: [VariableQuestion]) -> [String: String] {
        let saved = self.saved
        var result: [String: String] = [:]
        for question in questions {
            guard let value = saved[question.name] else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if question.format.problem(with: trimmed) == nil { result[question.name] = trimmed }
        }
        return result
    }

    /// Saves one answer and keeps every other value in the file. An unreadable file is moved to this run's backups
    /// first; the result is where it went, or nil when there was nothing to move.
    @discardableResult
    public func save(_ answer: String, for name: String) throws -> URL? {
        var record: [String: String] = [:]
        var backup: URL?
        switch load() {
        case .missing:
            break
        case .answers(let existing):
            record = existing
        case .unreadable:
            backup = try FileOps(environment: environment).backUp(url)
        }
        record[name] = answer
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)
        try Self.replace(url, with: data)
        return backup
    }

    /// Writes `data` to a new file next to `url` (mode 0600 from the start), then renames it over `url`.
    static func replace(_ url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = url.resolvingSymlinksInPath()
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8))")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw FileOpsError("cannot write \(temporary.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            fchmod(descriptor, 0o600)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw FileOpsError("cannot replace \(target.path): \(reason)")
        }
    }
}
