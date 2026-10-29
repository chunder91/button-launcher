# Dry-run checks for Build-Installer.ps1 (no install, no build). Runs on pwsh (Linux or Windows).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'Build-Installer.ps1'
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
$e = $null; $t = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
Check 'Build-Installer.ps1 parses' ($e.Count -eq 0)
$assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
$tmpl = @{}
foreach ($x in $assign) { $l = $x.Left.Extent.Text
    if ($l -in '$uninstTemplate', '$install' -and $x.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $tmpl[$l] = $x.Right.Expression.Value } }
foreach ($k in '$uninstTemplate', '$install') {
    $src = $tmpl[$k].Replace('__NAME__', 'Launcher').Replace('__VERSION__', '1.1.0').Replace('__B64__', 'AA==').Replace('__UNINST_B64__', 'AA==')
    $pe = $null; $sa = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$pe)
    Check "$k template parses" ($pe.Count -eq 0)
    Check "$k template has param() first" ([bool]$sa.ParamBlock)
}
Check 'uninstall uses $PSScriptRoot' ($tmpl['$uninstTemplate'] -match '\$dest = \$PSScriptRoot')
Check 'uninstall has no cmd rmdir' ($tmpl['$uninstTemplate'] -notmatch 'rmdir')
Check 'uninstall removes Run value' ($tmpl['$uninstTemplate'] -match 'Remove-ItemProperty -LiteralPath \$run -Name \$rn')
# H1/L4: sanitizer (same expression as the builder)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SafeAppName' }, $true)
Check 'builder defines Get-SafeAppName' ([bool]$fn)
Invoke-Expression $fn.Extent.Text
foreach ($case in @(@('?', 'Launcher'), @('  ', 'Launcher'), @('::', 'Launcher'), @('..', 'Launcher'), @('..\..\Windows', 'Windows'),
                     @('C:\Temp', 'CTemp'), @('a$(calc)b', 'acalcb'), @("O'Brien", 'OBrien'), @('Shop  Panel', 'Shop Panel'), @('Launcher', 'Launcher'),
                     # R-L1/R-L4: reserved device names (any case, with or without extension), trailing dots/spaces, 64-char cap
                     @('CON', 'Launcher'), @('con', 'Launcher'), @('Nul.txt', 'Launcher'), @('PRN', 'Launcher'), @('aux.', 'Launcher'),
                     @('COM1', 'Launcher'), @('com9.log', 'Launcher'), @('LPT1', 'Launcher'), @('lpt9 ', 'Launcher'), @('C O N', 'C O N'),
                     @('COM10', 'COM10'), @('Console', 'Console'), @('Shop. . ', 'Shop'), @(('A' * 300), ('A' * 64)),
                     @((('B' * 63) + ' xyz'), ('B' * 63)))) {
    $safe = Get-SafeAppName $case[0]
    Check ("name '{0}' -> '{1}'" -f $case[0], $safe) ($safe -ceq $case[1] -and $safe -match '^[A-Za-z0-9 _-]+$')
}
# Uninstall guard logic (copied from the template) against fake folders
$guard = @($tmpl['$uninstTemplate'] -split "`n" | Where-Object { $_ -match '^\$ok = |^\s+\(\[IO|^\s+\(Test-Path' }) -join "`n"
$tmpBase = Join-Path ([IO.Path]::GetTempPath()) ('bl-test-' + [guid]::NewGuid()); $env:LOCALAPPDATA = $tmpBase
$progs = Join-Path $tmpBase 'Programs'; New-Item -ItemType Directory -Force (Join-Path $progs 'Launcher') | Out-Null
Set-Content (Join-Path $progs 'Launcher/Launcher.ps1') '#'
foreach ($c in @(@('Launcher', (Join-Path $progs 'Launcher'), $true), @('Launcher', $progs, $false), @('', $progs, $false),
                 @('Launcher', (Join-Path $progs 'Other'), $false))) {
    $AppName = $c[0]; $dest = $c[1]
    $expected = Join-Path $env:LOCALAPPDATA ('Programs\' + $AppName)
    if ($IsLinux -or $IsMacOS) { $expected = $expected.Replace('\', '/') }
    $guardSrc = if ($IsLinux -or $IsMacOS) { $guard.Replace("TrimEnd('\')", "TrimEnd('/')") } else { $guard }
    $ok = $false; Invoke-Expression $guardSrc
    Check ("uninstall guard app='{0}' dest='{1}' -> {2}" -f $c[0], ($c[1] -replace [regex]::Escape($tmpBase), '<LOCALAPPDATA>'), [bool]$ok) ([bool]$ok -eq $c[2])
}
Remove-Item -LiteralPath $tmpBase -Recurse -Force
# Pictures: every image a button uses exists, and the builder stages images\ + ButtonLauncher.exe
$cfg = Get-Content (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
foreach ($pc in @($cfg.panels)) { foreach ($b in @($pc.buttons)) { if ($b.image -and $b.image -ne 'icon') {
    Check ("picture ships: " + $b.image) (Test-Path -LiteralPath (Join-Path $root $b.image)) } } }
Check 'builder copies images folder' ($ast.Extent.Text -match "Copy-Item -LiteralPath \(Join-Path \`$here 'images'\)")
Check 'builder packages ButtonLauncher.exe' ($ast.Extent.Text -match "'ButtonLauncher.exe','Start Launcher.vbs'")
Check 'ButtonLauncher.exe present' (Test-Path -LiteralPath (Join-Path $root 'ButtonLauncher.exe'))
# ---------- R-L4 ----------
# Launcher.ps1 uses the same name rules and key name as the builder.
$lp = Join-Path $root 'Launcher.ps1'; $le = $null
$last = [System.Management.Automation.Language.Parser]::ParseFile($lp, [ref]$null, [ref]$le)
$lfn = $last.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'global:Get-SafeAppName' }, $true)
Check 'Launcher.ps1 Get-SafeAppName matches the builder' ($lfn -and $lfn.Body.Extent.Text -ceq $fn.Body.Extent.Text)
Check 'Launcher toggle uses Get-AppKeyName for the Run value' ($last.Extent.Text -match "-Name \`$n -Value \(Get-AutostartCommand\)" -and $last.Extent.Text -notmatch "-Name 'ButtonLauncher'")
$keyLine = "`$KeyName = if (`$AppName -eq 'Launcher') { 'ButtonLauncher' } else { 'ButtonLauncher-' + `$AppName }"
Check 'installer and uninstaller derive the same key name' ($tmpl['$install'].Contains($keyLine) -and $tmpl['$uninstTemplate'].Contains($keyLine))
Check 'Launcher derives the same key name' ($last.Extent.Text -match [regex]::Escape("if (`$AppName -eq 'Launcher') { return 'ButtonLauncher' } else { return 'ButtonLauncher-' + `$AppName }"))
Check 'Reload timeout asks Yes/No, default No (R3-L1)' ($last.Extent.Text -match [regex]::Escape("Start anyway? Changes from the old one may be lost."", 'Launcher', 'YesNo', 'Warning', 'No')"))
Check 'Reload timeout: No exits, Yes logs and continues (R3-L1)' ($last.Extent.Text -match "if \(\`$ans -ne 'Yes'\) \{ exit 0 \}" -and $last.Extent.Text -match 'user chose to start anyway' -and $last.Extent.Text -match '\$got = \$true\s+\}\s+\}')

# Stub (exe/ButtonLauncher.cs): source checks for a missing Launcher.ps1 and the PowerShell path (R-M3)
$cs = Get-Content -LiteralPath (Join-Path $root 'exe/ButtonLauncher.cs') -Raw
Check 'stub: missing Launcher.ps1 shows an error and exits' ($cs -match '(?s)if \(!File\.Exists\(script\)\)\s*\{\s*MessageBox\.Show\(.*?return 1;')
Check 'stub: PowerShell only from Environment.SystemDirectory' ($cs -match 'Path\.Combine\(Environment\.SystemDirectory, @"WindowsPowerShell\\v1\.0\\powershell\.exe"\)')
Check 'stub: no bare powershell.exe fallback' ($cs -notmatch '=\s*"powershell\.exe"')
Check 'stub: missing PowerShell shows an error' ($cs -match '(?s)if \(!File\.Exists\(ps\)\)\s*\{\s*MessageBox\.Show\(')
$shaRec = ((Get-Content -LiteralPath (Join-Path $root 'exe/ButtonLauncher.exe.sha256') -Raw).Trim() -split '\s+')[0]
Check 'committed exe matches exe/ButtonLauncher.exe.sha256' ((Get-FileHash -LiteralPath (Join-Path $root 'ButtonLauncher.exe') -Algorithm SHA256).Hash -ieq $shaRec)
Check 'RELEASE.md lists verify-exe, dry-run, check-launcher (R3-L2)' ((Get-Content (Join-Path $root 'RELEASE.md') -Raw) -match 'verify-exe\.sh' -and (Get-Content (Join-Path $root 'RELEASE.md') -Raw) -match 'test-installer-dryrun' -and (Get-Content (Join-Path $root 'RELEASE.md') -Raw) -match 'check-launcher')
Check 'builder prints the RELEASE.md reminder (R3-L2)' ($ast.Extent.Text -match 'RELEASE\.md checklist')
Check 'builder checks the exe SHA-256' ($ast.Extent.Text -match 'does not match its recorded SHA-256')
Check 'R4-L2: uninstall delete has no recursive Directory.Delete' ($tmpl['$uninstTemplate'] -notmatch 'Delete\(\$d, \$true\)' -and $tmpl['$uninstTemplate'] -match 'for \(\$i = \$order\.Count - 1')
# R6-N1: every SVG master in the repo's history is a known shipped hash
$svgMiss = @(); foreach ($c in (& git -C $root rev-list --all -- images/svg)) { foreach ($ln in (& git -C $root ls-tree -r $c images/svg)) {
    $bid = ($ln -split '\s+')[2]; $tmpf = [IO.Path]::GetTempFileName()
    $pi = New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName = 'git'; Arguments = "-C `"$root`" cat-file blob $bid"; RedirectStandardOutput = $true; UseShellExecute = $false }
    $pr = [System.Diagnostics.Process]::Start($pi); $ms = New-Object IO.MemoryStream; $pr.StandardOutput.BaseStream.CopyTo($ms); $pr.WaitForExit()
    $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($ms.ToArray())).Replace('-', '').ToLowerInvariant()
    if (-not $tmpl['$install'].Contains("'$h'")) { $svgMiss += $h } ; Remove-Item $tmpf } }
Check 'R6-N1: all older SVG master hashes known to the installer' ($svgMiss.Count -eq 0)
Check 'R6-L1: swap failure restores the old folder' ($tmpl['$install'] -match [regex]::Escape('if ($old -and -not (Test-Path -LiteralPath $dest)) { try { Move-Dir $old $dest } catch { $restored = $false } }'))
Check 'R7-N2: install log has a random name and is created with CreateNew' ($tmpl['$install'] -match "-install-' \+ \[guid\]::NewGuid\(\)" -and $tmpl['$install'] -match '\[IO\.FileMode\]::CreateNew' -and $tmpl['$install'] -notmatch "'-install\.log'")
Check 'R6-L1: stage/.old removal never follows links' ($tmpl['$install'] -match 'function Remove-Tree' -and $tmpl['$install'] -notmatch '-Recurse -Force' -and $tmpl['$install'] -notmatch 'Delete\(\$p, \$true\)')
Check 'builder never ships buttons.json' ($ast.Extent.Text -notmatch "'Launcher.ps1','buttons.json'" -and $ast.Extent.Text -match "Join-Path \`$stage 'buttons.default.json'")

# Simulated install -> reinstall -> uninstall in a temp dir. Registry, shortcuts, message boxes, processes are mocked.
if (-not ('BLMock.Shell' -as [type])) {
Microsoft.PowerShell.Utility\Add-Type -TypeDefinition @"
namespace BLMock {
  public static class Box { public static string Show(params object[] a) { foreach (object o in a) { if ((o + "") == "YesNo") return "Yes"; } return "OK"; } }
  public static class Env { public static string GetFolderPath(string n) { string d = System.IO.Path.Combine(System.Environment.GetEnvironmentVariable("BL_MOCK_FOLDERS"), n); System.IO.Directory.CreateDirectory(d); return d; } }
  public class Link { public string TargetPath, Arguments, WorkingDirectory, IconLocation, Description, Path;
    public void Save() { System.IO.File.WriteAllText(Path, TargetPath + "|" + Arguments); } }
  public class Shell { public Link CreateShortcut(string p) { Link l = new Link(); l.Path = p; return l; } }
}
"@
}
$global:Reg = @{}; $global:Started = New-Object System.Collections.ArrayList
function Add-Type { }
function Get-CimInstance { @() }
function Unblock-File { }
function Start-Process { [void]$global:Started.Add(($args -join ' ')) }
function New-Item { if ("$args" -match 'HKCU:') { $global:Reg[[string]$args[1]] = @{} ; return } ; Microsoft.PowerShell.Management\New-Item @args }
function Remove-Item { if ("$args" -match 'HKCU:') { $global:Reg.Remove([string]$args[1]); return } ; Microsoft.PowerShell.Management\Remove-Item @args }
function New-ItemProperty { [CmdletBinding()] param($LiteralPath, $Name, $Value, $PropertyType, [switch]$Force)
    if (-not $global:Reg.ContainsKey($LiteralPath)) { $global:Reg[$LiteralPath] = @{} }; $global:Reg[$LiteralPath][$Name] = $Value }
function Remove-ItemProperty { [CmdletBinding()] param($LiteralPath, $Name) if ($global:Reg.ContainsKey($LiteralPath)) { $global:Reg[$LiteralPath].Remove($Name) } }
function Get-ItemProperty { [CmdletBinding()] param($LiteralPath, $Name)
    if ($global:Reg.ContainsKey($LiteralPath) -and $global:Reg[$LiteralPath].ContainsKey($Name)) { [pscustomobject]@{ $Name = $global:Reg[$LiteralPath][$Name] } } }
function Convert-ForTest([string]$src) {
    $src = $src.Replace('[System.Windows.MessageBox]::Show', '[BLMock.Box]::Show').Replace('[Environment]::GetFolderPath', '[BLMock.Env]::GetFolderPath').Replace('New-Object -ComObject WScript.Shell', '[BLMock.Shell]::new()')
    if ($IsLinux -or $IsMacOS) { $src = $src.Replace("'Programs\'", "'Programs/'").Replace('"Programs\"', '"Programs/"').Replace("TrimEnd('\')", "TrimEnd('/')") }
    $src }
$runK = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; $unK = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'
foreach ($title in 'Launcher', 'Shop Panel') {
    $tb = Join-Path ([IO.Path]::GetTempPath()) ('bl-sim-' + [guid]::NewGuid())
    $savedLad = $env:LOCALAPPDATA; $savedTemp = $env:TEMP
    $env:LOCALAPPDATA = Join-Path $tb 'lad'; $env:TEMP = Join-Path $tb 'tmp'; $env:BL_MOCK_FOLDERS = Join-Path $tb 'folders'
    New-Item -ItemType Directory -Force $env:LOCALAPPDATA, $env:TEMP | Out-Null
    $global:Reg = @{ $runK = @{ 'Other' = 'other.exe' } }; $global:Started.Clear()
    $safe = Get-SafeAppName $title
    $key = if ($safe -eq 'Launcher') { 'ButtonLauncher' } else { 'ButtonLauncher-' + $safe }
    $unB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Convert-ForTest $tmpl['$uninstTemplate']).Replace('__NAME__', $safe)))   # same as the builder
    # Payload zip built in memory: shipped-images.txt in the builder's format, plus optional hostile entry names (LJ-N7)
    function New-TestInstaller([hashtable]$imgs, [string[]]$evil, [string]$omit) {
        $pz = Join-Path $tb ('p-' + [guid]::NewGuid() + '.zip')
        $fs = [IO.File]::Open($pz, 'CreateNew'); $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        $files = [ordered]@{ 'Launcher.ps1' = '#'; 'ButtonLauncher.exe' = 'MZ'; 'buttons.default.json' = '{"default":true}' }
        $man = @(); foreach ($k in $imgs.Keys) { $files['images/' + $k] = $imgs[$k]
            $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($imgs[$k]))).Replace('-', '').ToLowerInvariant()
            $man += "$h  images/$k" }
        $files['shipped-images.txt'] = ($man -join "`n")
        if ($omit) { $files.Remove($omit) }
        foreach ($k in @($files.Keys) + @($evil | Where-Object { $_ })) {
            $w = New-Object IO.StreamWriter($za.CreateEntry($k).Open()); $w.Write($(if ($files.Contains($k)) { $files[$k] } else { 'evil' })); $w.Dispose() }
        $za.Dispose(); $fs.Dispose()
        $f = Join-Path $tb ('install-' + [guid]::NewGuid() + '.ps1')
        Set-Content $f ((Convert-ForTest $tmpl['$install']).Replace('__NAME__', $safe).Replace('__VERSION__', '1.1.0').Replace('__B64__', [Convert]::ToBase64String([IO.File]::ReadAllBytes($pz))).Replace('__UNINST_B64__', $unB64))
        $f }
    function Write-Raw($path, $text) { [IO.File]::WriteAllText($path, $text) }
    $instFile = New-TestInstaller @{ 'reddog.png' = 'png'; 'globe.png' = 'g1' } @()
    $dest = Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') $safe
    $exeQ = '"' + (Join-Path $dest 'ButtonLauncher.exe') + '"'
    & $instFile
    $p = "[$title] "
    Check ($p + 'install: buttons.json created from default') ((Get-Content (Join-Path $dest 'buttons.json') -Raw).Trim() -eq '{"default":true}')
    Check ($p + "install: Run value '$key' set to the exe") ($global:Reg[$runK][$key] -eq $exeQ)
    Check ($p + "install: Uninstall key '$key' with name/location") ($global:Reg[$unK + $key].DisplayName -eq $safe -and $global:Reg[$unK + $key].InstallLocation -eq $dest)
    Check ($p + 'install: other Run values untouched') ($global:Reg[$runK]['Other'] -eq 'other.exe')
    $progs = Join-Path $env:BL_MOCK_FOLDERS 'Programs'; $desk = Join-Path $env:BL_MOCK_FOLDERS 'Desktop'
    Check ($p + 'install: Start menu, uninstall and desktop shortcuts') ((Test-Path (Join-Path $progs "$safe.lnk")) -and (Test-Path (Join-Path $progs "Uninstall $safe.lnk")) -and (Test-Path (Join-Path $desk "$safe.lnk")))
    Check ($p + 'install: launches the exe') (@($global:Started) -match 'ButtonLauncher\.exe').Count -ge 1
    # R5-L2: a payload missing a core file stops before shortcuts or registry are written
    foreach ($om in 'ButtonLauncher.exe', 'Launcher.ps1', 'buttons.default.json') {
        $sbx = Join-Path $tb ('sbx-' + [guid]::NewGuid()); $saveL = $env:LOCALAPPDATA; $env:LOCALAPPDATA = $sbx; $saveF = $env:BL_MOCK_FOLDERS; $env:BL_MOCK_FOLDERS = Join-Path $sbx 'folders'
        $saveReg = $global:Reg; $global:Reg = @{}; $saveSt = @($global:Started); $global:Started.Clear()
        $bad = New-TestInstaller @{ 'reddog.png' = 'png' } @() $om
        & $bad
        $sd = Join-Path (Join-Path $sbx 'Programs') $safe
        $lg = Get-ChildItem -LiteralPath $env:TEMP -Filter "$safe-install-*.log" | Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName; $lt = if (Test-Path -LiteralPath $lg) { Get-Content -LiteralPath $lg -Raw } else { '' }
        $lnks = @(Get-ChildItem -Recurse -Filter *.lnk -LiteralPath $env:BL_MOCK_FOLDERS -ErrorAction SilentlyContinue)
        Check ($p + "R5-L2: missing $om -> no shortcuts, no registry, no launch, logged") ($lnks.Count -eq 0 -and $global:Reg.Count -eq 0 -and $global:Started.Count -eq 0 -and $lt -match "missing after extraction: .*$([regex]::Escape($om))")
        $global:Reg = $saveReg; $global:Started.Clear(); foreach ($s in $saveSt) { [void]$global:Started.Add($s) }
        $env:LOCALAPPDATA = $saveL; $env:BL_MOCK_FOLDERS = $saveF }
    # R6-L1: a failed check on an upgrade leaves the existing install byte-for-byte as it was, with nothing left beside it
    function Snap($d) { (Get-ChildItem -LiteralPath $d -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($d.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';' }
    Write-Raw (Join-Path $dest 'buttons.json') '{"mine":1}'; Write-Raw (Join-Path $dest 'images/user-added.png') 'mine'
    $before = Snap $dest; $saveReg = $global:Reg.Clone(); $runSnap = $global:Reg[$runK].Clone()
    & (New-TestInstaller @{ 'reddog.png' = 'png' } @() 'ButtonLauncher.exe')
    $sib = @(Get-ChildItem -LiteralPath (Split-Path $dest) -Force | Where-Object { $_.Name -like "$safe.new-*" -or $_.Name -like "$safe.old-*" })
    Check ($p + 'R6-L1: failed check -> existing install untouched, no stage/.old left') ((Snap $dest) -eq $before -and $sib.Count -eq 0)
    & (New-TestInstaller @{ 'reddog.png' = 'png'; 'globe.png' = 'g1' } @())
    $sib = @(Get-ChildItem -LiteralPath (Split-Path $dest) -Force | Where-Object { $_.Name -like "$safe.new-*" -or $_.Name -like "$safe.old-*" })
    Check ($p + 'R6-L1: swap -> buttons.json and user picture carried over, no stage/.old left') ((Get-Content (Join-Path $dest 'buttons.json') -Raw) -eq '{"mine":1}' -and (Test-Path (Join-Path $dest 'images/user-added.png')) -and $sib.Count -eq 0 -and (Test-Path (Join-Path $dest 'ButtonLauncher.exe')))
    Remove-Item -LiteralPath (Join-Path $dest 'images/user-added.png'); Write-Raw (Join-Path $dest 'buttons.json') '{"default":true}'
    # R7-L2: copy of the current install fails -> nothing changed, staging cleaned up, clear message
    function Sib { @(Get-ChildItem -LiteralPath (Split-Path $dest) -Force | Where-Object { $_.Name -like "$safe.new-*" -or $_.Name -like "$safe.old-*" }) }
    $before = Snap $dest
    $f = New-TestInstaller @{ 'reddog.png' = 'png' } @(); (Get-Content $f -Raw).Replace('function Copy-Tree($from, $to) {', 'function Copy-Tree($from, $to) { throw "disk full"') | Set-Content $f
    $global:boxes = 0; & $f
    $lg = Get-ChildItem -LiteralPath $env:TEMP -Filter "$safe-install-*.log" | Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName
    Check ($p + 'R7-L2: copy-over failure -> install untouched, staging removed, logged') ((Snap $dest) -eq $before -and (Sib).Count -eq 0 -and (Get-Content $lg -Raw) -match 'could not copy the current install \(disk full\)')
    # R7-L2: second rename and rollback both fail -> nothing deleted, both folders named in the log
    $f = New-TestInstaller @{ 'reddog.png' = 'png' } @()
    (Get-Content $f -Raw).Replace('function Move-Dir($a, $b) { [IO.Directory]::Move($a, $b) }', 'function Move-Dir($a, $b) { $script:mv++; if ($script:mv -ge 2) { throw "in use" }; [IO.Directory]::Move($a, $b) }') | Set-Content $f
    & $f
    $lg = Get-ChildItem -LiteralPath $env:TEMP -Filter "$safe-install-*.log" | Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName; $lt = Get-Content $lg -Raw
    $o = @(Sib | Where-Object { $_.Name -like "$safe.old-*" }); $n = @(Sib | Where-Object { $_.Name -like "$safe.new-*" })
    Check ($p + 'R7-L2: swap + rollback fail -> old and new kept, both paths logged') ($o.Count -eq 1 -and $n.Count -eq 1 -and -not (Test-Path $dest) -and $lt -match [regex]::Escape($o[0].FullName) -and $lt -match [regex]::Escape($n[0].FullName) -and (Test-Path (Join-Path $n[0].FullName 'ButtonLauncher.exe')))
    [IO.Directory]::Move($o[0].FullName, $dest); Microsoft.PowerShell.Management\Remove-Item -LiteralPath $n[0].FullName -Recurse -Force
    Check ($p + 'R7-N2: each failed run gets its own new log file') (@(Get-ChildItem -LiteralPath $env:TEMP -Filter "$safe-install-*.log").Count -ge 2)
    # R7-N1/I-R6b: removing the backup deletes a file link as-is and never clears read-only on its target
    $ro = Join-Path $tb ('ro-' + [guid]::NewGuid() + '.txt'); Set-Content $ro 'keep'; Set-ItemProperty -LiteralPath $ro -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
    if (-not $IsWindows) { & chmod a-w $ro }
    $roBefore = (Get-Item $ro).Attributes
    [void](New-Item -ItemType SymbolicLink -Path (Join-Path $dest 'link.txt') -Target $ro)
    & (New-TestInstaller @{ 'reddog.png' = 'png'; 'globe.png' = 'g1' } @())
    Check ($p + 'R7-N1: backup cleanup leaves a file link target and its read-only flag alone') ((Test-Path $ro) -and (Get-Item $ro).Attributes -eq $roBefore -and -not (Test-Path (Join-Path $dest 'link.txt')) -and (Sib).Count -eq 0)
    if (-not $IsWindows) { & chmod u+w $ro }
    # R-M2 + Pictures/R3-N1: an upgrade keeps buttons.json, pictures the user added, and a user-replaced reddog.png,
    # but refreshes shipped pictures the user never touched.
    Set-Content (Join-Path $dest 'buttons.json') '{"mine":1}'
    Write-Raw (Join-Path $dest 'images/my-own.png') 'mine'; Write-Raw (Join-Path $dest 'images/reddog.png') 'custom'
    $outside = Join-Path $env:LOCALAPPDATA 'escape.txt'
    $instFile2 = New-TestInstaller @{ 'reddog.png' = 'png2'; 'globe.png' = 'g2'; 'my-own.png' = 'shipped' } @('../escape.txt', '../../escape.txt', 'images/../../escape.txt', 'images/bad:name.png', 'images/what?.png')
    & $instFile2
    $img = { param($n) [IO.File]::ReadAllText((Join-Path $dest "images/$n")) }
    Check ($p + 'upgrade: buttons.json kept') ((Get-Content (Join-Path $dest 'buttons.json') -Raw).Trim() -eq '{"mine":1}')
    Check ($p + 'upgrade: added picture with a shipped name kept') ((& $img 'my-own.png') -eq 'mine')
    Check ($p + 'upgrade: user-replaced reddog.png kept') ((& $img 'reddog.png') -eq 'custom')
    Check ($p + 'upgrade: untouched shipped globe.png refreshed') ((& $img 'globe.png') -eq 'g2')
    $ilog = Join-Path $dest 'install.log'; $ltxt = if (Test-Path $ilog) { Get-Content $ilog -Raw } else { '' }
    Check ($p + 'upgrade: kept pictures logged') ($ltxt -match 'images/reddog\.png' -and $ltxt -match 'images/my-own\.png' -and $ltxt -notmatch 'globe')
    Check ($p + 'R4-N1: invalid entry names skipped and logged, install continued') ($ltxt -match 'invalid name: images/bad:name\.png' -and $ltxt -match 'invalid name: images/what\?\.png' -and -not (Test-Path -LiteralPath (Join-Path $dest 'images/bad:name.png')) -and ((& $img 'globe.png') -eq 'g2'))
    Check ($p + 'LJ-N7: ../ entries not extracted outside') (-not (Test-Path $outside) -and -not (Test-Path (Join-Path $tb 'escape.txt')))
    & $instFile2   # a second run with the new manifest: reddog stays the user's
    # R4-L1: an install from before the manifest (no shipped-images.txt) refreshes pictures that still match a v1.1.0 hash
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $dest 'shipped-images.txt')
    $badgeOld = Join-Path $dest 'images/badge.png'
    $gitOk = $true; try { & git -C $root cat-file -e origin/main:images/badge.png 2>$null; $gitOk = ($LASTEXITCODE -eq 0) } catch { $gitOk = $false }
    if ($gitOk) {
        $raw = [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName = 'git'; Arguments = "-C `"$root`" show origin/main:images/badge.png"; RedirectStandardOutput = $true; UseShellExecute = $false }))
        $ms = New-Object IO.MemoryStream; $raw.StandardOutput.BaseStream.CopyTo($ms); $raw.WaitForExit(); [IO.File]::WriteAllBytes($badgeOld, $ms.ToArray())
        Write-Raw (Join-Path $dest 'images/power.png') 'user-made'
        $instFile3 = New-TestInstaller @{ 'badge.png' = 'new-badge'; 'power.png' = 'new-power' } @()
        & $instFile3
        Check ($p + 'R4-L1: no manifest: v1.1.0 badge.png refreshed') ((& $img 'badge.png') -eq 'new-badge')
        # R5-L1: a picture shipped by a review-fixes-1 build (772f83a) is also recognised
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $dest 'shipped-images.txt')
        $raw2 = [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName = 'git'; Arguments = "-C `"$root`" show 772f83a:images/reddog-small.png"; RedirectStandardOutput = $true; UseShellExecute = $false }))
        $ms2 = New-Object IO.MemoryStream; $raw2.StandardOutput.BaseStream.CopyTo($ms2); $raw2.WaitForExit(); [IO.File]::WriteAllBytes((Join-Path $dest 'images/reddog-small.png'), $ms2.ToArray())
        & (New-TestInstaller @{ 'reddog-small.png' = 'new-small' } @())
        Check ($p + 'R5-L1: no manifest: 772f83a reddog-small.png refreshed') ((& $img 'reddog-small.png') -eq 'new-small')
        Check ($p + 'R4-L1: no manifest: unknown power.png kept') ((& $img 'power.png') -eq 'user-made')
    } else { Check ($p + 'R4-L1: origin/main available for the test') $false }
    Check ($p + 'upgrade again: user-replaced reddog.png still kept') ((& $img 'reddog.png') -eq 'custom')
    if ($safe -ne 'Launcher') {   # LJ-N6: a legacy 'ButtonLauncher' value for a look-alike folder (<name>2) is not ours
        $global:Reg[$runK]['ButtonLauncher'] = '"' + (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') ($safe + '2')) + '/ButtonLauncher.exe"'
        & $instFile2
        Check ($p + 'LJ-N6: install keeps a look-alike folder''s legacy Run value') ($global:Reg[$runK].ContainsKey('ButtonLauncher')) }
    # Uninstall (the generated Uninstall.ps1, run from the install folder)
    $global:Started.Clear()
    Check ($p + 'installed Uninstall.ps1 has its real name') ((Get-Content (Join-Path $dest 'Uninstall.ps1') -Raw) -notmatch '__NAME__')
    $global:Started.Clear(); $unOut = & (Join-Path $dest 'Uninstall.ps1') 2>&1
    Check ($p + 'uninstall: Run value removed') (-not $global:Reg[$runK].ContainsKey($key))
    Check ($p + 'uninstall: Uninstall key removed') (-not $global:Reg.ContainsKey($unK + $key))
    Check ($p + 'uninstall: other Run values untouched') ($global:Reg[$runK]['Other'] -eq 'other.exe')
    Check ($p + 'uninstall: shortcuts removed') (-not ((Test-Path (Join-Path $progs "$safe.lnk")) -or (Test-Path (Join-Path $progs "Uninstall $safe.lnk")) -or (Test-Path (Join-Path $desk "$safe.lnk"))))
    $enc = @(@($global:Started) -match '-EncodedCommand (\S+)'); $cmdText = if ($enc.Count) { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($enc[0] -split '-EncodedCommand ')[1].Trim())) } else { '' }
    Check ($p + 'uninstall: folder delete targets exactly the install folder') ($cmdText.StartsWith('Start-Sleep -Seconds 2; try { & { param($d)') -and $cmdText.EndsWith("} '" + $dest.Replace("'", "''") + "' } catch { }"))
    if ($safe -ne 'Launcher') { Check ($p + 'LJ-N6: uninstall keeps a look-alike folder''s legacy Run value') ($global:Reg[$runK].ContainsKey('ButtonLauncher')) }
    # LJ-N5: run that delete command (minus the sleep) with a directory symlink inside the folder pointing outside
    $victim = Join-Path $tb 'victim'; New-Item -ItemType Directory -Force (Join-Path $victim 'sub') | Out-Null; Write-Raw (Join-Path $victim 'sub/keep.txt') 'keep'
    $linkOk = $true
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $dest 'images/link') -Target $victim -ErrorAction Stop | Out-Null } catch { $linkOk = $false }
    if (-not $linkOk -and -not ($IsLinux -or $IsMacOS)) { cmd /c mklink /J "$(Join-Path $dest 'images\link')" "$victim" | Out-Null; $linkOk = $LASTEXITCODE -eq 0 }
    New-Item -ItemType Directory -Force (Join-Path $dest 'images/deep/deeper') | Out-Null; Write-Raw (Join-Path $dest 'images/deep/deeper/ro.txt') 'x'
    [IO.File]::SetAttributes((Join-Path $dest 'images/deep/deeper/ro.txt'), [IO.FileAttributes]::ReadOnly)
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $dest 'images/deep/deeper/link2') -Target $victim -ErrorAction Stop | Out-Null } catch { }
    $vfile = Join-Path $victim 'ro-target.txt'; Write-Raw $vfile 'keep'; [IO.File]::SetAttributes($vfile, [IO.FileAttributes]::ReadOnly)
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $dest 'images/filelink.txt') -Target $vfile -ErrorAction Stop | Out-Null } catch { }
    Check ($p + 'LJ-N5: test link created') $linkOk
    Invoke-Expression ($cmdText.Replace('Start-Sleep -Seconds 2; ', '').Replace('catch { }', 'catch { throw }'))
    Check ($p + 'LJ-N5: install folder deleted') (-not (Test-Path -LiteralPath $dest))
    Check ($p + 'LJ-N10: read-only file behind a file link keeps its read-only bit') ((Test-Path $vfile) -and (([IO.File]::GetAttributes($vfile) -band [IO.FileAttributes]::ReadOnly) -ne 0))
    [IO.File]::SetAttributes($vfile, [IO.FileAttributes]::Normal)
    Check ($p + 'LJ-N5: link target and its files survive') ((Test-Path (Join-Path $victim 'sub/keep.txt')) -and ([IO.File]::ReadAllText((Join-Path $victim 'sub/keep.txt')) -eq 'keep'))
    $env:LOCALAPPDATA = $savedLad; $env:TEMP = $savedTemp
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $tb -Recurse -Force
}
foreach ($f in 'Add-Type','Get-CimInstance','Unblock-File','Start-Process','New-Item','Remove-Item','New-ItemProperty','Remove-ItemProperty','Get-ItemProperty','Convert-ForTest') { Microsoft.PowerShell.Management\Remove-Item -LiteralPath "function:$f" }
# v1.4.0 (M14-I3): the NSIS uninstaller removes only this user's email count files from %LOCALAPPDATA%\ButtonLauncher
$nsi = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'installer\launcher.nsi') -Raw
$un = [regex]::Match($nsi, '(?s)Section "Uninstall".*?SectionEnd').Value
$blLines = @(($un -split "`r?`n") | Where-Object { $_ -match 'LOCALAPPDATA\\ButtonLauncher' -and $_ -notmatch '^\s*;' } | ForEach-Object { $_.Trim() -replace '\s*;.*$', '' })
$want = @('Delete "$LOCALAPPDATA\ButtonLauncher\email-count.json"', 'Delete "$LOCALAPPDATA\ButtonLauncher\email-count.dat"', 'Delete "$LOCALAPPDATA\ButtonLauncher\email-count.json.tmp"', 'Delete "$LOCALAPPDATA\ButtonLauncher\email-count.dat.tmp"')
$dels = @($blLines | Where-Object { $_ -like 'Delete *' })
Check 'uninstall: exact deletes only: email-count.json, .dat, .json.tmp, .dat.tmp (no wildcard)' ((($dels | Sort-Object) -join '|') -ceq (($want | Sort-Object) -join '|') -and -not ($un -match 'ButtonLauncher\\[^"]*\*'))
Check 'uninstall: the ButtonLauncher folder only if empty (RMDir without /r)' (@($blLines | Where-Object { $_ -like 'RMDir *' }) -join '|' -ceq 'RMDir "$LOCALAPPDATA\ButtonLauncher"' -and -not ($un -match 'RMDir /r "\$LOCALAPPDATA\\ButtonLauncher'))
$lk = [regex]::Match($un, '(?s)StrCpy \$R6 "\$LOCALAPPDATA\\ButtonLauncher"\s+Call un\.IsLink[^\r\n]*\s+\$\{If\} \$R5 = 0(.*?)\$\{Else\}(.*?)\$\{EndIf\}')
Check 'uninstall: link check on %LOCALAPPDATA%\ButtonLauncher first; a link skips every delete and the RMDir' ($lk.Success -and ([regex]::Matches($lk.Groups[1].Value, '(?m)^\s*(Delete|RMDir) ')).Count -eq 5 -and $lk.Groups[2].Value -notmatch '(?m)^\s*(Delete|RMDir) ')

if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
