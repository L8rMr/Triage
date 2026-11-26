#!/bin/bash
# Archives the iPhone app on this Mac and uploads it to TestFlight, using the Apple ID signed in to Xcode.
cd "$(dirname "$0")" || exit 1
ROOT="$PWD"
LOG="$ROOT/.export/testflight-upload.log"
mkdir -p "$ROOT/.export"
exec > >(tee "$LOG") 2>&1
echo "== Triage iPhone → TestFlight · $(date)"

TOOLS="$HOME/.triage-tools"
XG="$(command -v xcodegen || echo "$TOOLS/xcodegen/bin/xcodegen")"
if [ ! -x "$XG" ]; then
  echo "Getting XcodeGen (one time)…"
  mkdir -p "$TOOLS" && (cd "$TOOLS" && curl -fsSL -o xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip && unzip -oq xcodegen.zip && rm xcodegen.zip)
  XG="$TOOLS/xcodegen/bin/xcodegen"
fi
xcodebuild -version | head -1

cd "$ROOT/iOS" || exit 1
"$XG" generate --quiet || { echo "XcodeGen failed"; exit 1; }

# Sign and upload with the App Store Connect API key (no Xcode sign-in needed).
# The key file stays on this Mac; it's looked up by name, never copied into the project.
ASC_KEY_ID="WY7826CZ94"
ASC_ISSUER_ID="575e8bfd-a564-41e7-be69-a80f672c9915"
KEY=""
for d in "$HOME/.appstoreconnect/private_keys" "$HOME/private_keys" "$HOME/Downloads" "$HOME/Desktop"; do
  [ -f "$d/AuthKey_$ASC_KEY_ID.p8" ] && KEY="$d/AuthKey_$ASC_KEY_ID.p8" && break
done
AUTH=()
if [ -n "$KEY" ]; then
  echo "Using App Store Connect key $ASC_KEY_ID"
  AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  echo "No AuthKey_$ASC_KEY_ID.p8 found; falling back to the Apple ID signed in to Xcode"
fi

BUILD=$(date +%Y%m%d%H%M)      # always higher than the last one, here or on GitHub
ARCHIVE="$ROOT/.export/Triage-iOS.xcarchive"
rm -rf "$ARCHIVE" "$ROOT/.export/ios-export"
echo "== Archiving build ${BUILD}..."
xcodebuild archive -project TriageRemote.xcodeproj -scheme Triage \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}" CURRENT_PROJECT_VERSION="$BUILD" -quiet || { echo "== ARCHIVE FAILED"; exit 1; }

echo "== Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist \
  -exportPath "$ROOT/.export/ios-export" -allowProvisioningUpdates "${AUTH[@]}" || { echo "== UPLOAD FAILED"; exit 1; }

echo "== DONE: build ${BUILD} uploaded. It shows up in TestFlight after Apple finishes processing (~10-15 min)."
