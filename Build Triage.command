#!/bin/bash
# Double-click: builds Triage, installs it in /Applications, and makes the DMG installer in ./dist
cd "$(dirname "$0")" && mkdir -p .export && ./release.sh 2>&1 | tee .export/build.log
echo; read -n 1 -s -r -t 15 -p "Done. Closing in 15 seconds (or press any key)."
