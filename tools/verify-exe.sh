#!/usr/bin/env bash
# R-M1: rebuild ButtonLauncher.exe from exe/ButtonLauncher.cs in a clean temp folder (deterministic build,
# PathMap'd) and check that the committed ButtonLauncher.exe and exe/ButtonLauncher.exe.sha256 both match it.
# Needs: dotnet SDK 8 (net48 reference assemblies come from NuGet). Exit 0 = match, 1 = mismatch.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp "$root/exe/ButtonLauncher.cs" "$root/exe/ButtonLauncher.csproj" "$root/exe/app.ico" "$tmp/"
"$DOTNET" build "$tmp/ButtonLauncher.csproj" -c Release -nologo -v q >/dev/null
built=$(sha256sum "$tmp/bin/Release/net48/ButtonLauncher.exe" | cut -d' ' -f1)
committed=$(sha256sum "$root/ButtonLauncher.exe" | cut -d' ' -f1)
recorded=$(cut -d' ' -f1 "$root/exe/ButtonLauncher.exe.sha256")
echo "rebuilt   $built"; echo "committed $committed"; echo "recorded  $recorded"
if [ "$built" = "$committed" ] && [ "$built" = "$recorded" ]; then echo "MATCH"; else echo "MISMATCH"; exit 1; fi
