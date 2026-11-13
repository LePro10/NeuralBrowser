#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Starts the bundled app (builds it first if missing). Extra arguments are
# passed through, e.g. scripts/run.sh --data-dir /tmp/nb-profile
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NeuralBrowser.app"
[ -d "$APP" ] || "$ROOT/scripts/bundle.sh"
if [ "$#" -eq 0 ]; then
  open "$APP"
else
  exec "$APP/Contents/MacOS/NeuralBrowser" "$@"
fi
