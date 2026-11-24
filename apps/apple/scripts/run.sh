#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Builds the current source (always; incremental, so usually seconds), quits a
# running NeuralBrowser and starts the fresh app.
#   scripts/run.sh                          build and open
#   scripts/run.sh --clean                  delete all build output first (slow full rebuild)
#   scripts/run.sh --data-dir /tmp/nb-x     extra arguments go to the app
# Never touches browser data (profile, logins, extensions).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
APP="$ROOT/build/NeuralBrowser.app"

if [ "${1:-}" = "--clean" ]; then
  shift
  echo "Cleaning build output…"
  rm -rf "$ROOT/.build" "$ROOT/build"
  (cd "$REPO" && cargo clean)
fi

"$ROOT/scripts/bundle.sh"

# Quit a running copy so the new build is the one that starts.
if pgrep -f "NeuralBrowser.app/Contents/MacOS/NeuralBrowser" >/dev/null; then
  osascript -e 'tell application id "'"$(defaults read "$APP/Contents/Info" CFBundleIdentifier)"'" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -f "NeuralBrowser.app/Contents/MacOS/NeuralBrowser" >/dev/null && [ $i -lt 50 ]; do
    sleep 0.2; i=$((i + 1))
  done
  pkill -f "NeuralBrowser.app/Contents/MacOS/NeuralBrowser" 2>/dev/null || true
fi

if [ "$#" -eq 0 ]; then
  open "$APP"
else
  exec "$APP/Contents/MacOS/NeuralBrowser" "$@"
fi
