// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Simple `BrowserStore` that keeps everything in memory and, if a file URL is
/// given, mirrors it to a single JSON file (debounced writes). Placeholder
/// until the Rust core (SQLite) is wired in behind the same protocol.
final class JSONBrowserStore: BrowserStore {
    private struct Snapshot: Codable {
        var history: [HistoryEntry] = []
        var bookmarks: [Bookmark] = []
        var session: SessionState?
        var settings: [String: String] = [:]
        var nextId: Int64 = 1
    }

    private var data = Snapshot()
    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?
    private let historyLimit = 5000

    /// - Parameter fileURL: `nil` keeps the store purely in memory.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: raw) {
            data = decoded
        }
    }

    private func newId() -> Int64 {
        defer { data.nextId += 1 }
        return data.nextId
    }

    private func changed() {
        guard fileURL != nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func flush() {
        saveWork?.cancel()
        saveWork = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let raw = try JSONEncoder().encode(data)
            try raw.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NeuralBrowser: failed to write store: \(error)")
        }
    }

    // MARK: History

    func recordVisit(url: String, title: String, timestampMs: Int64) throws {
        if let i = data.history.firstIndex(where: { $0.url == url }) {
            data.history[i].visitCount += 1
            data.history[i].lastVisitMs = timestampMs
            if !title.isEmpty { data.history[i].title = title }
        } else {
            data.history.append(HistoryEntry(id: newId(), url: url, title: title,
                                             lastVisitMs: timestampMs, visitCount: 1))
            if data.history.count > historyLimit {
                data.history.sort { $0.lastVisitMs > $1.lastVisitMs }
                data.history.removeLast(data.history.count - historyLimit)
            }
        }
        changed()
    }

    func updateTitle(url: String, title: String) throws {
        guard !title.isEmpty, let i = data.history.firstIndex(where: { $0.url == url }),
              data.history[i].title != title else { return }
        data.history[i].title = title
        changed()
    }

    func recentHistory(limit: Int) throws -> [HistoryEntry] {
        Array(data.history.sorted { $0.lastVisitMs > $1.lastVisitMs }.prefix(limit))
    }

    func searchHistory(query: String, limit: Int) throws -> [HistoryEntry] {
        let q = query.lowercased()
        return Array(data.history
            .filter { $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q) }
            .sorted { $0.lastVisitMs > $1.lastVisitMs }
            .prefix(limit))
    }

    // MARK: Bookmarks

    func addBookmark(url: String, title: String, folderId: Int64?) throws -> Int64 {
        let id = newId()
        data.bookmarks.append(Bookmark(id: id, url: url, title: title, folderId: folderId, createdMs: nowMs()))
        changed()
        return id
    }

    func removeBookmark(id: Int64) throws {
        data.bookmarks.removeAll { $0.id == id }
        changed()
    }

    func listBookmarks(folderId: Int64?) throws -> [Bookmark] {
        data.bookmarks.filter { $0.folderId == folderId }
    }

    func isBookmarked(url: String) throws -> Bool {
        data.bookmarks.contains { $0.url == url }
    }

    // MARK: Session

    func saveSession(tabs: [TabState], activeTabId: String?) throws {
        let session = SessionState(tabs: tabs, activeTabId: activeTabId)
        guard session != data.session else { return }
        data.session = session
        changed()
    }

    func loadSession() throws -> SessionState? { data.session }

    // MARK: Settings

    func getSetting(key: String) throws -> String? { data.settings[key] }

    func setSetting(key: String, value: String) throws {
        data.settings[key] = value
        changed()
    }

    // MARK: Suggestions

    func suggest(query: String, limit: Int) throws -> [Suggestion] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let now = Double(nowMs())
        var best: [String: Suggestion] = [:]

        func matchScore(url: String, title: String) -> Double? {
            let u = url.lowercased()
            let stripped = u.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
            if stripped.hasPrefix(q) { return 3 }
            if title.lowercased().hasPrefix(q) { return 2 }
            if u.contains(q) || title.lowercased().contains(q) { return 1 }
            return nil
        }

        for h in data.history {
            guard let m = matchScore(url: h.url, title: h.title) else { continue }
            let ageDays = max(0, (now - Double(h.lastVisitMs)) / 86_400_000)
            let score = m + log2(Double(h.visitCount) + 1) * 0.5 + 1 / (1 + ageDays)
            best[h.url] = Suggestion(url: h.url, title: h.title, kind: .history, score: score)
        }
        for b in data.bookmarks {
            guard let m = matchScore(url: b.url, title: b.title) else { continue }
            let score = m + 1.5 + (best[b.url]?.score ?? 0)
            best[b.url] = Suggestion(url: b.url, title: b.title, kind: .bookmark, score: score)
        }
        return Array(best.values.sorted { $0.score > $1.score }.prefix(limit))
    }

    func resolveInput(text: String, searchTemplate: String) -> String {
        InputResolver.resolve(text, searchTemplate: searchTemplate)
    }
}
