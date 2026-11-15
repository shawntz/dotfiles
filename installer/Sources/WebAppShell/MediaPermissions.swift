import AppKit
import WebKit

/// Camera and microphone access, asked per site. Answers last for the session, or for good when the
/// person ticks "Remember"; App ▸ Reset Camera & Microphone Permissions forgets them.
@MainActor
final class MediaPermissionStore {
    private static let key = "ShawnWebAppMediaPermissions"
    private let defaults: UserDefaults
    private var sessionDecisions: [String: Bool] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func decide(origin: WKSecurityOrigin, type: WKMediaCaptureType, appName: String, window: NSWindow?,
                completion: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let port = origin.port > 0 ? ":\(origin.port)" : ""
        let originKey = "\(origin.protocol)://\(origin.host)\(port)"
        let devices: [String]
        switch type {
        case .camera: devices = ["camera"]
        case .microphone: devices = ["microphone"]
        default: devices = ["camera", "microphone"]
        }
        let keys = devices.map { "\(originKey) \($0)" }
        let remembered = defaults.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
        let known = keys.compactMap { sessionDecisions[$0] ?? remembered[$0] }
        if known.count == keys.count {
            completion(known.allSatisfy { $0 } ? .grant : .deny)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Allow \"\(origin.host)\" to use your \(devices.joined(separator: " and "))?"
        alert.informativeText = "\(appName) only passes this on to the site while you use it."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice for \(origin.host)"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let allowed = response == .alertFirstButtonReturn
            self?.record(keys, allowed: allowed, remember: alert.suppressionButton?.state == .on)
            completion(allowed ? .grant : .deny)
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func record(_ keys: [String], allowed: Bool, remember: Bool) {
        for key in keys { sessionDecisions[key] = allowed }
        guard remember else { return }
        var remembered = defaults.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
        for key in keys { remembered[key] = allowed }
        defaults.set(remembered, forKey: Self.key)
    }

    func reset() {
        sessionDecisions.removeAll()
        defaults.removeObject(forKey: Self.key)
    }
}
