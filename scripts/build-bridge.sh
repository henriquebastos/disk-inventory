#!/bin/bash
# Generate from the pinned runtime archive; keep every product outside the repository.
# An exported CARGO_TARGET_DIR is used (one Cargo tree per check root); the default is OUT/target.
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
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$out/target}
case "$CARGO_TARGET_DIR" in
  /*) ;;
  *) echo "CARGO_TARGET_DIR must be absolute" >&2; exit 2;;
esac
case "$CARGO_TARGET_DIR/" in "$repo/"*) echo "CARGO_TARGET_DIR must be outside the repository" >&2; exit 2;; esac
export CARGO_NET_OFFLINE=true
export TMPDIR="$out/tmp"
mkdir -p "$out/generated" "$out/swift-module-cache" "$TMPDIR"
cargo build --offline --locked --release --lib --features bridge
# The Xcode project links this copy. An unchanged archive is not copied, so Xcode does not relink.
archive="$out/libdisk_map_bench.a"
cmp -s "$CARGO_TARGET_DIR/release/libdisk_map_bench.a" "$archive" ||
  cp "$CARGO_TARGET_DIR/release/libdisk_map_bench.a" "$archive"
cargo run --offline --locked --features bridge-build --bin bridge-bindgen -- \
  "$archive" "$out/generated" \
  --swift-sources --headers --modulemap \
  --module-name disk_map_benchFFI --modulemap-filename module.modulemap
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$out/swift-module-cache" \
  -I "$out/generated" "$out/generated/disk_map_bench.swift" \
  "$repo/tests/bridge-smoke.swift" "$archive" \
  -framework Foundation -o "$out/bridge-smoke"
echo "Generated bindings: $out/generated"
echo "Smoke executable: $out/bridge-smoke"
