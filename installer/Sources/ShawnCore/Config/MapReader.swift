import Foundation

/// Thread-safe accumulator for config issues.
public final class IssueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConfigIssue] = []

    public init() {}

    public func add(_ issue: ConfigIssue) {
        lock.lock()
        storage.append(issue)
        lock.unlock()
    }

    public func add(contentsOf issues: [ConfigIssue]) {
        lock.lock()
        storage.append(contentsOf: issues)
        lock.unlock()
    }

    public var issues: [ConfigIssue] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var errors: [ConfigIssue] { issues.filter { $0.severity == .error } }
    public var hasErrors: Bool { !errors.isEmpty }
}

/// Typed, error-accumulating access to a YAML mapping.
///
/// Every accessor marks its key as consumed; `finish()` then reports any key
/// nobody asked for (usually a typo), with a "did you mean" suggestion. Problems
/// are recorded on the shared collector rather than thrown, so one pass over a
/// config reports everything that is wrong with it.
public final class MapReader {
    public let map: YAMLMap
    /// File (and line of the mapping) for error messages.
    public let source: SourceRef
    /// What this mapping is, for error messages: `item 3 (cask)`, `dock.settings`, ...
    public let context: String
    public let collector: IssueCollector
    private var consumed: Set<String> = []
    private var knownKeys: Set<String> = []
    private var alsoSuggested: Set<String> = []

    public init(map: YAMLMap, source: SourceRef, context: String, collector: IssueCollector) {
        self.map = map
        self.source = source
        self.context = context
        self.collector = collector
    }

    // MARK: Reporting

    private func location(of key: String?) -> SourceRef {
        if let key, let line = map.line(of: key) { return SourceRef(file: source.file, line: line) }
        return source
    }

    public func error(_ message: String, key: String? = nil) {
        collector.add(.error("\(context): \(message)", at: location(of: key)))
    }

    public func warning(_ message: String, key: String? = nil) {
        collector.add(.warning("\(context): \(message)", at: location(of: key)))
    }

    private func touch(_ key: String) -> YAMLValue? {
        knownKeys.insert(key)
        guard let value = map[key] else { return nil }
        consumed.insert(key)
        return value
    }

    public func has(_ key: String) -> Bool { map.contains(key) }

    // MARK: Scalars

    /// Raw value for a key (marks it consumed).
    public func value(_ key: String) -> YAMLValue? {
        touch(key)
    }

    public func string(_ key: String) -> String? {
        guard let value = touch(key) else { return nil }
        if value.isNull { return nil }
        guard let text = value.string else {
            error("'\(key)' must be a string, not a \(value.typeName)", key: key)
            return nil
        }
        return text
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        string(key) ?? defaultValue
    }

    /// Records an error and returns "" when the key is missing or empty.
    public func requiredString(_ key: String) -> String {
        guard map.contains(key) else {
            knownKeys.insert(key)
            error("missing required key '\(key)'")
            return ""
        }
        guard let text = string(key), !text.isEmpty else {
            if map[key]?.isNull == true || map[key]?.string == "" { error("'\(key)' must not be empty", key: key) }
            return ""
        }
        return text
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = touch(key) else { return nil }
        if value.isNull { return nil }
        guard let flag = value.bool else {
            error("'\(key)' must be true or false, not a \(value.typeName)", key: key)
            return nil
        }
        return flag
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        bool(key) ?? defaultValue
    }

    public func int(_ key: String) -> Int? {
        guard let value = touch(key) else { return nil }
        if value.isNull { return nil }
        guard let number = value.int else {
            error("'\(key)' must be a whole number, not a \(value.typeName)", key: key)
            return nil
        }
        return number
    }

    public func double(_ key: String) -> Double? {
        guard let value = touch(key) else { return nil }
        if value.isNull { return nil }
        guard let number = value.double else {
            error("'\(key)' must be a number, not a \(value.typeName)", key: key)
            return nil
        }
        return number
    }

    /// One of a fixed set of strings.
    public func oneOf(_ key: String, _ allowed: [String], default defaultValue: String) -> String {
        guard let text = string(key) else { return defaultValue }
        guard allowed.contains(text) else {
            error("'\(key)' must be one of: \(allowed.joined(separator: ", ")) (got '\(text)')", key: key)
            return defaultValue
        }
        return text
    }

    // MARK: Collections

    /// A list of strings; a single scalar is accepted as a one-element list.
    public func stringList(_ key: String) -> [String] {
        guard let value = touch(key) else { return [] }
        guard let list = value.stringList else {
            error("'\(key)' must be a list of strings", key: key)
            return []
        }
        return list
    }

    public func list(_ key: String) -> [YAMLValue] {
        guard let value = touch(key) else { return [] }
        if value.isNull { return [] }
        guard let list = value.list else {
            error("'\(key)' must be a list, not a \(value.typeName)", key: key)
            return []
        }
        return list
    }

    /// An ordered map of scalar values, as (key, text) pairs.
    public func stringPairs(_ key: String) -> [(key: String, value: String)] {
        guard let value = touch(key) else { return [] }
        if value.isNull { return [] }
        guard let nested = value.map else {
            error("'\(key)' must be a mapping, not a \(value.typeName)", key: key)
            return []
        }
        var pairs: [(key: String, value: String)] = []
        for entry in nested.entries {
            guard let text = entry.value.string else {
                error("'\(key).\(entry.key)' must be a simple value, not a \(entry.value.typeName)", key: key)
                continue
            }
            pairs.append((entry.key, text))
        }
        return pairs
    }

