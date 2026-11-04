#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 ]]; then
    echo "Usage: $0 <version> <sha256>" >&2
    exit 2
fi
version=$1
sha256=$2
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <version> <sha256>: <version> is SemVer X.Y.Z" >&2
    exit 2
fi
if [[ ! $sha256 =~ ^[0-9a-f]{64}$ ]]; then
    echo "Usage: $0 <version> <sha256>: <sha256> is 64 lowercase hex characters" >&2
    exit 2
fi
sed -e "s/^  version \".*\"\$/  version \"$version\"/" \
    -e "s/^  sha256 \".*\"\$/  sha256 \"$sha256\"/" \
    packaging/homebrew/micboost.rb
