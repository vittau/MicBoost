#!/bin/bash
# Regenerates the README header images (light and dark variants) from the app icon
# previews. The output is committed, so this only needs to run when the icon or the
# header layout changes.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root="$script_dir/.."
icon="$root/design/icon/previews/light-1024.png"
output="$root/docs/design/readme"

if [[ ! -f "$icon" ]]; then
    echo "missing icon preview: $icon (run design/icon/render-previews.sh)" >&2
    exit 1
fi

mkdir -p "$output"
swift "$root/design/readme/RenderHeader.swift" "$icon" "$output"

# Icon variants shown in the README grid, scaled down from the 1024 px previews.
for variant in light dark clear-light tinted-light; do
    sips --resampleHeightWidth 256 256 \
        "$root/design/icon/previews/$variant-1024.png" \
        --out "$output/icon-$variant-256.png" >/dev/null
done
