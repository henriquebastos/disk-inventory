#!/bin/bash
# Generate from the pinned runtime archive; keep every product outside the repository.
set -euo pipefail
if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "usage: $0 /absolute/external/output-root" >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$1"
out=$(cd "$1" && pwd -P)
case "$out/" in "$repo/"*) echo "output must be outside the repository" >&2; exit 2;; esac
cd "$repo"
export CARGO_TARGET_DIR="$out/target"
export CARGO_NET_OFFLINE=true
export TMPDIR="$out/tmp"
mkdir -p "$out/generated" "$out/swift-module-cache" "$TMPDIR"
cargo build --offline --locked --release --lib --features bridge
cargo run --offline --locked --features bridge-build --bin bridge-bindgen -- \
  "$CARGO_TARGET_DIR/release/libdisk_map_bench.a" "$out/generated" \
  --swift-sources --headers --modulemap \
  --module-name disk_map_benchFFI --modulemap-filename module.modulemap
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$out/swift-module-cache" \
  -I "$out/generated" "$out/generated/disk_map_bench.swift" \
  "$repo/tests/bridge-smoke.swift" "$CARGO_TARGET_DIR/release/libdisk_map_bench.a" \
  -framework Foundation -o "$out/bridge-smoke"
echo "Generated bindings: $out/generated"
echo "Smoke executable: $out/bridge-smoke"
