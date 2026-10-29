#!/usr/bin/env bash
# One-step re-sync of launcher art into images/ (same file names). Usage: tools/sync-icons.sh [images-dir]
# v1.3.0 Direction 2 (Fluent 3D): Smudge's pre-downscaled 48 px Fluent Emoji 3D PNGs for every button EXCEPT Red Dog.
# - Red Dog = real full-colour logo, untouched: reddog.png (256) + reddog-small.png (48, used at 48 px and below).
# - Licences (MIT, Microsoft Fluent UI Emoji / System Icons) -> images/LICENSES/.
# - App icon -> images/app.ico and exe/app.ico (rebuild the exe after: exe/build-exe.sh).
set -euo pipefail
ART=/home/box/shared/button-launcher/art
SRC="$ART/fluent-3d"
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/images}"
# images/<name>.png  <-  fluent-3d/<source>-48.png
MAP="register:register globe:globe email:email guide:guide-backoffice guide-register:guide-register badge:badge
revenue:revenue security:security screenconnect:screenconnect power:power chip-document:chip-document chip-files:chip-files jartrek-security:jartrek-security"
for m in $MAP; do
  name=${m%%:*}; src=${m#*:}
  [ "$name" = reddog ] && continue          # never replace the Red Dog logo with the emoji stand-in
  cp -v "$SRC/$src-48.png" "$DEST/$name.png"
done
mkdir -p "$DEST/LICENSES"
cp -v "$SRC"/LICENSE*.txt "$DEST/LICENSES/"
cp -v "$ART"/reddog/reddog-full-256.png "$DEST"/reddog.png
cp -v "$ART"/reddog/reddog-full-48.png  "$DEST"/reddog-small.png
cp -v "$ART"/reddog/reddog-full.svg     "$DEST"/svg/reddog.svg
cp -v "$ART"/app-icon/launcher.ico "$DEST"/app.ico
[ -d "$(dirname "$DEST")/exe" ] && cp -v "$ART"/app-icon/launcher.ico "$(dirname "$DEST")"/exe/app.ico
echo "Synced into $DEST"
