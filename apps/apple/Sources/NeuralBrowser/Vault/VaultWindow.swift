// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import NeuralCore

/// File ▸ Passwords… (⇧⌘P): sign in to a Vaultwarden/Bitwarden server, then a searchable
/// list of the logins (name, user name, owner; never a password) with Sync and Lock.
@MainActor
final class VaultWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate {
    private let vault: VaultService
    private var observer: NSObjectProtocol?

    // Signed out
    private let signedOutView = NSView()
    private let serverField = NSTextField()
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let methodPopup = NSPopUpButton()
    private let sendCodeButton = NSButton(title: "Send Code", target: nil, action: nil)
    private let codeField = NSTextField()
    private let twoFactorNote = NSTextField(wrappingLabelWithString: "")
    private let signInButton = NSButton(title: "Sign In", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var twoFactorRows: [NSGridRow] = []
    private var offeredProviders: [TwoFactorProvider] = []

    // Signed in
    private let signedInView = NSView()
    private let serverValue = NSTextField(labelWithString: "")
    private let accountValue = NSTextField(labelWithString: "")
    private let countValue = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let listStatus = NSTextField(labelWithString: "")
    private let syncButton = NSButton(title: "Sync", target: nil, action: nil)
    private let lockButton = NSButton(title: "Lock", target: nil, action: nil)
    private var allRows: [LoginSummary] = []
    private var rows: [LoginSummary] = []

    init(vault: VaultService) {
        self.vault = vault
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Passwords"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.setFrameAutosaveName("PasswordsWindow")
        super.init(window: window)
        window.delegate = self
        let root = NSView()
        window.contentView = root
        for v in [signedOutView, signedInView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                v.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            ])
        }
        buildSignedOut()
        buildSignedIn()
        observer = NotificationCenter.default.addObserver(forName: VaultService.didChange, object: vault, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if !window.setFrameUsingName("PasswordsWindow") { window.center() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func buildSignedOut() {
        let title = NSTextField(labelWithString: "Sign in to your Vaultwarden or Bitwarden server")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let intro = NSTextField(wrappingLabelWithString:
            "The address must start with https:// and is shown here in full. The master password is never stored; "
            + "you sign in again after locking or restarting the browser.")
        intro.textColor = .secondaryLabelColor

        serverField.placeholderString = "https://vault.example.com"
        emailField.placeholderString = "you@example.com"
        passwordField.placeholderString = "Master password"
        codeField.placeholderString = "Code"
        for f in [serverField, emailField, passwordField, codeField] {
            f.delegate = self
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        methodPopup.target = self
        methodPopup.action = #selector(methodChanged(_:))
        sendCodeButton.target = self
        sendCodeButton.action = #selector(sendCode(_:))
        let methodRow = NSStackView(views: [methodPopup, sendCodeButton])
        twoFactorNote.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label("Server:"), serverField],
            [label("E-mail:"), emailField],
            [label("Master password:"), passwordField],
            [label("Two-step login:"), methodRow],
            [label("Code:"), codeField],
            [NSGridCell.emptyContentView, twoFactorNote],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        twoFactorRows = [grid.row(at: 3), grid.row(at: 4), grid.row(at: 5)]

        signInButton.target = self
        signInButton.action = #selector(signIn(_:))
        signInButton.keyEquivalent = "\r"
        signInButton.bezelStyle = .push
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spinner, statusLabel, NSView(), signInButton])
        bottom.alignment = .top
        bottom.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, intro, grid, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        signedOutView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: signedOutView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: signedOutView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: signedOutView.topAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        showTwoFactor(nil)
    }

