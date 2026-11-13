// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Offline self test for the extension installer and translator.
// Run: swift run -c release translator-selftest   (exit 0 = all passed)

import Compression
import ExtensionTranslator
import Foundation
import JavaScriptCore

var failures = 0
var passed = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failures += 1; print("FAIL \(name) \(detail())") }
}

func expectError(_ name: String, contains: String, _ body: () throws -> Void) {
    do { try body(); check(false, name, "no error") } catch {
        check("\(error)".lowercased().contains(contains.lowercased()), name, "\(error)")
    }
}

// MARK: Test zip writer (stored or deflated entries, optional unix mode, optional wrong sizes/CRC)

struct TestEntry {
    var name: String
    var data: Data
    var deflate = false
    var unixMode: UInt32? = nil
    var declaredSize: Int? = nil
    var badCRC = false
}

func crc32(_ d: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in d {
        crc ^= UInt32(b)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }
    return crc ^ 0xFFFF_FFFF
}

func deflate(_ d: Data) -> Data {
    var out = Data(count: d.count + 1024)
    let n = out.withUnsafeMutableBytes { dst in
        d.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, d.count + 1024,
                                      src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB)
        }
    }
    return out.prefix(n)
}

func makeZip(_ entries: [TestEntry]) -> Data {
    var out = Data(), central = Data()
    func le16(_ v: Int) -> Data { var x = UInt16(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 2) }
    func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    for e in entries {
        let name = Data(e.name.utf8)
        let payload = e.deflate ? deflate(e.data) : e.data
        let crc = e.badCRC ? crc32(e.data) ^ 0xFFFF : crc32(e.data)
        let usize = UInt32(e.declaredSize ?? e.data.count)
        let offset = UInt32(out.count)
        let method = e.deflate ? 8 : 0
        out += le32(0x0403_4b50) + le16(20) + le16(0x800) + le16(method) + le16(0) + le16(0)
        out += le32(crc) + le32(UInt32(payload.count)) + le32(usize) + le16(name.count) + le16(0) + name + payload
        let madeBy = e.unixMode != nil ? (3 << 8) | 20 : 20
        central += le32(0x0201_4b50) + le16(madeBy) + le16(20) + le16(0x800) + le16(method) + le16(0) + le16(0)
        central += le32(crc) + le32(UInt32(payload.count)) + le32(usize) + le16(name.count) + le16(0) + le16(0)
        central += le16(0) + le16(0) + le32((e.unixMode ?? 0) << 16) + le32(offset) + name
    }
    let cdOffset = UInt32(out.count)
    out += central
    out += le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
    out += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
    return out
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("nb-translator-selftest-\(UUID().uuidString)")
try! fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

func file(_ name: String, _ data: Data) -> URL {
    let url = work.appendingPathComponent(name)
    try! data.write(to: url)
    return url
}

let manifestText = """
{
  // Comments as in Vimium's source manifest
  "manifest_version": 3,
  "name": "Test Ext", /* block comment */
  "version": "1.2.3",
  "homepage_url": "https://example.com/a//b",
  "permissions": ["storage", "scripting", "webNavigation", "notifications", "userScripts",],
  "host_permissions": ["https://example.com/*"],
  "background": { "service_worker": "bg/sw.js" },
  "action": { "default_popup": "popup.html" },
  "side_panel": { "default_path": "panel.html" },
}
"""
let swSource = "chrome.scripting.executeScript({ world: chrome.scripting.ExecutionWorld.ISOLATED, files: ['x.js'] });\n"
let goodEntries = [
    TestEntry(name: "manifest.json", data: Data(manifestText.utf8), deflate: true),
    TestEntry(name: "bg/", data: Data()),
    TestEntry(name: "bg/sw.js", data: Data(swSource.utf8), deflate: true),
    TestEntry(name: "popup.html", data: Data("<!doctype html><html><head><title>p</title></head><body></body></html>".utf8)),
    TestEntry(name: "big.txt", data: Data(String(repeating: "abc", count: 50_000).utf8), deflate: true),
]

// MARK: 1. Safe unpacking: malicious archives

func installMustFail(_ name: String, _ entries: [TestEntry], contains: String, limits: InstallLimits = InstallLimits()) {
    let dir = work.appendingPathComponent("exts-\(name)")
    let pkg = file("\(name).zip", makeZip(entries))
    expectError("malicious:\(name)", contains: contains) { try Installer.install(from: pkg, into: dir, limits: limits) }
    let left = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    check(left.isEmpty, "malicious:\(name):no-leftovers", "\(left)")
}

let base = [TestEntry(name: "manifest.json", data: Data(#"{"manifest_version":3,"name":"x","version":"1"}"#.utf8))]
installMustFail("dotdot", base + [TestEntry(name: "../evil.txt", data: Data("x".utf8))], contains: "invalid path")
installMustFail("dotdot-inner", base + [TestEntry(name: "a/../../evil.txt", data: Data("x".utf8))], contains: "invalid path")
installMustFail("absolute", base + [TestEntry(name: "/tmp/evil.txt", data: Data("x".utf8))], contains: "absolute")
installMustFail("backslash", base + [TestEntry(name: "..\\evil.txt", data: Data("x".utf8))], contains: "backslash")
installMustFail("symlink", base + [TestEntry(name: "link", data: Data("/etc/passwd".utf8), unixMode: 0o120777)], contains: "symbolic link")
installMustFail("symlink-dir-escape", base + [
    TestEntry(name: "d", data: Data("..".utf8), unixMode: 0o120755),
    TestEntry(name: "d/evil.txt", data: Data("x".utf8)),
], contains: "symbolic link")
installMustFail("fifo", base + [TestEntry(name: "p", data: Data(), unixMode: 0o010644)], contains: "special file")
installMustFail("case-duplicate", base + [TestEntry(name: "A.js", data: Data()), TestEntry(name: "a.js", data: Data())], contains: "duplicate")
installMustFail("file-and-dir", base + [TestEntry(name: "a", data: Data()), TestEntry(name: "a/b", data: Data())], contains: "both a file and a folder")
installMustFail("drive", base + [TestEntry(name: "C:/evil.txt", data: Data())], contains: "drive")
installMustFail("control-char", base + [TestEntry(name: "a\u{1}b", data: Data())], contains: "control")
installMustFail("bad-crc", base + [TestEntry(name: "x.js", data: Data("hello".utf8), badCRC: true)], contains: "checksum")
// Declares 10 bytes but inflates to 150 kB: output is capped at the declared size and rejected.
installMustFail("bomb", base + [TestEntry(name: "bomb.txt", data: Data(String(repeating: "a", count: 150_000).utf8), deflate: true, declaredSize: 10)],
                contains: "decompress")
var small = InstallLimits()
small.maxFileBytes = 1000
installMustFail("file-limit", base + [TestEntry(name: "big.bin", data: Data(count: 2000))], contains: "larger than", limits: small)
var few = InstallLimits()
few.maxEntries = 3
installMustFail("count-limit", base + (0..<5).map { TestEntry(name: "f\($0)", data: Data()) }, contains: "entries", limits: few)
var tiny = InstallLimits()
tiny.maxTotalBytes = 3000
tiny.maxFileBytes = 2000
installMustFail("total-limit", base + (0..<3).map { TestEntry(name: "f\($0)", data: Data(count: 1500)) }, contains: "unpacked size", limits: tiny)
installMustFail("no-manifest", [TestEntry(name: "readme.txt", data: Data())], contains: "no manifest.json")
check(!fm.fileExists(atPath: work.appendingPathComponent("evil.txt").path), "malicious:nothing-outside")
check(!fm.fileExists(atPath: "/tmp/evil.txt"), "malicious:nothing-absolute")

expectError("not-a-zip", contains: "not a .zip") { try Installer.install(from: file("x.zip", Data("hello world".utf8)), into: work.appendingPathComponent("e-nz")) }

// Folder source with a symlink is refused.
do {
    let src = work.appendingPathComponent("folder-symlink")
    try! fm.createDirectory(at: src, withIntermediateDirectories: true)
    try! Data(#"{"manifest_version":3,"name":"x","version":"1"}"#.utf8).write(to: src.appendingPathComponent("manifest.json"))
    try! fm.createSymbolicLink(atPath: src.appendingPathComponent("escape").path, withDestinationPath: "/etc")
    expectError("folder:symlink", contains: "symbolic link") { try Installer.install(from: src, into: work.appendingPathComponent("e-fs")) }
}

// MARK: 2. Good packages: zip, crx, folder

let exts = work.appendingPathComponent("Extensions")
let zipData = makeZip(goodEntries)
var record: InstallRecord?
do { record = try Installer.install(from: file("good.zip", zipData), into: exts) } catch { check(false, "install:zip", "\(error)") }
if let r = record {
    let dir = exts.appendingPathComponent(r.id)
    check(r.id == "test-ext", "install:id", r.id)
    check(r.source.kind == "zip" && r.version == "1.2.3" && r.sha256.count == 64, "install:record")
    check(fm.fileExists(atPath: dir.appendingPathComponent("install.json").path), "install:metadata-file")
    let orig = try! String(contentsOf: dir.appendingPathComponent("original/manifest.json"), encoding: .utf8)
    check(orig == manifestText, "install:original-unchanged")
    check(try! Data(contentsOf: dir.appendingPathComponent("original/bg/sw.js")) == Data(swSource.utf8), "install:original-js-unchanged")
    check(try! Data(contentsOf: dir.appendingPathComponent("original/big.txt")).count == 150_000, "install:deflate")
    let attrs = try! fm.attributesOfItem(atPath: dir.appendingPathComponent("original/bg/sw.js").path)
    check((attrs[.posixPermissions] as? Int) == 0o644, "install:no-exec-bit")

    let pm = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("patched/manifest.json"))) as! [String: Any]
    let bg = pm["background"] as! [String: Any]
    check(bg["service_worker"] as? String == "bg/nb-sw-wrapper.js", "translate:sw-wrapper-path", "\(bg)")
    let wrapper = try! String(contentsOf: dir.appendingPathComponent("patched/bg/nb-sw-wrapper.js"), encoding: .utf8)
    check(wrapper.contains("importScripts(\"/nb-compat.js\", \"./sw.js\")"), "translate:sw-wrapper-classic", wrapper)
    check(pm["permissions"] as? [String] == ["storage", "scripting", "webNavigation", "notifications", "userScripts"], "translate:permissions-unchanged")
    check(pm["homepage_url"] as? String == "https://example.com/a//b", "translate:jsonc-keeps-strings")
    let popup = try! String(contentsOf: dir.appendingPathComponent("patched/popup.html"), encoding: .utf8)
    check(popup.contains("<head><script src=\"/nb-compat.js\"></script><title>"), "translate:page-prelude", popup)
    let sw = try! String(contentsOf: dir.appendingPathComponent("patched/bg/sw.js"), encoding: .utf8)
    check(sw.contains("world: \"ISOLATED\""), "translate:execution-world-text", sw)
    let rules = Dictionary(r.translation.hits.map { ($0.rule, $0) }, uniquingKeysWith: { a, _ in a })
    check(rules["manifest-comments"]?.count == 4, "report:manifest-comments", "\(String(describing: rules["manifest-comments"]))")
    check(rules["scripting-execution-world-literal"]?.count == 1, "report:text-count")
    check(rules["missing-namespace-stubs"]?.details == ["notifications"], "report:stubs")
    check(rules["unsupported-manifest-keys"]?.details == ["side_panel"], "report:unsupported-keys")
    check(rules["unsupported-permissions"]?.details.contains("userScripts") == true, "report:unsupported-permissions")
    check(r.translation.issues.first?.severity == .broken && r.translation.issues.first?.feature == "permission userScripts", "report:issues-sorted")

    // Retranslation from original/ gives the same result; a second install replaces (update).
    let again = try? Installer.retranslate(dir)
    check(again?.translation.hits == r.translation.hits, "retranslate:same-hits")
    check((try? Installer.install(from: file("good2.zip", zipData), into: exts))?.id == r.id, "install:update-same-id")
    let names = (try? fm.contentsOfDirectory(atPath: exts.path)) ?? []
    check(names == ["test-ext"], "install:no-staging-left", "\(names)")
}

// crx3: "Cr24", version 3, header length, header, zip.
do {
    var crx = Data("Cr24".utf8)
    var v: UInt32 = 3, len: UInt32 = 8
    crx += Data(bytes: &v, count: 4) + Data(bytes: &len, count: 4) + Data(repeating: 7, count: 8) + zipData
    let r = try Installer.install(from: file("good.crx", crx), into: work.appendingPathComponent("e-crx"))
    check(r.source.kind == "crx", "install:crx")
} catch { check(false, "install:crx", "\(error)") }

// Folder with a nested manifest (source zip of a repo, like JSONVue's src/), module service worker, MV2 scripts.
do {
    let src = work.appendingPathComponent("repo/ext-src")
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try Data(#"{"manifest_version":3,"name":"__MSG_n__","default_locale":"en","version":"2","permissions":["idle"],"background":{"service_worker":"main.js","type":"module"}}"#.utf8)
        .write(to: src.appendingPathComponent("manifest.json"))
    try Data("export {};\n".utf8).write(to: src.appendingPathComponent("main.js"))
    try fm.createDirectory(at: src.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
    try Data(#"{"N":{"message":"Locale Name"}}"#.utf8).write(to: src.appendingPathComponent("_locales/en/messages.json"))
    let r = try Installer.install(from: work.appendingPathComponent("repo"), into: work.appendingPathComponent("e-folder"))
    check(r.id == "locale-name" && r.source.kind == "folder", "install:folder-nested+locale", r.id)
    let w = try String(contentsOf: work.appendingPathComponent("e-folder/locale-name/patched/nb-sw-wrapper.js"), encoding: .utf8)
    check(w.contains("import \"/nb-compat.js\";\nimport \"./main.js\";"), "translate:sw-wrapper-module", w)
} catch { check(false, "install:folder", "\(error)") }

do {
    let src = work.appendingPathComponent("mv2")
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try Data(#"{"manifest_version":2,"name":"Two","version":"1","permissions":["notifications","<all_urls>"],"background":{"scripts":["a.js","b.js"]}}"#.utf8)
        .write(to: src.appendingPathComponent("manifest.json"))
    try Data("1;".utf8).write(to: src.appendingPathComponent("a.js"))
    let r = try Installer.install(from: src, into: work.appendingPathComponent("e-mv2"))
    let pm = try JSONSerialization.jsonObject(with: Data(contentsOf: work.appendingPathComponent("e-mv2/two/patched/manifest.json"))) as! [String: Any]
    check((pm["background"] as? [String: Any])?["scripts"] as? [String] == ["nb-compat.js", "a.js", "b.js"], "translate:mv2-scripts")
    check(r.translation.hits.contains { $0.rule == "manifest-comments" } == false, "translate:strict-json-untouched")
} catch { check(false, "install:mv2", "\(error)") }

// MARK: 3. Text rule

func world(_ js: String) -> (String, Int, Int) {
    let r = TextRules.replaceExecutionWorld(in: Data(js.utf8))
    return (String(decoding: r.text, as: UTF8.self), r.replaced, r.skipped)
}
check(world("f({world:chrome.scripting.ExecutionWorld.ISOLATED})").0 == #"f({world:"ISOLATED"})"#, "text:chrome")
check(world("x=browser.scripting.ExecutionWorld.MAIN;").0 == #"x="MAIN";"#, "text:browser")
check(world("a.world||t.scripting.ExecutionWorld.MAIN}").0 == #"a.world||"MAIN"}"#, "text:minified-receiver")
check(world("y=chrome?.scripting?.ExecutionWorld?.ISOLATED;").0 == #"y="ISOLATED";"#, "text:optional-chaining")
check(world("y=globalThis.chrome.scripting.ExecutionWorld.MAIN;").0 == #"y="MAIN";"#, "text:long-chain")
check(world("y=1;/* chrome.scripting.ExecutionWorld.MAIN */").1 == 0, "text:not-in-block-comment")
check(world("// chrome.scripting.ExecutionWorld.MAIN\ny=1;").1 == 0, "text:not-in-line-comment")
check(world("s='chrome.scripting.ExecutionWorld.MAIN';").1 == 0, "text:not-in-string")
check(world("s=\"x\" + `chrome.scripting.ExecutionWorld.MAIN ${a}`;").1 == 0, "text:not-in-template")
check(world("s=`${chrome.scripting.ExecutionWorld.MAIN}`;").1 == 1, "text:template-expression")
check(world("r=/scripting.ExecutionWorld.MAIN/;").1 == 0, "text:not-in-regex")
check(world("chrome.scripting.ExecutionWorld.MAIN = 1;").1 == 0, "text:not-assignment-target")
check(world("x = f().scripting.ExecutionWorld.MAIN;").1 == 0 && world("x = f().scripting.ExecutionWorld.MAIN;").2 == 1, "text:ambiguous-skipped")
check(world("x = chrome.scripting.ExecutionWorld.MAINLY;").1 == 0, "text:identifier-boundary")
check(world("x = chrome.scripting.ExecutionWorld.MAIN == 'MAIN';").1 == 1, "text:comparison-ok")
check(world("x = a / 2; y = chrome.scripting.ExecutionWorld.MAIN; z = b / 3;").1 == 1, "text:division-not-regex")
check(world("const world = chrome.scripting.ExecutionWorld;").1 == 0, "text:whole-enum-untouched")

func alias(_ js: String) -> (String, Int) {
    let r = TextRules.alias(in: Data(js.utf8), from: "browser", to: "chrome", namespaces: ["permissions", "webNavigation"])
    return (String(decoding: r.text, as: UTF8.self), r.replaced)
}
check(alias("Pi=browser.permissions;Pi.contains({})").0 == "Pi=chrome.permissions;Pi.contains({})", "alias:stored-namespace")
check(alias("x=browser?.webNavigation?.onCommitted").0 == "x=chrome?.webNavigation?.onCommitted", "alias:optional")
check(alias("browser.tabs.query({});browser.runtime.id").1 == 0, "alias:other-namespaces-untouched")
check(alias("o.browser.permissions.contains()").1 == 0, "alias:member-not-free-identifier")
check(alias("mybrowser.permissions;browser.permissionsX").1 == 0, "alias:identifier-boundaries")
check(alias("s='browser.permissions';// browser.permissions").1 == 0, "alias:not-in-strings-or-comments")
check(alias("browser.permissions = {}").1 == 0, "alias:not-assignment-target")
check(TextRules.alias(in: Data("chrome.permissions.contains(x)".utf8), from: "chrome", to: "browser", namespaces: ["permissions"]).replaced == 1, "alias:reverse-direction")
let usage = TextRules.apiRootUsage(in: Data("const a=globalThis.browser; browser.tabs.query(); chrome.runtime.id; mybrowser.x; browserX.y".utf8))
check(usage.browser == 2 && usage.chrome == 1, "alias:usage-count", "\(usage)")

// MARK: 4. JSONC

let jc = JSONC.strip("{\"a\": \"// not a comment\", /* c */ \"b\": [1, 2,], // end\n}")
check(jc.comments == 2 && jc.trailingCommas == 2, "jsonc:counts", "\(jc)")
check((try? JSONSerialization.jsonObject(with: Data(jc.json.utf8)) as? [String: Any])?["a"] as? String == "// not a comment", "jsonc:string-kept")

// MARK: 5. Prelude behaviour in JavaScriptCore with a fake WebKit API

var lastPrelude: URL!

func runPrelude(permissions: [String]) -> JSContext {
    let ctx = JSContext()!
    ctx.exceptionHandler = { _, e in failures += 1; print("FAIL prelude-js \(e?.toString() ?? "?")") }
    // Like WebKit: every read of a namespace returns a fresh wrapper (as after a GC), the
    // namespace properties cannot be replaced, and methods check their receiver.
    ctx.evaluateScript("""
        var setTimeout = (f) => f();
        var brands = new WeakSet();
        var illegal = () => { throw new TypeError("Illegal invocation"); };
        var makers = {
          runtime: () => ({ id: "x", onMessage: { addListener() {} }, getURL(p) { if (!brands.has(this)) illegal(); return "ext:/" + p; } }),
          scripting: () => ({ executeScript() { if (!brands.has(this)) illegal(); return Promise.resolve([]); } }),
          webNavigation: () => ({ onCompleted: { addListener() {} } }),
          webRequest: () => ({ onBeforeRequest: { addListener() {} } }),
          tabs: () => ({ query() { if (!brands.has(this)) illegal(); return Promise.resolve([1]); } }),
          permissions: () => ({
            contains(q) {
              if (!brands.has(this)) illegal();
              const p = (q && q.permissions) || [];
              for (const x of p) if (!["storage", "tabs"].includes(x))
                throw new Error("Invalid call to permissions.contains(). The 'permissions' value is invalid, because '" + x + "' is not a valid permission.");
              return Promise.resolve(true);
            },
          }),
        };
        var chrome = {};
        for (const [name, make] of Object.entries(makers))
          Object.defineProperty(chrome, name, { get() { const o = make(); brands.add(o); return o; }, configurable: false, enumerable: true });
        var browser = chrome;
        """)
    var manifest: [String: Any] = ["manifest_version": 3, "name": "p", "version": "1", "permissions": permissions,
                                   "background": ["service_worker": "sw.js"]]
    manifest["action"] = ["default_popup": "p.html"]
    let src = work.appendingPathComponent("prelude-\(UUID().uuidString)")
    try! fm.createDirectory(at: src, withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: manifest).write(to: src.appendingPathComponent("manifest.json"))
    try! Data("1;".utf8).write(to: src.appendingPathComponent("sw.js"))
    let out = work.appendingPathComponent("prelude-out-\(UUID().uuidString)")
    _ = try! Translator.translate(original: src, into: out)
    lastPrelude = out.appendingPathComponent("nb-compat.js")
    let prelude = try! String(contentsOf: out.appendingPathComponent("nb-compat.js"), encoding: .utf8)
    ctx.evaluateScript(prelude)
    return ctx
}

let ctx = runPrelude(permissions: ["scripting", "webNavigation", "webRequest", "notifications", "idle", "offscreen", "storage"])
@discardableResult func js(_ s: String) -> String { ctx.evaluateScript(s)?.toString() ?? "nil" }
// Rules count as applied only once the extension actually reads a stand-in.
check(js("__neuralbrowserCompat.applied.length") == "0", "prelude:applied-only-when-used", js("__neuralbrowserCompat.applied.join(',')"))
check(js("chrome.scripting.ExecutionWorld.ISOLATED + '/' + chrome.scripting.ExecutionWorld.MAIN") == "ISOLATED/MAIN", "prelude:execution-world")
check(js("typeof chrome.webNavigation.onHistoryStateUpdated.addListener") == "function", "prelude:webnavigation-event")
check(js("chrome.webNavigation.onHistoryStateUpdated.addListener(function f(){}); chrome.webNavigation.onHistoryStateUpdated.hasListeners()") == "true", "prelude:inert-event-listeners")
js("var r1, r2, r3; chrome.permissions.contains({permissions:['webRequestBlocking']}).then(v => r1 = v); chrome.permissions.contains({permissions:['storage']}).then(v => r2 = v); chrome.permissions.contains({permissions:['downloads']}, v => r3 = v);")
check(js("String(r1) + '/' + String(r2) + '/' + String(r3)") == "false/true/false", "prelude:permissions-contains", js("String(r1) + '/' + String(r2) + '/' + String(r3)"))
check(js("try { chrome.permissions.contains(); 'no' } catch (e) { 'other errors still throw' }") == "no", "prelude:contains-passthrough")
js("var nid; chrome.notifications.create({type:'basic', title:'t', message:'m'}).then(v => nid = v);")
check(js("nid").hasPrefix("nb-notification-"), "prelude:notifications-create")
check(js("typeof chrome.notifications.onClicked.addListener") == "function", "prelude:notifications-events")
js("var st; chrome.idle.queryState(60, v => st = v);")
check(js("st") == "active", "prelude:idle")
js("var off; chrome.offscreen.createDocument({}).catch(e => off = e.message);")
check(js("off").contains("not supported"), "prelude:offscreen-rejects")
check(js("chrome.webRequest.OnBeforeSendHeadersOptions.REQUEST_HEADERS") == "requestHeaders", "prelude:webrequest-constants")
check(js("typeof chrome.runtime.onUpdateAvailable.addListener") == "function", "prelude:runtime-events")
check(js("typeof chrome.sidePanel") == "undefined", "prelude:no-stub-without-permission")
check(js("chrome.runtime.getURL('a') + '/' + chrome.runtime.id") == "ext:/a/x", "prelude:methods-bound-to-real-object")
js("var tq; chrome.tabs.query({}).then(v => tq = v.length);")
check(js("tq") == "1", "prelude:untouched-namespace-works")
check(js("typeof browser.notifications.create === 'function' && browser.webNavigation !== undefined") == "true", "prelude:browser-stays-real-but-sees-stubs")
check(js("Object.getOwnPropertyDescriptor(globalThis, 'browser').value !== chrome") == "true", "prelude:only-chrome-is-proxied")
check(js("'notifications' in chrome && 'onHistoryStateUpdated' in chrome.webNavigation && !('sidePanel' in chrome)") == "true", "prelude:in-operator")
check(js("Object.keys(chrome.webNavigation).includes('onHistoryStateUpdated') && Object.keys(chrome).includes('notifications')") == "true", "prelude:keys")
check(js("__neuralbrowserCompat.applied.join(',')").contains("permissions-contains-unknown"), "prelude:applied-list", js("__neuralbrowserCompat.applied.join(',')"))
check(js("__neuralbrowserCompat.failed.length") == "0", "prelude:no-failures", js("__neuralbrowserCompat.failed.join(',')"))

// Once WebKit provides an API, the prelude leaves it alone.
let ctx2 = JSContext()!
ctx2.evaluateScript("var chrome = { scripting: { ExecutionWorld: { ISOLATED: 'native' } }, runtime: {} }; var setTimeout = f => f();")
ctx2.evaluateScript(try! String(contentsOf: lastPrelude, encoding: .utf8))
check(ctx2.evaluateScript("chrome.scripting.ExecutionWorld.ISOLATED")?.toString() == "native", "prelude:native-wins")

// MARK: 6. The translator never widens permissions

for (key, value) in [("permissions", ["storage", "tabs"]), ("host_permissions", ["<all_urls>"])] as [(String, Any)] {
    var patched: [String: Any] = ["manifest_version": 3, "permissions": ["storage"]]
    patched[key] = value
    expectError("guard:\(key)", contains: "changed") {
        try TranslatorTesting.verifyPermissions(original: ["manifest_version": 3, "permissions": ["storage"]], patched: patched)
    }
}
expectError("guard:background-type", contains: "changed") {
    try TranslatorTesting.verifyPermissions(original: ["background": ["service_worker": "a.js"]],
                                            patched: ["background": ["service_worker": "a.js", "type": "module"]])
}

// MARK: Summary

print("translator-selftest: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
