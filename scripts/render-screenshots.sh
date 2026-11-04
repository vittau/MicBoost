#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product render-screenshots
bin=$(swift build --show-bin-path)
render_dir=$(mktemp -d "${TMPDIR:-/tmp}/micboost-render.XXXXXX")
trap 'rm -rf "$render_dir"' EXIT
cp "$bin/render-screenshots" "$render_dir/"
for bundle in "$bin"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$render_dir/"
done
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
scripts/record-build-sdk.sh "$render_dir/render-screenshots" "$minimum_macos"
codesign --force --sign - "$render_dir/render-screenshots"
"$render_dir/render-screenshots" docs/screenshots
