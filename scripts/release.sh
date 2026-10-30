#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${PUDDLE_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
: "${PUDDLE_NOTARY_PROFILE:?Set the notarytool Keychain profile name}"
: "${PUDDLE_VERSION:?Set a release version}"
: "${PUDDLE_BUILD_NUMBER:?Set a monotonically increasing integer build}"
case "$PUDDLE_SIGNING_IDENTITY" in -|"") echo 'A Developer ID identity is required for public releases.' >&2; exit 1;; esac
case "$PUDDLE_VERSION" in ""|*[!0-9.]*) echo 'Use a numeric dotted version.' >&2; exit 1;; esac
case "$PUDDLE_BUILD_NUMBER" in ""|*[!0-9]*) echo 'Use an integer build number.' >&2; exit 1;; esac
output="$repo_root/build/releases/$PUDDLE_VERSION-$PUDDLE_BUILD_NUMBER"
if [ -e "$output" ]; then echo 'This release directory already exists; previous artifacts were preserved.' >&2; exit 1; fi
mkdir -p "$output"
# A developer's debug setting must never enable fixture mode in a public archive.
PUDDLE_BUILD_CONFIGURATION=release sh "$repo_root/scripts/build.sh"
app="$repo_root/build/Puddle.app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$output/submission.zip"
xcrun notarytool submit "$output/submission.zip" --keychain-profile "$PUDDLE_NOTARY_PROFILE" --wait --output-format json > "$output/notarization.json"
result=$(plutil -extract status raw -o - "$output/notarization.json")
if [ "$result" != Accepted ]; then echo 'Apple did not accept this submission. Inspect the notarization log; nothing was published.' >&2; exit 1; fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" "$output/Puddle-$PUDDLE_VERSION.zip"
shasum -a 256 "$output/Puddle-$PUDDLE_VERSION.zip" > "$output/SHA256SUMS"
printf 'Prepared notarized release in %s. Publishing is a separate step.\n' "$output"
