#!/usr/bin/env bash
# Builds the per-user NSIS installer from a committed tree, reproducibly (same commit -> same bytes).
# Usage: tools/build-nsis.sh [commit=HEAD] [outdir=installer-output]. Needs makensis (apt nsis), python3, pwsh, git.
# Payload = the same files Build-Installer.ps1 ships (no tests, no tools). No network access.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rev="${1:-HEAD}"; out="${2:-$root/installer-output}"
commit="$(git -C "$root" rev-parse "$rev")"
ver="$(sed -n "s/^\$AppVersion = '\([0-9.]*\)'.*/\1/p" "$root/Build-Installer.ps1")"
[ -n "$ver" ] || { echo "FAIL: AppVersion not found in Build-Installer.ps1"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$root" archive "$commit" | tar -x -C "$tmp" && src="$tmp/src" && mkdir "$src"
epoch="$(git -C "$root" show -s --format=%ct "$commit")"
# exe must be the one whose hash was recorded (same rule as Build-Installer.ps1)
want="$(awk '{print tolower($1)}' "$tmp/exe/ButtonLauncher.exe.sha256")"; have="$(sha256sum "$tmp/ButtonLauncher.exe" | cut -d' ' -f1)"
[ "$want" = "$have" ] || { echo "FAIL: ButtonLauncher.exe does not match exe/ButtonLauncher.exe.sha256"; exit 1; }
for f in Launcher.ps1 ButtonLauncher.exe "Start Launcher.vbs" "Start Launcher.cmd" README.txt Build-Installer.ps1; do cp "$tmp/$f" "$src/"; done
cp "$tmp/buttons.default.json" "$src/"; cp "$tmp/exe/ButtonLauncher.exe.sha256" "$src/"; cp -r "$tmp/images" "$src/"
python3 - "$src" "$tmp" "$root" <<'PY'
import json, sys, os, hashlib, re, subprocess
src, tmp, root = sys.argv[1:4]
cfg = json.load(open(os.path.join(src, 'buttons.default.json'), encoding='utf-8-sig'))
assert cfg.get('layout') == 'single', 'buttons.default.json layout must be single'
miss = [b['image'] for p in cfg['panels'] for b in p.get('buttons', []) if b.get('image') and b['image'] != 'icon' and not os.path.isabs(b['image']) and not os.path.exists(os.path.join(src, b['image']))]
assert not miss, 'missing pictures: %s' % miss
imgs = sorted(os.path.relpath(os.path.join(d, f), src).replace(os.sep, '/') for d, _, fs in os.walk(os.path.join(src, 'images')) for f in fs)
h = lambda p: hashlib.sha256(open(os.path.join(src, p), 'rb').read()).hexdigest()
open(os.path.join(src, 'shipped-images.txt'), 'w', newline='\r\n').write(''.join('%s  %s\n' % (h(p), p) for p in imgs))
# known = current manifest + the legacy table embedded in Build-Installer.ps1 (pre-manifest installs)
bi = open(os.path.join(tmp, 'Build-Installer.ps1'), encoding='utf-8-sig').read()
known = set((h(p), p) for p in imgs)
for name, hs in re.findall(r"'(images/[^']+)' = @\(([^)]*)\)", bi):
    for x in re.findall(r"[0-9a-f]{64}", hs): known.add((x, name))
open(os.path.join(tmp, 'known-pictures.txt'), 'w', newline='\r\n').write(''.join('%s  %s\n' % k for k in sorted(known)))
def nsis(name):
    s = open(os.path.join(tmp, 'installer', name)).read().strip()
    assert '"' not in s and '`' not in s and '\n' not in s, name
    assert len(s) < 800, name
    return s.replace('$', '$$')
lines = ['!define VERSION "%s"' % sys.argv[4] if len(sys.argv) > 4 else '']
g = open(os.path.join(tmp, 'generated.nsh'), 'w')
g.write('!define PICS_SAVE `%s`\n!define PICS_RESTORE `%s`\n!define STOP_LAUNCHER `%s`\n' % (nsis('pictures-save.ps1'), nsis('pictures-restore.ps1'), nsis('stop-launcher.ps1')))
g.write('!macro PAYLOAD_FILES\n')
for d, _, fs in sorted(os.walk(src)):
    rel = os.path.relpath(d, src)
    g.write('  SetOutPath "$Stage%s"\n' % ('' if rel == '.' else '\\' + rel.replace('/', '\\')))
    for f in sorted(fs): g.write('  File "%s"\n' % os.path.join(d, f))
g.write('  SetOutPath "$Stage"\n!macroend\n'); g.close()
PY
find "$tmp" -exec touch -h -d "@$epoch" {} +
mkdir -p "$out"; exe="$out/ButtonLauncher-Setup-v$ver.exe"
SOURCE_DATE_EPOCH="$epoch" makensis -V2 -WX ${NSIS_EXTRA:-} -NOCD -INPUTCHARSET UTF8 \
  "-DVERSION=$ver" "-DSRC=$src" "-DKNOWN=$tmp/known-pictures.txt" "-DOUTFILE=$exe" "-X!addincludedir $tmp" \
  "$tmp/installer/launcher.nsi"
touch -d "@$epoch" "$exe"
echo "built $exe from $commit"; sha256sum "$exe"
