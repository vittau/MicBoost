#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
icon_source="$script_dir/../../Resources/AppIcon.icon"
developer_dir="$(xcode-select -p)"
ictool="$(dirname "$developer_dir")/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ictool" ]]; then
    echo "Icon Composer from Xcode 27 or later is required" >&2
    exit 1
fi

mkdir -p "$script_dir/previews"
for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
    case "$rendition" in
        Default) appearance=light ;;
        Dark) appearance=dark ;;
        TintedLight) appearance=tinted-light ;;
        TintedDark) appearance=tinted-dark ;;
        ClearLight) appearance=clear-light ;;
        ClearDark) appearance=clear-dark ;;
    esac
    for size in 1024 128 32 16; do
        "$ictool" "$icon_source" --export-image \
            --output-file "$script_dir/previews/$appearance-$size.png" \
            --platform macOS --rendition "$rendition" \
            --width "$size" --height "$size" --scale 1
    done
done
