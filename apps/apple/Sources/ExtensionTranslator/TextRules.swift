// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JavaScriptCore

/// Careful text replacement in JavaScript. Used only where the prelude cannot help.
///
/// Safety net, in this order: (1) a small lexer marks strings, template literals,
/// comments and regular expressions, and matches inside them are never touched;
/// (2) only one exact, unambiguous member-chain shape is replaced; (3) a file that
/// JavaScriptCore can parse before the change must still parse after it, otherwise
/// the file is left as it was. Parsing only checks syntax, it never runs the code.
public enum TextRules {
    public struct Result {
        public var text: Data
        public var replaced: Int
        public var skipped: Int       // matches left alone (ambiguous position, failed syntax check)
    }

    /// `….scripting.ExecutionWorld.ISOLATED` / `.MAIN` → `"ISOLATED"` / `"MAIN"`.
    public static func replaceExecutionWorld(in data: Data) -> Result {
        let bytes = [UInt8](data)
        let needle = Array("ExecutionWorld".utf8)
        guard let first = find(needle, in: bytes, from: 0) else { return Result(text: data, replaced: 0, skipped: 0) }
        let code = Lexer.codeMask(bytes)
        var edits: [(range: Range<Int>, value: String)] = []
        var skipped = 0
        var at: Int? = first
        while let pos = at {
            defer { at = find(needle, in: bytes, from: pos + needle.count) }
            guard code[pos] else { continue }
            // Before: "scripting" + ("." | "?.")
            guard let (scriptingStart, ok) = memberBefore(bytes, pos, name: "scripting"), ok else { continue }
            // After: ("." | "?.") + ISOLATED | MAIN, then a non-identifier character.
            var q = pos + needle.count
            if q + 1 < bytes.count, bytes[q] == UInt8(ascii: "?"), bytes[q + 1] == UInt8(ascii: ".") { q += 2 }
            else if q < bytes.count, bytes[q] == UInt8(ascii: ".") { q += 1 } else { continue }
            var value: String?
            for v in ["ISOLATED", "MAIN"] where startsWith(bytes, q, v) && !isIdent(byte(bytes, q + v.utf8.count)) { value = v }
            guard let value else { continue }
            let end = q + value.utf8.count
            // Walk back over the receiver chain (identifiers joined by "." or "?.").
            var start = scriptingStart
            while true {
                var d = start
                if d >= 2, bytes[d - 1] == UInt8(ascii: "."), bytes[d - 2] == UInt8(ascii: "?") { d -= 2 }
                else if d >= 1, bytes[d - 1] == UInt8(ascii: ".") { d -= 1 } else { break }
                var s = d
                while s > 0, isIdent(bytes[s - 1]) { s -= 1 }
                guard s < d, !isDigit(bytes[s]) else { start = -1; break } // `)`/`]`/number before the dot: ambiguous
                start = s
            }
            guard start >= 0, (start..<end).allSatisfy({ code[$0] }) else { skipped += 1; continue }
            // Neither an assignment target nor `delete`/increment operand.
            let after = nextSignificant(bytes, end)
            if let a = after {
                let c = bytes[a], n = byte(bytes, a + 1)
                if c == UInt8(ascii: "=") && n != UInt8(ascii: "=") { skipped += 1; continue }
                if (c == UInt8(ascii: "+") && n == UInt8(ascii: "+")) || (c == UInt8(ascii: "-") && n == UInt8(ascii: "-")) { skipped += 1; continue }
                if c == UInt8(ascii: "(") || c == UInt8(ascii: "`") { skipped += 1; continue }
            }
            if precededByWord(bytes, start, "delete") { skipped += 1; continue }
            edits.append((start..<end, "\"\(value)\""))
        }
        return apply(edits, to: data, bytes: bytes, skipped: skipped)
    }

