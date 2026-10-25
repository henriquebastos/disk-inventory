#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 || "$1" != /* ]]; then
  echo "usage: $0 /absolute/external/output-root" >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
bash "$repo/scripts/build-bridge.sh" "$1"
out=$(cd "$1" && pwd -P)
export CARGO_TARGET_DIR="$out/target"
export CARGO_NET_OFFLINE=true
export TMPDIR="$out/tmp"
export BRIDGE_TEST_ROOT="$out"
cd "$repo"
cargo fmt --check
cargo test --offline --locked
cargo test --offline --locked --features bridge
cargo clippy --offline --locked --all-targets -- -D warnings
cargo clippy --offline --locked --all-targets --features bridge -- -D warnings
cargo clippy --offline --locked --all-targets --features bridge-build -- -D warnings
fixture=$(mktemp -d "$out/swift-fixture.XXXXXX")
"$out/bridge-smoke" "$fixture"
echo "Owned Swift fixture retained: $fixture"
