// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation

/// What is stored next to an installed extension (`<Extensions>/<id>/install.json`).
public struct InstallRecord: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var kind: String        // "folder", "zip" or "crx"
        public var path: String        // where it was installed from
    }

    public var schema = 1
    public var id: String
    public var name: String
    public var version: String
    public var manifestVersion: Int
    public var source: Source
    /// SHA-256 of the package file; for a folder, of the sorted list "path NUL sha256(file)".
    public var sha256: String
    public var installedAt: String
    public var translatedAt: String
    public var ruleSetVersion: Int
    public var permissions: [String]
    public var hostPermissions: [String]
    public var translation: TranslationReport
}

/// Installs extensions from a folder, `.zip` or `.crx` into `<Extensions>/<id>/`:
/// `original/` (the package, unchanged), `patched/` (what the browser loads) and `install.json`.
public enum Installer {
    public static let recordName = "install.json"

    @discardableResult
    public static func install(from source: URL, into extensionsDir: URL, limits: InstallLimits = InstallLimits()) throws -> InstallRecord {
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        let staging = extensionsDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let raw = staging.appendingPathComponent("raw", isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw InstallError.notFound(source.path) }
        let kind: String
        let checksum: String
        if isDir.boolValue {
            kind = "folder"
            _ = try FileTree.copy(from: source.resolvingSymlinksInPath(), to: raw, limits: limits)
            checksum = try FileTree.treeHash(raw)
        } else {
            let attrs = try fm.attributesOfItem(atPath: source.path)
            if let size = attrs[.size] as? Int, size > limits.maxPackageBytes {
                throw InstallError.limitExceeded("package is larger than \(limits.maxPackageBytes / 1_000_000) MB")
            }
            let data = try Data(contentsOf: source)
            checksum = SHA256.hash(data: data).hex
            let (zipData, isCrx) = try Package.zipPayload(of: data)
            kind = isCrx ? "crx" : "zip"
            try extract(ZipArchive(data: zipData, limits: limits), to: raw)
        }

        let root = try Package.manifestRoot(in: raw)
        let original = staging.appendingPathComponent("original", isDirectory: true)
        try fm.moveItem(at: root, to: original)
        let manifest = try JSONC.parseObject(Data(contentsOf: original.appendingPathComponent("manifest.json"))).object
        let name = Package.displayName(manifest: manifest, root: original)
        let id = Package.slug(name)

        let now = ISO8601DateFormatter().string(from: Date())
        let report = try Translator.translate(original: original, into: staging.appendingPathComponent("patched", isDirectory: true), limits: limits)
        let record = InstallRecord(
            id: id, name: name, version: manifest["version"] as? String ?? "?",
            manifestVersion: manifest["manifest_version"] as? Int ?? 2,
            source: .init(kind: kind, path: source.path), sha256: checksum,
            installedAt: now, translatedAt: now, ruleSetVersion: RuleSet.version,
            permissions: ((manifest["permissions"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted(),
            hostPermissions: (((manifest["host_permissions"] as? [Any]) ?? []) + contentMatches(manifest)).compactMap { $0 as? String }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
            translation: report)
        try write(record, to: staging)
        try? fm.removeItem(at: raw) // gone already when the manifest was at the top level

        try move(staging, into: extensionsDir, id: id)
        return record
    }

    /// Moves an installed folder to `<dir>/<id>`; an existing installation with that id is replaced (update).
    @discardableResult
    public static func move(_ folder: URL, into dir: URL, id: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            let trash = dir.appendingPathComponent(".trash-\(UUID().uuidString)")
            try fm.moveItem(at: dest, to: trash)
            do { try fm.moveItem(at: folder, to: dest) } catch { try? fm.moveItem(at: trash, to: dest); throw error }
            try? fm.removeItem(at: trash)
        } else {
            try fm.moveItem(at: folder, to: dest)
        }
        return dest
    }

    /// Rebuilds `patched/` from `original/` with the current rules.
    @discardableResult
    public static func retranslate(_ folder: URL, limits: InstallLimits = InstallLimits()) throws -> InstallRecord {
        guard var record = record(in: folder) else { throw InstallError.notFound("\(folder.path)/\(recordName)") }
        let fm = FileManager.default
        let fresh = folder.appendingPathComponent(".patched-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: fresh) }
        let report = try Translator.translate(original: folder.appendingPathComponent("original"), into: fresh, limits: limits)
        let patched = folder.appendingPathComponent("patched", isDirectory: true)
        if fm.fileExists(atPath: patched.path) { try fm.removeItem(at: patched) }
        try fm.moveItem(at: fresh, to: patched)
        record.translation = report
        record.ruleSetVersion = RuleSet.version
        record.translatedAt = ISO8601DateFormatter().string(from: Date())
        try write(record, to: folder)
        return record
    }

    public static func record(in folder: URL) -> InstallRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(recordName)) else { return nil }
        return try? JSONDecoder().decode(InstallRecord.self, from: data)
    }

    /// The folder WebKit should load: `patched/` for installed extensions, the folder itself for plain unpacked ones.
    public static func loadableFolder(for folder: URL) -> URL? {
        let fm = FileManager.default
        let patched = folder.appendingPathComponent("patched", isDirectory: true)
        if fm.fileExists(atPath: patched.appendingPathComponent("manifest.json").path) { return patched }
        if fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        return nil
    }

    static func write(_ record: InstallRecord, to folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(record).write(to: folder.appendingPathComponent(recordName))
    }

    static func contentMatches(_ manifest: [String: Any]) -> [Any] {
        ((manifest["content_scripts"] as? [[String: Any]]) ?? []).flatMap { ($0["matches"] as? [Any]) ?? [] }
    }

    /// Writes every entry below `dest`. Paths were validated by ZipArchive; the prefix check is a second guard.
    static func extract(_ zip: ZipArchive, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        let rootPath = dest.standardizedFileURL.path + "/"
        for entry in zip.entries {
            let url = dest.appendingPathComponent(entry.path, isDirectory: entry.isDirectory).standardizedFileURL
            guard url.path.hasPrefix(rootPath) else { throw InstallError.unsafePath("\(entry.path) leaves the target folder") }
            if entry.isDirectory {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            let data = try zip.contents(of: entry)
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                throw InstallError.badArchive("cannot write \(entry.path)")
            }
        }
    }
}

/// Package formats and manifest lookup.
public enum Package {
    /// The zip inside a file: a plain zip, or a crx (v2/v3) with its header cut off.
    public static func zipPayload(of data: Data) throws -> (Data, isCrx: Bool) {
        if data.count >= 4, data.prefix(4) == Data("Cr24".utf8) {
            guard data.count >= 16 else { throw InstallError.badArchive("truncated crx header") }
            let version = data.u32(4)
            let start: Int
            switch version {
            case 2: start = 16 + Int(data.u32(8)) + Int(data.u32(12))
            case 3: start = 12 + Int(data.u32(8))
            default: throw InstallError.badArchive("unknown crx version \(version)")
            }
            guard start + 4 <= data.count, data.u32(start) == 0x0403_4b50 else {
                throw InstallError.badArchive("crx does not contain a zip")
            }
            return (data.subdata(in: start..<data.count), true)
        }
        guard data.count >= 4, data.u32(0) == 0x0403_4b50 || data.u32(0) == 0x0605_4b50 else {
            throw InstallError.badArchive("not a .zip or .crx file")
        }
        return (data, false)
    }

