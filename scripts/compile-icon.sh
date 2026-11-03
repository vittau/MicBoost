#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: $0 <output-dir>" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
icon_source="$script_dir/../Resources/AppIcon.icon"
mkdir -p "$1"
output_dir="$(cd "$1" && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/micboost-icon.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

# actool renders the layered document and includes legacy macOS icon sizes.
xcrun actool "$icon_source" \
    --compile "$temporary_dir" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --app-icon AppIcon \
    --output-partial-info-plist "$temporary_dir/icon-info.plist" \
    --output-format human-readable-text

if [[ ! -s "$temporary_dir/AppIcon.icns" ]]; then
    echo "actool did not produce the required AppIcon.icns" >&2
    exit 1
fi

# actool can emit only the smaller legacy sizes for a .icon document.
# Render a complete iconset so macOS 14 also has a sharp 1024 px fallback.
developer_dir="$(xcode-select -p)"
ictool="$(dirname "$developer_dir")/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ictool" ]]; then
    echo "Icon Composer from Xcode 27 or later is required" >&2
    exit 1
fi
iconset="$temporary_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        if [[ "$scale" -eq 2 ]]; then suffix="@2x"; fi
        "$ictool" "$icon_source" --export-image \
            --output-file "$iconset/icon_${size}x${size}${suffix}.png" \
            --platform macOS --rendition Default \
            --width "$size" --height "$size" --scale "$scale" > /dev/null
    done
done
iconutil -c icns "$iconset" -o "$temporary_dir/AppIcon.icns"

cp "$temporary_dir/AppIcon.icns" "$output_dir/AppIcon.icns"
echo "Wrote $output_dir/AppIcon.icns"
if [[ -s "$temporary_dir/Assets.car" ]]; then
    cp "$temporary_dir/Assets.car" "$output_dir/Assets.car"
    echo "Wrote $output_dir/Assets.car"
fi
