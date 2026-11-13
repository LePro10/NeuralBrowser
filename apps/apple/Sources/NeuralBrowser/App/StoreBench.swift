// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import NeuralCore

/// `--store-bench`: seeds the (in-memory) store with synthetic history and times
/// what the UI does: `suggest` while typing and `saveSession`. "mainMs" is the
/// time the main thread is blocked by the call; "latencyMs" is until the result
/// arrived / the write was done.
@MainActor
enum StoreBench {
    private static func ms(_ since: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6
    }

    static func run(on store: BrowserStore) async -> [String: Any] {
        var out: [String: Any] = [:]
        let words = ["swift", "rust", "news", "mail", "docs", "video", "shop", "maps", "wiki", "code"]
        let seedStart = DispatchTime.now()
        for i in 0..<20_000 {
            let w = words[i % words.count]
            store.recordVisit(url: "https://\(w)\(i % 997).example.com/page/\(i)",
                              title: "\(w) page \(i)", timestampMs: Int64(1_000_000 + i))
        }
        let enqueueMs = ms(seedStart)
        store.flush()
        out["seed20000VisitsEnqueueMainMs"] = enqueueMs
        out["seed20000VisitsTotalMs"] = ms(seedStart)

        var suggest: [[String: Any]] = []
        for q in ["s", "sw", "swift", "swift12", "exam", "zzzz"] {
            let t = DispatchTime.now()
            var call = 0.0
            let (count, latency) = await withCheckedContinuation { (c: CheckedContinuation<(Int, Double), Never>) in
                store.suggest(query: q, limit: 8) { r in c.resume(returning: (r.count, ms(t))) }
                call = ms(t)
            }
            suggest.append(["query": q, "results": count, "mainMs": call, "latencyMs": latency])
        }
        out["suggest"] = suggest

        let tabs = (0..<40).map { i in
            TabState(id: "tab-\(i)", url: "https://example.com/\(i)", title: "Tab \(i)",
                     pinned: i < 2, position: UInt32(i), lastActiveMs: 1_000 + Int64(i))
        }
        let t = DispatchTime.now()
        store.saveSession(tabs: tabs, activeTabId: "tab-3")
        let mainMs = ms(t)
        store.flush()
        out["saveSession40Tabs"] = ["mainMs": mainMs, "latencyMs": ms(t)]
        return out
    }
}
