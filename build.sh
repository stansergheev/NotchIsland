#!/bin/bash
# Builds NotchIsland.app without opening Xcode.
# Needs Xcode or the Command Line Tools:  xcode-select --install
#
#   ./build.sh            build into build/NotchIsland.app
#   ./build.sh --run      build, then quit the old copy and open the new one
#   ./build.sh --install  build, copy to /Applications and open it from there
#   ./build.sh --dmg      build for Apple silicon and Intel, then make build/NotchIsland.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchIsland"
BUNDLE_ID="com.example.notchisland"
OUT="build/$APP.app"
MODE="${1:-}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

compile() { # $1 = arch, $2 = output file
  xcrun --sdk macosx swiftc \
    -O -swift-version 5 -parse-as-library \
    -target "$1-apple-macos15.0" \
    Sources/*.swift \
    -o "$2"
}

if [[ "$MODE" == "--dmg" ]]; then
  echo "Compiling for Apple silicon..."
  compile arm64 "build/$APP-arm64"
  echo "Compiling for Intel..."
  compile x86_64 "build/$APP-x86_64"
  lipo -create "build/$APP-arm64" "build/$APP-x86_64" -output "$OUT/Contents/MacOS/$APP"
  rm "build/$APP-arm64" "build/$APP-x86_64"
else
  echo "Compiling..."
  compile arm64 "$OUT/Contents/MacOS/$APP"
fi

# Ad-hoc signature so macOS privacy prompts work.
codesign --force --sign - "$OUT"
echo "Built $OUT"

case "$MODE" in
  --run|--install)
    # Every build gets a new signature, which silently breaks the old Accessibility
    # approval (it still looks switched on). Clear it so macOS asks again cleanly.
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    pkill -x "$APP" 2>/dev/null || true
    sleep 0.5
    ;;
esac

case "$MODE" in
  --run)
    open "$OUT"
    ;;
  --install)
    rm -rf "/Applications/$APP.app"
    cp -R "$OUT" "/Applications/"
    open "/Applications/$APP.app"
    echo "Installed to /Applications/$APP.app"
    ;;
  --dmg)
    # A disk image with the app and a shortcut to Applications, so people can drag to install.
    STAGE="build/dmg"
    rm -rf "$STAGE" "build/$APP.dmg"
    mkdir -p "$STAGE"
    cp -R "$OUT" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "build/$APP.dmg" >/dev/null
    rm -rf "$STAGE"
    echo "Made build/$APP.dmg"
    ;;
esac
