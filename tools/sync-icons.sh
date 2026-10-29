#!/usr/bin/env bash
# One-step re-sync of launcher art into images/ (same file names). Usage: tools/sync-icons.sh [images-dir]
# - Set A line icons for every button EXCEPT Red Dog.
# - Red Dog = real full-colour logo: reddog.png (256) + reddog-small.png (48, used at 48 px and below).
# - App icon -> images/app.ico and exe/app.ico (rebuild the exe after: exe/build-exe.sh).
set -euo pipefail
ART=/home/box/shared/button-launcher/art
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/images}"
for f in "$ART"/set-a-line/*.png; do
  [ "$(basename "$f")" = reddog.png ] && continue
  cp -v "$f" "$DEST"/
done
if [ -d "$ART/set-a-line/svg" ]; then
  for f in "$ART"/set-a-line/svg/*.svg; do [ "$(basename "$f")" = reddog.svg ] && continue; cp -v "$f" "$DEST"/svg/; done
fi
cp -v "$ART"/reddog/reddog-full-256.png "$DEST"/reddog.png
cp -v "$ART"/reddog/reddog-full-48.png  "$DEST"/reddog-small.png
cp -v "$ART"/reddog/reddog-full.svg     "$DEST"/svg/reddog.svg
cp -v "$ART"/app-icon/launcher.ico "$DEST"/app.ico
[ -d "$(dirname "$DEST")/exe" ] && cp -v "$ART"/app-icon/launcher.ico "$(dirname "$DEST")"/exe/app.ico
echo "Synced into $DEST"
