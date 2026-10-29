# Builds "<PanelName> Setup.exe" (IExpress, built into Windows) from this folder's
# current buttons.json, images\ and launcher files. Also writes a fallback
# "<PanelName> Setup.cmd" + ".ps1" pair in case IExpress isn't available.
param([string]$OutDir)
Add-Type -AssemblyName PresentationFramework
# R3-L2: release builds follow RELEASE.md (verify-exe, dry-run, check-launcher first).
Write-Host 'Reminder: before a release build, run the RELEASE.md checklist (tools/verify-exe.sh, tools/test-installer-dryrun.ps1, check-launcher.ps1).'
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
$AppVersion = '1.2.0'
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
# Pictures/R3-N1: record each shipped picture and its SHA-256, so a later upgrade only overwrites pictures the user never changed.
$stImg = Join-Path $stage 'images'
$man = @(if (Test-Path -LiteralPath $stImg) { Get-ChildItem -LiteralPath $stImg -Recurse -File | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  images/' + $_.FullName.Substring($stImg.Length + 1).Replace('\', '/') } })
Set-Content -LiteralPath (Join-Path $stage 'shipped-images.txt') -Value $man -Encoding UTF8
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
    if ($rv -and ($rv -ieq ('"' + (Join-Path $dest 'ButtonLauncher.exe') + '"') -or $rv -ieq ('wscript.exe "' + (Join-Path $dest 'Start Launcher.vbs') + '"'))) {   # LJ-N6: exact command only
        Remove-ItemProperty -LiteralPath $run -Name $rn -ErrorAction SilentlyContinue } }
# Delete the folder from a child PowerShell after this script exits (no cmd.exe, -LiteralPath only).
$q = $dest.Replace("'", "''")
# LJ-N5/R4-L2: never follow a junction/symlink inside the folder. Walk the tree, then delete bottom-up by hand, re-checking
# ReparsePoint on every directory right before deleting it; links are unlinked (the link only), never recursed into.
# LJ-N10: a file that is a link is deleted as-is; its read-only bit is never cleared (that would change the link's target). $del has no single quotes so it can be embedded below.
$del = 'param($d) $rp = [IO.FileAttributes]::ReparsePoint; if (-not [IO.Directory]::Exists($d)) { return }; if (([IO.File]::GetAttributes($d) -band $rp) -ne 0) { [IO.Directory]::Delete($d, $false); return }; $order = New-Object System.Collections.ArrayList; $st = New-Object System.Collections.Stack; $st.Push($d); while ($st.Count -gt 0) { $c = $st.Pop(); [void]$order.Add($c); foreach ($s in [IO.Directory]::GetDirectories($c)) { if (([IO.File]::GetAttributes($s) -band $rp) -ne 0) { [IO.Directory]::Delete($s, $false) } else { $st.Push($s) } } }; for ($i = $order.Count - 1; $i -ge 0; $i--) { $c = $order[$i]; if (-not [IO.Directory]::Exists($c)) { continue }; if (([IO.File]::GetAttributes($c) -band $rp) -ne 0) { [IO.Directory]::Delete($c, $false); continue }; foreach ($f in [IO.Directory]::GetFiles($c)) { if (([IO.File]::GetAttributes($f) -band $rp) -eq 0) { [IO.File]::SetAttributes($f, [IO.FileAttributes]::Normal) }; [IO.File]::Delete($f) }; foreach ($s in [IO.Directory]::GetDirectories($c)) { if (([IO.File]::GetAttributes($s) -band $rp) -ne 0) { [IO.Directory]::Delete($s, $false) } }; [IO.Directory]::Delete($c, $false) }'
$cmd = "Start-Sleep -Seconds 2; try { & { $del } '$q' } catch { }"
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
# Pictures/R3-N1: what the previous install shipped (name -> SHA-256). An existing picture is replaced only if it is
# still byte-for-byte what we shipped; pictures the user added or replaced are kept and logged.
$oldMan = @{}
$manPath = Join-Path $dest 'shipped-images.txt'
if (Test-Path -LiteralPath $manPath) { foreach ($ml in Get-Content -LiteralPath $manPath) {
    if ($ml -match '^([0-9a-fA-F]{64})\s+(.+)$') { $oldMan[$matches[2].Trim().ToLowerInvariant()] = @($matches[1].ToLowerInvariant()) } } }
else {   # R4-L1/R5-L1: installs from before the manifest shipped these pictures: v1.1.0 (main) and builds from review-fixes-1
    # 772f83a..cde5cf5 (hashes computed from those commits). A picture that still matches any of them is refreshed.
    $oldMan = @{
        'images/globe.png' = @('0b5d8cd2ef4b0010ae965dbfcc35f7f9dfea5b2b5842d38b893a1c015956a2cf', '9febcce7441d02c7cc04edb8fca6e655c15f65da395d1ed2b3982d12837d5124')
        'images/register.png' = @('18d7fc75aedb9d82e4c279e53df076ccaf9fc513094680117bfc61c0609bce88', '662105e5ab430976a35bef64abae4cedfcd60211447d6968386763c6ba1a615f')
        'images/svg/power.svg' = @('1ef48914be3b033c01964faeeed297efe1be3e546968b9735a98c04271d9acb5')
        'images/svg/badge.svg' = @('2528196660f1873fa49517097f73d2e06adf6bbbf1f2648c39f92b94a3aeb53b')
        'images/svg/security.svg' = @('2d21a3dcb74d50a1230a8ffc5d7977918d576eeb6da61a1ba932ece7b45dd381')
        'images/reddog-small.png' = @('3615faf1978993df2d72066a033d61bae27dd965afac8ec3801b8fa910eeb59a')
        'images/revenue.png' = @('3c875cebd0396788a53715464fd6af61c706cdf93cfbe9d29fa5b68f3acfaaa5', '5fa7b0c5bae94e8dc96ceff920e566907e81e7e95054c88208b56685f448f969')
        'images/reddog.png' = @('4125711cedf60d0fb4dd4a9fb0b05aff01c7db95f12d80a0032f1657d37d553b', '875aaf04221c6602808fe75a3736ff55fc0a057cc7a984f7b7785161e6d32816')
        'images/screenconnect.png' = @('4abcbbb7c5ac7664f7282e17e0df135caf61dc52d14c15b72bc9a9254766e735', 'f903c058d8ae014f69ae2e9c09b87e39780ab1240b0e355db86935fe476c700e')
        'images/security.png' = @('664fa94fb69012934cf3a6c7647a122b19105c43b164543a99d2a8b4cb59f70f', 'da7d33138bd401dd1ac00c43d97e9acf0a35967c35d64c5b669242e55edc2952')
        'images/email.png' = @('6ded870b51d0fbaa4ce94d6d1c9aedaca47d60ef744c00a54212fb7af16bf01a', '785779ad2815f5886e5f780176022ed2289ec245e749d792fe34ef63ffe82ae1')
        'images/svg/guide.svg' = @('80e7fd4e9de79c00082298a55c72cb1412791df3722a1743c140dcb76cb07427')
        'images/power.png' = @('8289780bca861ad9aaf69dfc88de61675e7851a1182e686feea63600e5c18081', '9a6b72e428bea6cc14a698bf5d61c04bb2667b714c82500bca8b93335c5e0c86')
        'images/guide.png' = @('a950556411e95be22caa7dc33a59e19fb80734e0c9e75784b1ef513142655893', 'd5177aec60a07cdd838c4570c56bb699e070100f3b6a2868f4e66934492d3b82')
        'images/badge.png' = @('aafa4f4831c6260e4228e08fa1922e44e628b814fd9ff169f960ee2dfefb9cce', 'c80191a8b71708f5126bb81c02945e72c88df7f94458236cc36cc9f7a618b072')
        'images/svg/register.svg' = @('ba2541a8de286809c8138732b7fe811eeb2abf34c3e76bcb07bd106d33a67db9')
        'images/svg/reddog.svg' = @('ba6cd2d4d9a74e63eea48d0ff3814eb023234aa1f752a1d985a87d5d4a2c0de9')
        'images/svg/globe.svg' = @('cca25437b131e4f9eea570871f5c5277594ec721ff62339276e704065b74fbe6')
        'images/svg/revenue.svg' = @('d40e7ad5e89afce789d81b98999df27f2a33884ac5d74391cc7b4ba11d9c7ceb')
        'images/svg/screenconnect.svg' = @('e9ae1141b148a9199ab6e6a353bffff885516d373b0bb284eb6745a2b93c3b5a')
        'images/svg/email.svg' = @('edc024409b3e514db726f3ccc6cb629edda7965fd4d15434b787b5cb995b56e9')
        'images/app.ico' = @('f1cab83836a4af76b9f86f43f863ca5abaae409ba6d07bc0a8be0a6f98426c02') } }
$instLog = Join-Path $dest 'install.log'
$destRoot = [IO.Path]::GetFullPath($dest).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
foreach ($e in $z.Entries) {
    # LJ-N7: skip entries that are rooted, contain '..', or resolve outside $dest
    $en = $e.FullName
    # R4-N1: ':' or other invalid characters in an entry name: skip and log it, don't stop the install
    if ($en.IndexOf(':') -ge 0 -or $en.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $en.IndexOfAny([char[]]'*?"<>|') -ge 0) {
        Add-Content -LiteralPath $instLog -Value ("{0}  skipped a payload entry with an invalid name: {1}" -f (Get-Date -Format s), $en) -ErrorAction SilentlyContinue; continue }
    if ([IO.Path]::IsPathRooted($en) -or $en -match '(^|[\\/])\.\.([\\/]|$)') { continue }
    $t = Join-Path $dest $en
    if (-not [IO.Path]::GetFullPath($t).StartsWith($destRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { New-Item -ItemType Directory -Force $t | Out-Null; continue }
    $rel = $en.Replace('\', '/')
    if ($rel -like 'images/*' -and (Test-Path -LiteralPath $t)) {
        $was = @($oldMan[$rel.ToLowerInvariant()] | Where-Object { $_ })
        $now = (Get-FileHash -LiteralPath $t -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($was.Count -eq 0 -or $was -notcontains $now) {
            Add-Content -LiteralPath $instLog -Value ("{0}  kept your picture {1} (added or changed on this PC); the shipped one was not copied" -f (Get-Date -Format s), $rel) -ErrorAction SilentlyContinue
            continue } }
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
$uninst = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__UNINST_B64__'))   # name already filled in by the builder
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
    if ($rv -and ($rv -ieq ('"' + (Join-Path $dest 'ButtonLauncher.exe') + '"') -or $rv -ieq ('wscript.exe "' + (Join-Path $dest 'Start Launcher.vbs') + '"'))) {   # LJ-N6: exact command only
        Remove-ItemProperty -LiteralPath $run -Name 'ButtonLauncher' -ErrorAction SilentlyContinue } }
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
# Fill the uninstaller's name here: replacing __NAME__ inside $install would also rewrite a .Replace('__NAME__',...) call there.
$unB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uninstTemplate.Replace('__NAME__', $safe)))
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
[System.Windows.MessageBox]::Show($msg + "`n`nReleasing it? Run the RELEASE.md checklist first (verify-exe, dry-run, check-launcher).", 'Build installer') | Out-Null
Start-Process explorer.exe "`"$OutDir`""
