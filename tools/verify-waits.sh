#!/usr/bin/env bash
# R11-M1: compile the launcher's BL.Waits C# (from $global:WaitsSource in Launcher.ps1) as C# 5 against .NET 4.8
# reference assemblies, the same as Windows PowerShell 5.1's Add-Type. Needs dotnet SDK 8 + pwsh. Exit 0 = compiles.
# R12-L1: no MSBuild node reuse or shared compiler server; restores offline from the local NuGet cache when it has
# the net48 reference assemblies; build servers are shut down on exit.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
tmp="$(mktemp -d)"
cleanup() { "$DOTNET" build-server shutdown >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
pwsh -NoProfile -c "\$a=[System.Management.Automation.Language.Parser]::ParseFile('$root/Launcher.ps1',[ref]\$null,[ref]\$null); \$x=\$a.Find({param(\$n) \$n -is [System.Management.Automation.Language.AssignmentStatementAst] -and \$n.Left.Extent.Text -eq '\$global:WaitsSource'},\$true); \$x.Right.Expression.Value" > "$tmp/Waits.cs"
[ -s "$tmp/Waits.cs" ] || { echo "WaitsSource not found"; exit 1; }
cat > "$tmp/Waits.csproj" <<'P'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net48</TargetFramework><OutputType>Library</OutputType><LangVersion>5</LangVersion><TreatWarningsAsErrors>true</TreatWarningsAsErrors></PropertyGroup>
<ItemGroup><Reference Include="WindowsBase" /><Reference Include="System" /></ItemGroup></Project>
P
cache="${NUGET_PACKAGES:-$HOME/.nuget/packages}"
src=()
if [ -d "$cache/microsoft.netframework.referenceassemblies.net48" ]; then src=(-p:RestoreSources="$cache"); fi   # offline restore
"$DOTNET" build "$tmp/Waits.csproj" -nologo -v q -nodeReuse:false -p:UseSharedCompilation=false "${src[@]}" >/dev/null && echo "BL.Waits compiles (C# 5, net48)"
