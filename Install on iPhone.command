#!/bin/bash
# Builds the iPhone app and installs it straight onto your iPhone (USB cable or same Wi-Fi, already paired with this Mac).
cd "$(dirname "$0")" || exit 1
ROOT="$PWD"
mkdir -p "$ROOT/.export"
LOG="$ROOT/.export/iphone-install.log"
exec > >(tee "$LOG") 2>&1
echo "== Install Triage on iPhone · $(date)"

XG="$(command -v xcodegen || echo "$HOME/.triage-tools/xcodegen/bin/xcodegen")"
[ -x "$XG" ] || { echo "Run Upload to TestFlight.command once first (it fetches XcodeGen)"; exit 1; }

echo "== Looking for your iPhone…"
xcrun devicectl list devices --json-output "$ROOT/.export/devices.json" >/dev/null 2>&1
DEVICE=$(/usr/bin/python3 - "$ROOT/.export/devices.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
best = None
for dev in d.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical":
        continue
    st = dev.get("connectionProperties", {}).get("tunnelState", "")
    name = dev.get("deviceProperties", {}).get("name", "")
    cand = (st == "connected", dev.get("identifier"), name)
    if best is None or cand[0] > best[0]:
        best = cand
if best:
    print(best[1] + "\t" + best[2])
PY
)
if [ -z "$DEVICE" ]; then
  echo "== NO IPHONE FOUND. Plug it in with a cable (or keep it on the same Wi-Fi), unlock it, and tap Trust if asked."
  exit 1
fi
UDID="${DEVICE%%$'\t'*}"; NAME="${DEVICE#*$'\t'}"
echo "Found: $NAME ($UDID)"

cd "$ROOT/iOS" || exit 1
"$XG" generate --quiet || exit 1
BUILD=$(date +%Y%m%d%H%M%S)
DERIVED="$ROOT/.export/ios-derived"

echo "== Building build ${BUILD}..."
xcodebuild build -project TriageRemote.xcodeproj -scheme Triage -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$BUILD" -quiet || { echo "== BUILD FAILED"; exit 1; }

APP="$DERIVED/Build/Products/Debug-iphoneos/Triage.app"
echo "== Installing on $NAME..."
xcrun devicectl device install app --device "$UDID" "$APP" || { echo "== INSTALL FAILED"; exit 1; }
xcrun devicectl device process launch --device "$UDID" com.alenlvovich.triage.ios >/dev/null 2>&1 || true
echo "== DONE: Triage is on $NAME. If iOS says 'Untrusted Developer', go to Settings › General › VPN & Device Management and trust your developer profile."
