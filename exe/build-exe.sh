#!/usr/bin/env bash
# Builds ButtonLauncher.exe (.NET Framework 4.8) on Linux with the free .NET SDK and copies it next to Launcher.ps1.
# Needs: dotnet SDK 8 (https://dot.net/v1/dotnet-install.sh). Uses Microsoft.NETFramework.ReferenceAssemblies, no Windows needed.
set -euo pipefail
cd "$(dirname "$0")"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
"$DOTNET" build ButtonLauncher.csproj -c Release -nologo -v q
cp bin/Release/net48/ButtonLauncher.exe ../ButtonLauncher.exe
ls -l ../ButtonLauncher.exe