    /// `from.<ns>` / `from?.<ns>` → `to.<ns>` for the given namespaces (`browser`/`chrome`).
    ///
    /// The prelude's proxy can replace only one of the two globals (see Prelude.swift), so code
    /// that reaches a patched namespace through the other name would miss the fix. WebKit's
    /// `browser` and `chrome` are the same object, so the rename changes nothing else. Only a
    /// free identifier (not `x.browser`) directly followed by one of the namespaces is renamed.
    public static func alias(in data: Data, from: String, to: String, namespaces: Set<String>) -> Result {
        let bytes = [UInt8](data)
        let needle = Array(from.utf8)
        guard !namespaces.isEmpty, let first = find(needle, in: bytes, from: 0) else { return Result(text: data, replaced: 0, skipped: 0) }
        let code = Lexer.codeMask(bytes)
        var edits: [Range<Int>] = []
        var skipped = 0
        var at: Int? = first
        while let pos = at {
            defer { at = find(needle, in: bytes, from: pos + needle.count) }
            guard code[pos] else { continue }
            if pos > 0, isIdent(bytes[pos - 1]) || bytes[pos - 1] == UInt8(ascii: ".") { continue }
            var q = pos + needle.count
            if q + 1 < bytes.count, bytes[q] == UInt8(ascii: "?"), bytes[q + 1] == UInt8(ascii: ".") { q += 2 }
            else if q < bytes.count, bytes[q] == UInt8(ascii: ".") { q += 1 } else { continue }
            guard let ns = namespaces.first(where: { startsWith(bytes, q, $0) && !isIdent(byte(bytes, q + $0.utf8.count)) }) else { continue }
            let end = q + ns.utf8.count
            guard (pos..<end).allSatisfy({ code[$0] }) else { skipped += 1; continue }
            if let a = nextSignificant(bytes, end), bytes[a] == UInt8(ascii: "="), byte(bytes, a + 1) != UInt8(ascii: "=") {
                skipped += 1; continue   // `browser.permissions = …` is an assignment, leave it
            }
            edits.append(pos..<(pos + needle.count))
        }
        return apply(edits.map { ($0, to) }, to: data, bytes: bytes, skipped: skipped)
    }

    /// Applies edits back to front; undoes everything if a file that parsed before no longer parses.
    static func apply(_ edits: [(range: Range<Int>, value: String)], to data: Data, bytes: [UInt8], skipped: Int) -> Result {
        guard !edits.isEmpty else { return Result(text: data, replaced: 0, skipped: skipped) }
        var out = bytes
        for e in edits.reversed() { out.replaceSubrange(e.range, with: Array(e.value.utf8)) }
        let patched = Data(out)
        if SyntaxCheck.parses(data), !SyntaxCheck.parses(patched) {
            return Result(text: data, replaced: 0, skipped: skipped + edits.count)
        }
        return Result(text: patched, replaced: edits.count, skipped: skipped)
    }

    // MARK: Helpers

