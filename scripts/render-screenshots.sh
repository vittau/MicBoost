#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift run render-screenshots docs/screenshots
