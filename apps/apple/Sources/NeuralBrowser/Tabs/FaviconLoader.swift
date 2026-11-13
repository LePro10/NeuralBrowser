// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// Fetches favicons with a tiny in-memory cache. Private windows use an
/// ephemeral session so nothing is written to the URL cache on disk.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private lazy var session = URLSession(configuration: .default)
    private lazy var ephemeralSession = URLSession(configuration: .ephemeral)

    func load(_ url: URL, ephemeral: Bool, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) { return completion(cached) }
        let task = (ephemeral ? ephemeralSession : session).dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let bytes = ok ? data : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let bytes, let image = NSImage(data: bytes) else { return completion(nil) }
                    image.size = NSSize(width: 16, height: 16)
                    self.cache.setObject(image, forKey: url as NSURL)
                    completion(image)
                }
            }
        }
        task.resume()
    }
}
