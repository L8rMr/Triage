#!/bin/bash
# Builds a Release VitalOS.app, installs it in /Applications, and makes a drag-to-install DMG in ./dist.
# Needs Xcode or the Command Line Tools (Swift 5.9+).
set -euo pipefail
cd "$(dirname "$0")"

NAME="VitalOS"
BUNDLE_ID="com.alenlvovich.vitalos"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "1.0")
BUILD=$(date +%Y%m%d%H%M)

echo "▸ Building $NAME $VERSION ($BUILD), Release…"
swift build -c release

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

echo "▸ Icon…"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Same certificate every build, so macOS keeps your permission grants (Files, Bluetooth, Accessibility…)
IDENTITY=$(security find-identity -v -p codesigning | grep -E "Apple Development|Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [ -n "$IDENTITY" ]; then
  echo "▸ Signing with: $IDENTITY"
  codesign --force --deep --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "▸ No certificate found, signing ad-hoc (permissions will be asked again after each update)"
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "▸ Installing in /Applications…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
rm -rf "/Applications/$NAME.app"
ditto "$APP" "/Applications/$NAME.app"
rm -rf "$HOME/Applications/$NAME.app"   # the old dev copy made by Xcode runs

echo "▸ Making the DMG…"
mkdir -p dist
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/$NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$DMG" || true
rm -rf "$STAGE" "$ICONSET"

echo ""
echo "✓ Installed: /Applications/$NAME.app"
echo "✓ Installer: $(pwd)/$DMG"
open "/Applications/$NAME.app"
open -R "$DMG"
