#!/usr/bin/env bash
# Builds the distributable disk image: archives the Release build, exports it signed with the team's
# Developer ID, notarizes and staples the app, packs it with LICENSE and NOTICE into a disk image,
# then signs, notarizes and staples that. Runs in the owner's Terminal, not in a sandbox: it needs
# the Xcode account, the login keychain and Apple's notary service. CONTRIBUTING.md, "Release", has
# the setup.
#
#   tools/release.sh            (notary credentials from the keychain profile cue-notary)
#   NOTARY_PROFILE=name tools/release.sh
set -euo pipefail

team=ZMAK33FWYB
profile=${NOTARY_PROFILE:-cue-notary}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

fail() { echo "release: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes; commit first"
identity=$(security find-identity -v -p codesigning |
  awk -v t="($team)" '/"Developer ID Application: / && index($0, t) { print $2; exit }')
[ -n "$identity" ] || fail "no Developer ID Application certificate of team $team in the keychain"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 ||
  fail "no working notary credentials under the keychain profile $profile"

settings=$(xcodebuild -project Bridge.xcodeproj -target Bridge -configuration Release \
  -showBuildSettings 2>/dev/null)
version=$(awk '$1 == "MARKETING_VERSION" { print $3; exit }' <<<"$settings")
build=$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }' <<<"$settings")
[ -n "$version" ] && [ -n "$build" ] || fail "cannot read the version from the project"
out=$root/build/release/$version-$build
dmg="$out/Cue-Bridge-$version.dmg"
[ ! -e "$dmg.sha256" ] ||
  fail "$version ($build) was already released; raise CURRENT_PROJECT_VERSION for a new build"
rm -rf "$out"
mkdir -p "$out"

xcodebuild -scheme Bridge -configuration Release -derivedDataPath build \
  -archivePath "$out/Bridge.xcarchive" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$out/Bridge.xcarchive" \
  -exportOptionsPlist tools/ExportOptions.plist -exportPath "$out/export" -allowProvisioningUpdates

app="$out/export/Cue Bridge.app"
[ -d "$app" ] || fail "the export holds no Cue Bridge.app"
codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
grep -q "^Authority=Developer ID Application: .*($team)$" <<<"$details" ||
  fail "the app is not signed with the team's Developer ID"
grep -q "^TeamIdentifier=$team$" <<<"$details" || fail "the app's team is not $team"
grep -q "^CodeDirectory .*flags=.*runtime" <<<"$details" || fail "the app lacks the hardened runtime"
grep -q "^Timestamp=" <<<"$details" || fail "the app's signature has no secure timestamp"
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
grep -q "com.apple.developer.usernotifications.communication" <<<"$entitlements" ||
  fail "the app lacks the communication notifications entitlement"
! grep -q "get-task-allow" <<<"$entitlements" || fail "the app carries get-task-allow"
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")" \
  = "$version" ] || fail "the exported app's version is not $version"
security cms -D -i "$app/Contents/embedded.provisionprofile" >"$out/profile.plist"
profile_name=$(plutil -extract Name raw "$out/profile.plist")
profile_expiry=$(plutil -extract ExpirationDate raw "$out/profile.plist")
rm "$out/profile.plist"

notarize() {
  local result id status
  echo "notarizing $(basename "$1"): waiting for Apple's verdict, usually minutes, silent meanwhile"
  result=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json) ||
    true
  id=$(plutil -extract id raw - <<<"$result" 2>/dev/null) || fail "notarytool answered: $result"
  status=$(plutil -extract status raw - <<<"$result")
  if [ "$status" != Accepted ]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    fail "notarization of $(basename "$1") ended $status (submission $id)"
  fi
  echo "notarized $(basename "$1"): submission $id"
}

ditto -c -k --keepParent "$app" "$out/notarize-app.zip"
notarize "$out/notarize-app.zip"
xcrun stapler staple "$app"
rm "$out/notarize-app.zip"

stage=$out/dmg
mkdir -p "$stage"
ditto "$app" "$stage/Cue Bridge.app"
ln -s /Applications "$stage/Applications"
cp LICENSE NOTICE "$stage/"
hdiutil create -volname "Cue Bridge $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
rm -rf "$stage"
codesign --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
spctl --assess --type execute --verbose=2 "$app"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$out" && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")

echo
echo "Cue: $version ($build) from $(git rev-parse --short HEAD)"
echo "profile: $profile_name, expires $profile_expiry"
echo "$dmg"
cat "$dmg.sha256"
