// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import NeuralCore
import WebKit

/// Edit ▸ Fill Login (⌘\) and Edit ▸ Save Login… on the browser window.
/// Both only run after this user action, on https pages, in the main frame.
extension BrowserWindowController {
    /// A login offered in the chooser menu, with the URL it was looked up for.
    private final class FillChoice: NSObject {
        let id: String
        let lookedUp: URL
        init(id: String, lookedUp: URL) {
            self.id = id
            self.lookedUp = lookedUp
        }
    }

    /// True when the menu items make sense for the active tab.
    var canUseVaultOnActiveTab: Bool {
        guard app.vault != nil, let url = activeTab?.webView?.url else { return false }
        return url.scheme?.lowercased() == "https"
    }

    @objc func fillLogin(_ sender: Any?) {
        guard let vault = app.vault, let webView = activeTab?.webView else { return }
        let url = webView.url
        if let reason = VaultFill.refusal(url: url, lookedUp: nil, hasOnlySecureContent: webView.hasOnlySecureContent) {
            return showVaultMessage("Cannot fill a login", reason)
        }
        guard let url, let logins = vault.logins(for: url) else {
            app.showPasswords(nil) // locked or signed out
            return
        }
        let host = url.host() ?? ""
        switch logins.count {
        case 0:
            showVaultMessage("No saved login for \(host)",
                             "Logins are matched by the exact host name; entries for other subdomains are not offered.")
        case 1:
            performFill(id: logins[0].id, lookedUp: url)
        default:
            let menu = NSMenu(title: "Logins for \(host)")
            menu.autoenablesItems = false
            for login in logins {
                let title = login.name + (login.username.map { $0.isEmpty ? "" : " — \($0)" } ?? "")
                let item = NSMenuItem(title: title, action: #selector(fillChosenLogin(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = FillChoice(id: login.id, lookedUp: url)
                menu.addItem(item)
            }
            let y = webView.isFlipped ? 48 : webView.bounds.height - 48
            menu.popUp(positioning: nil, at: NSPoint(x: webView.bounds.midX - 120, y: y), in: webView)
        }
    }

    @objc private func fillChosenLogin(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? FillChoice else { return }
        performFill(id: choice.id, lookedUp: choice.lookedUp)
    }

    private func performFill(id: String, lookedUp: URL) {
        guard let vault = app.vault, let webView = activeTab?.webView else { return }
        // Re-check right before filling: the tab may have navigated while the chooser was open.
        if let reason = VaultFill.refusal(url: webView.url, lookedUp: lookedUp,
                                          hasOnlySecureContent: webView.hasOnlySecureContent) {
            return showVaultMessage("Nothing was filled", reason)
        }
        guard vault.isUnlocked else { app.showPasswords(nil); return }
        let username = vault.username(id: id)
        guard let password = vault.password(id: id), !password.isEmpty else {
            return showVaultMessage("This entry has no password", "Nothing was filled.")
        }
        let host = lookedUp.host() ?? ""
        Task { @MainActor [weak self] in
            do {
                let result = try await VaultFill.fill(in: webView, expected: lookedUp, username: username, password: password)
                if result.reason == "origin" {
                    self?.showVaultMessage("Nothing was filled", "The page is no longer on \(host).")
                } else if !result.password {
                    self?.showVaultMessage("No password field found",
                                           "There is no visible password field on this page (frames of other sites are never filled).")
                }
            } catch {
                self?.showVaultMessage("Filling failed", "The page did not accept the script (\(type(of: error))).")
            }
        }
    }

    @objc func saveLogin(_ sender: Any?) {
        guard let vault = app.vault, let webView = activeTab?.webView else { return }
        if let reason = VaultFill.refusal(url: webView.url, lookedUp: nil, hasOnlySecureContent: webView.hasOnlySecureContent) {
            return showVaultMessage("Cannot save a login here", reason)
        }
        guard let url = webView.url else { return }
        guard vault.isUnlocked else { app.showPasswords(nil); return }
        Task { @MainActor [weak self] in
            let values = try? await VaultFill.read(in: webView, expected: url)
            guard let self else { return }
            guard let values, !values.password.isEmpty else {
                return self.showVaultMessage("No password to save",
                                             "Type your password into the page's visible password field first, then choose Save Login… again.")
            }
            self.presentSaveSheet(url: url, username: values.username, password: values.password)
        }
    }

    /// Confirmation in the shell (SECURITY.md 4.7): nothing is saved without "Save".
    /// The password read from the page lives only in this sheet.
    private func presentSaveSheet(url: URL, username: String, password: String) {
        guard let window, let vault = app.vault else { return }
        let host = url.host() ?? ""
        let alert = NSAlert()
        alert.messageText = "Save login for \(host)?"
        alert.informativeText = "A new entry is added to your vault on \(vault.serverURL ?? "the server"). "
            + "Existing entries are not changed: if this user name is already saved for \(host), nothing is saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: host)
        let userField = NSTextField(string: username)
        let secureField = NSSecureTextField(string: password)
        let plainField = NSTextField(string: password)
        plainField.isHidden = true
        let reveal = NSButton(checkboxWithTitle: "Show password", target: nil, action: nil)
        let toggle = RevealToggle(secure: secureField, plain: plainField)
        reveal.target = toggle
        reveal.action = #selector(RevealToggle.toggle(_:))

        let passwordStack = NSStackView(views: [secureField, plainField])
        passwordStack.orientation = .vertical
        let grid = NSGridView(views: [
            [label("Site:"), NSTextField(labelWithString: host)],
            [label("Name:"), nameField],
            [label("User name:"), userField],
            [label("Password:"), passwordStack],
            [NSGridCell.emptyContentView, reveal],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for field in [nameField, userField, secureField, plainField] {
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = userField

        alert.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(toggle) {}
            let secret = plainField.isHidden ? secureField.stringValue : plainField.stringValue
            secureField.stringValue = ""
            plainField.stringValue = ""
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !secret.isEmpty else { return self.showVaultMessage("Not saved", "The password is empty.") }
            Task { @MainActor [weak self] in
                let result = await vault.saveLogin(name: name.isEmpty ? host : name, url: url, username: user, password: secret)
                switch result {
                case .saved:
                    self?.showVaultMessage("Login saved", "\(user.isEmpty ? "The login" : user) for \(host) is now in your vault.")
                case .duplicate:
                    self?.showVaultMessage("Already saved",
                                           "Your vault already has \(user.isEmpty ? "an entry without user name" : user) for \(host). "
                                           + "Updating existing entries is not supported yet; nothing was saved.")
                case .failed(let message):
                    self?.showVaultMessage("Saving failed", message)
                }
            }
        }
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    func showVaultMessage(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Swaps the dots field and the plain field of the save sheet, keeping their text in step.
@MainActor
final class RevealToggle: NSObject {
    private let secure: NSSecureTextField
    private let plain: NSTextField

    init(secure: NSSecureTextField, plain: NSTextField) {
        self.secure = secure
        self.plain = plain
    }

    @objc func toggle(_ sender: NSButton) {
        let show = sender.state == .on
        if show { plain.stringValue = secure.stringValue } else { secure.stringValue = plain.stringValue }
        plain.isHidden = !show
        secure.isHidden = show
    }
}
