#!/bin/bash
# Builds a Release Triage.app, installs it in /Applications, and makes a drag-to-install DMG in ./dist.
# Builds through Xcode (signed for iCloud, so Triage is reachable from anywhere); falls back to SwiftPM if that fails.
set -uo pipefail
cd "$(dirname "$0")"

NAME="Triage"
BUNDLE_ID="com.alenlvovich.triage"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "1.0")
BUILD=$(date +%Y%m%d%H%M)

echo "▸ Icon…"
ICONSET="build/AppIcon.iconset"
mkdir -p build Mac/Generated
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Mac/Generated/AppIcon.icns

TOOLS="$HOME/.triage-tools"
XG="$(command -v xcodegen || echo "$TOOLS/xcodegen/bin/xcodegen")"
if [ ! -x "$XG" ]; then
  echo "▸ Getting XcodeGen (one time)…"
  mkdir -p "$TOOLS" && (cd "$TOOLS" && curl -fsSL -o xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip && unzip -oq xcodegen.zip && rm xcodegen.zip)
fi

APP=""
echo "▸ Building $NAME $VERSION ($BUILD) with Xcode…"
if (cd Mac && "$XG" generate --quiet) && xcodebuild -project Mac/TriageMac.xcodeproj -scheme Triage -configuration Release \
     -derivedDataPath build/dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     CURRENT_PROJECT_VERSION="$BUILD" -quiet build; then
  APP="build/dd/Build/Products/Release/$NAME.app"
  echo "▸ Signed by Xcode (iCloud on)"
else
  echo "▸ Xcode build failed: falling back to SwiftPM (works, but without iCloud)"
  swift build -c release || exit 1
  APP="build/$NAME.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$APP/Contents/Info.plist"
  cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
  cp Mac/Generated/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  IDENTITY=$(security find-identity -v -p codesigning | grep -E "Apple Development|Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
  if [ -n "$IDENTITY" ]; then
    codesign --force --deep --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
  fi
fi
codesign --verify --deep --strict "$APP" || echo "▸ (signature check warning)"

echo "▸ Installing in /Applications…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
osascript -e 'tell application id "com.alenlvovich.vitalos" to quit' >/dev/null 2>&1 || true
rm -rf "/Applications/VitalOS.app" "$HOME/Applications/VitalOS.app"
sleep 1
rm -rf "/Applications/$NAME.app"
ditto "$APP" "/Applications/$NAME.app"
rm -rf "$HOME/Applications/$NAME.app"
touch "/Applications/$NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$NAME.app" >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

echo "▸ Making the DMG…"
mkdir -p dist
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/$NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE" "$ICONSET"

echo ""
echo "✓ Installed: /Applications/$NAME.app"
echo "✓ Installer: $(pwd)/$DMG"
open "/Applications/$NAME.app"
