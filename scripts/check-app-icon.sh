#!/bin/bash
# Checks that a built DiskInventory.app carries the icon that actool compiles from
# native/Explorer/AppIcon.icon. Reads the bundle only.
set -euo pipefail
if [[ $# -ne 1 || ! -f "$1/Contents/Info.plist" ]]; then
  echo "usage: $0 /path/to/DiskInventory.app" >&2; exit 2
fi
app=$1
resources="$app/Contents/Resources"
fail() { echo "app icon check failed: $*" >&2; exit 1; }
for key in CFBundleIconName CFBundleIconFile; do
  value=$(plutil -extract "$key" raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
  [[ "$value" == AppIcon ]] || fail "Info.plist $key is '$value', expected AppIcon"
done
[[ -s "$resources/AppIcon.icns" ]] || fail "$resources/AppIcon.icns is missing"
[[ -s "$resources/Assets.car" ]] || fail "$resources/Assets.car is missing"
# The default, dark and mono looks of the .icon become one AppIcon image stack each.
xcrun assetutil --info "$resources/Assets.car" | python3 -c '
import json, sys
found = {row.get("Appearance") for row in json.load(sys.stdin)[1:]
         if row.get("AssetType") == "IconImageStack" and row.get("Name") == "AppIcon"}
wanted = {"NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"}
if wanted - found:
    sys.exit(f"Assets.car lacks AppIcon image stacks for {sorted(wanted - found)}")
' || fail "Assets.car has no complete AppIcon entry"
printf 'App icon: %s\n' "$app"
