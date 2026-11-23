#!/bin/bash
# Signs OUT/DiskInventory.app from scripts/build-release.sh, puts it in a DMG with an
# Applications link, and writes OUT/DiskInventory-VERSION.dmg and its .sha256.
# Usage: scripts/package-release.sh VERSION /absolute/external/output-root
#   SIGN_IDENTITY   a Developer ID Application identity; without it the app keeps its ad hoc
#                   signature and the DMG is not signed or notarized
#   SIGN_KEYCHAIN   optional keychain that holds the identity
#   Notarization (needs SIGN_IDENTITY): NOTARY_PROFILE, a notarytool keychain profile, or
#   NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID, an App Store Connect API key.
#   Without either, the DMG is signed but not notarized.
# The staging folder OUT/dmg is replaced at the start and removed after a successful run.
set -euo pipefail
if [[ $# -ne 2 || "$2" != /* ]]; then
  awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2
fi
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be like 1.2.0: $version" >&2; exit 2; }
out=$(cd "$2" && pwd -P)
built="$out/DiskInventory.app"
shown=$(plutil -extract CFBundleShortVersionString raw -o - "$built/Contents/Info.plist")
[[ $shown == "$version" ]] || { echo "app version is '$shown', expected $version" >&2; exit 1; }
identity=${SIGN_IDENTITY:-}
keychain=()
[[ -n ${SIGN_KEYCHAIN:-} ]] && keychain=(--keychain "$SIGN_KEYCHAIN")
notary=()
if [[ -n ${NOTARY_PROFILE:-} ]]; then
  notary=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n ${NOTARY_KEY_PATH:-} ]]; then
  notary=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
fi
if [[ ${#notary[@]} -gt 0 && -z $identity ]]; then
  echo "notarization needs SIGN_IDENTITY" >&2; exit 2
fi

stage="$out/dmg"
rm -rf "$stage"
mkdir -p "$stage"
ditto "$built" "$stage/DiskInventory.app"
app="$stage/DiskInventory.app"
if [[ -n $identity ]]; then
  # Notarization needs the hardened runtime and a secure timestamp. The app has no
  # entitlements and no nested code, so one signature covers it.
  codesign --force --options runtime --timestamp --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$app"
fi
codesign --verify --strict --verbose=2 "$app"
ln -s /Applications "$stage/Applications"

dmg="$out/DiskInventory-$version.dmg"
rm -f "$dmg" "$dmg.sha256"
hdiutil create -volname "Disk Inventory" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
if [[ -n $identity ]]; then
  codesign --force --timestamp --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$dmg"
  codesign --verify --strict --verbose=2 "$dmg"
fi
if [[ ${#notary[@]} -gt 0 ]]; then
  result="$stage/notary.json"
  # A failed submission still writes its JSON; the status check below reports it with the log.
  xcrun notarytool submit "$dmg" ${notary[@]+"${notary[@]}"} --wait --timeout 1h \
    --output-format json > "$result" || true
  cat "$result"
  status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
  if [[ $status != Accepted ]]; then
    id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
    [[ -z $id ]] || xcrun notarytool log "$id" ${notary[@]+"${notary[@]}"} || true
    echo "notarization status is '$status', expected Accepted" >&2; exit 1
  fi
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
else
  echo "warning: $dmg is not notarized; macOS blocks it on other Macs" >&2
fi
(cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
rm -rf "$stage"
printf 'DMG: %s\n' "$dmg"
