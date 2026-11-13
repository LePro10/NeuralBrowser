// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// "JSON with comments" as Chrome accepts it in manifest.json: `//` and `/* */`
/// comments and trailing commas. Strings are respected, so `"http://x"` stays intact.
public enum JSONC {
    /// Returns strict JSON text and how many comments / trailing commas were removed.
    public static func strip(_ text: String) -> (json: String, comments: Int, trailingCommas: Int) {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var comments = 0, commas = 0
        var i = 0
        var inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < s.count { out.append(s[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                comments += 1
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                comments += 1
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i += 2
                out.append(" ")
                continue
            }
            if c == "," {
                // Trailing comma: next significant character closes the object/array.
                var j = i + 1
                while j < s.count {
                    let n = s[j]
                    if n == " " || n == "\n" || n == "\r" || n == "\t" { j += 1; continue }
                    if n == "/", j + 1 < s.count, s[j + 1] == "/" {
                        while j < s.count, s[j] != "\n" { j += 1 }
                        continue
                    }
                    if n == "/", j + 1 < s.count, s[j + 1] == "*" {
                        j += 2
                        while j + 1 < s.count, !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
                        j += 2
                        continue
                    }
                    break
                }
                if j < s.count, s[j] == "}" || s[j] == "]" { commas += 1; i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return (String(out), comments, commas)
    }

    /// Parses strict JSON first, then JSONC. `relaxed` tells whether stripping was needed.
    public static func parseObject(_ data: Data) throws -> (object: [String: Any], relaxed: Bool, comments: Int, trailingCommas: Int) {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return (obj, false, 0, 0) }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let stripped = strip(text)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(stripped.json.utf8)) as? [String: Any] else {
            throw InstallError.badManifest("manifest.json is not valid JSON (even with comments removed)")
        }
        return (obj, true, stripped.comments, stripped.trailingCommas)
    }
}
