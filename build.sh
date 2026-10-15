#!/bin/bash
# Builds NotchIsland.app without opening Xcode.
# Needs Xcode or the Command Line Tools:  xcode-select --install
#
#   ./build.sh            build into build/NotchIsland.app
#   ./build.sh --run      build, then quit the old copy and open the new one
#   ./build.sh --install  build, copy to /Applications and open it from there
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchIsland"
BUNDLE_ID="com.example.notchisland"
OUT="build/$APP.app"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp Info.plist "$OUT/Contents/Info.plist"

echo "Compiling..."
xcrun --sdk macosx swiftc \
  -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos15.0 \
  Sources/*.swift \
  -o "$OUT/Contents/MacOS/$APP"

# Ad-hoc signature so macOS privacy prompts work.
codesign --force --sign - "$OUT"

# Every build gets a new signature, which silently breaks the old Accessibility
# approval (it still looks switched on). Clear it so macOS asks again cleanly.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "Built $OUT"

case "${1:-}" in
  --run)
    pkill -x "$APP" 2>/dev/null || true
    sleep 0.5
    open "$OUT"
    ;;
  --install)
    pkill -x "$APP" 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/$APP.app"
    cp -R "$OUT" "/Applications/"
    open "/Applications/$APP.app"
    echo "Installed to /Applications/$APP.app"
    ;;
esac
