import Foundation
import ShawnCore

/// Color roles; views map them onto the palette.
enum Tone: Equatable {
    case faint, dim, text, pink, yellow, mint, red, cyan
}

/// How a status is drawn: one glyph in a fixed-width column, a color, and words for VoiceOver.
struct StatusLook: Equatable {
    /// One monospaced character. Ignored while `spins` is true.
    let glyph: String
    let tone: Tone
    let label: String
    let detail: String?
    /// Shows the spinner instead of the glyph.
    let spins: Bool

    init(_ glyph: String, _ tone: Tone, _ label: String, detail: String? = nil, spins: Bool = false) {
        self.glyph = glyph
        self.tone = tone
        self.label = label
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        self.spins = spins
    }

    /// Classic terminal spinner: every frame is in the monospaced font, so the column never shifts.
    static let spinnerFrames = ["|", "/", "-", "\\"]
    static let spinnerInterval: TimeInterval = 0.12
}

extension ItemStatus {
    var look: StatusLook {
        switch self {
        case .pending: return StatusLook("·", .faint, "waiting")
        case .disabled: return StatusLook("-", .faint, "off")
        case .checking: return StatusLook("?", .dim, "checking", spins: true)
        case .running: return StatusLook("▸", .pink, "running", spins: true)
        case .done(let message): return StatusLook("✓", .mint, "done", detail: message)
        case .alreadyDone(let message): return StatusLook("✓", .dim, "already done", detail: message)
        case .skipped(let reason): return StatusLook("»", .dim, "skipped", detail: reason)
        case .needsAttention(let message): return StatusLook("!", .yellow, "needs you", detail: message)
        case .failed(let message): return StatusLook("✗", .red, "failed", detail: message)
        // STOP is not a failure: the same pink ■ as the STOPPED banner, never red.
        case .cancelled: return StatusLook("■", .pink, "stopped", detail: "interrupted")
        }
    }

    /// The item got all the way through in this run. Unlike `isFinished`, an item interrupted by STOP
    /// (`.cancelled`) does not count, so progress never claims work that did not happen.
    var isComplete: Bool {
        switch self {
        case .pending, .disabled, .checking, .running, .cancelled: return false
        case .done, .alreadyDone, .skipped, .needsAttention, .failed: return true
        }
    }
}

extension StepStatus {
    var look: StatusLook {
        switch self {
        case .pending: return StatusLook("·", .faint, "waiting")
        case .disabled: return StatusLook("-", .faint, "off")
        case .running: return StatusLook("▸", .pink, "running", spins: true)
        case .done: return StatusLook("✓", .mint, "done")
        case .finishedWithFailures(let count): return StatusLook("✗", .red, Self.failedLabel(count))
        case .stopped: return StatusLook("■", .pink, "stopped part-way")
        }
    }

    static func failedLabel(_ count: Int) -> String {
        count == 1 ? "1 failed" : "\(count) failed"
    }
}

extension StatusLook {
    /// A step or item the run never reached (after a STOP).
    static let notStarted = StatusLook("·", .faint, "not started")
}

enum Format {
    /// `03:12`, or `1:03:12` past an hour.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// `4m 12s`, `38s`, `1h 03m`.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }

    static func count(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// The block-character progress bar: full cells, one partial cell, then shade.
    static func progressBar(fraction: Double, cells: Int) -> (filled: String, empty: String) {
        let cells = max(1, cells)
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        let eighths = Int((clamped * Double(cells * 8)).rounded(.down))
        let full = eighths / 8
        let remainder = eighths % 8
        let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var filled = String(repeating: "█", count: full)
        var used = full
        if remainder > 0, full < cells {
            filled += partials[remainder]
            used += 1
        }
        return (filled, String(repeating: "░", count: max(0, cells - used)))
    }
}
