#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-debug}
case "$config" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2;; esac
args=(-c "$config")
if [[ "$config" == release ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}" --product MicBoost
bin=$(swift build "${args[@]}" --show-bin-path)
app=build/MicBoost.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MicBoost" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/Info.plist"
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
scripts/record-build-sdk.sh "$app/Contents/MacOS/MicBoost" "$minimum_macos"
version=$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || echo v0.0.0)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version#v}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$app/Contents/Info.plist"
for bundle in "$bin"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$app/Contents/Resources/"
done
if [[ -x scripts/compile-icon.sh ]]; then scripts/compile-icon.sh "$app/Contents/Resources"; fi
identity=${MICBOOST_SIGN_IDENTITY:--}
if [[ "$config" == release ]]; then identity=-; fi
codesign --force --deep --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "$app"