    /// The folder with manifest.json: the root, or the single shallowest folder that has one (depth ≤ 3).
    static func manifestRoot(in dir: URL) throws -> URL {
        let fm = FileManager.default
        var level = [dir]
        for _ in 0...3 {
            let hits = level.filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { throw InstallError.badManifest("several manifest.json files at the same level") }
            level = level.flatMap { d -> [URL] in
                ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
        }
        throw InstallError.badManifest("no manifest.json in package")
    }

    /// Manifest name with `__MSG_key__` resolved from the default locale.
    static func displayName(manifest: [String: Any], root: URL) -> String {
        let raw = (manifest["name"] as? String) ?? (manifest["short_name"] as? String) ?? "extension"
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        let locale = (manifest["default_locale"] as? String) ?? "en"
        for loc in [locale, "en"] {
            let file = root.appendingPathComponent("_locales/\(loc)/messages.json")
            if let data = try? Data(contentsOf: file), let obj = try? JSONC.parseObject(data).object,
               let entry = obj.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return (manifest["short_name"] as? String) ?? key
    }

    /// Folder-safe id: lowercase letters, digits and dashes, at most 48 characters.
    public static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased().unicodeScalars {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") { out.unicodeScalars.append(ch) }
            else if !out.hasSuffix("-"), !out.isEmpty { out += "-" }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "extension" : String(out.prefix(48))
    }
}

/// Copying and hashing folder trees without following links.
public enum FileTree {
    /// Copies regular files and folders. Symlinks and special files are refused, limits enforced.
    @discardableResult
    public static func copy(from src: URL, to dest: URL, limits: InstallLimits) throws -> (files: Int, bytes: Int) {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        var files = 0, bytes = 0
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: keys, options: []) else {
            throw InstallError.notFound(src.path)
        }
        let base = src.standardizedFileURL.path
        for case let url as URL in walker {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { throw InstallError.unsafePath("\(full) outside of \(base)") }
            let rel = try PathPolicy.validate(String(full.dropFirst(base.count + 1)), limits: limits)
            let v = try url.resourceValues(forKeys: Set(keys))
            if PathPolicy.isIgnored(rel) { if v.isDirectory == true { walker.skipDescendants() }; continue }
            if v.isSymbolicLink == true { throw InstallError.unsafePath("symbolic link: \(rel)") }
            let target = dest.appendingPathComponent(rel)
            if v.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            } else if v.isRegularFile == true {
                files += 1
                bytes += v.fileSize ?? 0
                guard files <= limits.maxEntries else { throw InstallError.limitExceeded("more than \(limits.maxEntries) files") }
                guard (v.fileSize ?? 0) <= limits.maxFileBytes else { throw InstallError.limitExceeded("\(rel) is too large") }
                guard bytes <= limits.maxTotalBytes else { throw InstallError.limitExceeded("folder exceeds \(limits.maxTotalBytes / 1_000_000) MB") }
                let data = try Data(contentsOf: url)
                guard fm.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                    throw InstallError.badArchive("cannot write \(rel)")
                }
            } else {
                throw InstallError.unsafePath("special file: \(rel)")
            }
        }
        return (files, bytes)
    }

    /// Relative paths of all regular files, sorted.
    public static func files(in dir: URL) throws -> [String] {
        let fm = FileManager.default
        let base = dir.standardizedFileURL.path
        var out: [String] = []
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    static func treeHash(_ dir: URL) throws -> String {
        var listing = ""
        for rel in try files(in: dir) {
            let data = try Data(contentsOf: dir.appendingPathComponent(rel))
            listing += "\(rel)\u{0}\(SHA256.hash(data: data).hex)\n"
        }
        return SHA256.hash(data: Data(listing.utf8)).hex
    }
}

extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
