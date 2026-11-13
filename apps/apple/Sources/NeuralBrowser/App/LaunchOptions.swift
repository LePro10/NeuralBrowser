// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation
import NeuralCore

/// Command-line options. Usage:
///   NeuralBrowser [--data-dir DIR] [--extensions-dir DIR]
///   NeuralBrowser --smoke-test URL [URL ...] [--timeout SEC] [--hold SEC] [--sleep-test]
///                 [--private] [--screenshot PNG] [--profile-dir DIR] [--store-bench]
///                 [--shield-lists FILE ... | --shield-download] [--shield-off HOST] [--eval JS]
///                 [--vault-fill-test]
///   NeuralBrowser --extension-report [--extensions-dir DIR]
///   NeuralBrowser --ext-script STEPS.json [--extensions-dir DIR] [--timeout SEC]
///                 [--normal-mode --data-dir DIR]   (persistent profile, normal loading, see ExtensionScript)
///   NeuralBrowser --install-extension PATH [PATH ...] [--extensions-dir DIR]   (folder, .zip or .crx)
///   NeuralBrowser --retranslate-extensions [--extensions-dir DIR]
struct LaunchOptions {
    enum Mode {
        case normal
        case smokeTest([URL])
        case extensionReport
        /// Runs the steps of a JSON test script (see ExtensionScript.swift).
        case extensionScript(URL)
        /// Installs (unpacks + translates) packages without UI and prints the records as JSON.
        case installExtensions([URL])
        /// Rebuilds `patched/` of every installed extension with the current rules.
        case retranslateExtensions
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
    /// Smoke test: persist into DIR/browser.sqlite (a throw-away profile) instead of memory.
    /// Without it the smoke test never writes to disk.
    var profileDirectory: URL?
    /// Smoke test: also time store calls (suggest, saveSession) on a seeded store.
    var storeBench = false
    /// Smoke test: use a private window (no history, no extensions).
    var privateWindow = false
    /// Test knob: application name for the user agent of extension web views
    /// (background, popup, options), e.g. to compare Safari and Chrome code paths.
    var extensionUserAgentName: String?
    /// Test knob: same for normal tabs.
    var tabUserAgentName: String?
    /// `--ext-script` only: run like the normal app on `--data-dir` (persistent store, WebKit data
    /// and extension storage, extensions loaded and granted the normal way) instead of in memory.
    var scriptNormalMode = false
    /// Smoke test: content blocking with these local filter list files (no network).
    var shieldListFiles: [URL] = []
    /// Smoke test: content blocking with the real lists, downloaded into a temporary folder.
    var shieldDownload = false
    /// Smoke test: sites where content blocking is switched off.
    var shieldOffHosts: [String] = []
    /// Smoke test: JavaScript evaluated in the first tab after loading; the result goes into the report.
    var evalScript: String?
    /// Smoke test: run the password fill routine and its guard with dummy values on the first tab
    /// (no vault, no server; see VaultFillTest).
    var vaultFillTest = false

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
                    if let u = URL(string: resolveInput(text: args[i], searchTemplate: Defaults.searchTemplate)) {
                        urls.append(u)
                    }
                }
                o.mode = .smokeTest(urls)
            case "--extension-report": o.mode = .extensionReport
            case "--install-extension":
                var paths: [URL] = []
                while i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    i += 1
                    paths.append(URL(fileURLWithPath: args[i]))
                }
                o.mode = .installExtensions(paths)
            case "--retranslate-extensions": o.mode = .retranslateExtensions
            case "--ext-script": if let v = value() { o.mode = .extensionScript(URL(fileURLWithPath: v)) }
            case "--data-dir": if let v = value() { o.dataDirectory = URL(fileURLWithPath: v) }
            case "--profile-dir": if let v = value() { o.profileDirectory = URL(fileURLWithPath: v) }
            case "--extensions-dir": if let v = value() { o.extensionsDirectory = URL(fileURLWithPath: v) }
            case "--timeout": if let v = value(), let t = Double(v) { o.timeout = t }
            case "--hold": if let v = value(), let t = Double(v) { o.hold = t }
            case "--sleep-test": o.sleepTest = true
            case "--screenshot": o.screenshotPath = value()
            case "--store-bench": o.storeBench = true
            case "--private": o.privateWindow = true
            case "--extension-ua": o.extensionUserAgentName = value()
            case "--tab-ua": o.tabUserAgentName = value()
            case "--normal-mode": o.scriptNormalMode = true
            case "--shield-lists":
                while i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    i += 1
                    o.shieldListFiles.append(URL(fileURLWithPath: args[i]))
                }
            case "--shield-download": o.shieldDownload = true
            case "--shield-off": if let v = value() { o.shieldOffHosts.append(v) }
            case "--eval": o.evalScript = value()
            case "--vault-fill-test": o.vaultFillTest = true
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

    /// Stable UUID for a custom `--data-dir` (separate WebKit data and extension storage).
    var profileIdentifier: UUID? {
        guard let path = dataDirectory?.standardizedFileURL.path else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in path.utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4 layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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
