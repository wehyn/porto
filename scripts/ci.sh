#!/bin/zsh
set -euo pipefail

expected_build="${PORTO_EXPECTED_XCODE_BUILD:-17F113}"
actual_build="$(xcodebuild -version | awk '/^Build version/{print $3}')"
if [[ "$actual_build" != "$expected_build" ]]; then
    echo "Unsupported Xcode build: $actual_build (expected $expected_build)" >&2
    exit 1
fi

xcodegen generate
xcodebuild -project Porto.xcodeproj -scheme Porto -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Porto.xcodeproj -scheme Porto -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
