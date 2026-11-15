import Foundation
import ShawnCore

struct ConfigEditError: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Adds one item to a step file by editing its text, never by re-emitting the YAML: comments, blank
/// lines, quoting and indentation all stay exactly as the author left them.
///
/// Where the new item goes (see `insertionPoint`): next to the items of the same kind that are switched
/// on (or off) the same way, in alphabetical order when that group already is, and never inside a
/// trailing group of `optional: true` items unless the new item is optional too.
enum ConfigEditor {
    enum Result: Equatable {
        /// 1-based line number of the new item.
        case inserted(line: Int)
        /// The same kind and value is already there (1-based line).
        case alreadyPresent(line: Int)
    }

    struct Item: Equatable {
        var kind: String
        var value: String
        /// 0-based line indexes.
        var start: Int
        var end: Int
        /// The item says `optional: true` (it starts switched off).
        var optional = false
        /// Items in one group follow each other with no blank line or heading comment in between.
        var group = 0
    }

    struct Layout: Equatable {
        /// 0-based index of the `items:` line, nil when the file has none.
        var itemsLine: Int?
        var flowEmpty: Bool
        /// Indentation in front of each item's dash.
        var indent: String
        var items: [Item]
    }

    typealias Option = (key: String, value: YAMLValue)

    static func insert(kind: String, value: String, options: [Option] = [], file: URL) throws -> Result {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw ConfigEditError(message: "cannot read \(file.path)")
        }
        let (newText, result) = try insert(kind: kind, value: value, options: options, into: text)
        guard case .inserted = result else { return result }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        do {
            try Data(newText.utf8).write(to: file, options: .atomic)
            if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        } catch {
            throw ConfigEditError(message: "cannot write \(file.path): \(error.localizedDescription)")
        }
        return result
    }

    static func insert(kind: String, value: String, options: [Option] = [], into text: String) throws -> (text: String, result: Result) {
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        let layout = analyse(lines)

        if let existing = layout.items.first(where: { $0.kind == kind && $0.value == value }) {
            return (text, .alreadyPresent(line: existing.start + 1))
        }

        let indent = layout.items.isEmpty ? "  " : layout.indent
        let newLines = itemLines(kind: kind, value: value, options: options, indent: indent)
        let optional = options.contains { $0.key == "optional" && $0.value.bool == true }
        let insertAt: Int
        if let position = insertionPoint(kind: kind, value: value, optional: optional, items: layout.items) {
            insertAt = position
        } else if let itemsLine = layout.itemsLine {
            if layout.flowEmpty {
                // `items: []  # none yet` becomes a block list: `items:  # none yet`.
                let original = lines[itemsLine]
                let comment = original.range(of: "#.*$", options: .regularExpression).map { "  " + original[$0] } ?? ""
                lines[itemsLine] = "items:" + comment
            }
            insertAt = itemsLine + 1
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("items:")
            insertAt = lines.count
        }
        lines.insert(contentsOf: newLines, at: insertAt)
        let newText = lines.joined(separator: "\n") + (endsWithNewline || layout.itemsLine == nil ? "\n" : "")

        // Belt and braces: the result must still be YAML with the new item, exactly as meant, in its items list.
        guard let parsed = try? YAML.parse(newText), let items = parsed.map?["items"]?.list,
              items.contains(where: { $0.map?.entries.first?.key == kind && $0.map?.entries.first?.value.string == value }) else {
            throw ConfigEditError(message: "could not add '\(kind): \(value)' without breaking the file's YAML; add it by hand")
        }
        return (newText, .inserted(line: insertAt + 1))
    }

    /// 0-based line the new item is inserted at, or nil when the file has no items yet.
    ///
    /// 1. Next to the last item of the same kind that is optional exactly when the new one is, so a
    ///    switched-on app joins the switched-on apps, not a "── Optional ──" group after them. In a group
    ///    that is already in alphabetical order (by name, ignoring a tap prefix) it goes in its place.
    /// 2. After the last item of the same kind: kinds stay together.
    /// 3. A switched-on item of a kind the file does not have yet stays above the trailing groups in
    ///    which every item is optional.
    /// 4. After the last item.
    static func insertionPoint(kind: String, value: String, optional: Bool, items: [Item]) -> Int? {
        guard let last = items.last else { return nil }
        if let anchor = items.lastIndex(where: { $0.kind == kind && $0.optional == optional }) {
            let run = items.indices.filter { items[$0].group == items[anchor].group && items[$0].kind == kind && items[$0].optional == optional }
            let keys = run.map { sortKey(items[$0].value) }
            // Two or more names in order show the group is kept sorted; ids (App Store numbers) are not names.
            let sortable = keys.count >= 2 && !(keys + [sortKey(value)]).contains { $0.allSatisfy(\.isNumber) }
            if sortable, keys == keys.sorted(), let next = run.first(where: { sortKey(items[$0].value) > sortKey(value) }) {
                return items[next].start
            }
            return items[anchor].end + 1
        }
        if let anchor = items.last(where: { $0.kind == kind }) {
            return anchor.end + 1
        }
        if !optional, let block = trailingOptionalStart(items), block > 0 {
            return items[block - 1].end + 1
        }
        return last.end + 1
    }

    /// Index of the first item of the trailing groups in which every item is optional, if there are any.
    static func trailingOptionalStart(_ items: [Item]) -> Int? {
        var start: Int?
        var index = items.count - 1
        while index >= 0 {
            let group = items[index].group
            let members = items.indices.filter { items[$0].group == group }
            guard members.allSatisfy({ items[$0].optional }) else { break }
            start = members.first
            index = (members.first ?? 0) - 1
        }
        return start
    }

    /// `nikitabobko/tap/aerospace` sorts as `aerospace`, the way the step files ask for.
    static func sortKey(_ value: String) -> String {
        (value.split(separator: "/").last.map(String.init) ?? value).lowercased()
    }

    /// Finds the `items:` list and every item in it (kind, value, line span, optional, group).
    static func analyse(_ lines: [String]) -> Layout {
        var layout = Layout(itemsLine: nil, flowEmpty: false, indent: "  ", items: [])
        guard let itemsLine = lines.firstIndex(where: { $0.range(of: "^items:\\s*(\\[\\s*\\])?\\s*(#.*)?$", options: .regularExpression) != nil }) else {
            return layout
        }
        layout.itemsLine = itemsLine
        layout.flowEmpty = lines[itemsLine].contains("[")
        var dashIndent: Int?
        var group = 0
        var separated = false
        var index = itemsLine + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !trimmed.isEmpty, let dashIndent, indent > dashIndent, !layout.items.isEmpty {
                    // A comment indented under the current item belongs to it.
                    layout.items[layout.items.count - 1].end = index
                } else {
                    // A blank line or a heading comment ends the group.
                    separated = true
                }
                index += 1
                continue
            }
            if dashIndent == nil {
                guard trimmed.hasPrefix("- ") || trimmed == "-" else { break }
                dashIndent = indent
                layout.indent = String(line.prefix(indent))
            }
            guard let dash = dashIndent else { break }
            if indent == dash && (trimmed.hasPrefix("- ") || trimmed == "-") {
                if separated && !layout.items.isEmpty { group += 1 }
                separated = false
                let (kind, value) = parseItemHead(trimmed)
                layout.items.append(Item(kind: kind, value: value, start: index, end: index, group: group))
            } else if indent > dash, !layout.items.isEmpty {
                layout.items[layout.items.count - 1].end = index
                if isOptionalTrue(trimmed) { layout.items[layout.items.count - 1].optional = true }
            } else {
                break
            }
            index += 1
        }
        return layout
    }

    /// `optional: true` (or another YAML spelling of true), with or without a comment.
    static func isOptionalTrue(_ trimmed: String) -> Bool {
        trimmed.range(of: "^optional:\\s*(true|yes|on)\\s*(#.*)?$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `- brew: eza  # note` → ("brew", "eza").
    static func parseItemHead(_ trimmed: String) -> (String, String) {
        let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let colon = body.range(of: ":") else { return (body, "") }
        let kind = String(body[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = String(body[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") || rest.hasPrefix("'") {
            // Read the quoted scalar the way YAML does, escapes included.
            if let parsed = (try? YAML.parse("k: " + rest))??.map?["k"]?.string {
                rest = parsed
            } else if let close = rest.dropFirst().firstIndex(of: rest.first!) {
                rest = String(rest[rest.index(after: rest.startIndex)..<close])
            }
        } else if let comment = rest.range(of: " #") {
            rest = String(rest[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (kind, rest)
    }

    /// The new item as YAML lines, e.g. `  - mas: 937984704` / `    name: Amphetamine`.
    static func itemLines(kind: String, value: String, options: [Option], indent: String) -> [String] {
        var lines = ["\(indent)- \(kind): \(scalar(value))"]
        for option in options {
            lines.append("\(indent)  \(option.key): \(yamlText(option.value))")
        }
        return lines
    }

    /// A value as YAML text: booleans and numbers as such (`optional: true`, `id: 42`), strings through
    /// `scalar`, so a string never turns into a boolean or a number on the way back in.
    static func yamlText(_ value: YAMLValue) -> String {
        switch value {
        case .scalar(let scalar):
            switch scalar.kind {
            case .null: return "null"
            case .bool(let flag): return flag ? "true" : "false"
            case .int(let number): return String(number)
            case .double: return scalar.raw
            case .string: return quotedIfNeeded(scalar.raw)
            }
        case .list, .map:
            // Flow style; JSON is valid YAML.
            return JSONText.encode(value)
        }
    }

    /// A value typed on the command line as YAML text: a canonical whole number stays a number
    /// (`937984704`), everything else is a string, plain when that is safe and double-quoted otherwise.
    static func scalar(_ text: String) -> String {
        if isCanonicalInteger(text) { return text }
        return quotedIfNeeded(text)
    }

    /// The string `text`, plain when YAML reads the plain text back as this very string, double-quoted
    /// otherwise.
    ///
    /// Plain needs all of: a first character that cannot start anything else in YAML (no `-`, `@`, `` ` ``,
    /// `&`, `*`, `!`, `|`, `>`, `%`, `#`, quotes or brackets); only letters, digits, spaces and `_ . / @ + ( ) -`
    /// after it (no `: ` or ` #`, which would end the value); no space at either end; not a word YAML
    /// reads as a boolean or null in any version (`yes`, `off`, `y`, `~`, …), a number (`1.10`, `0x1F`, `0123`)
    /// or a date. The last rules are checked by parsing the plain text back with the config's own YAML
    /// reader, so they follow what it actually does.
    static func quotedIfNeeded(_ text: String) -> String {
        plainReadsBack(text) ? text : doubleQuoted(text)
    }

    static func plainReadsBack(_ text: String) -> Bool {
        guard text.range(of: "^[A-Za-z0-9_./+(][A-Za-z0-9_./@+() -]*$", options: .regularExpression) != nil,
              !text.hasSuffix(" ") else { return false }
        let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~"]
        if reserved.contains(text.lowercased()) { return false }
        if text.range(of: "^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}", options: .regularExpression) != nil { return false }
        guard let parsed = (try? YAML.parse("k: " + text))??.map?["k"], case .scalar(let scalar) = parsed else { return false }
        return scalar.kind == .string && scalar.raw == text
    }

    static func isCanonicalInteger(_ text: String) -> Bool {
        text.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil && Int(text) != nil
    }

    /// A YAML double-quoted scalar. Escapes everything YAML does not allow as is (control characters,
    /// DEL, C1 controls) and the characters YAML 1.1 treats as line breaks.
    static func doubleQuoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                let value = scalar.value
                if value < 0x20 || (0x7F...0x9F).contains(value) {
                    result += String(format: "\\x%02X", value)
                } else if value == 0x2028 || value == 0x2029 || value == 0xFEFF {
                    result += String(format: "\\u%04X", value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
