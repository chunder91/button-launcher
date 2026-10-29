# Builds "<PanelName> Setup.exe" (IExpress, built into Windows) from this folder's
# current buttons.json, images\ and launcher files. Also writes a fallback
# "<PanelName> Setup.cmd" + ".ps1" pair in case IExpress isn't available.
param([string]$OutDir)
Add-Type -AssemblyName PresentationFramework
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# R-M2: this PC's buttons.json (or the shipped default) becomes the installer's buttons.default.json.
# The installer only turns it into buttons.json when the target PC has none, so reinstalls keep that PC's edits.
$cfgSrc = Join-Path $here 'buttons.json'
if (-not (Test-Path -LiteralPath $cfgSrc)) { $cfgSrc = Join-Path $here 'buttons.default.json' }
$cfg  = Get-Content -LiteralPath $cfgSrc -Raw -Encoding UTF8 | ConvertFrom-Json
$name = if ($cfg.title) { $cfg.title } else { 'Launcher' }
# H1/M1/LJ-L4: allow-list the name (letters, digits, space, - and _ only) so it can never be empty,
# rooted, '..', or carry quotes/$()/cmd metacharacters into the generated scripts.
# R-L1: also reject Windows reserved device names (with or without an extension), trim trailing dots/spaces, cap at 64.
function Get-SafeAppName([string]$n) {
    $reserved = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
    $raw = ([string]$n).Trim()
    if ((($raw -split '\.')[0]).Trim() -match $reserved) { return 'Launcher' }
    $s = (($raw -replace '[^A-Za-z0-9 _-]', '') -replace '\s+', ' ').Trim()
    if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
    $s = $s.TrimEnd('.', ' ')
    if (-not $s -or $s -match $reserved) { return 'Launcher' }
    return $s
}
$safe = Get-SafeAppName $name
if (-not $OutDir) { $OutDir = Join-Path $here 'installer-output' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# 1. Zip the payload
$stage = Join-Path $env:TEMP ("bl-stage-" + [guid]::NewGuid())
$zip = Join-Path $env:TEMP ("bl-" + [guid]::NewGuid() + '.zip')
$work = $null
try {   # CC-L7: temp stage/zip/work dirs are always cleaned up
New-Item -ItemType Directory $stage | Out-Null
$AppVersion = '1.1.0'
if (-not (Test-Path -LiteralPath (Join-Path $here 'ButtonLauncher.exe'))) { throw 'ButtonLauncher.exe is missing from this folder (build it with exe/build-exe.sh).' }
# R-M1: only package the exe whose SHA-256 was recorded at build time (exe\ButtonLauncher.exe.sha256 in the repo,
# ButtonLauncher.exe.sha256 next to an installed copy). tools/verify-exe.sh proves that hash rebuilds from exe\ButtonLauncher.cs.
$shaFile = @((Join-Path $here 'exe\ButtonLauncher.exe.sha256'), (Join-Path $here 'ButtonLauncher.exe.sha256')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $shaFile) { throw 'ButtonLauncher.exe.sha256 is missing, so the exe cannot be checked. Rebuild it with exe/build-exe.sh.' }
$wantSha = ((Get-Content -LiteralPath $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$haveSha = (Get-FileHash -LiteralPath (Join-Path $here 'ButtonLauncher.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($wantSha -notmatch '^[0-9a-f]{64}$' -or $haveSha -ne $wantSha) { throw "ButtonLauncher.exe does not match its recorded SHA-256.`nexpected $wantSha`nfound    $haveSha" }
foreach ($f in 'Launcher.ps1','ButtonLauncher.exe','Start Launcher.vbs','Start Launcher.cmd','README.txt','Build-Installer.ps1') {
    if (Test-Path (Join-Path $here $f)) { Copy-Item (Join-Path $here $f) $stage } }
Copy-Item -LiteralPath $cfgSrc -Destination (Join-Path $stage 'buttons.default.json')   # R-M2: never ships as buttons.json
Copy-Item -LiteralPath $shaFile -Destination (Join-Path $stage 'ButtonLauncher.exe.sha256')   # lets an installed copy build installers too
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
param([switch]$Quiet)
Add-Type -AssemblyName PresentationFramework
$AppName = '__NAME__'
$dest = $PSScriptRoot
$KeyName = if ($AppName -eq 'Launcher') { 'ButtonLauncher' } else { 'ButtonLauncher-' + $AppName }   # R-L2: per-title Uninstall key + Run value
$expected = Join-Path $env:LOCALAPPDATA ('Programs\' + $AppName)
$ok = $AppName -and ($AppName -match '^[A-Za-z0-9 _-]+$') -and $dest -and
      ([IO.Path]::GetFullPath($dest).TrimEnd('\') -ieq [IO.Path]::GetFullPath($expected).TrimEnd('\')) -and
      (Test-Path -LiteralPath (Join-Path $dest 'Launcher.ps1'))
if (-not $ok) { if (-not $Quiet) { [System.Windows.MessageBox]::Show("Uninstall stopped: this doesn't look like the $AppName install folder.`n$dest", 'Uninstall') | Out-Null }; exit 1 }
if (-not $Quiet -and [System.Windows.MessageBox]::Show("Remove $AppName?", 'Uninstall', 'YesNo') -ne 'Yes') { exit }
$pat = '*' + $dest + '\Launcher.ps1*'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like $pat } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
foreach ($l in @((Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"), (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"),
                 (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"), (Join-Path ([Environment]::GetFolderPath('Programs')) "Uninstall $AppName.lnk"))) {
    Remove-Item -LiteralPath $l -ErrorAction SilentlyContinue }
$uk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'
Remove-Item -LiteralPath ($uk + $KeyName) -Recurse -ErrorAction SilentlyContinue
foreach ($old in @('ButtonLauncher', $AppName) | Select-Object -Unique) {   # older builds: only if that key points at this folder
    if ($old -eq $KeyName) { continue }
    $il = (Get-ItemProperty -LiteralPath ($uk + $old) -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
    if ($il -and ($il.TrimEnd('\') -ieq $dest.TrimEnd('\'))) { Remove-Item -LiteralPath ($uk + $old) -Recurse -ErrorAction SilentlyContinue } }
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($rn in @($KeyName, 'ButtonLauncher') | Select-Object -Unique) {   # only remove a Run value that starts this folder's exe
    $rv = (Get-ItemProperty -LiteralPath $run -Name $rn -ErrorAction SilentlyContinue).$rn
    if ($rv -and $rv.IndexOf($dest, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-ItemProperty -LiteralPath $run -Name $rn -ErrorAction SilentlyContinue } }
# Delete the folder from a child PowerShell after this script exits (no cmd.exe, -LiteralPath only).
$q = $dest.Replace("'", "''")
$cmd = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$q' -Recurse -Force -ErrorAction SilentlyContinue"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
'@

# 2. Self-contained install script (payload embedded)
$install = @'
param([switch]$Desktop, [switch]$NoAutostart)   # defaults: no desktop shortcut unless chosen, autostart ON
Add-Type -AssemblyName PresentationFramework, System.IO.Compression.FileSystem
$AppName = '__NAME__'
$dest = Join-Path $env:LOCALAPPDATA ("Programs\" + $AppName)
$KeyName = if ($AppName -eq 'Launcher') { 'ButtonLauncher' } else { 'ButtonLauncher-' + $AppName }   # R-L2: per-title Uninstall key + Run value
if ([System.Windows.MessageBox]::Show("Install $AppName for this user?`n`nIt goes in the Start menu and starts with Windows (you can turn that off: unlock, right-click a panel > Start with Windows).", "$AppName Setup", 'OKCancel', 'Question') -ne 'OK') { exit }
if (-not $Desktop) { $Desktop = ([System.Windows.MessageBox]::Show("Also put a shortcut on the desktop?", "$AppName Setup", 'YesNo', 'Question', 'No') -eq 'Yes') }
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
# R-M2: keep this PC's buttons.json (edits, saved paths). Only a first install gets the default. The payload never
# contains buttons.json, and extraction only writes payload files, so pictures the user added to images\ stay too.
$userCfg = Join-Path $dest 'buttons.json'
if (-not (Test-Path -LiteralPath $userCfg)) { Copy-Item -LiteralPath (Join-Path $dest 'buttons.default.json') -Destination $userCfg }
Get-ChildItem $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# Uninstall.ps1 comes from the literal template built below (see __UNINST_B64__).
$uninst = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__UNINST_B64__')).Replace('__NAME__', $AppName)
Set-Content (Join-Path $dest 'Uninstall.ps1') $uninst -Encoding UTF8
$unCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\Uninstall.ps1`""

$ws = New-Object -ComObject WScript.Shell
$exe = Join-Path $dest 'ButtonLauncher.exe'
function Make-Link($path, $target, $a) {
    $l = $ws.CreateShortcut($path); $l.TargetPath = $target; $l.Arguments = $a; $l.WorkingDirectory = $dest
    $l.IconLocation = "$exe,0"; $l.Description = $AppName; $l.Save() }
$progs = [Environment]::GetFolderPath('Programs')   # %APPDATA%\Microsoft\Windows\Start Menu\Programs -> shows in Windows search
Make-Link (Join-Path $progs "$AppName.lnk") $exe ''
Make-Link (Join-Path $progs "Uninstall $AppName.lnk") 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\Uninstall.ps1`""
$deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
if ($Desktop) { Make-Link $deskLnk $exe '' } else { Remove-Item -LiteralPath $deskLnk -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk") -ErrorAction SilentlyContinue   # older builds used the Startup folder

# Start with Windows: per-user Run key, ON by default
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($KeyName -ne 'ButtonLauncher') {   # older builds always used 'ButtonLauncher': drop it only if it starts this folder
    $rv = (Get-ItemProperty -LiteralPath $run -Name 'ButtonLauncher' -ErrorAction SilentlyContinue).ButtonLauncher
    if ($rv -and $rv.IndexOf($dest, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-ItemProperty -LiteralPath $run -Name 'ButtonLauncher' -ErrorAction SilentlyContinue } }
if ($NoAutostart) { Remove-ItemProperty -LiteralPath $run -Name $KeyName -ErrorAction SilentlyContinue }
else { New-ItemProperty -LiteralPath $run -Name $KeyName -Value ('"' + $exe + '"') -PropertyType String -Force | Out-Null }

# Installed apps entry
$uk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'
foreach ($old in @('ButtonLauncher', $AppName) | Select-Object -Unique) {   # older builds: only if that key points at this folder
    if ($old -eq $KeyName) { continue }
    $il = (Get-ItemProperty -LiteralPath ($uk + $old) -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
    if ($il -and ($il.TrimEnd('\') -ieq $dest.TrimEnd('\'))) { Remove-Item -LiteralPath ($uk + $old) -Recurse -ErrorAction SilentlyContinue } }
$k = $uk + $KeyName
New-Item -Path $k -Force | Out-Null
$kb = [int][Math]::Ceiling(((Get-ChildItem -LiteralPath $dest -Recurse -File | Measure-Object Length -Sum).Sum) / 1KB)
$vals = [ordered]@{ DisplayName = $AppName; DisplayVersion = '__VERSION__'; Publisher = 'Charles Cipolla'; DisplayIcon = "$exe,0"
          InstallLocation = $dest; UninstallString = $unCmd; QuietUninstallString = "$unCmd -Quiet" }
foreach ($n in $vals.Keys) { New-ItemProperty -LiteralPath $k -Name $n -Value $vals[$n] -PropertyType String -Force | Out-Null }
foreach ($n in 'NoModify','NoRepair') { New-ItemProperty -LiteralPath $k -Name $n -Value 1 -PropertyType DWord -Force | Out-Null }
New-ItemProperty -LiteralPath $k -Name 'EstimatedSize' -Value $kb -PropertyType DWord -Force | Out-Null

Start-Process -FilePath $exe -WorkingDirectory $dest
$where = if ($Desktop) { 'the Start menu and the desktop' } else { 'the Start menu' }
[System.Windows.MessageBox]::Show("$AppName is installed.`nFind it in $where (type its name in Windows search).`nUninstall from Settings > Apps.", "$AppName Setup") | Out-Null
'@
$unB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uninstTemplate))
$install = $install.Replace('__NAME__', $safe).Replace('__B64__', $b64).Replace('__UNINST_B64__', $unB64).Replace('__VERSION__', $AppVersion)   # $safe is allow-listed: no quotes possible
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
