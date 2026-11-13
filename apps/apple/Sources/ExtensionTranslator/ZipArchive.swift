// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Compression
import Foundation

/// Minimal, defensive ZIP reader for extension packages (zip, and crx after its header).
///
/// Only what extension packages need: stored and deflated entries, no ZIP64, no
/// encryption, no multi-disk. Every entry name is validated before anything touches
/// the disk, symlinks and special files are refused, declared sizes are capped, and
/// the CRC-32 of every extracted file is checked. Nothing in the archive is executed.
public struct ZipArchive {
    public struct Entry {
        public let path: String          // validated, relative, "/"-separated
        public let isDirectory: Bool
        public let method: UInt16
        public let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public let entries: [Entry]
    private let data: Data
    private let base: Int

    /// Parses the central directory of `data` (a zip, possibly with leading bytes).
    public init(data: Data, limits: InstallLimits) throws {
        self.data = data
        guard data.count >= 22 else { throw InstallError.badArchive("file too small for a zip archive") }
        guard data.count <= limits.maxPackageBytes else {
            throw InstallError.limitExceeded("package is larger than \(limits.maxPackageBytes / 1_000_000) MB")
        }
        // End of central directory: last 22 bytes + up to 64 KiB comment.
        var eocd = -1
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var i = data.count - 22
        while i >= lowest {
            if data.u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw InstallError.badArchive("no zip end record found") }
        let diskNumber = data.u16(eocd + 4), cdDisk = data.u16(eocd + 6)
        let countOnDisk = Int(data.u16(eocd + 8)), count = Int(data.u16(eocd + 10))
        let cdSize = Int(data.u32(eocd + 12)), cdOffset = Int(data.u32(eocd + 16))
        guard diskNumber == 0, cdDisk == 0, countOnDisk == count else {
            throw InstallError.badArchive("multi-part archives are not supported")
        }
        guard count != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else {
            throw InstallError.badArchive("ZIP64 archives are not supported")
        }
        guard count <= limits.maxEntries else {
            throw InstallError.limitExceeded("archive has \(count) entries (limit \(limits.maxEntries))")
        }
        // Bytes in front of the archive (crx header, self-extractor stub) shift all offsets.
        let base = eocd - cdSize - cdOffset
        guard base >= 0, eocd - cdSize >= 0 else { throw InstallError.badArchive("central directory out of range") }
        self.base = base

        var result: [Entry] = []
        var seen = Set<String>()        // case-folded: APFS is case-insensitive by default
        var directories = Set<String>()
        var files = Set<String>()
        var total = 0
        var p = base + cdOffset
        for _ in 0..<count {
            guard p + 46 <= eocd, data.u32(p) == 0x0201_4b50 else {
                throw InstallError.badArchive("broken central directory")
            }
            let madeBy = data.u16(p + 4)
            let flags = data.u16(p + 8)
            let method = data.u16(p + 10)
            let crc = data.u32(p + 16)
            let csize = Int(data.u32(p + 20)), usize = Int(data.u32(p + 24))
            let nameLen = Int(data.u16(p + 28)), extraLen = Int(data.u16(p + 30)), commentLen = Int(data.u16(p + 32))
            let external = data.u32(p + 38)
            let local = Int(data.u32(p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= eocd else { throw InstallError.badArchive("broken entry") }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            p += 46 + nameLen + extraLen + commentLen

            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw InstallError.unsafePath("entry name is not valid UTF-8")
            }
            if flags & 0x1 != 0 { throw InstallError.badArchive("encrypted entry: \(rawName)") }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || local == 0xFFFF_FFFF {
                throw InstallError.badArchive("ZIP64 entries are not supported")
            }
            // Unix mode lives in the upper 16 bits when the archive was made on Unix (host 3).
            let unixMode = (madeBy >> 8) == 3 ? (external >> 16) & 0o170000 : 0
            if unixMode == 0o120000 { throw InstallError.unsafePath("symbolic link in archive: \(rawName)") }
            let isDir = rawName.hasSuffix("/") || unixMode == 0o040000
            if unixMode != 0, unixMode != 0o100000, unixMode != 0o040000 {
                throw InstallError.unsafePath("special file in archive: \(rawName)")
            }
            let path = try PathPolicy.validate(rawName, limits: limits)
            if PathPolicy.isIgnored(path) { continue }
            let folded = path.lowercased()
            guard !seen.contains(folded) else { throw InstallError.unsafePath("duplicate entry: \(path)") }
            seen.insert(folded)
            if isDir {
                directories.insert(folded)
            } else {
                guard method == 0 || method == 8 else {
                    throw InstallError.badArchive("unsupported compression method \(method) for \(path)")
                }
                guard usize <= limits.maxFileBytes else {
                    throw InstallError.limitExceeded("\(path) is larger than \(limits.maxFileBytes / 1_000_000) MB")
                }
                total += usize
                guard total <= limits.maxTotalBytes else {
                    throw InstallError.limitExceeded("unpacked size exceeds \(limits.maxTotalBytes / 1_000_000) MB")
                }
                files.insert(folded)
            }
            result.append(Entry(path: path, isDirectory: isDir, method: method, crc32: crc,
                                compressedSize: csize, uncompressedSize: usize, localHeaderOffset: local))
        }
        // A file must not also be used as a directory ("a" and "a/b").
        for f in files {
            var parent = f
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                if files.contains(parent) { throw InstallError.unsafePath("\(parent) is both a file and a folder") }
            }
            if directories.contains(f) { throw InstallError.unsafePath("\(f) is both a file and a folder") }
        }
        entries = result
    }

