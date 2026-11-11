#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="Edge Controls.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/EdgeControl "$APP/Contents/MacOS/EdgeControl"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/MacOS/EdgeControl"
codesign --force --sign - "$APP"
echo "Built $APP"
echo "Run: open \"$APP\""
