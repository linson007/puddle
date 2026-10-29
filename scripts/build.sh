#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${PUDDLE_BUILD_CONFIGURATION:-release}
# Provision one Google Desktop OAuth client for the app, not per end user.
# The downloaded client JSON is gitignored; account tokens only use Keychain.
google_client=${PUDDLE_GOOGLE_CLIENT_FILE:-}
if [ -z "$google_client" ]; then
    for candidate in "$repo_root"/client_secret*.json; do
        [ -f "$candidate" ] || continue
        if [ -n "$google_client" ]; then
            echo "Multiple Google client files found; set PUDDLE_GOOGLE_CLIENT_FILE to choose one." >&2
            exit 1
        fi
        google_client=$candidate
    done
fi
if [ -n "$google_client" ] && [ ! -f "$google_client" ]; then
    echo "PUDDLE_GOOGLE_CLIENT_FILE must point to a downloaded Desktop OAuth client JSON." >&2
    exit 1
fi
if [ "$configuration" = release ]; then
    sh "$repo_root/scripts/swift.sh" build -c release -debug-info-format none
else
    sh "$repo_root/scripts/swift.sh" build -c "$configuration"
fi
binary_dir=$(sh "$repo_root/scripts/swift.sh" build -c "$configuration" --show-bin-path)
app_bundle="$repo_root/build/Puddle.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
# Replace the executable's inode so an already running build keeps its code pages.
binary_stage="$app_bundle/Contents/MacOS/.Puddle.$$"
install -m 755 "$binary_dir/Puddle" "$binary_stage"
mv -f "$binary_stage" "$app_bundle/Contents/MacOS/Puddle"
cp "$repo_root/app/Info.plist" "$app_bundle/Contents/Info.plist"
if [ -n "$google_client" ]; then
    install -m 600 "$google_client" "$app_bundle/Contents/Resources/GoogleClient.json"
else
    rm -f "$app_bundle/Contents/Resources/GoogleClient.json"
fi
swift -module-cache-path "$repo_root/.build/module-cache" "$repo_root/scripts/Icon.swift" \
    "$repo_root/build/Puddle.iconset" "$app_bundle/Contents/Resources/Puddle.icns"
codesign --force --sign - --identifier app.puddle.mac "$app_bundle"
printf 'Built %s\n' "$app_bundle"
