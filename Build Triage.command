#!/bin/bash
# Double-click: builds Triage, installs it in /Applications, and makes the DMG installer in ./dist
cd "$(dirname "$0")" && ./release.sh
echo; read -n 1 -s -r -p "Done. Press any key to close."
