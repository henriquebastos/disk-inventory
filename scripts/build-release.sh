#!/bin/bash
# Builds the Release app for Apple silicon with a version and writes OUT/DiskInventory.app.
# It signs nothing and needs no secrets; scripts/package-release.sh signs and packages the app.
# Usage: scripts/build-release.sh VERSION /absolute/external/output-root
#   VERSION  such as 1.2.0; it becomes CFBundleShortVersionString and CFBundleVersion
# The build folder OUT/build is replaced at the start and removed after a successful build.
set -euo pipefail
if [[ $# -ne 2 || "$2" != /* ]]; then
  awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2
fi
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be like 1.2.0: $version" >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$2"
out=$(cd "$2" && pwd -P)
case "$out/" in "$repo/"*) echo "output must be outside the repository" >&2; exit 2;; esac
build="$out/build"
rm -rf "$build" "$out/DiskInventory.app"
export REPO_ROOT="$repo" BRIDGE_ROOT="$build/bridge"
export TMPDIR="$build/tmp" CLANG_MODULE_CACHE_PATH="$build/module-cache"
mkdir -p "$TMPDIR" "$build/project" "$CLANG_MODULE_CACHE_PATH"
bash "$repo/scripts/build-bridge.sh" "$BRIDGE_ROOT"
xcodegen generate --spec "$repo/native/project.yml" --project "$build/project"
xcodebuild -project "$build/project/DiskInventory.xcodeproj" -scheme DiskInventory \
  -configuration Release -derivedDataPath "$build/DerivedData" \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" \
  BRIDGE_ROOT="$BRIDGE_ROOT" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" build
built="$build/DerivedData/Build/Products/Release/DiskInventory.app"
bash "$repo/scripts/check-app-icon.sh" "$built"
shown=$(plutil -extract CFBundleShortVersionString raw -o - "$built/Contents/Info.plist")
[[ $shown == "$version" ]] || { echo "app version is '$shown', expected $version" >&2; exit 1; }
ditto "$built" "$out/DiskInventory.app"
rm -rf "$build"
printf 'App: %s\n' "$out/DiskInventory.app"