    private func buildSignedIn() {
        serverValue.isSelectable = true
        accountValue.isSelectable = true
        serverValue.lineBreakMode = .byCharWrapping
        countValue.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [label("Server:"), serverValue],
            [label("Account:"), accountValue],
            [label("Logins:"), countValue],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        searchField.placeholderString = "Search by name or user name"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true

        for (id, title, width) in [("name", "Name", 220.0), ("user", "User Name", 200.0), ("owner", "Owner", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        syncButton.target = self
        syncButton.action = #selector(syncNow(_:))
        lockButton.target = self
        lockButton.action = #selector(lockNow(_:))
        listStatus.textColor = .secondaryLabelColor
        listStatus.lineBreakMode = .byTruncatingTail
        listStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [listStatus, NSView(), syncButton, lockButton])

        let stack = NSStackView(views: [grid, searchField, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        signedInView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: signedInView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: signedInView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: signedInView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: signedInView.bottomAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            serverValue.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    // MARK: State

    func refresh() {
        let unlocked = vault.isUnlocked
        signedOutView.isHidden = unlocked
        signedInView.isHidden = !unlocked
        if unlocked {
            serverValue.stringValue = vault.serverURL ?? ""
            accountValue.stringValue = vault.accountEmail ?? ""
            allRows = vault.allLogins()
            var text = "\(allRows.count)"
            if let s = vault.lastSync {
                if s.undecryptable > 0 {
                    let reasons = s.undecryptableReasons.map { "\($0.reason): \($0.count)" }.joined(separator: ", ")
                    text += " · \(s.undecryptable) could not be decrypted (\(reasons))"
                }
                if s.skippedOtherTypes > 0 { text += " · \(s.skippedOtherTypes) other items (notes, cards, …) not shown" }
            }
            countValue.stringValue = text
            applySearch()
            syncButton.isEnabled = !vault.busy
            lockButton.isEnabled = !vault.busy
            passwordField.stringValue = ""
            codeField.stringValue = ""
        } else {
            allRows = []
            rows = []
            table.reloadData()
            if serverField.stringValue.isEmpty { serverField.stringValue = vault.savedServer }
            if emailField.stringValue.isEmpty { emailField.stringValue = vault.savedEmail }
            setBusy(vault.busy)
        }
    }

    private func setBusy(_ busy: Bool, _ text: String? = nil) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        for c in [serverField, emailField, passwordField, codeField] as [NSControl] { c.isEnabled = !busy }
        signInButton.isEnabled = !busy
        sendCodeButton.isEnabled = !busy
        methodPopup.isEnabled = !busy
        if let text { setStatus(text, error: false) }
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    /// Shows or hides the two-factor rows. nil hides them (new sign-in).
    private func showTwoFactor(_ providers: [TwoFactorProvider]?, unsupported: [String] = []) {
        offeredProviders = providers ?? []
        twoFactorRows.forEach { $0.isHidden = providers == nil }
        methodPopup.removeAllItems()
        for p in offeredProviders {
            methodPopup.addItem(withTitle: p == .authenticator ? "Authenticator app" : "E-mail code")
        }
        var note = ""
        if providers != nil {
            note = offeredProviders.isEmpty
                ? "Your account only offers two-step methods this browser does not support yet."
                : "Enter the code, then choose Sign In again."
            if !unsupported.isEmpty { note += " Not supported here: \(unsupported.joined(separator: ", "))." }
        }
        twoFactorNote.stringValue = note
        methodChanged(nil)
    }

    private var selectedProvider: TwoFactorProvider? {
        let i = methodPopup.indexOfSelectedItem
        return i >= 0 && i < offeredProviders.count ? offeredProviders[i] : nil
    }

    // MARK: Actions

    @objc private func methodChanged(_ sender: Any?) {
        sendCodeButton.isHidden = selectedProvider != .email
    }

    @objc private func signIn(_ sender: Any?) {
        signIn(allowWeakKdf: false)
    }

    private func signIn(allowWeakKdf: Bool) {
        let server = serverField.stringValue
        let email = emailField.stringValue
        guard !server.isEmpty, !email.isEmpty, !passwordField.stringValue.isEmpty else {
            return setStatus("Enter the server address, your e-mail and your master password.", error: true)
        }
        var twoFactor: TwoFactorCode?
        if !offeredProviders.isEmpty {
            let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
            guard let provider = selectedProvider, !code.isEmpty else {
                return setStatus("Enter the code from your second step.", error: true)
            }
            twoFactor = TwoFactorCode(provider: provider, code: code)
        }
        setBusy(true, "Signing in… deriving the key can take a few seconds.")
        // The password is read from the field for this call only; it is not kept anywhere else.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.vault.signIn(server: server, email: email, masterPassword: self.passwordField.stringValue,
                                                 twoFactor: twoFactor, allowWeakKdf: allowWeakKdf)
            self.setBusy(false)
            self.handle(result)
        }
    }

    private func handle(_ result: VaultService.SignInResult) {
        switch result {
        case .success(let summary):
            passwordField.stringValue = ""
            codeField.stringValue = ""
            showTwoFactor(nil)
            setStatus("", error: false)
            refresh()
            listStatus.stringValue = "Signed in, \(summary.logins) logins loaded."
        case .twoFactorRequired(let providers, let unsupported):
            showTwoFactor(providers, unsupported: unsupported)
            setStatus("This account uses two-step login.", error: false)
            window?.makeFirstResponder(codeField)
        case .invalidCredentials:
            passwordField.stringValue = ""
            showTwoFactor(nil)
            setStatus("Wrong e-mail or master password.", error: true)
            window?.makeFirstResponder(passwordField)
        case .invalidTwoFactorCode:
            codeField.stringValue = ""
            setStatus("The code was not accepted. Try a new one.", error: true)
            window?.makeFirstResponder(codeField)
        case .weakKdf(let settings):
            confirmWeakKdf(settings)
        case .failed(let message):
            setStatus(message, error: true)
        }
    }

    private func confirmWeakKdf(_ s: KdfSettings) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Weak protection of your vault"
        let detail: String
        switch s.algorithm {
        case .pbkdf2Sha256:
            detail = "PBKDF2 with \(s.iterations.formatted()) iterations (at least 600,000 are recommended)"
        case .argon2id:
            detail = "Argon2id with \(s.memoryMib ?? 0) MiB and \(s.iterations) iterations (at least 19 MiB and 2 iterations are recommended)"
        }
        alert.informativeText = "The server says your account uses \(detail). With weak settings, someone who gets a copy "
            + "of your vault can guess the master password much faster. A wrong or hostile server could also report weak "
            + "settings on purpose.\n\nBetter: raise the setting in the web vault (Settings ▸ Security ▸ Keys) and sign in again."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign In Anyway")
        setStatus("Sign-in stopped: weak key derivation settings.", error: true)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.signIn(allowWeakKdf: true)
        }
    }

