import Foundation
import ShawnCore

/// The on-screen log: bounded, with progress frames collapsed into one line.
///
/// A real run's full transcript is in its log file (a dry run writes none); this only keeps what is worth
/// scrolling through. `InstallerModel.droppedLinesNote` says where the trimmed lines went.
struct LogBuffer: Equatable {
    struct Entry: Equatable, Identifiable {
        enum Kind: Equatable {
            case line(LogLine.Style)
            /// A divider naming the item whose output follows.
            case header
        }

        /// Unique and increasing for the life of the buffer (never reused after trimming).
        let id: Int
        var kind: Kind
        var text: String
        let itemID: String?
        var isProgress: Bool
        /// Bumped whenever the entry is rewritten in place, so views know to redraw it.
        var version: Int
    }

    static let defaultCapacity = 3000
    /// Longest line kept; minified JSON or base64 blobs would otherwise swamp the view.
    static let maxLineLength = 2000
    /// How far back to look for the progress line an incoming line replaces.
    private static let progressSearchWindow = 64

    let capacity: Int
    private(set) var entries: [Entry] = []
    /// Lines dropped from the top to stay under `capacity`.
    private(set) var droppedCount = 0
    /// Changes on every mutation (append, overwrite, trim).
    private(set) var revision = 0
    private var nextID = 0
    private var lastItemID: String?

    init(capacity: Int = LogBuffer.defaultCapacity) {
        self.capacity = max(10, capacity)
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// Adds a line. `title` names the item for the divider shown when output switches to a new item.
    mutating func append(_ line: LogLine, itemTitle title: String? = nil) {
        let text = Self.clip(line.text)
        revision += 1

        // A progress frame is replaced by whatever that item prints next (curl/brew `\r` updates).
        if let itemID = line.itemID, let index = lastEntryIndex(for: itemID), entries[index].isProgress {
            entries[index].text = text
            entries[index].kind = .line(line.style)
            entries[index].isProgress = line.isProgress
            entries[index].version += 1
            return
        }

        if let itemID = line.itemID, itemID != lastItemID, let title {
            add(Entry(id: takeID(), kind: .header, text: title, itemID: itemID, isProgress: false, version: 0))
        }
        lastItemID = line.itemID ?? lastItemID
        add(Entry(id: takeID(), kind: .line(line.style), text: text, itemID: line.itemID, isProgress: line.isProgress, version: 0))
    }

    /// A plain narration line from the app itself (run dividers, simulation notes).
    mutating func note(_ text: String, style: LogLine.Style = .info) {
        revision += 1
        lastItemID = nil
        // A narration line (a run divider, "stopping…") closes any progress frame left open above it,
        // so the next run's output cannot overwrite a line from the previous one.
        for index in entries.indices.suffix(Self.progressSearchWindow) where entries[index].isProgress {
            entries[index].isProgress = false
        }
        add(Entry(id: takeID(), kind: .line(style), text: Self.clip(text), itemID: nil, isProgress: false, version: 0))
    }

    mutating func removeAll() {
        entries.removeAll()
        droppedCount = 0
        lastItemID = nil
        revision += 1
    }

    /// Plain text of everything on screen (Copy Log).
    var plainText: String {
        entries.map { entry in
            switch entry.kind {
            case .header: return "── \(entry.text) ──"
            case .line: return entry.text
            }
        }.joined(separator: "\n")
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private mutating func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > capacity {
            // Trim in chunks so a chatty install is not an O(n) shift per line.
            let excess = entries.count - capacity + max(1, capacity / 10)
            let removed = min(excess, entries.count - 1)
            entries.removeFirst(removed)
            droppedCount += removed
        }
    }

    private func lastEntryIndex(for itemID: String) -> Int? {
        var index = entries.count - 1
        var looked = 0
        while index >= 0, looked < Self.progressSearchWindow {
            if entries[index].itemID == itemID, entries[index].kind != .header { return index }
            index -= 1
            looked += 1
        }
        return nil
    }

    private static func clip(_ text: String) -> String {
        guard text.count > maxLineLength else { return text }
        return String(text.prefix(maxLineLength)) + " …"
    }
}
