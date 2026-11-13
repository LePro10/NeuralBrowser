#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Builds neural_core for macOS (aarch64-apple-darwin) and writes
#   core/dist/apple/{libneural_core.a, neural_core.swift,
#                    neural_coreFFI.h, module.modulemap}
# Extra targets can be added to TARGETS once installed (e.g. via rustup).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/core/dist/apple"
TARGETS=("aarch64-apple-darwin")

cd "$ROOT"
for t in "${TARGETS[@]}"; do
  cargo build --release -p neural_core --target "$t"
done

rm -rf "$OUT"
mkdir -p "$OUT"
LIB="$ROOT/target/${TARGETS[0]}/release/libneural_core.a"
cp "$LIB" "$OUT/libneural_core.a"

# Library mode: bindings are derived from the metadata embedded in the library.
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
cargo run --release -q -p uniffi-bindgen -- generate \
  --library "$LIB" --language swift --out-dir "$GEN"

cp "$GEN/neural_core.swift" "$OUT/neural_core.swift"
cp "$GEN/neural_coreFFI.h" "$OUT/neural_coreFFI.h"
# SwiftPM / clang expect the file to be called module.modulemap.
cp "$GEN/neural_coreFFI.modulemap" "$OUT/module.modulemap"

ls -l "$OUT"