    @objc private func sendCode(_ sender: Any?) {
        setBusy(true, "Asking the server to send a code…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let error = await self.vault.requestEmailCode()
            self.setBusy(false)
            if let error { self.setStatus(error, error: true) } else { self.setStatus("Code sent. Check your e-mail.", error: false) }
        }
    }

    @objc private func syncNow(_ sender: Any?) {
        syncButton.isEnabled = false
        listStatus.stringValue = "Syncing…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let error = await self.vault.sync()
            self.refresh()
            self.listStatus.stringValue = error ?? "Synced."
            self.listStatus.textColor = error == nil ? .secondaryLabelColor : .systemRed
        }
    }

    @objc private func lockNow(_ sender: Any?) {
        vault.lock()
        setStatus("Locked. Sign in again to use your passwords.", error: false)
    }

    @objc private func searchChanged(_ sender: Any?) { applySearch() }

    private func applySearch() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = q.isEmpty ? allRows : allRows.filter {
            $0.name.lowercased().contains(q) || ($0.username ?? "").lowercased().contains(q)
        }
        table.reloadData()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let field = obj.object as? NSTextField
        // Another server or account starts a new sign-in.
        if field === serverField || field === emailField, !offeredProviders.isEmpty || !twoFactorRows.allSatisfy(\.isHidden) {
            showTwoFactor(nil)
            setStatus("", error: false)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier else { return nil }
        let login = rows[row]
        let text: String
        switch id.rawValue {
        case "name": text = login.name
        case "user": text = login.username ?? ""
        default: text = login.isOrganization ? "Organization" : "Personal"
        }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = text
        if id.rawValue == "owner" { cell.textField?.textColor = .secondaryLabelColor }
        return cell
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Do not leave a typed master password in a closed window.
        passwordField.stringValue = ""
        codeField.stringValue = ""
    }
}
