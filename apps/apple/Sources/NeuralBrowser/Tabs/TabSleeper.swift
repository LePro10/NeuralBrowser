// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Puts background tabs to sleep (releases their WKWebView) after a period of
/// inactivity. Tabs playing media or using camera/microphone stay awake.
@MainActor
final class TabSleeper {
    unowned let app: AppDelegate
    private var timer: Timer?

    init(app: AppDelegate) { self.app = app }

    /// Inactivity threshold from the setting `tabs.sleepAfterMinutes` (default 15, 0 = never).
    var threshold: TimeInterval {
        let raw = (try? app.store.getSetting(key: SettingKey.sleepAfterMinutes)) ?? nil
        return (raw.flatMap(Double.init) ?? Defaults.sleepAfterMinutes) * 60
    }

    func start() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() {
        let threshold = self.threshold
        guard threshold > 0 else { return }
        let cutoff = nowMs() - Int64(threshold * 1000)
        for window in app.windows {
            for tab in window.tabs where tab !== window.activeTab && !tab.isAsleep && tab.lastActiveMs < cutoff {
                tab.sleep { _ in }
            }
        }
    }
}
