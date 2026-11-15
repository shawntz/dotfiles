import AppKit
import ShawnCore
import SwiftUI

/// The application delegate: one window, standard menus, and a confirmation before quitting mid-run.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: LaunchOptions
    private let registry: ActionRegistry
    /// Made at launch (tests set it directly).
    var model: InstallerModel?
    /// Asks whether to stop the run and quit. An alert in the app; tests answer it themselves.
    var confirmQuit: @MainActor () -> Bool = AppController.runQuitAlert
    /// Answers a `.terminateLater`. Tests record the answer instead of quitting.
    var replyToTerminateRequest: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    private var window: NSWindow?
    private var simulationScratch: URL?
    private var isQuittingAfterStop = false
    private var hasRepliedToTerminate = false

    init(options: LaunchOptions, registry: ActionRegistry) {
        self.options = options
        self.registry = registry
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model: InstallerModel
        do {
            model = try makeModel()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Shawn's Dotfiles could not start"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.model = model
        NSApp.mainMenu = Self.makeMainMenu(appName: "Shawn's Dotfiles")

        let window = Self.makeWindow(rootView: RootView(model: model))
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        if model.phase == .loading { model.loadConfig() }
    }

    private func makeModel() throws -> InstallerModel {
        if options.simulate {
            let scratch = try Simulation.makeScratchDirectory()
            simulationScratch = scratch
            let model = try SnapshotCommand.makeSimulationModel(options: options, scratch: scratch, mode: .simulation)
            model.desktop = Self.narrating(into: model)
            return model
        }
        let environment = try AppEnvironment.make(options: options)
        return InstallerModel(registry: registry, environment: environment,
                              resolveOptions: AppEnvironment.resolveOptions(options: options),
                              settings: InstallerModel.Settings(options: options, mode: .live), dryRun: options.startsInDryRun,
                              desktop: .live, keepAwake: .live,
                              quipSeed: Int.random(in: 0..<10_000))
    }

    /// In the simulation, clipboard and browser actions are described in the log instead of performed.
    private static func narrating(into model: InstallerModel) -> DesktopActions {
        DesktopActions(
            copyToPasteboard: { [weak model] text in
                model?.narrate("[simulation] would copy \(text.count > 40 ? "\(text.count) characters" : "\"\(text)\"") to the clipboard")
            },
            open: { [weak model] url in model?.narrate("[simulation] would open \(url.absoluteString)") },
            reveal: { [weak model] url in model?.narrate("[simulation] would reveal \(url.path) in Finder") }
        )
    }

    // MARK: Quitting

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRunning else { return .terminateNow }
        if isQuittingAfterStop { return .terminateLater }
        guard confirmQuit() else { return .terminateCancel }
        // The alert is modal, but the run's events keep arriving behind it: if the run ended while the
        // person read it, there is nothing left to stop and no `.runFinished` still to come to wait for.
        guard model.isRunning else { return .terminateNow }

        isQuittingAfterStop = true
        model.onRunFinished = { [weak self] in self?.replyToTerminate() }
        model.stop()
        // An item that ignores cancellation must not keep the app open forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.replyToTerminate()
        }
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        replyToTerminateRequest(true)
    }

    private static func runQuitAlert() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop the install and quit?"
        alert.informativeText = "The current item is stopped. Everything already done stays done, and running the installer again picks up where it left off."
        let stop = alert.addButton(withTitle: "Stop & Quit")
        stop.hasDestructiveAction = true
        alert.addButton(withTitle: "Keep Running")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.isRunning == true else { return true }
        // Closing the only window quits; route through the same confirmation.
        NSApp.terminate(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normally released when the run finishes; this covers quitting before the stop wound down.
        model?.stopKeepingAwake()
        if let simulationScratch { Simulation.cleanUp(simulationScratch) }
    }

    // MARK: Window & menus

    static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.defaultWindowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Shawn's Dotfiles"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.standard.background.nsColor
        window.contentMinSize = Theme.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let host = NSHostingView(rootView: rootView)
        // The window decides its own size; the SwiftUI content just fills it.
        host.sizingOptions = []
        window.contentView = host
        window.center()
        return window
    }

    static func makeMainMenu(appName: String) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(appMenu))

        // Needed for ⌘V in the password field and ⌘C in the log.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
