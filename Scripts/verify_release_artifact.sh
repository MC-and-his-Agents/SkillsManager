#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/load_version_env.sh"
load_version_env "$ROOT/version.env"

APP=${1:?
"Usage: $0 SkillsManager.app SkillsManager-<ver>.zip appcast.xml verification.txt"}
ZIP=${2:?
"Usage: $0 SkillsManager.app SkillsManager-<ver>.zip appcast.xml verification.txt"}
APPCAST=${3:?
"Usage: $0 SkillsManager.app SkillsManager-<ver>.zip appcast.xml verification.txt"}
SUMMARY=${4:?
"Usage: $0 SkillsManager.app SkillsManager-<ver>.zip appcast.xml verification.txt"}

EXPECTED_BUNDLE_ID=${BUNDLE_ID:-com.mcandhisagents.skillsmanager}
EXPECTED_FEED_URL=${SPARKLE_FEED_URL:?
"Set SPARKLE_FEED_URL to the published appcast endpoint."}
EXPECTED_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:?
"Set SPARKLE_PUBLIC_KEY to the Sparkle EdDSA public key."}
EXPECTED_PRODUCT_URL=${SPARKLE_PRODUCT_URL:?
"Set SPARKLE_PRODUCT_URL to the public product page."}
EXPECTED_DOWNLOAD_URL=${SPARKLE_DOWNLOAD_URL_PREFIX:-"https://github.com/MC-and-his-Agents/SkillsManager/releases/download/v${MARKETING_VERSION}/"}
PLIST="$APP/Contents/Info.plist"

[[ -d "$APP" && -f "$ZIP" && -f "$APPCAST" && -f "$PLIST" ]]

plist_value() {
  plutil -extract "$1" raw -o - "$PLIST"
}

assert_equal() {
  local label="$1" actual="$2" expected="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "$label mismatch (expected: $expected, actual: $actual)." >&2
    exit 1
  }
}

bundle_id=$(plist_value CFBundleIdentifier)
version=$(plist_value CFBundleShortVersionString)
build=$(plist_value CFBundleVersion)
executable=$(plist_value CFBundleExecutable)
feed_url=$(plist_value SUFeedURL)
public_key=$(plist_value SUPublicEDKey)

assert_equal "Bundle identifier" "$bundle_id" "$EXPECTED_BUNDLE_ID"
assert_equal "Marketing version" "$version" "$MARKETING_VERSION"
assert_equal "Build number" "$build" "$BUILD_NUMBER"
assert_equal "Sparkle feed URL" "$feed_url" "$EXPECTED_FEED_URL"
assert_equal "Sparkle public key" "$public_key" "$EXPECTED_PUBLIC_KEY"

arches=$(lipo -archs "$APP/Contents/MacOS/$executable")
[[ "$(wc -w <<<"$arches" | tr -d ' ')" == "2" ]] || {
  echo "Unexpected architecture count (actual: $arches)." >&2
  exit 1
}
for arch in arm64 x86_64; do
  [[ " $arches " == *" $arch "* ]] || {
    echo "Missing architecture: $arch (actual: $arches)." >&2
    exit 1
  }
done

codesign --verify --deep --strict --verbose=4 "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"
xmllint --noout "$APPCAST"

item="(//*[local-name()='item'][\
* [local-name()='shortVersionString' and text()='${MARKETING_VERSION}'] and \
* [local-name()='version' and text()='${BUILD_NUMBER}']])[1]"
appcast_version=$(xmllint --xpath "string($item/*[local-name()='shortVersionString'])" "$APPCAST")
appcast_build=$(xmllint --xpath "string($item/*[local-name()='version'])" "$APPCAST")
appcast_url=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@url)" "$APPCAST")
appcast_length=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@length)" "$APPCAST")
appcast_signature=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$APPCAST")
appcast_link=$(xmllint --xpath "string($item/*[local-name()='link'])" "$APPCAST")
zip_length=$(stat -f%z "$ZIP")
expected_url="${EXPECTED_DOWNLOAD_URL}${ZIP##*/}"

assert_equal "Appcast version" "$appcast_version" "$MARKETING_VERSION"
assert_equal "Appcast build" "$appcast_build" "$BUILD_NUMBER"
assert_equal "Appcast download URL" "$appcast_url" "$expected_url"
assert_equal "Appcast ZIP length" "$appcast_length" "$zip_length"
assert_equal "Appcast product link" "$appcast_link" "$EXPECTED_PRODUCT_URL"
[[ -n "$appcast_signature" ]] || {
  echo "Appcast EdDSA signature is missing." >&2
  exit 1
}
swift "$ROOT/Scripts/verify_sparkle_signature.swift" \
  "$ZIP" \
  "$appcast_signature" \
  "$EXPECTED_PUBLIC_KEY"

zip_sha256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
{
  printf 'bundle_id=%s\n' "$bundle_id"
  printf 'marketing_version=%s\n' "$version"
  printf 'build_number=%s\n' "$build"
  printf 'architectures=%s\n' "$arches"
  printf 'zip_sha256=%s\n' "$zip_sha256"
  printf 'codesign=pass\nstapler=pass\ngatekeeper=pass\nappcast=pass\n'
} > "$SUMMARY"
