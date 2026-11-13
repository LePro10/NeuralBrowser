// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

// Entry point. Keep this tiny: nothing heavy may run before the first window.
MainActor.assumeIsolated {
    let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
    let application = NSApplication.shared
    let delegate = AppDelegate(options: options)
    application.delegate = delegate
    // NSApplication.delegate is weak; `run()` never returns, so `delegate` stays alive.
    withExtendedLifetime(delegate) { application.run() }
}
