#!/bin/bash
set -euo pipefail
# Print the DEVELOPER_DIR of the newest Xcode_*.app that is new enough for the
# package: Swift 6 needs Xcode 26 or later, and the icon needs actool from it.
dir=${1:-/Applications}
minimum_major=${2:-26}

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
    exit 1
fi
echo "$best_dir"
