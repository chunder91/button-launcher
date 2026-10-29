# Checks for the Option B look that run without Windows: labels, palette, restart grouping, order migration, limits.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Launcher.ps1'), [ref]$null, [ref]$null)
$src = $ast.Extent.Text
foreach ($n in 'Get-ButtonType', 'Set-Prop', 'Get-Color', 'Mix-Color', 'Get-TileColors', 'Test-DangerButton', 'Get-DisplayLabel', 'Update-OldDefaultOrder') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(ModernFill|Acronyms|Theme)\s*=') { Invoke-Expression $l.Extent.Text } }
function L($label, $extra) { $o = [pscustomobject]@{ label = $label; type = 'website'; action = '' }; if ($extra) { foreach ($k in $extra.Keys) { $o | Add-Member $k $extra[$k] -Force } }; $o }
$cases = @(
    @((L "RED DOG`nBACK`nOFFICE"), 'Red Dog Back Office', $null),
    @((L 'VIEW REGISTER'), 'View Register', $null),
    @((L 'PLCE'), 'PLCE', $null),
    @((L "DEPARTMENT`nOF`nREVENUE"), 'Department of Revenue', $null),
    @((L "BACK OFFICE`nUSER GUIDE`nVERSION 11"), 'Back Office User Guide', 'Version 11'),
    @((L "START`nJARTREK`nSECURITY"), 'Start Jartrek Security', $null),
    @((L "RESTART`nSCREEN CONNECT" @{ type = 'builtin'; action = 'restart-screenconnect' }), "Restart`nScreenConnect", $null),
    @((L "RESTART`nCOMPUTER" @{ type = 'builtin'; action = 'restart-computer' }), "Restart`nComputer", $null),
    @((L 'My Mixed Label'), 'My Mixed Label', $null),
    @((L 'eBay deals'), 'eBay deals', $null))
foreach ($c in $cases) { $d = Get-DisplayLabel $c[0]
    Check ("label '{0}' -> '{1}'" -f ($c[0].label -replace "`n", '|'), ($d.main -replace "`n", '|')) ($d.main -ceq $c[1] -and $d.sub -ceq $c[2]) }
