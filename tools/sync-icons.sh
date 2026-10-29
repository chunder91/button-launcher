#!/usr/bin/env bash
# Re-sync Smudge's Set A icons into the launcher's images/ (same file names). Run from anywhere.
set -euo pipefail
ART=/home/box/shared/button-launcher/art
for DEST in "$@"; do :; done
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/images}"
cp -v "$ART"/set-a-line/*.png "$DEST"/
[ -d "$ART/set-a-line/svg" ] && cp -v "$ART"/set-a-line/svg/*.svg "$DEST"/svg/
cp -v "$ART"/app-icon/launcher.ico "$DEST"/app.ico
cp -v "$ART"/app-icon/launcher.ico "$(dirname "$DEST")"/exe/app.ico
echo "Icons synced into $DEST. Rebuild the exe (exe/build-exe.sh) if launcher.ico changed."
