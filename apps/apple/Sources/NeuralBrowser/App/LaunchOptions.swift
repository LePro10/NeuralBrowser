// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

/// Command-line options. Usage:
///   NeuralBrowser [--data-dir DIR] [--extensions-dir DIR]
///   NeuralBrowser --smoke-test URL [URL ...] [--timeout SEC] [--hold SEC] [--sleep-test]
///                 [--private] [--screenshot PNG]
///   NeuralBrowser --extension-report [--extensions-dir DIR]
struct LaunchOptions {
    enum Mode {
        case normal
        case smokeTest([URL])
        case extensionReport
    }

    var mode: Mode = .normal
    var dataDirectory: URL?
    var extensionsDirectory: URL?
    var timeout: TimeInterval = 30
    /// Smoke test: keep running this many seconds after the report (for RAM measurement).
    var hold: TimeInterval = 0
    /// Smoke test: also put background tabs to sleep and wake one (M3 check).
    var sleepTest = false
    /// Smoke test: write a PNG of the window (sidebar + page) to this path.
    var screenshotPath: String?
    /// Smoke test: use a private window (no history, no extensions).
    var privateWindow = false

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--smoke-test":
                var urls: [URL] = []
                while i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    i += 1
                    if let u = URL(string: InputResolver.resolve(args[i], searchTemplate: Defaults.searchTemplate)) {
                        urls.append(u)
                    }
                }
                o.mode = .smokeTest(urls)
            case "--extension-report": o.mode = .extensionReport
            case "--data-dir": if let v = value() { o.dataDirectory = URL(fileURLWithPath: v) }
            case "--extensions-dir": if let v = value() { o.extensionsDirectory = URL(fileURLWithPath: v) }
            case "--timeout": if let v = value(), let t = Double(v) { o.timeout = t }
            case "--hold": if let v = value(), let t = Double(v) { o.hold = t }
            case "--sleep-test": o.sleepTest = true
            case "--screenshot": o.screenshotPath = value()
            case "--private": o.privateWindow = true
            default: break // ignore unknown (e.g. -NSDocumentRevisionsDebugMode)
            }
            i += 1
        }
        return o
    }

    var resolvedDataDirectory: URL {
        dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuralBrowser", isDirectory: true)
    }

    var resolvedExtensionsDirectory: URL {
        extensionsDirectory ?? resolvedDataDirectory.appendingPathComponent("Extensions", isDirectory: true)
    }
}

/// Wall-clock time the process was started by the kernel (for honest startup numbers).
func processStartDate() -> Date {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}
