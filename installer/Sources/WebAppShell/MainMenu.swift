import AppKit

/// The menu bar, built in code. Items without a target go to the first responder, which reaches the
/// key window's `BrowserWindowController` (it is the window's delegate).
@MainActor
enum MainMenu {
    static func make(appName: String, delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(appName, appMenu(appName: appName, delegate: delegate)))
        menu.addItem(submenu("File", fileMenu()))
        menu.addItem(submenu("Edit", editMenu()))
        menu.addItem(submenu("View", viewMenu()))
        let windowMenu = self.windowMenu()
        menu.addItem(submenu("Window", windowMenu))
        NSApp.windowsMenu = windowMenu
        return menu
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func appMenu(appName: String, delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("About \(appName)", #selector(AppDelegate.showAboutPanel(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Reset Camera & Microphone Permissions", #selector(AppDelegate.resetMediaPermissions(_:)), target: delegate))
        menu.addItem(.separator())
        let services = NSMenu()
        menu.addItem(submenu("Services", services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open in Default Browser", #selector(BrowserWindowController.openInDefaultBrowser(_:)), "o", [.command, .shift]))
        menu.addItem(item("Copy Page Address", #selector(BrowserWindowController.copyPageAddress(_:)), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Back", #selector(BrowserWindowController.goBackInHistory(_:)), "["))
        menu.addItem(item("Forward", #selector(BrowserWindowController.goForwardInHistory(_:)), "]"))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(BrowserWindowController.resetPageZoom(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomInPage(_:)), "+"))
        // ⌘= is what people actually press for "zoom in" on most keyboards.
        let zoomInAlternate = item("Zoom In", #selector(BrowserWindowController.zoomInPage(_:)), "=")
        zoomInAlternate.isHidden = true
        zoomInAlternate.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInAlternate)
        menu.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOutPage(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
