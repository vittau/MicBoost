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
# The About row reads the same Info.plist the app bundle uses, including the version
# build-app.sh computes (MICBOOST_VERSION or the latest v* tag).
cp Resources/Info.plist "$render_dir/Info.plist"
version=${MICBOOST_VERSION:-}
if [[ -z "$version" ]]; then
    version=$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || echo v0.0.0)
    version=${version#v}
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$render_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$render_dir/Info.plist"
scripts/record-build-sdk.sh "$render_dir/render-screenshots" "$minimum_macos"
codesign --force --sign - "$render_dir/render-screenshots"
"$render_dir/render-screenshots" docs/screenshots
