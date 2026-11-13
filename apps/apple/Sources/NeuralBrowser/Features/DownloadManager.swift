// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import WebKit

/// Saves downloads into ~/Downloads and exposes a tiny list for the sidebar.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    @MainActor
    final class Item: NSObject {
        enum State { case running, finished, failed }
        let download: WKDownload
        var filename = "download"
        var destination: URL?
        var fraction: Double = 0
        var state = State.running
        var observation: NSKeyValueObservation?

        init(download: WKDownload) { self.download = download }

        var label: String {
            switch state {
            case .running: return "\(filename) – \(Int(fraction * 100))%"
            case .finished: return filename
            case .failed: return "\(filename) – failed"
            }
        }

        @objc func reveal() {
            if let destination, state == .finished {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    private(set) var items: [Item] = []
    var onChange: (() -> Void)?
    private var lastNotify = Date.distantPast

    func track(_ download: WKDownload) {
        let item = Item(download: download)
        download.delegate = self
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self, weak item] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    item?.fraction = value
                    self?.throttledNotify()
                }
            }
        }
        items.append(item)
        onChange?()
    }

    private func throttledNotify() {
        guard Date().timeIntervalSince(lastNotify) > 0.25 else { return }
        lastNotify = Date()
        onChange?()
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = Self.uniqueURL(in: dir, name: suggestedFilename.isEmpty ? "download" : suggestedFilename)
        item(for: download)?.filename = dest.lastPathComponent
        item(for: download)?.destination = dest
        onChange?()
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        item(for: download)?.state = .finished
        item(for: download)?.fraction = 1
        onChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        item(for: download)?.state = .failed
        onChange?()
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            let numbered = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = dir.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}