    /// A nested mapping, wrapped in its own reader (unknown keys inside are checked too).
    public func reader(_ key: String) -> MapReader? {
        guard let value = touch(key) else { return nil }
        if value.isNull { return nil }
        guard let nested = value.map else {
            error("'\(key)' must be a mapping, not a \(value.typeName)", key: key)
            return nil
        }
        return MapReader(map: nested, source: location(of: key), context: "\(context) → \(key)", collector: collector)
    }

    /// A list of mappings, each wrapped in its own reader.
    public func readers(_ key: String) -> [MapReader] {
        var result: [MapReader] = []
        for (index, element) in list(key).enumerated() {
            guard let nested = element.map else {
                error("'\(key)' entry \(index + 1) must be a mapping, not a \(element.typeName)", key: key)
                continue
            }
            result.append(MapReader(map: nested, source: location(of: key), context: "\(context) → \(key)[\(index + 1)]", collector: collector))
        }
        return result
    }

    // MARK: Completion

    /// Marks keys as acceptable without reading them (they are handled elsewhere).
    public func allow(_ keys: String...) {
        for key in keys {
            knownKeys.insert(key)
            consumed.insert(key)
        }
    }

    /// Names keys worth suggesting for a typo although this reader never holds them, because something else
    /// reads them first: an item's `name`, `note` and `optional`.
    public func suggest(_ keys: Set<String>) {
        alsoSuggested.formUnion(keys)
    }

    /// Reports every key that no accessor asked for.
    public func finish() {
        for key in map.keys where !consumed.contains(key) {
            if let suggestion = Self.closestMatch(to: key, in: knownKeys.union(alsoSuggested)) {
                error("unknown key '\(key)'. Did you mean '\(suggestion)'?", key: key)
            } else if knownKeys.isEmpty {
                error("unknown key '\(key)' (this entry takes no extra options)", key: key)
            } else {
                error("unknown key '\(key)' (expected: \(knownKeys.sorted().joined(separator: ", ")))", key: key)
            }
        }
    }

    // MARK: Suggestions

    /// The candidate closest to `word` when it is close enough to be a likely typo.
    public static func closestMatch(to word: String, in candidates: Set<String>) -> String? {
        var best: (candidate: String, distance: Int)?
        for candidate in candidates.sorted() {
            let distance = editDistance(word.lowercased(), candidate.lowercased())
            if distance <= max(1, min(word.count, candidate.count) / 3), distance < (best?.distance ?? Int.max) {
                best = (candidate, distance)
            }
        }
        return best?.candidate
    }

    /// Edit distance where swapping two neighboring letters counts as one change ("itmes" → "items").
    public static func editDistance(_ lhs: String, _ rhs: String) -> Int {
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

/// Reader for one step item: the kind's own value plus its options.
public final class ItemParser {
    public let item: ItemConfig
    /// Reader over the item's options (every key except the kind key and the common keys).
    public let options: MapReader
    public let collector: IssueCollector

    public init(item: ItemConfig, collector: IssueCollector = IssueCollector()) {
        self.item = item
        self.collector = collector
        self.options = MapReader(map: item.options, source: item.source, context: Self.context(for: item), collector: collector)
        // The loader takes these out before the kind sees its options, so a typo of one lands here.
        options.suggest(ItemConfig.commonKeys)
    }

    static func context(for item: ItemConfig) -> String {
        "item \(item.index + 1) (\(item.kind))"
    }

    /// The value written after the kind key.
    public var primary: YAMLValue { item.value }

    public func fail(_ message: String) {
        collector.add(.error("\(Self.context(for: item)): \(message)", at: item.source))
    }

    public func warn(_ message: String) {
        collector.add(.warning("\(Self.context(for: item)): \(message)", at: item.source))
    }

    /// The kind's value as non-empty text, e.g. `eza` in `- brew: eza`. Records an error otherwise.
    public func primaryString() -> String {
        guard let text = item.value.string, !text.isEmpty else {
            fail("'\(item.kind)' needs a value, e.g. '\(item.kind): something'")
            return ""
        }
        return text
    }

    /// The kind's value as text, or nil when it was left empty / set to `true`.
    public func optionalPrimaryString() -> String? {
        if item.value.isNull || item.value.bool != nil { return nil }
        return item.value.string
    }

    public func primaryInt() -> Int? {
        guard let number = item.value.int else {
            fail("'\(item.kind)' must be a whole number")
            return nil
        }
        return number
    }

    /// The kind's value as a nested mapping, e.g. `dock: { apps: [...] }`.
    public func primaryReader() -> MapReader? {
        guard let map = item.value.map else {
            fail("'\(item.kind)' must be a mapping, not a \(item.value.typeName)")
            return nil
        }
        return MapReader(map: map, source: item.source, context: Self.context(for: item), collector: collector)
    }

    /// Call when parsing is complete: reports unknown option keys and throws if any error was recorded.
    public func finish() throws {
        options.finish()
        let errors = collector.errors
        if !errors.isEmpty { throw ConfigError(errors) }
    }
}
