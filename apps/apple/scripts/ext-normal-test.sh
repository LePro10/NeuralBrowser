#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Extension test along the user's path, on a throw-away persistent profile:
#   run 1: the app is started like from Finder (LaunchServices), the package is installed the way
#          File > Install Extension... does it, a local login page is opened, the sidebar button is
#          clicked: the popup must show TEXT and a message must have gone content script -> background;
#   run 2: app restarted on the same profile, same checks; then wait MINUTES and check once more.
# Also checks that extension pages share the tabs' website data store (tracking prevention stays on;
# the extension origin is exempted, see ExtensionManager.exemptFromTrackingPrevention). Exit 0 = passed.
#
# usage: scripts/ext-normal-test.sh PACKAGE FOLDER-ID "TEXT" [MINUTES]
#   scripts/ext-normal-test.sh ~/Downloads/bitwarden-chrome-2026.10.2.zip bitwarden-password-manager "Log in" 3
#   scripts/ext-normal-test.sh TestExtensions/hello hello-neuralbrowser "Active tab" 1   (FOLDER-ID = id the installer prints)
# Message check (content script -> background), built in for these two:
#   hello-neuralbrowser: the content script's ping is answered with "pong" (mark on the page);
#   bitwarden-password-manager: its content script asks the background to inject the autofill script;
#     the popup then asks that script for the login form's fields (must be "email,password").
#   Others: MSG_CHECK='JS returning truthy' MSG_TARGET=tab|popup (async function body, polled).
# env: APP=path/to/NeuralBrowser.app (default build/NeuralBrowser.app), PORT=8767 (local login page),
#      ITP_SEED=observations.db  copy this tracking-prevention database into the profile's store first
#      (worst case: an aged database that already deletes data), KEEP=1 keeps the profile.
# The window opens on screen; a run takes about MINUTES + 1 minute.
set -eu
[ $# -ge 3 ] || { sed -n '6,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/build/NeuralBrowser.app}"
PKG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
ID="$2"; TEXT="$3"; MINUTES="${4:-3}"; PORT="${PORT:-8767}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nb-ext-normal.XXXXXX")"
PROFILE="$WORK/profile"; mkdir -p "$PROFILE" "$WORK/www"
SERVER=""
cleanup() {
  [ -n "$SERVER" ] && { kill "$SERVER"; wait "$SERVER"; } 2>/dev/null
  [ -n "${KEEP:-}" ] && echo "kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

# Local login page (content scripts of password managers need a form; nothing is ever submitted).
cat > "$WORK/www/login.html" <<'HTML'
<!doctype html><html><head><title>Login test</title></head><body>
<form action="/done" method="post"><label>Email <input type="email" id="email" name="email" autocomplete="username"></label>
<label>Password <input type="password" id="password" name="password" autocomplete="current-password"></label>
<button type="submit">Log in</button></form></body></html>
HTML
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
SERVER=$!
sleep 1
PAGE="http://127.0.0.1:$PORT/login.html"

# Step lists (JSON built by Python so TEXT and paths are escaped correctly).
python3 -I - "$WORK" "$PKG" "$ID" "$TEXT" "$MINUTES" "$PAGE" "${MSG_CHECK:-}" "${MSG_TARGET:-tab}" <<'PY'
import json, sys
work, pkg, ext, text, minutes, page, msg_js, msg_target = sys.argv[1:]
probe = ("const t = document.body ? document.body.innerText : ''; "
         "return t.includes(%s) ? t.slice(0, 120) : ''" % json.dumps(text))
if not msg_js and ext == "hello-neuralbrowser":
    msg_js, msg_target = "return document.documentElement.dataset.helloBackground === 'pong' ? 'pong' : ''", "tab"
if not msg_js and ext == "bitwarden-password-manager":
    msg_js, msg_target = (
        "const [t] = await chrome.tabs.query({active: true, currentWindow: true}); "
        "const send = m => Promise.race([chrome.tabs.sendMessage(t.id, m), new Promise(ok => setTimeout(() => ok(null), 3000))]); "
        "await send({command: 'startAutofillMonitors'}); const r = await send({command: 'collectPageDetailsImmediately'}); "
        "const names = r && r.fields ? r.fields.map(f => f.htmlName).join(',') : ''; "
        "return names === 'email,password' ? names : ''"), "popup"
if not msg_js:
    sys.exit("no message check for %s: set MSG_CHECK (and MSG_TARGET=tab|popup)" % ext)
def message(label):
    target = "popup:" + ext if msg_target == "popup" else "tab"
    return [{"eval": msg_js, "target": target, "until": True, "timeout": 20, "label": label + " msg", "check": "message"}]
def check(label):
    steps = message(label) if msg_target == "tab" else []
    steps += [{"clickAction": ext, "label": label},
              {"eval": probe, "target": "popup:" + ext, "until": True, "timeout": 25, "label": label + " popup"}]
    if msg_target == "popup":
        steps += message(label)
    return steps + [{"closePopup": ext}, {"wait": 1}]
run1 = [{"open": page, "wait": 1}, {"install": pkg}, {"wait": 2}, {"open": page, "wait": 3}] \
       + check("after install") + [{"errors": True}]
run2 = [{"open": page, "wait": 3}] + check("after restart") + [{"wait": float(minutes) * 60}, {"open": page, "wait": 3}] \
       + check("after %s min" % minutes) + [{"errors": True}]
for name, steps in (("run1", run1), ("run2", run2)):
    json.dump({"steps": steps}, open("%s/%s.json" % (work, name), "w"))
PY

run() { # $1 = step file, $2 = report file; started via LaunchServices like a user would
  open -n -W --stdout "$2" --stderr "$WORK/stderr.log" "$APP" --args \
    --ext-script "$1" --normal-mode --data-dir "$PROFILE" --timeout "$(( MINUTES * 60 + 150 ))"
}

if [ -n "${ITP_SEED:-}" ]; then
  # Learn the store identifier from a short run, then put the database in place.
  echo '{"steps":[{"open":"about:blank"}]}' > "$WORK/probe.json"
  run "$WORK/probe.json" "$WORK/probe.out"
  STORE=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["dataStores"]["tabs"]["identifier"])' "$WORK/probe.out")
  BUNDLE=$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)
  DEST="$HOME/Library/WebKit/$BUNDLE/WebsiteDataStore/$(echo "$STORE" | tr 'A-Z' 'a-z')/ResourceLoadStatistics"
  mkdir -p "$DEST"; rm -f "$DEST"/observations.db*; cp "$ITP_SEED" "$DEST/observations.db"
  echo "seeded tracking-prevention database into $DEST"
