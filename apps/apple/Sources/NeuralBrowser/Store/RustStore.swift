// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import NeuralCore

/// `BrowserStore` backed by the Rust core (SQLite). Core errors are logged and
/// never crash the app: queued writes drop the failed operation, reads throw
/// (callers use `try?` and carry on with defaults).
///
/// Threading: the Rust `Store` is thread-safe (one connection behind a mutex).
/// Frequent writes go through a serial utility queue so the main thread never
/// waits for the disk; suggestions are computed on a concurrent queue.
final class RustStore: BrowserStore, @unchecked Sendable {
    private let core: NeuralCore.Store
    private let writeQueue = DispatchQueue(label: "org.neuralbrowser.store.write", qos: .utility)
    private let readQueue = DispatchQueue(label: "org.neuralbrowser.store.read", qos: .userInitiated)
    /// Set when the on-disk database could not be opened and memory is used instead.
    let isFallback: Bool

    /// Opens (or creates) the database file. If that fails (corrupt file, no
    /// permission, ...) the error is logged and a throw-away in-memory store is
    /// used so the browser still works.
    convenience init(databaseURL: URL) {
        var fallback = false
        var opened: NeuralCore.Store?
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            opened = try NeuralCore.Store.open(path: databaseURL.path)
        } catch {
            NSLog("NeuralBrowser: cannot open database \(databaseURL.path): \(error). Using memory.")
            fallback = true
        }
        self.init(core: opened ?? RustStore.memoryStore(), isFallback: fallback)
    }

    private init(core: NeuralCore.Store, isFallback: Bool) {
        self.core = core
        self.isFallback = isFallback
    }

    /// A store that keeps everything in memory (self tests; nothing is persisted).
    static func inMemory() -> RustStore {
        RustStore(core: memoryStore(), isFallback: false)
    }

    private static func memoryStore() -> NeuralCore.Store {
        do {
            return try NeuralCore.Store.openInMemory()
        } catch {
            // Opening ":memory:" cannot realistically fail; nothing sensible is left to do.
            fatalError("NeuralBrowser: in-memory database failed: \(error)")
        }
    }

    private func logged<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            NSLog("NeuralBrowser: store.\(what) failed: \(error)")
            throw error
        }
    }

    private func queued(_ what: String, _ body: @escaping () throws -> Void) {
        writeQueue.async { try? self.logged(what, body) }
    }

    // MARK: History

    func recordVisit(url: String, title: String, timestampMs: Int64) {
        queued("recordVisit") { try self.core.recordVisit(url: url, title: title, timestampMs: timestampMs) }
    }

    func updateTitle(url: String, title: String) {
        queued("updateTitle") { try self.core.updateTitle(url: url, title: title) }
    }

    func recentHistory(limit: UInt32) throws -> [HistoryEntry] {
        try logged("recentHistory") { try core.recentHistory(limit: limit) }
    }

    func searchHistory(query: String, limit: UInt32) throws -> [HistoryEntry] {
        try logged("searchHistory") { try core.searchHistory(query: query, limit: limit) }
    }

    // MARK: Bookmarks

    func addBookmark(url: String, title: String, folderId: Int64?) throws -> Bookmark {
        try logged("addBookmark") { try core.addBookmark(url: url, title: title, folderId: folderId) }
    }

    func removeBookmark(id: Int64) throws {
        try logged("removeBookmark") { try core.removeBookmark(id: id) }
    }

    func listBookmarks(folderId: Int64?) throws -> [Bookmark] {
        try logged("listBookmarks") { try core.listBookmarks(folderId: folderId) }
    }

    func isBookmarked(url: String) throws -> Bool {
        try logged("isBookmarked") { try core.isBookmarked(url: url) }
    }

    // MARK: Session

    func saveSession(tabs: [TabState], activeTabId: String?) {
        queued("saveSession") { try self.core.saveSession(tabs: tabs, activeTabId: activeTabId) }
    }

    func loadSession() throws -> Session {
        try logged("loadSession") { try core.loadSession() }
    }

    // MARK: Settings

    func getSetting(key: String) throws -> String? {
        try logged("getSetting") { try core.getSetting(key: key) }
    }

    func setSetting(key: String, value: String) throws {
        try logged("setSetting") { try core.setSetting(key: key, value: value) }
    }

    // MARK: Suggestions and input

    func suggest(query: String, limit: UInt32, completion: @escaping ([Suggestion]) -> Void) {
        readQueue.async {
            let result = (try? self.logged("suggest") { try self.core.suggest(query: query, limit: limit) }) ?? []
            DispatchQueue.main.async { completion(result) }
        }
    }

    func resolveInput(text: String, searchTemplate: String) -> String {
        NeuralCore.resolveInput(text: text, searchTemplate: searchTemplate)
    }

    func flush() {
        writeQueue.sync {}
    }
}
