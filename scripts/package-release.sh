#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "Usage: $0 <version>" >&2
    echo "  <version>: SemVer X.Y.Z, without the leading 'v'." >&2
}

fail() {
    echo "error: $*" >&2
    exit 1
}

if [[ $# != 1 ]]; then
    usage
    exit 2
fi
version=$1
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    usage
    exit 2
fi

head_tag=$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)
if [[ -n "$head_tag" && "${head_tag#v}" != "$version" ]]; then
    fail "HEAD is tagged ${head_tag#v}, which differs from the requested version $version"
fi

app=build/MicBoost.app
binary=$app/Contents/MacOS/MicBoost
zip=dist/MicBoost-$version.zip
checksum=$zip.sha256
mkdir -p dist
rm -f "$zip" "$checksum"

echo "==> Building release $version"
MICBOOST_VERSION="$version" scripts/build-app.sh release

echo "==> Packaging"
ditto -c -k --keepParent "$app" "$zip"
(cd dist && shasum -a 256 "$(basename "$zip")") > "$checksum"
sha256=$(cut -d ' ' -f 1 "$checksum")

echo "==> Verifying"
archs=$(lipo -archs "$binary")
for arch in arm64 x86_64; do
    if [[ " $archs " != *" $arch "* ]]; then
        fail "lipo -archs reports '$archs', missing $arch"
    fi
done
codesign --verify --strict --deep "$app" || fail "codesign --verify --strict --deep failed"
signature=$(codesign -dv --verbose=4 "$app" 2>&1)
if ! grep -qx 'Signature=adhoc' <<< "$signature"; then
    fail "the signature is not ad hoc"
fi
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
for arch in arm64 x86_64; do
    minos=$(xcrun vtool -show-build -arch "$arch" "$binary" | awk '$1 == "minos" { print $2 }')
    if [[ "$minos" != "$minimum_macos" ]]; then
        fail "the $arch slice records minos '$minos' instead of $minimum_macos"
    fi
done
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ "$plist_version" != "$version" ]]; then
    fail "CFBundleShortVersionString is '$plist_version' instead of $version"
fi

echo "==> Release artifacts"
echo "app:       $app"
echo "zip:       $zip ($(stat -f %z "$zip") bytes)"
echo "sha256:    $checksum"
echo "checksum:  $sha256"
echo "archs:     $archs"
echo "minos:     $minimum_macos (arm64 and x86_64)"
echo "signature: ad hoc, not notarized"
echo "==> Cask for the tap (packaging/homebrew/micboost.rb)"
scripts/print-cask.sh "$version" "$sha256"
