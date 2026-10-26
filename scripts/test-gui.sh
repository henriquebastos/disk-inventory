#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 || "$1" != /* ]]; then echo "usage: $0 /absolute/external/artifact-root" >&2; exit 2; fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
out=$(cd "$1" && pwd -P)
case "$out/" in "$repo/"*) echo "output must be outside repository" >&2; exit 2;; esac
export TMPDIR="$out/tmp"
result="$out/UI-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project "$out/project/DiskInventory.xcodeproj" -scheme DiskInventory \
  -configuration Debug -derivedDataPath "$out/DerivedData" \
  BRIDGE_ROOT="$out/bridge" CLANG_MODULE_CACHE_PATH="$out/module-cache" \
  -destination 'platform=macOS' -resultBundlePath "$result" test-without-building
printf 'Results: %s\n' "$result"