fi

run "$WORK/run1.json" "$WORK/run1.out"
run "$WORK/run2.json" "$WORK/run2.out"

python3 -I - "$WORK/run1.out" "$WORK/run2.out" <<'PY'
import json, sys
ok = True
for path in sys.argv[1:]:
    d = json.load(open(path))
    run_ok = d.get("ok") is True and d.get("mode") == "normal"
    for s in d["steps"]:
        if "clickAction" in s:
            print("%-22s click: presented=%s popover=%s" % (s.get("label"), s.get("presented"), s.get("popoverShown")))
            run_ok &= bool(s.get("presented"))
        if "satisfied" in s:
            print("%-22s %s %r" % (s.get("label"), "OK" if s.get("satisfied") else "MISSING", (s.get("value") or s.get("jsError") or "")[:60]))
            run_ok &= bool(s.get("satisfied"))
        if "install" in s:
            print("install: id=%s loaded=%s %s" % (s.get("id"), s.get("loaded"), s.get("error") or ""))
            run_ok &= bool(s.get("loaded"))
    pages = d.get("dataStores", {}).get("extensionPages") or {}
    store_ok = (pages.get("sameAsTabs") is True and pages.get("isDefault") is False
                and d["dataStores"].get("allExtensionsUseIt") is True)
    print("extension pages store: %s" % pages)
    errors = d.get("finalErrors", {})
    if any(errors.values()):
        print("extension errors: %s" % json.dumps(errors)[:400])
    if d.get("error"):
        print("error: %s" % d["error"])
    ok &= run_ok and store_ok
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
