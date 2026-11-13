// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Turns command-bar input into a URL string: either the input itself (when it
/// looks like an address) or a search URL built from `searchTemplate` (`%s`).
enum InputResolver {
    private static let schemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "webkit-extension", "javascript", "mailto",
    ]

    static func resolve(_ raw: String, searchTemplate: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "about:blank" }

        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon].lowercased()
            if schemes.contains(scheme), !text.contains(" ") { return text }
        }
        if !text.contains(" "), looksLikeHost(text) {
            // Local dev servers and raw IPs rarely have TLS; everything else gets https.
            return (isLocal(text) ? "http://" : "https://") + text
        }
        return search(text, template: searchTemplate)
    }

    static func search(_ text: String, template: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let query = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        let tpl = template.contains("%s") ? template : Defaults.searchTemplate
        return tpl.replacingOccurrences(of: "%s", with: query)
    }

    private static func isLocal(_ text: String) -> Bool {
        let host = text.split(whereSeparator: { "/?#:".contains($0) }).first.map { $0.lowercased() } ?? ""
        return host == "localhost" || host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        // Host part = everything before the first '/', '?' or '#'.
        let hostPort = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? text
        let host = hostPort.split(separator: ":").first.map(String.init) ?? hostPort
        if host.lowercased() == "localhost" { return true }
        // IPv4
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        // name.tld with a letter-only TLD of 2+ chars
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
