#!/bin/bash
set -euo pipefail
# Print the DEVELOPER_DIR of the newest Xcode_*.app that is new enough for the
# package: the interface uses AppKit APIs introduced in macOS 27, so the build
# needs the macOS 27 SDK, which only Xcode 27 or later ships
# (docs/distribution.md). The icon needs actool from the same Xcode.
dir=${1:-/Applications}
minimum_major=${2:-27}

newer() {
    local left=$1 right=$2
    local i l r
    local -a a=() b=()
    IFS=. read -r -a a <<< "$left"
    IFS=. read -r -a b <<< "$right"
    for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
        l=${a[i]:-0}
        r=${b[i]:-0}
        if ((10#$l > 10#$r)); then return 0; fi
        if ((10#$l < 10#$r)); then return 1; fi
    done
    return 1
}

best_version=""
best_dir=""
for app in "$dir"/Xcode_*.app; do
    [[ -d "$app" ]] || continue
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    (( ${version%%.*} >= minimum_major )) || continue
    if [[ -z "$best_version" ]] || newer "$version" "$best_version"; then
        best_version=$version
        best_dir=$app/Contents/Developer
    fi
done
if [[ -z "$best_dir" ]]; then
    echo "no Xcode_*.app with version $minimum_major or later in $dir" >&2
    echo "the build needs the macOS $minimum_major SDK; on GitHub Actions use runs-on: xcode-$minimum_major" >&2
    exit 1
fi
echo "$best_dir"