Check 'stored label untouched' ((L 'VIEW REGISTER').label -ceq 'VIEW REGISTER')
# Palette: old defaults map to Kern's AA fills; custom colours stay
$pal = @{ '#3EC3EE' = '#0B6E99'; '#FFFF00' = '#FACC15'; '#FF0000' = '#C40000'; '#DAA520' = '#8A6100'; '#fa8072' = '#B8432F' }
foreach ($k in $pal.Keys) { Check "fill $k -> $($pal[$k])" ((Get-TileColors ([pscustomobject]@{ bg = $k; fg = '#FFFFFF' })).bg -eq $pal[$k]) }
Check 'PLCE label is white (no gold on red)' ((Get-TileColors ([pscustomobject]@{ bg = '#FF0000'; fg = '#FFC000' })).fg -eq '#FFFFFF')
Check 'Email label is #111111' ((Get-TileColors ([pscustomobject]@{ bg = '#FFFF00'; fg = '#000000' })).fg -eq '#111111')
Check 'custom colour kept' ((Get-TileColors ([pscustomobject]@{ bg = '#123456'; fg = '#EEEEEE' })).bg -eq '#123456')
function Lum($hex) { $h = $hex.TrimStart('#'); $ch = foreach ($v in [Convert]::ToInt32($h.Substring(0,2),16), [Convert]::ToInt32($h.Substring(2,2),16), [Convert]::ToInt32($h.Substring(4,2),16)) { $x = $v / 255; if ($x -le 0.03928) { $x / 12.92 } else { [Math]::Pow(($x + 0.055) / 1.055, 2.4) } }; 0.2126 * $ch[0] + 0.7152 * $ch[1] + 0.0722 * $ch[2] }
function Ratio($a, $b) { $l1 = Lum $a; $l2 = Lum $b; ([Math]::Max($l1, $l2) + 0.05) / ([Math]::Min($l1, $l2) + 0.05) }
foreach ($k in $global:ModernFill.Keys) { $m = $global:ModernFill[$k]; $r = Ratio $m[0] $m[1]; Check ("AA {0} on {1}: {2:N2}:1" -f $m[1], $m[0], $r) ($r -ge 4.5) }
Check ("restart label white on #2A2A2A >= 4.5") ((Ratio '#FFFFFF' $global:Theme.restartFill) -ge 4.5)
Check ("restart red vs panel >= 3:1 (non-text)") ((Ratio $global:Theme.restartRed $global:Theme.panel) -ge 3)
Check ("Editing bar #111 on amber >= 4.5") ((Ratio $global:Theme.editText $global:Theme.amber) -ge 4.5)
# Spec limits in code
Check 'animations capped at 150 ms' ($src -match '\[Math\]::Min\(150, \$ms\)')
Check 'uses Storyboards' ($src -match 'New-Object System\.Windows\.Media\.Animation\.Storyboard')
Check 'launch runs before the flash' ($src -match '\$ok = Invoke-Button \$btn[^\n]*\n\s*if \(\$ok -eq \$true\) \{ Start-Flash \$flash \}')
Check '44 px minimum tile' ($src -match '\[Math\]::Max\(44, \$h\)')
Check 'label floor 12' ($src -match '\$floor = if .* \{ 13\.0 \} else \{ 12\.0 \}')
Check 'font Segoe UI Variable + Semibold fallback' ($src -match "Segoe UI Variable Text Semibold, Segoe UI Semibold, Segoe UI")
Check 'missing tooltip text' ($src -match "New-MissingDot 'Not set up on this PC yet'")
Check 'square-panel fallback' ($src -match '\[bool\]\$global:cfg\.squarePanels' -and $src -match 'AllowsTransparency = \$true')
Check 'restart confirm default No kept' ($src -match "\[System\.Windows\.MessageBox\]::Show\(\`$cText, \`$cTitle, 'YesNo', 'Warning', 'No'\)")
Check 'ScreenConnect admin prompt kept' ($src -match "function global:Restart-ScreenConnect" -and $src -match "RunAs")
# Default order + migration
$def = Get-Content (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
$bl = @($def.panels[1].buttons | ForEach-Object { ([string]$_.label) -replace "`n", ' ' })
Check 'default: Start Jartrek Security above the Restarts' ($bl.IndexOf('START JARTREK SECURITY') -lt $bl.IndexOf('RESTART SCREEN CONNECT') -and $bl[-1] -eq 'RESTART COMPUTER')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('bl-mig-' + [guid]::NewGuid()); New-Item -ItemType Directory $tmp | Out-Null
$global:cfgPath = Join-Path $tmp 'buttons.json'; $global:logPath = Join-Path $tmp 'log.txt'
$oldJson = git -C $root show 772f83a:buttons.json | Out-String
$global:cfg = $oldJson | ConvertFrom-Json; Update-OldDefaultOrder
$ml = @($global:cfg.panels[1].buttons | ForEach-Object { ([string]$_.label) -replace "`n", ' ' })
Check 'migration: old default order moved' ($ml -join '|') -eq 'BACK OFFICE USER GUIDE VERSION 11|REGISTER USER GUIDE VERSION 11|PLCE|DEPARTMENT OF REVENUE|START JARTREK SECURITY|RESTART SCREEN CONNECT|RESTART COMPUTER'
$saved = Get-Content $global:cfgPath -Raw | ConvertFrom-Json
Check 'migration: saved with both panels and layoutVersion 2' (@($saved.panels).Count -eq 2 -and $saved.layoutVersion -eq 2 -and @($saved.panels[0].buttons).Count -eq 4)
$global:cfg = $oldJson | ConvertFrom-Json
$b = @($global:cfg.panels[1].buttons); $global:cfg.panels[1].buttons = @($b[1], $b[0]) + $b[2..6]; Update-OldDefaultOrder
Check 'migration: a rearranged panel is left alone' ((([string]$global:cfg.panels[1].buttons[0].label) -replace "`n", ' ') -eq 'REGISTER USER GUIDE VERSION 11' -and (([string]$global:cfg.panels[1].buttons[4].label) -replace "`n", ' ') -eq 'RESTART SCREEN CONNECT')
Remove-Item -LiteralPath $tmp -Recurse -Force
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
