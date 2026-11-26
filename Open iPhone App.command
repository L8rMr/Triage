#!/bin/bash
# Generates the Xcode project for the iPhone app and opens it. Run it again after pulling changes.
cd "$(dirname "$0")/iOS" || exit 1
TOOLS="$HOME/.triage-tools"
XG="$(command -v xcodegen || echo "$TOOLS/xcodegen/bin/xcodegen")"
if [ ! -x "$XG" ]; then
  echo "Getting XcodeGen (one time)…"
  mkdir -p "$TOOLS" && cd "$TOOLS" || exit 1
  curl -fsSL -o xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip && unzip -oq xcodegen.zip && rm xcodegen.zip
  cd - >/dev/null || exit 1
  XG="$TOOLS/xcodegen/bin/xcodegen"
fi
# your signing team, read from the Mac's Apple Development certificate
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)}"
echo "Team: ${DEVELOPMENT_TEAM:-not found (pick it in Xcode › Signing)}"
"$XG" generate && open TriageRemote.xcodeproj
