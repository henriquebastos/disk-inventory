#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 || "$1" != /* ]]; then echo "usage: $0 /absolute/external/artifact-root" >&2; exit 2; fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$1"
out=$(cd "$1" && pwd -P)
case "$out/" in "$repo/"*) echo "output must be outside repository" >&2; exit 2;; esac
export REPO_ROOT="$repo" BRIDGE_ROOT="$out/bridge"
export TMPDIR="$out/tmp" CLANG_MODULE_CACHE_PATH="$out/module-cache"
mkdir -p "$TMPDIR" "$out/project" "$CLANG_MODULE_CACHE_PATH"
bash "$repo/scripts/build-bridge.sh" "$BRIDGE_ROOT"
# XcodeGen substitutions resolve all sources externally; no generated project enters Git.
xcodegen generate --spec "$repo/native/project.yml" --project "$out/project"
xcodebuild -project "$out/project/DiskInventory.xcodeproj" -scheme DiskInventory \
  -configuration Debug -derivedDataPath "$out/DerivedData" \
  BRIDGE_ROOT="$BRIDGE_ROOT" CLANG_MODULE_CACHE_PATH="$out/module-cache" build-for-testing
printf 'App: %s\n' "$out/DerivedData/Build/Products/Debug/DiskInventory.app"
