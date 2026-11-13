// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import NeuralCore

/// The built-in Vaultwarden/Bitwarden client (docs/SECURITY.md 4.7). The Rust core
/// (`Vault`) does all cryptography and builds/parses every HTTP message; this class only
/// sends them, keeps the session state for the UI and locks the vault when idle.
///
/// Stored in settings (not secret): server address, e-mail, a random device id.
/// Never stored or logged: master password, codes, requests, responses, passwords.
@MainActor
final class VaultService {
    /// What a sign-in attempt ended in, for the UI to act on.
    enum SignInResult {
        case success(SyncSummary)
        case twoFactorRequired(providers: [TwoFactorProvider], unsupported: [String])
        case invalidCredentials
        case invalidTwoFactorCode
        /// The server's KDF settings are below the minimums; retry with `allowWeakKdf` only after the user confirmed.
        case weakKdf(KdfSettings)
        case failed(String)
    }

    enum SaveResult {
        case saved(LoginSummary)
        case duplicate
        case failed(String)
    }

    static let didChange = Notification.Name("NeuralBrowserVaultDidChange")
    /// SECURITY.md 4.7: lock after this long without use.
    static let defaultIdleTimeout: TimeInterval = 15 * 60

    private let settings: BrowserStore?
    private let session: URLSession
    /// Signed in and unlocked (after a successful sync).
    private var vault: Vault?
    /// Sign-in in progress (between prelogin and a successful login; needed for two-factor).
    private var pending: Vault?
    private(set) var lastSync: SyncSummary?
    private(set) var busy = false
    var idleTimeout = VaultService.defaultIdleTimeout
    private var lastUse = Date()
    private var idleTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// `settings` nil: nothing is persisted.
    init(settings: BrowserStore?) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
        observeLockEvents()
    }

    // MARK: State

    var isUnlocked: Bool { vault?.isUnlocked() ?? false }
    /// Normalised address of the signed-in server (show it in full).
    var serverURL: String? { vault?.serverUrl() }
    var accountEmail: String? { vault?.email() }

    var savedServer: String { setting(SettingKey.vaultServer) ?? "" }
    var savedEmail: String { setting(SettingKey.vaultEmail) ?? "" }

    private var deviceId: String {
        if let id = setting(SettingKey.vaultDeviceId), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try? settings?.setSetting(key: SettingKey.vaultDeviceId, value: id)
        return id
    }

    private func setting(_ key: String) -> String? { (try? settings?.getSetting(key: key)) ?? nil }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Counts as use for the idle lock.
    private func touch() { lastUse = Date() }

    // MARK: Sign in

    /// Prelogin -> login -> sync. With `twoFactor`, continues the sign-in that asked for it
    /// (same server and e-mail). The master password is only passed through to the core.
    func signIn(server: String, email: String, masterPassword: String,
                twoFactor: TwoFactorCode? = nil, allowWeakKdf: Bool = false) async -> SignInResult {
        guard !busy else { return .failed("A sign-in is already running.") }
        busy = true
        defer { busy = false; changed() }
        touch()
        // A new sign-in replaces the current session; a pending two-factor sign-in stays.
        vault?.lock()
        vault = nil
        lastSync = nil

        let account: Vault
        if twoFactor != nil, let p = pending,
           p.email() == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            account = p
        } else {
            pending = nil
            do {
                account = try Vault(serverUrl: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                    email: email, deviceId: deviceId)
            } catch {
                return .failed(report(error, step: "Server address", status: nil))
            }
            let (prelogin, status) = await exchange(account.preloginRequest(), step: "Prelogin")
            guard let prelogin else { return .failed(status.text) }
            do {
                _ = try account.handlePrelogin(response: prelogin, allowWeakKdf: allowWeakKdf)
            } catch VaultError.WeakKdf(let settings) {
                return .weakKdf(settings)
            } catch {
                return .failed(report(error, step: "Prelogin", status: prelogin.status))
            }
            pending = account
        }

        // Key derivation takes up to seconds: off the main thread.
        let request: HttpRequest
        do {
            request = try await Task.detached(priority: .userInitiated) {
                try account.loginRequest(masterPassword: masterPassword, twoFactor: twoFactor)
            }.value
        } catch {
            return .failed(report(error, step: "Key derivation", status: nil))
        }
        let (response, status) = await exchange(request, step: "Sign-in")
        guard let response else { return .failed(status.text) }
        let outcome: LoginOutcome
        do {
            outcome = try account.handleLogin(response: response)
        } catch {
            return .failed(report(error, step: "Sign-in", status: response.status))
        }
        switch outcome {
        case .success:
            break
        case .twoFactorRequired(let providers, let unsupported):
            return .twoFactorRequired(providers: providers, unsupported: unsupported)
        case .invalidCredentials:
            pending = nil
            return .invalidCredentials
        case .invalidTwoFactorCode:
            return .invalidTwoFactorCode
        case .serverError(let code, let message):
            return .failed(log("Sign-in failed: HTTP \(code)\(message.isEmpty ? "" : ": \(message)")"))
        }

        pending = nil
        vault = account
        try? settings?.setSetting(key: SettingKey.vaultServer, value: account.serverUrl())
        try? settings?.setSetting(key: SettingKey.vaultEmail, value: account.email())
        startIdleTimer()
        switch await runSync(account) {
        case .success(let summary): return .success(summary)
        case .failure(let message):
            // Signed in but nothing loaded: do not keep a half-working session.
            lockNow(notify: false)
            return .failed(message.text)
        }
    }

    /// Asks the server to send (again) the e-mail code of the sign-in in progress.
    func requestEmailCode() async -> String? {
        guard let account = pending else { return "Sign in with your master password first." }
        let request: HttpRequest
        do { request = try account.sendEmailCodeRequest() } catch {
            return report(error, step: "Send e-mail code", status: nil)
        }
        let (response, status) = await exchange(request, step: "Send e-mail code")
        guard let response else { return status.text }
        do { try account.handleSendEmailCode(response: response) } catch {
            return report(error, step: "Send e-mail code", status: response.status)
        }
        return nil
    }

    /// Reloads all entries from the server. Returns an error text or nil.
    func sync() async -> String? {
        guard let account = vault, account.isUnlocked() else { return "The vault is locked. Sign in again." }
        guard !busy else { return "Busy, try again in a moment." }
        busy = true
        defer { busy = false; changed() }
        touch()
        if case .failure(let message) = await runSync(account) { return message.text }
        return nil
    }

    private struct Message: Error { let text: String }

    private func runSync(_ account: Vault) async -> Result<SyncSummary, Message> {
        let request: HttpRequest
        do { request = try account.syncRequest() } catch {
            return .failure(Message(text: report(error, step: "Sync", status: nil)))
        }
        let (response, status) = await exchange(request, step: "Sync")
        guard let response else { return .failure(status) }
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try account.handleSync(response: response)
            }.value
            lastSync = summary
            return .success(summary)
        } catch {
            return .failure(Message(text: report(error, step: "Sync", status: response.status)))
        }
    }

    // MARK: Lookups (only while unlocked)

    /// All loaded logins (sorted by the core).
    func allLogins() -> [LoginSummary] {
        guard let account = vault, account.isUnlocked() else { return [] }
        touch()
        return (try? account.allLogins()) ?? []
    }

    /// Logins for a page (https, host-exact). nil when locked or signed out.
    func logins(for url: URL) -> [LoginSummary]? {
        guard let account = vault, account.isUnlocked() else { return nil }
        touch()
        return (try? account.loginsForUrl(url: url.absoluteString)) ?? []
    }

    func username(id: String) -> String? {
        guard let account = vault, account.isUnlocked() else { return nil }
        touch()
        return (try? account.username(id: id)) ?? nil
    }

    /// Decrypts one password. Call only for a user action (fill).
    func password(id: String) -> String? {
        guard let account = vault, account.isUnlocked() else { return nil }
        touch()
        return (try? account.password(id: id)) ?? nil
    }

    /// True if an entry for this page's host already has this user name (case-insensitive).
    func hasLogin(for url: URL, username: String) -> Bool {
        let wanted = username.lowercased()
        return (logins(for: url) ?? []).contains { ($0.username ?? "").lowercased() == wanted }
    }

    /// Adds a new login (only after the user confirmed in the shell). Never updates existing entries.
    func saveLogin(name: String, url: URL, username: String, password: String) async -> SaveResult {
        guard let account = vault, account.isUnlocked() else { return .failed("The vault is locked. Sign in again.") }
        touch()
        if hasLogin(for: url, username: username) { return .duplicate }
        // Only the page's origin is stored, not its path or query.
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host()
        parts.port = url.port
        let site = parts.url?.absoluteString ?? url.absoluteString
        let request: HttpRequest
        do {
            request = try account.addLoginRequest(name: name, url: site, username: username, password: password)
        } catch {
            return .failed(report(error, step: "Save", status: nil))
        }
        let (response, status) = await exchange(request, step: "Save")
        guard let response else { return .failed(status.text) }
        do {
            let summary = try account.handleAddLogin(response: response)
            changed()
            return .saved(summary)
        } catch {
            return .failed(report(error, step: "Save", status: response.status))
        }
    }

    // MARK: Locking

    func lock() { lockNow(notify: true) }

    private func lockNow(notify: Bool) {
        let wasOpen = vault != nil || pending != nil
        vault?.lock()
        pending?.lock()
        vault = nil
        pending = nil
        lastSync = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if notify, wasOpen {
            NSLog("NeuralBrowser vault: locked")
            changed()
        }
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        // Checked against wall-clock time, so time spent asleep counts too.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastUse) >= self.idleTimeout { self.lock() }
            }
        }
    }

    private func observeLockEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        observers.append((distributed, token))
    }

    // MARK: Network

    /// Sends one request built by the core. Returns the response (any HTTP status; the core
    /// interprets it) or nil and a safe error text (step, transport error; never the content).
    private func exchange(_ request: HttpRequest, step: String) async -> (HttpResponse?, Message) {
        guard let url = URL(string: request.url), url.scheme == "https" else {
            return (nil, Message(text: log("\(step) failed: the core built a non-https URL")))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for header in request.headers { urlRequest.setValue(header.value, forHTTPHeaderField: header.name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return (nil, Message(text: log("\(step) failed: no HTTP answer from \(url.host() ?? "?")")))
            }
            return (HttpResponse(status: UInt16(clamping: http.statusCode), body: data), Message(text: ""))
        } catch let error as URLError {
            return (nil, Message(text: log("\(step) failed: \(url.host() ?? "?"): \(error.localizedDescription) (URLError \(error.code.rawValue))")))
        } catch {
            return (nil, Message(text: log("\(step) failed: \(type(of: error))")))
        }
    }

    /// A safe, specific error text: step, HTTP status and the core's message (which never
    /// contains request content). Also written to the system log.
    private func report(_ error: Error, step: String, status: UInt16?) -> String {
        let http = status.map { " (HTTP \($0))" } ?? ""
        return log("\(step) failed\(http): \(Self.describe(error))")
    }

    @discardableResult
    private func log(_ text: String) -> String {
        NSLog("NeuralBrowser vault: %@", text)
        return text
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? VaultError else { return "\(type(of: error))" }
        switch error {
        case .InvalidServerUrl(let reason): return "server address not usable: \(reason)"
        case .InvalidArgument(let message): return message
        case .WeakKdf: return "the server's key derivation settings are too weak"
        case .UnsupportedKdf(let message): return "key derivation settings not supported: \(message)"
        case .WrongState(let message): return "internal order error: \(message)"
        case .Locked: return "the vault is locked, sign in again"
        case .Unauthorized: return "the server rejected the session (HTTP 401), sign in again"
        case .Server(let status, let message): return "HTTP \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .InvalidResponse(let message): return "unexpected answer from the server: \(message)"
        case .Crypto(let message): return "decryption failed: \(message)"
        case .NotFound: return "entry not found"
        case .Internal(let message): return "internal error: \(message)"
        }
    }
}

/// Follows a redirect only to the same https host and port (e.g. a proxy adding a slash);
/// anything else is not followed and the 3xx answer goes to the core as an error.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url
        let to = request.url
        let same = to?.scheme == "https" && from?.host()?.lowercased() == to?.host()?.lowercased() && from?.port == to?.port
        completionHandler(same ? request : nil)
    }
}
