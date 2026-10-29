# Builds "<PanelName> Setup.exe" (IExpress, built into Windows) from this folder's
# current buttons.json, images\ and launcher files. Also writes a fallback
# "<PanelName> Setup.cmd" + ".ps1" pair in case IExpress isn't available.
param([string]$OutDir)
Add-Type -AssemblyName PresentationFramework
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg  = Get-Content (Join-Path $here 'buttons.json') -Raw | ConvertFrom-Json
$name = if ($cfg.title) { $cfg.title } else { 'Launcher' }
$safe = ($name -replace '[\\/:*?"<>|]', '').Trim()
if (-not $OutDir) { $OutDir = Join-Path $here 'installer-output' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# 1. Zip the payload
$stage = Join-Path $env:TEMP ("bl-stage-" + [guid]::NewGuid())
New-Item -ItemType Directory $stage | Out-Null
foreach ($f in 'Launcher.ps1','buttons.json','Start Launcher.vbs','Start Launcher.cmd','README.txt','Build-Installer.ps1') {
    if (Test-Path (Join-Path $here $f)) { Copy-Item (Join-Path $here $f) $stage } }
if (Test-Path (Join-Path $here 'images')) { Copy-Item (Join-Path $here 'images') $stage -Recurse }
$zip = Join-Path $env:TEMP ("bl-" + [guid]::NewGuid() + '.zip')
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))

# 2. Self-contained install script (payload embedded)
$install = @'
Add-Type -AssemblyName PresentationFramework, System.IO.Compression.FileSystem
$AppName = '__NAME__'
$dest = Join-Path $env:LOCALAPPDATA ("Programs\" + $AppName)
$startup = [System.Windows.MessageBox]::Show("Install $AppName for this user?`n`nStart it automatically when Windows starts?`n`nYes = install + start with Windows`nNo = install only`nCancel = don't install", "$AppName Setup", 'YesNoCancel', 'Question')
if ($startup -eq 'Cancel') { exit }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$dest*Launcher.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
New-Item -ItemType Directory -Force $dest | Out-Null
$zip = Join-Path $env:TEMP "$AppName-payload.zip"
[IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String('__B64__'))
$z = [IO.Compression.ZipFile]::OpenRead($zip)
foreach ($e in $z.Entries) {
    $t = Join-Path $dest $e.FullName
    if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { New-Item -ItemType Directory -Force $t | Out-Null; continue }
    New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
}
$z.Dispose(); Remove-Item $zip
Get-ChildItem $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

$uninst = @"
`$AppName = '$AppName'
if ([System.Windows.MessageBox]::Show("Remove `$AppName?", 'Uninstall', 'YesNo') -ne 'Yes') { exit }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { `$_.CommandLine -like '*$dest*Launcher.ps1*' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force }
Remove-Item "`$([Environment]::GetFolderPath('Programs'))\$AppName.lnk","`$([Environment]::GetFolderPath('Desktop'))\$AppName.lnk","`$([Environment]::GetFolderPath('Startup'))\$AppName.lnk","`$([Environment]::GetFolderPath('Programs'))\Uninstall $AppName.lnk" -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName' -Recurse -ErrorAction SilentlyContinue
Start-Process cmd.exe -ArgumentList '/c timeout /t 2 >nul & rmdir /s /q "$dest"' -WindowStyle Hidden
"@
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
$install = $install.Replace('__NAME__', $safe.Replace("'", "''")).Replace('__B64__', $b64)
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
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item $stage -Recurse -Force; Remove-Item $zip -Force

$msg = if ($built) { "Built:`n$exe`n`nCopy that one file to the other PC and run it.`n(Backup: '$safe Setup.cmd' + '$ps1Name' together also work.)" }
       else { "IExpress wasn't available, so built:`n$cmd`n$ps1`n`nCopy BOTH files to the other PC and run the .cmd." }
[System.Windows.MessageBox]::Show($msg, 'Build installer') | Out-Null
Start-Process explorer.exe "`"$OutDir`""
