# Builds "<PanelName> Setup.exe" (IExpress, built into Windows) from this folder's
# current buttons.json, images\ and launcher files. Also writes a fallback
# "<PanelName> Setup.cmd" + ".ps1" pair in case IExpress isn't available.
param([string]$OutDir)
Add-Type -AssemblyName PresentationFramework
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg  = Get-Content (Join-Path $here 'buttons.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$name = if ($cfg.title) { $cfg.title } else { 'Launcher' }
# H1/M1/LJ-L4: allow-list the name (letters, digits, space, - and _ only) so it can never be empty,
# rooted, '..', or carry quotes/$()/cmd metacharacters into the generated scripts.
$safe = (([string]$name) -replace '[^A-Za-z0-9 _-]', '' -replace '\s+', ' ').Trim()
if (-not $safe) { $safe = 'Launcher' }
if (-not $OutDir) { $OutDir = Join-Path $here 'installer-output' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# 1. Zip the payload
$stage = Join-Path $env:TEMP ("bl-stage-" + [guid]::NewGuid())
$zip = Join-Path $env:TEMP ("bl-" + [guid]::NewGuid() + '.zip')
$work = $null
try {   # CC-L7: temp stage/zip/work dirs are always cleaned up
New-Item -ItemType Directory $stage | Out-Null
foreach ($f in 'Launcher.ps1','buttons.json','Start Launcher.vbs','Start Launcher.cmd','README.txt','Build-Installer.ps1') {
    if (Test-Path (Join-Path $here $f)) { Copy-Item (Join-Path $here $f) $stage } }
if (Test-Path (Join-Path $here 'images')) { Copy-Item -LiteralPath (Join-Path $here 'images') -Destination (Join-Path $stage 'images') -Recurse -Force }
# Kern-2: make sure every picture a button uses actually ships. Stop the build if one is missing.
$missingPics = @()
foreach ($pc in @($cfg.panels)) { foreach ($b in @($pc.buttons)) {
    $img = [string]$b.image
    if (-not $img -or $img -eq 'icon' -or [IO.Path]::IsPathRooted($img)) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $stage $img))) { $missingPics += "$img  ($(([string]$b.label) -replace '\n',' '))" } } }
if ($missingPics.Count) { throw ("These button pictures are missing from images\ and would not ship:`n" + ($missingPics -join "`n")) }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))

