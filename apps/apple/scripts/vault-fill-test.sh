#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Password fill routine and its guard in a real window, against a local page (no vault, no
# server, no real credentials; only dummy values; nothing persisted). The page has hidden,
# disabled and read-only decoy password fields before the real one, an iframe with a password
# field, React-like inputs that only react to `input` events and a second form. Checks: the
# guard refuses http, other hosts, ports and mixed content; only the visible main-frame fields
# get the dummy values; the page world sees no helper globals; a focused field wins.
# usage: scripts/vault-fill-test.sh      env: APP=path/to/NeuralBrowser.app, PORT=8769. Exit 0 = passed.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${APP:-$ROOT/build/NeuralBrowser.app}/Contents/MacOS/NeuralBrowser"
PORT="${PORT:-8769}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nb-vault.XXXXXX")"
mkdir -p "$WORK/www"
SERVER=""
cleanup() {
  if [ -n "$SERVER" ]; then kill "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/www/login.html" <<'HTML'
<!doctype html><title>Vault fill test</title>
<p>Sign in</p>
<input type="text" id="outsideUser" placeholder="outside any form">
<form id="login">
  <input type="password" id="decoyNone" data-decoy style="display:none">
  <input type="password" id="decoyHidden" data-decoy style="visibility:hidden">
  <input type="password" id="decoyOpacity" data-decoy style="opacity:0">
  <input type="password" id="decoyZero" data-decoy style="width:0;height:0;border:0;padding:0">
  <input type="password" id="decoyOffPage" data-decoy style="position:absolute;left:-9999px">
  <div style="display:none"><input type="password" id="decoyParent" data-decoy></div>
  <input type="password" id="decoyDisabled" data-decoy disabled>
  <input type="password" id="decoyReadonly" data-decoy readonly>
  <input type="text" id="user" placeholder="user name">
  <input type="text" id="hiddenUser" style="display:none">
  <input type="password" id="pw" placeholder="password">
</form>
<iframe src="/frame.html" width="300" height="80"></iframe>
<form id="signup">
  <input type="email" id="user2" placeholder="e-mail">
  <input type="password" id="pw2" placeholder="new password">
</form>
<script>
  // Like React: the element's own value property records what script sets, and the
  // input listener only reports a change when the DOM value differs from that record.
  const nativeValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
  window.reactState = {};
  window.changeCount = 0;
  for (const id of ['user', 'pw']) {
    const el = document.getElementById(id);
    let tracked = el.value;
    Object.defineProperty(el, 'value', {
      configurable: true,
      get() { return nativeValue.get.call(this); },
      set(v) { tracked = String(v); nativeValue.set.call(this, v); },
    });
    el.addEventListener('input', () => {
      const now = nativeValue.get.call(el);
      if (now !== tracked) { tracked = now; window.reactState[id] = now; }
    });
    el.addEventListener('change', () => { window.changeCount += 1; });
  }
  window.__globalsBefore = Object.getOwnPropertyNames(window);
</script>
HTML
echo '<!doctype html><title>Frame</title><form><input type="text" id="fuser"><input type="password" id="fpw"></form>' > "$WORK/www/frame.html"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
SERVER=$!
sleep 1

OUT="$("$BIN" --smoke-test "http://127.0.0.1:$PORT/login.html" --vault-fill-test --timeout 40 2>/dev/null || true)"
printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    print("FAIL  no report"); sys.exit(1)
checks = (r.get("vaultFill") or {}).get("checks") or []
if not checks:
    print("FAIL  no vault fill checks (error: %s)" % r.get("error")); sys.exit(1)
failed = 0
for c in checks:
    ok = c.get("ok") is True
    failed += 0 if ok else 1
    detail = "" if ok or not c.get("detail") else " (" + str(c["detail"]) + ")"
    print(("ok    " if ok else "FAIL  ") + c["name"] + detail)
print("%d passed, %d failed" % (len(checks) - failed, failed))
sys.exit(1 if failed or not r.get("ok") else 0)
'
