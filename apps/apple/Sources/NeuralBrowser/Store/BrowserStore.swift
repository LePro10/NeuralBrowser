// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// The persistence boundary of the shell. It mirrors the API offered by the
// Rust core (`core/store`), so a UniFFI-backed implementation can replace
// `JSONBrowserStore` later without touching UI code.

struct HistoryEntry: Codable, Equatable {
    var id: Int64
    var url: String
    var title: String
    var lastVisitMs: Int64
    var visitCount: Int64
}

struct Bookmark: Codable, Equatable {
    var id: Int64
    var url: String
    var title: String
    var folderId: Int64?
    var createdMs: Int64
}

struct TabState: Codable, Equatable {
    var id: String
    var url: String
    var title: String
    var pinned: Bool
    var position: Int
    var lastActiveMs: Int64
}

struct SessionState: Codable, Equatable {
    var tabs: [TabState]
    var activeTabId: String?
}

enum SuggestionKind: String, Codable {
    case history
    case bookmark
}

struct Suggestion: Codable, Equatable {
    var url: String
    var title: String
    var kind: SuggestionKind
    var score: Double
}

protocol BrowserStore: AnyObject {
    // History
    func recordVisit(url: String, title: String, timestampMs: Int64) throws
    func updateTitle(url: String, title: String) throws
    func recentHistory(limit: Int) throws -> [HistoryEntry]
    func searchHistory(query: String, limit: Int) throws -> [HistoryEntry]

    // Bookmarks
    @discardableResult
    func addBookmark(url: String, title: String, folderId: Int64?) throws -> Int64
    func removeBookmark(id: Int64) throws
    func listBookmarks(folderId: Int64?) throws -> [Bookmark]
    func isBookmarked(url: String) throws -> Bool

    // Session
    func saveSession(tabs: [TabState], activeTabId: String?) throws
    func loadSession() throws -> SessionState?

    // Settings
    func getSetting(key: String) throws -> String?
    func setSetting(key: String, value: String) throws

    // Suggestions and input
    func suggest(query: String, limit: Int) throws -> [Suggestion]
    func resolveInput(text: String, searchTemplate: String) -> String

    /// Writes pending changes to disk. Called on quit.
    func flush()
}

enum SettingKey {
    static let searchTemplate = "search.template"
    static let sleepAfterMinutes = "tabs.sleepAfterMinutes"
    static func extensionGrant(_ id: String) -> String { "extensions.grant.\(id)" }
}

enum Defaults {
    static let searchTemplate = "https://duckduckgo.com/?q=%s"
    static let sleepAfterMinutes = 15.0
}

extension BrowserStore {
    var searchTemplate: String {
        ((try? getSetting(key: SettingKey.searchTemplate)) ?? nil) ?? Defaults.searchTemplate
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
