#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
    echo "Usage: $0 <version>" >&2
    exit 2
fi
version=$1
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <version>: <version> is SemVer X.Y.Z" >&2
    exit 2
fi
checksum=dist/MicBoost-$version.zip.sha256
if [[ ! -f "$checksum" ]]; then
    echo "error: missing $checksum; run scripts/package-release.sh $version first" >&2
    exit 1
fi
sha256=$(cut -d ' ' -f 1 "$checksum")
sed -e "s/X\.Y\.Z/$version/g" -e "s/^SHA256  /$sha256  /" packaging/release-notes.md