# H1/M1/LJ-L4: Uninstall.ps1 is a literal template (no interpolation). It finds its own folder via
# $PSScriptRoot and refuses to delete anything that isn't exactly <LOCALAPPDATA>\Programs\<AppName>
# containing Launcher.ps1.
$uninstTemplate = @'
$AppName = '__NAME__'
$dest = $PSScriptRoot
$expected = Join-Path $env:LOCALAPPDATA ('Programs\' + $AppName)
$ok = $AppName -and ($AppName -match '^[A-Za-z0-9 _-]+$') -and $dest -and
      ([IO.Path]::GetFullPath($dest).TrimEnd('\') -ieq [IO.Path]::GetFullPath($expected).TrimEnd('\')) -and
      (Test-Path -LiteralPath (Join-Path $dest 'Launcher.ps1'))
if (-not $ok) { [System.Windows.MessageBox]::Show("Uninstall stopped: this doesn't look like the $AppName install folder.`n$dest", 'Uninstall') | Out-Null; exit 1 }
if ([System.Windows.MessageBox]::Show("Remove $AppName?", 'Uninstall', 'YesNo') -ne 'Yes') { exit }
$pat = '*' + $dest + '\Launcher.ps1*'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like $pat } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
foreach ($l in @((Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"), (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"),
                 (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"), (Join-Path ([Environment]::GetFolderPath('Programs')) "Uninstall $AppName.lnk"))) {
    Remove-Item -LiteralPath $l -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $AppName) -Recurse -ErrorAction SilentlyContinue
# Delete the folder from a child PowerShell after this script exits (no cmd.exe, -LiteralPath only).
$q = $dest.Replace("'", "''")
$cmd = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$q' -Recurse -Force -ErrorAction SilentlyContinue"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
'@

# 2. Self-contained install script (payload embedded)
$install = @'
Add-Type -AssemblyName PresentationFramework, System.IO.Compression.FileSystem
$AppName = '__NAME__'
$dest = Join-Path $env:LOCALAPPDATA ("Programs\" + $AppName)
$startup = [System.Windows.MessageBox]::Show("Install $AppName for this user?`n`nStart it automatically when Windows starts?`n`nYes = install + start with Windows`nNo = install only`nCancel = don't install", "$AppName Setup", 'YesNoCancel', 'Question')
if ($startup -eq 'Cancel') { exit }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$dest\Launcher.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
New-Item -ItemType Directory -Force $dest | Out-Null
$zip = Join-Path $env:TEMP ("bl-payload-" + [guid]::NewGuid() + ".zip")   # LJ-I4/CC-L7: unpredictable name
[IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String('__B64__'))
$z = [IO.Compression.ZipFile]::OpenRead($zip)
foreach ($e in $z.Entries) {
    $t = Join-Path $dest $e.FullName
    if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { New-Item -ItemType Directory -Force $t | Out-Null; continue }
    New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
}
$z.Dispose(); Remove-Item -LiteralPath $zip
Get-ChildItem $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# Uninstall.ps1 comes from the literal template built below (see __UNINST_B64__).
$uninst = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__UNINST_B64__')).Replace('__NAME__', $AppName)
Set-Content (Join-Path $dest 'Uninstall.ps1') ("Add-Type -AssemblyName PresentationFramework`r`n" + $uninst) -Encoding UTF8
$unCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\Uninstall.ps1`""

$ws = New-Object -ComObject WScript.Shell
function Make-Link($path, $target, $a) {
    $l = $ws.CreateShortcut($path); $l.TargetPath = $target; $l.Arguments = $a; $l.WorkingDirectory = $dest
    $l.IconLocation = "$env:SystemRoot\System32\imageres.dll,15"; $l.Save() }
$vbs = Join-Path $dest 'Start Launcher.vbs'
Make-Link "$([Environment]::GetFolderPath('Programs'))\$AppName.lnk" 'wscript.exe' "`"$vbs`""
Make-Link "$([Environment]::GetFolderPath('Desktop'))\$AppName.lnk" 'wscript.exe' "`"$vbs`""
Make-Link "$([Environment]::GetFolderPath('Programs'))\Uninstall $AppName.lnk" 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\Uninstall.ps1`""
if ($startup -eq 'Yes') { Make-Link "$([Environment]::GetFolderPath('Startup'))\$AppName.lnk" 'wscript.exe' "`"$vbs`"" }

$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"
New-Item $k -Force | Out-Null
Set-ItemProperty $k DisplayName $AppName; Set-ItemProperty $k UninstallString $unCmd
Set-ItemProperty $k InstallLocation $dest; Set-ItemProperty $k Publisher 'Charles Cipolla'; Set-ItemProperty $k NoModify 1; Set-ItemProperty $k NoRepair 1

Start-Process wscript.exe "`"$vbs`""
[System.Windows.MessageBox]::Show("$AppName is installed.`nShortcuts are on the desktop and in the Start menu.`nUninstall from Settings > Apps or the Start menu.", "$AppName Setup") | Out-Null
'@
$unB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uninstTemplate))
$install = $install.Replace('__NAME__', $safe).Replace('__B64__', $b64).Replace('__UNINST_B64__', $unB64)   # $safe is allow-listed: no quotes possible
$ps1Name = "$safe Setup.ps1"
$ps1 = Join-Path $OutDir $ps1Name
[IO.File]::WriteAllText($ps1, $install, (New-Object Text.UTF8Encoding $true))
$cmd = Join-Path $OutDir "$safe Setup.cmd"
[IO.File]::WriteAllText($cmd, "@echo off`r`npowershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"%~dp0$ps1Name`"`r`n")

# 3. IExpress single exe
$exe = Join-Path $OutDir "$safe Setup.exe"
$iexp = Join-Path $env:SystemRoot 'System32\iexpress.exe'
$built = $false
if (Test-Path $iexp) {
    $work = Join-Path $env:TEMP ("bl-iexp-" + [guid]::NewGuid()); New-Item -ItemType Directory $work | Out-Null
    Copy-Item $ps1 (Join-Path $work 'install.ps1')
    $sed = Join-Path $work 'setup.sed'
@"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$exe
FriendlyName=$safe Setup
AppLaunched=powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File install.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
FILE0="install.ps1"
[SourceFiles]
SourceFiles0=$work\
[SourceFiles0]
%FILE0%=
"@ | Set-Content $sed -Encoding ASCII
    Start-Process $iexp -ArgumentList "/N /Q `"$sed`"" -Wait -WindowStyle Hidden
    $built = Test-Path $exe
}
}
catch {
    [System.Windows.MessageBox]::Show("The installer was not built.`n`n$($_.Exception.Message)", 'Build installer') | Out-Null
    exit 1
}
finally {
    foreach ($d in @($work, $stage, $zip)) { if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

$msg = if ($built) { "Built:`n$exe`n`nCopy that one file to the other PC and run it.`n(Backup: '$safe Setup.cmd' + '$ps1Name' together also work.)" }
       else { "IExpress wasn't available, so built:`n$cmd`n$ps1`n`nCopy BOTH files to the other PC and run the .cmd." }
[System.Windows.MessageBox]::Show($msg, 'Build installer') | Out-Null
Start-Process explorer.exe "`"$OutDir`""