    /// Decompressed, CRC-checked bytes of one entry.
    public func contents(of entry: Entry) throws -> Data {
        let lh = base + entry.localHeaderOffset
        guard lh >= 0, lh + 30 <= data.count, data.u32(lh) == 0x0403_4b50 else {
            throw InstallError.badArchive("broken local header for \(entry.path)")
        }
        let start = lh + 30 + Int(data.u16(lh + 26)) + Int(data.u16(lh + 28))
        guard start + entry.compressedSize <= data.count else { throw InstallError.badArchive("truncated entry \(entry.path)") }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        let out: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw InstallError.badArchive("size mismatch in \(entry.path)")
            }
            out = raw
        case 8:
            out = try Self.inflate(raw, expected: entry.uncompressedSize, name: entry.path)
        default:
            throw InstallError.badArchive("unsupported compression method \(entry.method)")
        }
        guard CRC32.checksum(out) == entry.crc32 else { throw InstallError.badArchive("checksum mismatch in \(entry.path)") }
        return out
    }

    /// Raw DEFLATE (RFC 1951) into a buffer of exactly the declared size: output can never grow beyond it.
    static func inflate(_ input: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 { return Data() }
        var output = Data(count: expected + 1) // one spare byte detects data beyond the declared size
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expected + 1, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw InstallError.badArchive("cannot decompress \(name)") }
        output.removeLast()
        return output
    }
}

/// Size and count limits for one package (defaults fit all tested extensions with a wide margin).
public struct InstallLimits: Sendable {
    public var maxPackageBytes = 200_000_000
    public var maxTotalBytes = 400_000_000
    public var maxFileBytes = 100_000_000
    public var maxEntries = 20_000
    public var maxDepth = 32
    public var maxPathLength = 1024

    public init() {}
}

public enum InstallError: Error, CustomStringConvertible, Equatable {
    case badArchive(String)
    case unsafePath(String)
    case limitExceeded(String)
    case badManifest(String)
    case notFound(String)
    case translation(String)

    public var description: String {
        switch self {
        case .badArchive(let s): return "Invalid package: \(s)"
        case .unsafePath(let s): return "Unsafe package: \(s)"
        case .limitExceeded(let s): return "Package too large: \(s)"
        case .badManifest(let s): return "Invalid manifest: \(s)"
        case .notFound(let s): return "Not found: \(s)"
        case .translation(let s): return "Translation failed: \(s)"
        }
    }
}

/// Rules for paths that come from a package (zip entry names or files of a folder).
public enum PathPolicy {
    /// Returns the normalized relative path or throws if it could leave the target folder.
    public static func validate(_ raw: String, limits: InstallLimits) throws -> String {
        guard !raw.isEmpty else { throw InstallError.unsafePath("empty name") }
        guard raw.utf8.count <= limits.maxPathLength else { throw InstallError.unsafePath("name too long") }
        if raw.contains("\\") { throw InstallError.unsafePath("backslash in name: \(raw)") }
        if raw.hasPrefix("/") { throw InstallError.unsafePath("absolute path: \(raw)") }
        if raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw InstallError.unsafePath("control character in name")
        }
        var name = raw
        if name.hasSuffix("/") { name.removeLast() }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= limits.maxDepth else { throw InstallError.unsafePath("path too deep: \(raw)") }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." { throw InstallError.unsafePath("invalid path: \(raw)") }
            if part.utf8.count > 255 { throw InstallError.unsafePath("name too long: \(raw)") }
            if parts.first == part, part.count == 2, part.hasSuffix(":") { throw InstallError.unsafePath("drive path: \(raw)") }
        }
        return name
    }

    /// Packaging noise that is skipped instead of copied.
    public static func isIgnored(_ path: String) -> Bool {
        let first = path.split(separator: "/").first.map(String.init) ?? path
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return first == "__MACOSX" || last == ".DS_Store" || path.split(separator: "/").contains(".git")
    }
}

/// CRC-32 (IEEE 802.3), as used by ZIP. A checksum for corruption, not a security primitive.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= count else { return 0 }
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= count else { return 0 }
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }
}
