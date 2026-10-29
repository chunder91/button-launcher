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
                     @('C:\Temp', 'CTemp'), @('a$(calc)b', 'acalcb'), @("O'Brien", 'OBrien'), @('Shop  Panel', 'Shop Panel'), @('Launcher', 'Launcher'))) {
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
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
