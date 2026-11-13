// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// Builds the main menu in code (no nib). Actions travel the responder chain,
/// so they reach the key `BrowserWindowController` or, failing that, the `AppDelegate`.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "NeuralBrowser")
        app.addItem(withTitle: "About NeuralBrowser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide NeuralBrowser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit NeuralBrowser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New Tab", #selector(BrowserWindowController.newTab(_:)), "t")
        item(file, "New Window", #selector(AppDelegate.newWindow(_:)), "n")
        item(file, "New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift])
        item(file, "Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l")
        file.addItem(.separator())
        item(file, "Close Tab", #selector(BrowserWindowController.closeCurrentTab(_:)), "w")
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        item(file, "Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift])
        file.addItem(.separator())
        item(file, "Install Extension…", #selector(AppDelegate.installExtension(_:)), "")
        item(file, "Extensions…", #selector(AppDelegate.showExtensions(_:)), "e", [.command, .shift])
        item(file, "Passwords…", #selector(AppDelegate.showPasswords(_:)), "p", [.command, .shift])

        let edit = submenu(main, "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find…", #selector(BrowserWindowController.findInPage(_:)), "f")
        item(edit, "Find Next", #selector(BrowserWindowController.findNext(_:)), "g")
        item(edit, "Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Fill Login", #selector(BrowserWindowController.fillLogin(_:)), "\\")
        item(edit, "Save Login…", #selector(BrowserWindowController.saveLogin(_:)), "")

        let view = submenu(main, "View")
        item(view, "Reload Page", #selector(BrowserWindowController.reload(_:)), "r")
        item(view, "Back", #selector(BrowserWindowController.goBack(_:)), "[")
        item(view, "Forward", #selector(BrowserWindowController.goForward(_:)), "]")
        view.addItem(.separator())
        item(view, "Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+")
        item(view, "Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-")
        item(view, "Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0")
        view.addItem(.separator())
        item(view, "Block Ads and Trackers", #selector(BrowserWindowController.toggleShield(_:)), "")
        item(view, "Block Ads and Trackers on This Site", #selector(BrowserWindowController.toggleShieldForSite(_:)), "")

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        item(window, "Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\t", [.control])
        item(window, "Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\t", [.control, .shift])
        for n in 1...9 {
            let i = item(window, n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(n)")
            i.tag = n
        }
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        host.submenu = menu
        main.addItem(host)
        return menu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                             _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        menu.addItem(i)
        return i
    }
}