    /// How often code names `chrome` vs `browser` as the API root (free `x.` / `x?.` and `.x`, e.g.
    /// `globalThis.browser`). Decides which global the prelude proxies; a heuristic, not a rewrite.
    public static func apiRootUsage(in data: Data) -> (chrome: Int, browser: Int) {
        let bytes = [UInt8](data)
        func count(_ word: String) -> Int {
            let needle = Array(word.utf8)
            var n = 0
            var at = find(needle, in: bytes, from: 0)
            while let pos = at {
                let end = pos + needle.count
                let freeRoot = (pos == 0 || !isIdent(bytes[pos - 1])) && !isIdent(byte(bytes, end))
                    && (byte(bytes, end) == UInt8(ascii: ".") || (byte(bytes, end) == UInt8(ascii: "?") && byte(bytes, end + 1) == UInt8(ascii: ".")))
                let property = pos > 0 && bytes[pos - 1] == UInt8(ascii: ".") && !isIdent(byte(bytes, end))
                if freeRoot || property { n += 1 }
                at = find(needle, in: bytes, from: end)
            }
            return n
        }
        return (count("chrome"), count("browser"))
    }

    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count, from <= hay.count - needle.count else { return nil }
        var i = from
        let last = hay.count - needle.count
        let f = needle[0]
        while i <= last {
            if hay[i] == f {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// If `name` followed by "." or "?." ends right at `pos`, returns its start.
    static func memberBefore(_ b: [UInt8], _ pos: Int, name: String) -> (Int, Bool)? {
        var d = pos
        if d >= 2, b[d - 1] == UInt8(ascii: "."), b[d - 2] == UInt8(ascii: "?") { d -= 2 }
        else if d >= 1, b[d - 1] == UInt8(ascii: ".") { d -= 1 } else { return nil }
        let n = Array(name.utf8)
        let s = d - n.count
        guard s >= 0, Array(b[s..<d]) == n else { return nil }
        if s > 0, isIdent(b[s - 1]) { return nil }
        return (s, true)
    }

    static func startsWith(_ b: [UInt8], _ i: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        return i + u.count <= b.count && Array(b[i..<(i + u.count)]) == u
    }

    static func byte(_ b: [UInt8], _ i: Int) -> UInt8 { i >= 0 && i < b.count ? b[i] : 0 }

    static func isIdent(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c >= 0x80
    }

    static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    static func nextSignificant(_ b: [UInt8], _ i: Int) -> Int? {
        var j = i
        while j < b.count, b[j] == 0x20 || b[j] == 0x09 || b[j] == 0x0A || b[j] == 0x0D { j += 1 }
        return j < b.count ? j : nil
    }

    static func precededByWord(_ b: [UInt8], _ i: Int, _ word: String) -> Bool {
        var j = i
        while j > 0, b[j - 1] == 0x20 || b[j - 1] == 0x09 { j -= 1 }
        let w = Array(word.utf8)
        guard j >= w.count, Array(b[(j - w.count)..<j]) == w else { return false }
        return j - w.count == 0 || !isIdent(b[j - w.count - 1])
    }
}

/// Marks which bytes of a JavaScript source are code (true) as opposed to strings,
/// template text, comments and regular-expression literals (false). Conservative:
/// when in doubt about a `/`, it treats it as the start of a regular expression,
/// which only hides more text from replacement.
enum Lexer {
    static func codeMask(_ b: [UInt8]) -> [Bool] {
        var mask = [Bool](repeating: true, count: b.count)
        var i = 0
        var templateDepth: [Int] = []   // brace depth at each `${`
        var braces = 0
        var lastSignificant: UInt8 = 0  // 0 = start of input
        var lastWordEnd = -1
        func mark(_ r: Range<Int>) { for k in r where k < mask.count { mask[k] = false } }
        func scanTemplate(from start: Int) -> Int {   // returns index after closing ` or after `${`
            var j = start
            while j < b.count {
                if b[j] == 0x5C { j += 2; continue }
                if b[j] == 0x60 { return j + 1 }
                if b[j] == 0x24, j + 1 < b.count, b[j + 1] == 0x7B {
                    templateDepth.append(braces)
                    braces += 1
                    return -(j + 2)
                }
                j += 1
            }
            return b.count
        }
        while i < b.count {
            let c = b[i]
            switch c {
            case 0x22, 0x27: // " '
                var j = i + 1
                while j < b.count, b[j] != c, b[j] != 0x0A { j += b[j] == 0x5C ? 2 : 1 }
                mark(i..<min(j + 1, b.count)); i = j + 1; lastSignificant = 0x22
            case 0x60: // `
                let r = scanTemplate(from: i + 1)
                if r < 0 { mark(i..<(-r)); i = -r; lastSignificant = 0x7B } else { mark(i..<r); i = r; lastSignificant = 0x22 }
            case 0x2F: // /
                let n = i + 1 < b.count ? b[i + 1] : 0
                if n == 0x2F {
                    var j = i
                    while j < b.count, b[j] != 0x0A { j += 1 }
                    mark(i..<j); i = j
                } else if n == 0x2A {
                    var j = i + 2
                    while j + 1 < b.count, !(b[j] == 0x2A && b[j + 1] == 0x2F) { j += 1 }
                    mark(i..<min(j + 2, b.count)); i = j + 2
                } else if regexAllowed(after: lastSignificant, b: b, wordEnd: lastWordEnd) {
                    var j = i + 1
                    var inClass = false
                    while j < b.count, b[j] != 0x0A {
                        if b[j] == 0x5C { j += 2; continue }
                        if b[j] == 0x5B { inClass = true } else if b[j] == 0x5D { inClass = false }
                        else if b[j] == 0x2F, !inClass { break }
                        j += 1
                    }
                    j += 1
                    while j < b.count, TextRules.isIdent(b[j]) { j += 1 } // flags
                    mark(i..<min(j, b.count)); i = j; lastSignificant = 0x22
                } else {
                    i += 1; lastSignificant = c
                }
            case 0x7B: braces += 1; i += 1; lastSignificant = c
            case 0x7D:
                if let d = templateDepth.last, braces - 1 == d {
                    templateDepth.removeLast(); braces -= 1
                    let r = scanTemplate(from: i + 1)
                    if r < 0 { mark(i..<(-r)); i = -r; lastSignificant = 0x7B } else { mark(i..<r); i = r; lastSignificant = 0x22 }
                } else {
                    braces -= 1; i += 1; lastSignificant = c
                }
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default:
                if TextRules.isIdent(c) {
                    var j = i
                    while j < b.count, TextRules.isIdent(b[j]) { j += 1 }
                    lastWordEnd = j; lastSignificant = 0x41 // "A": identifier or number
                    i = j
                } else {
                    lastSignificant = c; i += 1
                }
            }
        }
        return mask
    }

    /// After an identifier or `)`/`]` a slash is division, except after keywords like `return`.
    private static func regexAllowed(after last: UInt8, b: [UInt8], wordEnd: Int) -> Bool {
        if last == 0x41 {
            var s = wordEnd
            while s > 0, TextRules.isIdent(b[s - 1]) { s -= 1 }
            let word = String(decoding: b[s..<wordEnd], as: UTF8.self)
            return ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw",
                    "instanceof", "yield", "await"].contains(word)
        }
        return !(last == 0x29 || last == 0x5D || last == 0x22)
    }
}

/// Syntax check with JavaScriptCore (parse only, nothing is executed).
enum SyntaxCheck {
    static func parses(_ data: Data) -> Bool {
        guard let source = String(data: data, encoding: .utf8) else { return false }
        let ctx = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(ctx) }
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(ctx, script, nil, 1, nil)
    }
}
