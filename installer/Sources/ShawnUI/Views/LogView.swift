import AppKit
import ShawnCore
import SwiftUI

/// The live log: a read-only NSTextView so thousands of lines scroll smoothly and can be selected and
/// copied across lines. It only re-renders what changed (new lines, a rewritten progress line, lines
/// trimmed from the top) and keeps following the end only while the reader is already at the bottom.
struct LogTextView: NSViewRepresentable {
    let buffer: LogBuffer
    let palette: Palette
    /// Whether the view is scrolled to the bottom (and so follows new output).
    @Binding var isFollowing: Bool
    /// Changing this scrolls to the end ("jump to latest").
    let scrollToEndRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(isFollowing: $isFollowing)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.scrollerKnobStyle = .light
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 0, height: 2)
            // Room on the right so text never runs under the overlay scroller.
            textView.textContainer?.lineFragmentPadding = 8
            textView.textContainer?.widthTracksTextView = true
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.selectedTextAttributes = [.backgroundColor: palette.pink.nsColor.withAlphaComponent(0.3)]
            textView.setAccessibilityLabel("Install log")
            context.coordinator.textView = textView
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.isFollowing = $isFollowing
        context.coordinator.render(buffer, palette: palette, in: scrollView)
        context.coordinator.scrollIfRequested(scrollToEndRequest, in: scrollView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        var isFollowing: Binding<Bool>
        weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var rendered: [(id: Int, version: Int, length: Int)] = []
        private var renderedPalette: Palette?
        private var lastScrollRequest = 0
        private var followUpdateScheduled = false

        init(isFollowing: Binding<Bool>) {
            self.isFollowing = isFollowing
        }

        func observe(_ scrollView: NSScrollView) {
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        @objc private func boundsChanged(_ notification: Notification) {
            // This can arrive in the middle of a SwiftUI update (our own scroll-to-end), so the state change is
            // deferred, and so is the decision: a burst of scrolls (scroll to the end before layout, then again
            // after) must settle on where the view ends up, not on a position it has already left.
            guard !followUpdateScheduled else { return }
            followUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                followUpdateScheduled = false
                guard let scrollView else { return }
                let atBottom = Self.isAtBottom(scrollView)
                if isFollowing.wrappedValue != atBottom { isFollowing.wrappedValue = atBottom }
            }
        }

        static func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            guard let document = scrollView.documentView else { return true }
            let visible = scrollView.contentView.documentVisibleRect
            return visible.maxY >= document.bounds.maxY - 12
        }

        func scrollIfRequested(_ request: Int, in scrollView: NSScrollView) {
            guard request != lastScrollRequest else { return }
            lastScrollRequest = request
            textView?.scrollToEndOfDocument(nil)
        }

        func render(_ buffer: LogBuffer, palette: Palette, in scrollView: NSScrollView) {
            guard let textView, let storage = textView.textStorage else { return }
            let follow = rendered.isEmpty || Self.isAtBottom(scrollView)
            let entries = buffer.entries

            storage.beginEditing()
            if renderedPalette != palette {
                storage.setAttributedString(NSAttributedString())
                rendered.removeAll()
                renderedPalette = palette
            }

            // Lines trimmed off the top of the buffer.
            let firstID = entries.first?.id ?? Int.max
            var dropCount = 0
            var dropLength = 0
            while dropCount < rendered.count, rendered[dropCount].id < firstID {
                dropLength += rendered[dropCount].length
                dropCount += 1
            }
            if dropCount > 0 {
                storage.deleteCharacters(in: NSRange(location: 0, length: dropLength))
                rendered.removeFirst(dropCount)
            }

            // If the two lists ever disagree, start over rather than show a scrambled log.
            // (Entry ids are consecutive and only ever trimmed from the front, so matching first ids and
            // counts mean every rendered line lines up with its entry.)
            if let first = rendered.first, first.id != entries.first?.id || rendered.count > entries.count {
                storage.setAttributedString(NSAttributedString())
                rendered.removeAll()
            }

            // Lines rewritten in place (progress frames), only ever near the end.
            let window = max(0, rendered.count - 80)
            var location = storage.length - rendered[window...].reduce(0) { $0 + $1.length }
            for index in window..<rendered.count {
                let entry = entries[index]
                if entry.version != rendered[index].version {
                    let text = Self.attributed(entry, palette: palette)
                    storage.replaceCharacters(in: NSRange(location: location, length: rendered[index].length), with: text)
                    rendered[index] = (entry.id, entry.version, text.length)
                }
                location += rendered[index].length
            }

            // New lines.
            if rendered.count < entries.count {
                let added = NSMutableAttributedString()
                for entry in entries[rendered.count...] {
                    let text = Self.attributed(entry, palette: palette)
                    added.append(text)
                    rendered.append((entry.id, entry.version, text.length))
                }
                storage.append(added)
            }
            storage.endEditing()

            if follow {
                textView.scrollToEndOfDocument(nil)
                // Once more after AppKit has laid out the new text, or the last line can end up below the fold.
                DispatchQueue.main.async { [weak textView] in textView?.scrollToEndOfDocument(nil) }
            }
        }

        static func attributed(_ entry: LogBuffer.Entry, palette: Palette) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            // Wrapped continuation lines sit under the text, not under the first character.
            paragraph.headIndent = Theme.monoAdvance * 11.5 * 2

            var colour = palette.text.nsColor
            var font = Theme.nsMono(11.5)
            var text = entry.text

            switch entry.kind {
            case .header:
                text = "── \(entry.text) " + String(repeating: "─", count: max(3, 48 - entry.text.count))
                colour = palette.faint.nsColor
                paragraph.paragraphSpacingBefore = 6
                paragraph.headIndent = 0
            case .line(let style):
                switch style {
                case .command: colour = palette.cyan.nsColor
                case .stdout: colour = palette.text.nsColor.withAlphaComponent(0.92)
                case .stderr: colour = palette.orange.nsColor
                case .info: colour = palette.dim.nsColor
                case .success: colour = palette.mint.nsColor
                case .warning: colour = palette.yellow.nsColor
                case .error:
                    colour = palette.red.nsColor
                    font = Theme.nsMono(11.5, .bold)
                }
                if entry.isProgress { colour = palette.pink.nsColor }
            }

            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
            return NSAttributedString(string: text + "\n", attributes: attributes)
        }
    }
}

