#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "Usage: $0 <mach-o> <minimum-macos>" >&2; exit 2; fi
binary=$1
minimum_macos=$2
build_sdk_version=$(xcrun --sdk macosx --show-sdk-version)
# Record the SDK actually used by the selected Xcode, independently of deployment target.
# The caller must sign the resulting executable after this change.
xcrun vtool -set-build-version macos "$minimum_macos" "$build_sdk_version" -replace -output "$binary" "$binary"
xcrun vtool -show-build "$binary" | awk -v sdk="$build_sdk_version" -v minos="$minimum_macos" '
    $1 == "sdk" { sdk_count++; if ($2 != sdk) exit 1 }
    $1 == "minos" { min_count++; if ($2 != minos) exit 1 }
    END { if (!sdk_count || !min_count) exit 1 }
'
