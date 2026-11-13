#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Content blocking in a real window, against a local page (no network, nothing persisted):
#   1 on:        ad script, third-party tracker and ad element are blocked, the page's own script runs;
#   2 site off:  --shield-off 127.0.0.1, nothing is blocked;
#   3 off -> on: starts on a switched-off site that navigates to a filtered one (rules must attach);
#   4 on -> off: starts on a filtered site that navigates to a switched-off one (rules must detach).
# usage: scripts/shield-test.sh      env: APP=path/to/NeuralBrowser.app, PORT=8768. Exit 0 = passed.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${APP:-$ROOT/build/NeuralBrowser.app}/Contents/MacOS/NeuralBrowser"
PORT="${PORT:-8768}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nb-shield.XXXXXX")"
mkdir -p "$WORK/www/ads"
SERVER=""
cleanup() {
  if [ -n "$SERVER" ]; then kill "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/www/index.html" <<HTML
<!doctype html><title>Shield test</title>
<p>Content blocking test page</p>
<div class="ad-banner">ADVERTISEMENT</div>
<script src="/app.js"></script>
<script src="/ads/banner.js"></script>
<script src="http://localhost:$PORT/tracker.js"></script>
HTML
echo "<!doctype html><title>Go</title><p>Redirecting elsewhere</p><script>location.href='http://127.0.0.1:$PORT/index.html'</script>" > "$WORK/www/go.html"
echo 'window.appLoaded = true' > "$WORK/www/app.js"
echo 'window.adLoaded = true' > "$WORK/www/ads/banner.js"
echo 'window.trackerLoaded = true' > "$WORK/www/tracker.js"
printf '%s\n' '! Title: test list' '/ads/banner.js' '||localhost^$third-party' '##.ad-banner' > "$WORK/list.txt"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
SERVER=$!
sleep 1

EVAL='location.host + " ad=" + !!window.adLoaded + " tracker=" + !!window.trackerLoaded + " app=" + !!window.appLoaded + " banner=" + getComputedStyle(document.querySelector(".ad-banner")).display'
BLOCKED="127.0.0.1:$PORT ad=false tracker=false app=true banner=none"
OPEN="127.0.0.1:$PORT ad=true tracker=true app=true banner=block"
FAILED=0
check() { # name expected url [options]
  name="$1"; expected="$2"; url="$3"; shift 3
  out="$("$BIN" --smoke-test "$url" --shield-lists "$WORK/list.txt" --eval "$EVAL" --timeout 40 "$@" 2>/dev/null || true)"
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("eval"))' 2>/dev/null || echo "no report")"
  if [ "$got" = "$expected" ]; then echo "ok    $name"; else echo "FAIL  $name: got '$got', expected '$expected'"; FAILED=1; fi
}
check "1 on"        "$BLOCKED" "http://127.0.0.1:$PORT/index.html"
check "2 site off"  "$OPEN"    "http://127.0.0.1:$PORT/index.html" --shield-off 127.0.0.1
check "3 off -> on" "$BLOCKED" "http://localhost:$PORT/go.html"    --shield-off localhost
check "4 on -> off" "$OPEN"    "http://localhost:$PORT/go.html"    --shield-off 127.0.0.1
check "5 private"   "$BLOCKED" "http://127.0.0.1:$PORT/index.html" --private
exit $FAILED