/// The LOG panel: the text view plus a "jump to latest" control while scrolled up.
struct LogPanel: View {
    @Environment(\.palette) private var palette
    let model: InstallerModel
    @State private var isFollowing = true
    @State private var scrollRequest = 0

    var body: some View {
        TerminalPanel(title: model.runIsDryRun ? "LOG · DRY RUN" : "LOG", tint: model.runIsDryRun ? .yellow : .dim,
                      padding: Theme.Space.xs) {
            HStack(spacing: Theme.Space.m) {
                if !isFollowing {
                    Button("▼ LATEST") { scrollRequest += 1 }
                        .buttonStyle(.terminal(.link))
                        .help("Scroll to the newest output and keep following it")
                        .accessibilityLabel("Jump to the latest log line")
                }
                Button("COPY") { model.copyLog() }
                    .buttonStyle(.terminal(.link))
                    .help("Copy the log shown here")
                    .accessibilityLabel("Copy log")
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if let note = model.droppedLinesNote {
                    Text(note)
                        .font(Theme.mono(Theme.Size.caption))
                        .foregroundStyle(palette.faint.color)
                        .padding(.bottom, 2)
                }
                LogTextView(buffer: model.log, palette: palette, isFollowing: $isFollowing, scrollToEndRequest: scrollRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .edgeFade(top: 10, bottom: 0)
            }
        }
    }
}
