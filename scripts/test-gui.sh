#!/bin/bash
# Runs the built tests of scripts/build-gui.sh. Extra arguments go to xcodebuild, such as
# -only-testing:ExplorerModelTests. RESULT_BUNDLE names the result bundle (default: under G).
set -euo pipefail
if [[ $# -lt 1 || "$1" != /* ]]; then
  echo "usage: $0 /absolute/external/artifact-root [xcodebuild test options...]" >&2; exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
out=$(cd "$1" && pwd -P)
shift
case "$out/" in "$repo/"*) echo "output must be outside repository" >&2; exit 2;; esac
export TMPDIR="$out/tmp"
result=${RESULT_BUNDLE:-"$out/UI-$(date +%Y%m%d-%H%M%S).xcresult"}
# UI tests share one screen and pointer, so test classes never run in parallel clones.
xcodebuild -project "$out/project/DiskInventory.xcodeproj" -scheme DiskInventory \
  -configuration Debug -derivedDataPath "$out/DerivedData" \
  BRIDGE_ROOT="$out/bridge" CLANG_MODULE_CACHE_PATH="$out/module-cache" \
  -destination 'platform=macOS' -resultBundlePath "$result" -parallel-testing-enabled NO \
  "$@" test-without-building
printf 'Results: %s\n' "$result"
