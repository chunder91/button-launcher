# Checks for the Option B look that run without Windows: labels, palette, restart grouping, order migration, limits.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
if (-not $env:ProgramFiles) { $env:ProgramFiles = 'C:\Program Files' }   # Linux box: Windows sets this
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Launcher.ps1'), [ref]$null, [ref]$null)
$src = $ast.Extent.Text
foreach ($n in 'Get-ButtonType', 'Set-Prop', 'Get-Color', 'Mix-Color', 'Get-TileColors', 'Test-DangerButton', 'Get-DisplayLabel', 'Update-OldDefaultOrder', 'ConvertTo-Hex', 'Get-D2Fill',
         'Get-SafeUrl', 'Is-Todo', 'Test-CustomSlot', 'Test-SlotEmpty', 'New-EmptySlot', 'Clear-CustomSlot', 'Test-CustomSlotTarget', 'ConvertTo-CustomSlot', 'Remove-CustomRow', 'Add-CustomRow', 'Test-StockSecurityTile', 'Test-SecurityLabel', 'Get-SecurityMigration', 'ConvertTo-SecuritySlot', 'Test-CustomFileExt') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(ModernFill|Acronyms|Theme|D2Fill|CustomSlotTypes|CustomSlotBadExt|CustomFileExts|CustomFileFilter)\s*=') { Invoke-Expression $l.Extent.Text } }
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
Check 'custom colour kept' ((Get-TileColors ([pscustomobject]@{ bg = '#2D6B8C'; fg = '#EEEEEE' })).bg -eq '#2D6B8C')
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
Check 'MB-M1: Enter/Space ignore key repeat' ($src -match "\(\`$_\.Key -eq 'Enter' -or \`$_\.Key -eq 'Space'\) -and -not \`$_\.IsRepeat")
# D2 (v1.3.0): the per-tile shadow is gone (MB-N1 is moot); the panel has no effect either
$tileSrc = ([regex]::Match($src, '(?s)function global:New-Tile.*?\r?\nfunction global:Pick-Color')).Value
$chipSrc = ([regex]::Match($src, '(?s)function global:New-Chip.*?\r?\nfunction global:Move-Chip')).Value
Check 'D2: no DropShadowEffect, BlurEffect or Effect on tiles/chips' ($tileSrc -and $chipSrc -and ($tileSrc + $chipSrc) -notmatch 'DropShadowEffect|BlurEffect|\.Effect\s*=')
Check 'D2: tile states are pre-built layers; only Opacity and transforms animate' ($tileSrc -match '\$hov = ' -and $tileSrc -match '\$prs = ' -and $tileSrc -match '\$glow = ' -and $tileSrc -notmatch 'ColorProperty')
Check 'D2: hover lift -2, icon 1.06, pressed 0.97, glow 0.90 (restarts 0.55)' ($tileSrc -match '\$lift \$yProp -2 ' -and $tileSrc -match '\$iscale \$sxProp 1\.06' -and $tileSrc -match '\$press \$sxProp 0\.97' -and $tileSrc -match 'glowMax = if \(\$danger\) \{ 0\.55 \} else \{ 0\.90 \}')
Check 'D2: tile radius 12, hero 14, sheen 10 px' ($tileSrc -match '\$rad = if \(\$cls -eq ''hero''\) \{ 14 \} else \{ 12 \}' -and $tileSrc -match 'Set-D2Surface \$tile \$rad 10 ')
Check 'D2: restarts keep the 2 px red outline' ($tileSrc -match 'restartRed; \$tile\.BorderThickness = .2.')
Check 'D2: restart icons are no longer red masks' ($src -notmatch 'OpacityMask = \$ib')
# Default order + migration
$def = Get-Content (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
$bl = @($def.panels[1].buttons | ForEach-Object { ([string]$_.label) -replace "`n", ' ' })
Check 'v1.4.0 default: Start Jartrek Security removed' ($bl -notcontains 'START JARTREK SECURITY' -and -not ($src -match '(?m)^\s*"label": "START\\nJARTREK'))
$db = @($def.panels[1].buttons)
Check 'v1.4.0 default: 2 empty custom slots, half width, just above the Restarts' ((Test-SlotEmpty $db[4]) -and (Test-SlotEmpty $db[5]) -and $db[4].width -eq 'half' -and $db[5].width -eq 'half' -and (Test-DangerButton $db[6]) -and $bl[-1] -eq 'RESTART COMPUTER' -and $def.layoutVersion -eq 3)
Check 'v1.4.0 default: slots same size as the Revenue half tile' ($db[4].height -eq $db[3].height -and $db[4].fontSize -eq $db[3].fontSize)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('bl-mig-' + [guid]::NewGuid()); New-Item -ItemType Directory $tmp | Out-Null
$global:cfgPath = Join-Path $tmp 'buttons.json'; $global:logPath = Join-Path $tmp 'log.txt'
$oldJson = git -C $root show 772f83a:buttons.json | Out-String
$global:cfg = $oldJson | ConvertFrom-Json; Update-OldDefaultOrder
$ml = @($global:cfg.panels[1].buttons | ForEach-Object { ([string]$_.label) -replace "`n", ' ' })
Check 'migration: old default order moved, then Security replaced by 2 empty slots' ($ml -join '|') -eq 'BACK OFFICE USER GUIDE VERSION 11|REGISTER USER GUIDE VERSION 11|PLCE|DEPARTMENT OF REVENUE|||RESTART SCREEN CONNECT|RESTART COMPUTER' -and (Test-SlotEmpty $global:cfg.panels[1].buttons[4]) -and (Test-SlotEmpty $global:cfg.panels[1].buttons[5])
$saved = Get-Content $global:cfgPath -Raw | ConvertFrom-Json
Check 'migration: saved with both panels and layoutVersion 3' (@($saved.panels).Count -eq 2 -and $saved.layoutVersion -eq 3 -and @($saved.panels[0].buttons).Count -eq 4)
$global:cfg = $oldJson | ConvertFrom-Json
$b = @($global:cfg.panels[1].buttons); $global:cfg.panels[1].buttons = @($b[1], $b[0]) + $b[2..6]; Update-OldDefaultOrder
Check 'migration: a rearranged panel keeps its order (only Security becomes the 2 slots, in place)' ((([string]$global:cfg.panels[1].buttons[0].label) -replace "`n", ' ') -eq 'REGISTER USER GUIDE VERSION 11' -and (([string]$global:cfg.panels[1].buttons[4].label) -replace "`n", ' ') -eq 'RESTART SCREEN CONNECT' -and (Test-SlotEmpty $global:cfg.panels[1].buttons[5]) -and (Test-SlotEmpty $global:cfg.panels[1].buttons[6]) -and @($global:cfg.panels[1].buttons).Count -eq 8)
foreach ($bad in 'abc', '2.5x', '') { $global:cfg = $oldJson | ConvertFrom-Json; $global:cfg | Add-Member layoutVersion $bad -Force; $e = $null
    try { Update-OldDefaultOrder } catch { $e = $_ }
    Check "MB-L1: layoutVersion '$bad' treated as 1 (migrates, no error)" (-not $e -and $global:cfg.layoutVersion -eq 3 -and (Test-SlotEmpty $global:cfg.panels[1].buttons[4])) }
$global:cfgPath = Join-Path $tmp 'no-such-dir/buttons.json'; $global:cfg = $oldJson | ConvertFrom-Json; $e = $null
try { Update-OldDefaultOrder } catch { $e = $_ }
Check 'MB-L2: failed migration write is logged, no error, config migrated in memory' (-not $e -and $global:cfg.layoutVersion -eq 3 -and ((Get-Content $global:logPath -Raw) -match "couldn't save the migrated"))
$global:cfgPath = Join-Path $tmp 'buttons.json'; $global:cfg = $oldJson | ConvertFrom-Json
$sb = $global:cfg.panels[1].buttons; $sb[5].height = 99; $sb[5].fontSize = 15; $sb[4].width = 'full'; $sb[4].height = 70; $sb[6].fontSize = 14
Update-OldDefaultOrder; $mb = $global:cfg.panels[1].buttons
Check 'MB-L3: moved tiles keep their sizes (Security gone, Restarts untouched)' ((Test-SlotEmpty $mb[4]) -and (Test-SlotEmpty $mb[5]) -and $mb[6].width -eq 'full' -and $mb[6].height -eq 70 -and $mb[7].fontSize -eq 14 -and $mb[7].height -eq 85)
# --- v1.4.0 custom row: migration keeps data and backs up ---
$global:cfgPath = Join-Path $tmp 'buttons.json'; $v2 = $def | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$sb = @($v2.panels[1].buttons); $sec = [pscustomobject]@{ label = "START`nJARTREK`nSECURITY"; bg = '#8A6100'; width = 'full'; height = 80; type = 'program'; target = 'C:\Program Files\Jartrek\JSecurity.exe'; image = 'C:\pics\mine.png'; args = ''; runAsAdmin = $false }
$v2.panels[1].buttons = @($sb[0..3]) + $sec + @($sb[6..7]); $v2.layoutVersion = 2; $v2.panels[0].buttons[0].label = 'MY RENAMED TILE'
$before = $v2 | ConvertTo-Json -Depth 12; [IO.File]::WriteAllText($global:cfgPath, $before)
Remove-Item -LiteralPath ($global:cfgPath + '.pre-v1.4.bak') -ErrorAction SilentlyContinue
$global:cfg = $before | ConvertFrom-Json; Update-OldDefaultOrder
$after = Get-Content $global:cfgPath -Raw | ConvertFrom-Json; $al = @($after.panels[1].buttons)
Check 'CC M1: a configured Security tile (C:\Program Files\Jartrek\JSecurity.exe) becomes the LEFT custom slot (label, picture, target kept; no args, not admin), right slot empty' ($al.Count -eq 8 -and (Test-CustomSlot $al[4]) -and -not (Test-SlotEmpty $al[4]) -and $al[4].target -eq 'C:\Program Files\Jartrek\JSecurity.exe' -and $al[4].type -eq 'program' -and $al[4].image -eq 'C:\pics\mine.png' -and $al[4].label -eq "START`nJARTREK`nSECURITY" -and $al[4].args -eq '' -and -not $al[4].runAsAdmin -and $al[4].width -eq 'half' -and (Test-SlotEmpty $al[5]) -and -not (@($al | Where-Object { Test-StockSecurityTile $_ }).Count) -and $after.layoutVersion -eq 3)
Check 'v3 migration: every other tile kept as is (no data loss)' ($after.panels[0].buttons[0].label -eq 'MY RENAMED TILE' -and @($after.panels[0].buttons).Count -eq @($v2.panels[0].buttons).Count -and (($al[0..3] | ConvertTo-Json -Depth 8) -eq (@($sb[0..3]) | ConvertTo-Json -Depth 8)) -and (($al[6..7] | ConvertTo-Json -Depth 8) -eq (@($sb[6..7]) | ConvertTo-Json -Depth 8)))
Check 'v3 migration: one-time backup buttons.json.pre-v1.4.bak is the old file byte for byte' ((Get-Content ($global:cfgPath + '.pre-v1.4.bak') -Raw) -ceq $before -and (Test-Path ($global:cfgPath + '.bak')))
$global:cfg = Get-Content $global:cfgPath -Raw | ConvertFrom-Json; $mt = (Get-Item $global:cfgPath).LastWriteTimeUtc; Start-Sleep -Milliseconds 30; Update-OldDefaultOrder
Check 'v3 migration: runs once (a v3 file is not touched again)' ((Get-Item $global:cfgPath).LastWriteTimeUtc -eq $mt)
$c3 = $before | ConvertFrom-Json; $c3.panels[1].buttons[4].label = "START`nJARTREK`nSECURITY 2"; $global:cfg = $c3; Update-OldDefaultOrder
Check 'v3 migration: a user tile with a different label is kept' (@($global:cfg.panels[1].buttons | Where-Object { ([string]$_.label) -like '*SECURITY 2' }).Count -eq 1)
# CC M1 / LJ M18-I3: stock (TODO) tile dropped; a target a custom slot can't hold is kept as is; label alone is not enough
function MigOne($tgt, $lbl = "START`nJARTREK`nSECURITY") { $c = $before | ConvertFrom-Json; $c.panels[1].buttons[4].target = $tgt; $c.panels[1].buttons[4].label = $lbl; $global:cfg = $c; Update-OldDefaultOrder; return @($global:cfg.panels[1].buttons) }
$m = MigOne 'TODO: set the Jartrek Security program'
Check 'CC M1: stock TODO tile -> 2 empty slots' ($m.Count -eq 8 -and (Test-SlotEmpty $m[4]) -and (Test-SlotEmpty $m[5]))
$m = MigOne 'C:\JT\run.bat'
Check 'CC M1: configured target that fails the custom check -> tile kept exactly, no row added' ($m.Count -eq 7 -and $m[4].target -eq 'C:\JT\run.bat' -and -not (Test-CustomSlot $m[4]) -and -not @($m | Where-Object { Test-CustomSlot $_ }).Count)
Check 'LJ M18-I3: match needs the stock label AND stock target' ((Test-StockSecurityTile ([pscustomobject]@{ label = "START`nJARTREK`nSECURITY"; target = 'TODO: set the Jartrek Security program' })) -and -not (Test-StockSecurityTile ([pscustomobject]@{ label = "START`nJARTREK`nSECURITY"; target = 'C:\x\other.exe' })) -and -not (Test-StockSecurityTile ([pscustomobject]@{ label = 'START JARTREK'; target = 'TODO: set the Jartrek Security program' })) -and (Get-SecurityMigration ([pscustomobject]@{ label = 'OTHER'; target = 'TODO: set the Jartrek Security program' })) -eq $null)
$al = MigOne 'TODO: set the Jartrek Security program'   # the row model below starts from the stock (2 empty slots) migration
# --- custom row model ---
$items = New-Object System.Collections.ArrayList; foreach ($x in $al) { [void]$items.Add(($x | ConvertTo-Json -Depth 8 | ConvertFrom-Json)) }
Check 'row: renders as 2 +Add slots (both empty, adjacent, half)' (@($items | Where-Object { Test-SlotEmpty $_ }).Count -eq 2 -and $items.IndexOf(@($items | Where-Object { Test-SlotEmpty $_ })[0]) -eq 4)
$s0 = $items[4]; Set-Prop $s0 'label' 'Schedule'; Set-Prop $s0 'type' 'website'; Set-Prop $s0 'target' 'https://example.invalid/s'; Set-Prop $s0 'args' 'x'; Set-Prop $s0 'runAsAdmin' $true; Set-Prop $s0 'width' 'full'; ConvertTo-CustomSlot $s0
Check 'add: a filled slot is not empty, forced half, no args, never elevated' (-not (Test-SlotEmpty $s0) -and (Test-CustomSlot $s0) -and $s0.width -eq 'half' -and $s0.args -eq '' -and $s0.runAsAdmin -eq $false)
Set-Prop $s0 'label' 'Schedule 2'; ConvertTo-CustomSlot $s0; Check 'edit: label changes, still a slot' ($s0.label -eq 'Schedule 2' -and (Test-CustomSlot $s0))
Check 'remove row refused while a slot is filled' (-not (Remove-CustomRow $items) -and $items.Count -eq 8)
Clear-CustomSlot $s0; Check 'remove button: the slot goes back to +Add, row keeps its shape' ((Test-SlotEmpty $s0) -and $s0.target -eq '' -and $s0.label -eq '' -and $items.Count -eq 8)
Check 'remove row: both empty -> row collapses (no slots, nothing else lost)' ((Remove-CustomRow $items) -and $items.Count -eq 6 -and -not @($items | Where-Object { Test-CustomSlot $_ }).Count -and (Test-DangerButton $items[4]))
Check 'restore row: Setup brings 2 empty slots back just above the Restarts' ((Add-CustomRow $items) -and (Test-SlotEmpty $items[4]) -and (Test-SlotEmpty $items[5]) -and (Test-DangerButton $items[6]) -and $items.Count -eq 8)
Check 'restore row: only once' (-not (Add-CustomRow $items) -and $items.Count -eq 8)
$e2 = New-Object System.Collections.ArrayList; Check 'restore row on a panel with no Restarts: at the end' ((Add-CustomRow $e2) -and $e2.Count -eq 2)
# --- untrusted targets ---
foreach ($ok in @(@('website', 'https://example.invalid/a?b=1'), @('website', 'http://example.invalid'), @('website', 'example.invalid/x'), @('program', 'C:\Program Files\App\app.exe'), @('program', '%ProgramFiles%\App\app.exe'), @('file', 'C:\Docs\a.pdf'), @('file', '\\server\share\a.xlsx'))) {
    Check ("target ok: {0} {1}" -f $ok[0], $ok[1]) ($null -eq (Test-CustomSlotTarget $ok[0] $ok[1])) }
foreach ($bad in @(@('script', 'C:\x.ps1'), @('builtin', ''), @('website', 'javascript:alert(1)'), @('website', 'file:///C:/x.exe'), @('website', 'mailto:a@example.invalid'), @('website', 'ms-settings:'), @('website', 'C:\x.exe'), @('website', '\\srv\x'),
                      @('website', "https://a.invalid/`r`nx"), @('website', ''), @('program', 'C:\x.bat'), @('program', 'C:\x.cmd'), @('program', 'C:\x.lnk'), @('program', 'notepad.exe'), @('program', 'C:\a.exe" /c calc'), @('program', 'C:\a.exe & calc'),
                      @('program', 'C:\a.pdf'), @('file', 'C:\x.vbs'), @('file', 'C:\x.hta'), @('file', 'C:\x.url'), @('file', 'shell:startup'), @('file', 'TODO: x'), @('file', 'relative\a.pdf'), @('program', "C:\a`0.exe"))) {
    Check ("target refused: {0} {1}" -f $bad[0], ($bad[1] -replace "`r", '\r' -replace "`n", '\n' -replace [char]0, '\0')) ([bool](Test-CustomSlotTarget $bad[0] $bad[1])) }
$ib = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Invoke-Button' }, $true).Extent.Text
Check 'click re-checks the target and drops args/admin for slots' ($ib -match 'Test-CustomSlotTarget \$kind' -and $ib -match "args = ''; runAsAdmin = .false" -and $ib.IndexOf('Test-CustomSlot $btn') -lt $ib.IndexOf('$verb ='))
$eb = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Edit-Button' }, $true).Extent.Text
Check 'edit dialog: custom offers only Program, Website, File; Save refuses a bad target' ($eb.Contains("if (`$Custom) { `$types = [ordered]@{ program = 'Program'; website = 'Website'; file = 'File / PDF' }") -and $eb.Contains('Test-CustomSlotTarget $kk') -and $eb.Contains('ConvertTo-CustomSlot $btn'))
$as = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:New-AddSlot' }, $true).Extent.Text
Check '+Add: focusable, screen-reader name, click and Enter add' ($as.Contains('Focusable = $true') -and $as.Contains("SetName(`$tile, ('Add a button, ' + `$side))") -and $as.Contains('Add_MouseLeftButtonUp') -and $as.Contains("Key -eq 'Enter'") -and $as.Contains("Tag = 'half'"))
Check 'layout: empty slots render as +Add, others as tiles' ($src -match 'if \(Test-SlotEmpty \$btn\) \{ New-AddSlot \$p \$btn \} else \{ New-Tile \$p \$btn \}')
Check 'Set up this PC never lists an empty slot as missing' ($src -match 'function global:Test-ButtonReady\(\$btn\) \{\s+if \(Test-SlotEmpty \$btn\) \{ return \$true \}')
$os = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Open-Single' }, $true).Extent.Text
$op = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Open-Panel' }, $true).Extent.Text
$bp = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Build-Panel' }, $true).Extent.Text
Check 'layout: one-panel and two-panel both draw tiles through Build-Panel -> Add-TileRows (one code path for the row)' ($os.Contains('foreach ($p in $groups) { Build-Panel $p }') -and $op.Contains('Build-Panel $p') -and $bp.Contains('Add-TileRows $p $stack $normal'))
Check 'layout: a collapsed row leaves no element (only items are drawn; no spacer or placeholder for a removed row)' ($bp -notmatch 'slot' -and $src -notmatch 'New-Object System.Windows.Controls.Border; \$gap')
Check 'layout: the 2 slots are half width, so Add-TileRows puts them side by side in one row' ((New-EmptySlot).width -eq 'half' -and $src.Contains("if (`$btn.width -eq 'half') {"))
$sm = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Slot-Menu' }, $true).Extent.Text
Check 'menus: slot menu has Add/Edit/Remove this button/Remove this row (disabled while filled); Setup restores the row' ($sm.Contains("'Add a button here...'") -and $sm.Contains("'Edit this button...'") -and $sm.Contains("'Remove this button'") -and $sm.Contains('Get-RemoveRowLabel $canRow') -and $sm.Contains('$rr.IsEnabled = $canRow') -and $src.Contains("'Add the row of 2 custom buttons'"))
Check 'restarts unchanged: ScreenConnect elevation and force-restart confirmation' ($ib.Contains("'restart-screenconnect' { return (Restart-ScreenConnect) }") -and $ib.Contains("CC-M4/LJ-L3: force restart ALWAYS asks") -and $ib.Contains("'YesNo', 'Warning', 'No'"))
# --- LJ M18 / CC L1: File allowlist, trailing dot/space, ADS, wildcards, expanded paths, userinfo ---
foreach ($b in 'C:\x\a.chm', 'C:\x\a.jar', 'C:\x\a.wsc', 'C:\x\a.settingcontent-ms', 'C:\x\a.library-ms', 'C:\x\a.searchConnector-ms', 'C:\x\a.diagcab', 'C:\x\a.msix', 'C:\x\a.appx', 'C:\x\a.docm', 'C:\x\a.xlsm', 'C:\x\a.pptm', 'C:\x\a.iso', 'C:\x\a.img', 'C:\x\a.vhdx', 'C:\x\a.zip',
                'C:\x\run.bat.', 'C:\x\run.bat ', 'C:\x\a.pdf.', 'C:\x\a.pdf ', 'C:\x.\a.pdf', 'C:\x\x.ps1:s', 'C:\x\a.pdf:s', 'C:\x\a.pdf::$DATA', 'C:\x\run.ba?', 'C:\x\*', 'C:\x\*.pdf', 'C:\x\[a].pdf', 'C:\x\a].pdf') {
    Check "LJ M18: file target refused: $b" ([bool](Test-CustomSlotTarget 'file' $b)) }
foreach ($b in 'C:\x\run.ex?', 'C:\x\*.exe', 'C:\x\a.exe.', 'C:\x\a.exe ', 'C:\x\a.exe:s', 'C:\x\[a].exe') { Check "LJ M18: program target refused: $b" ([bool](Test-CustomSlotTarget 'program' $b)) }
foreach ($e in $global:CustomFileExts) { Check "LJ M18: allowlisted .$e passes" ($null -eq (Test-CustomSlotTarget 'file' "C:\Docs\a b.$e")) }
Check 'LJ M18: allowlist has no macro, archive, image or script types' (-not @($global:CustomFileExts | Where-Object { $_ -match '^(docm|xlsm|pptm|zip|iso|img|vhdx?|exe|bat|cmd|ps1|js|chm|jar)$' }).Count)
$env:BLT_DIR = 'C:\Docs'; $env:BLT_BAD = 'C:\x\run.bat'; $env:BLT_WILD = 'C:\x\*'
Check 'CC L1: %VAR% expanded then checked (good)' ($null -eq (Test-CustomSlotTarget 'file' '%BLT_DIR%\a.pdf'))
Check 'CC L1: %VAR% expanding to a script or wildcard is refused' ([bool](Test-CustomSlotTarget 'file' '%BLT_BAD%') -and [bool](Test-CustomSlotTarget 'file' '%BLT_WILD%\a.pdf') -and [bool](Test-CustomSlotTarget 'file' '%BLT_NOPE_UNSET%\a.pdf'))
Check 'LJ M18-I2: website with user info refused, normal ones pass' ([bool](Test-CustomSlotTarget 'website' 'https://bank.com@evil.example') -and [bool](Test-CustomSlotTarget 'website' 'https://u:p@example.invalid/') -and $null -eq (Test-CustomSlotTarget 'website' 'https://example.invalid/a?b=1&c=[x]'))
$rb = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Resolve-ButtonPath' }, $true).Extent.Text
$ap = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Ask-ForPath' }, $true).Extent.Text
$sct = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Start-CustomTarget' }, $true).Extent.Text
Check 'LJ M18-M2: Resolve-ButtonPath uses Test-Path -LiteralPath only' ($rb.Contains('Test-Path -LiteralPath $t') -and $rb -notmatch 'Test-Path \$')
Check 'LJ M18-M2: custom click re-checks the resolved path and launches exactly it via Process.Start (no Start-Process wildcard resolution)' ($ib.Contains('$why = Test-CustomSlotTarget $kind $path') -and $ib.Contains('Start-CustomTarget $path; return $true') -and $ib.IndexOf('Start-CustomTarget $path') -lt $ib.IndexOf('Start-Process -FilePath $path') -and $sct.Contains('[System.Diagnostics.Process]::Start($si)') -and $sct -notmatch '(?m)^[^#]*Start-Process' -and $ib.Contains("slot = 'custom'; empty = `$false"))
Check 'LJ M18-L1: picker for a custom slot uses the type filter and runs the pick through Test-CustomSlotTarget' ($ap.Contains("if (`$custom) { if (`$kind -eq 'program') { 'Programs|*.exe' } else { `$global:CustomFileFilter } }") -and $ap.Contains('Test-CustomSlotTarget $kind $o.FileName') -and $ap.IndexOf('Test-CustomSlotTarget') -lt $ap.LastIndexOf('return $o.FileName') -and $eb.Contains("slot = `$(if (`$Custom) { 'custom' }"))
Check 'LJ M18-L1: picker filter lists exactly the allowlist' ($global:CustomFileFilter -eq ('Documents, pictures and media|' + (($global:CustomFileExts | ForEach-Object { '*.' + $_ }) -join ';')))
# --- v1.4.0 Squint/Kern custom-row fixes ---
foreach ($n in 'Test-CustomSlot', 'Test-SlotEmpty', 'Get-CustomFullName', 'Get-SlotSide', 'Get-SlotView', 'Get-RemoveSlotText', 'Get-RemoveRowLabel') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
$e1 = [pscustomobject]@{ slot = 'custom'; empty = $true; label = '' }; $e2 = [pscustomobject]@{ slot = 'custom'; empty = $true; label = '' }
$f1 = [pscustomobject]@{ slot = 'custom'; empty = $false; label = 'Schedule' }; $o1 = [pscustomobject]@{ label = 'Email' }
Check 'Squint Major: unlocked empty slot = +Add' ((Get-SlotView @($o1, $e1, $e2) $e1 $false) -eq 'add')
Check 'Squint Major: locked, both empty = hidden (row collapses)' ((Get-SlotView @($o1, $e1, $e2) $e1 $true) -eq 'hidden' -and (Get-SlotView @($o1, $e1, $e2) $e2 $true) -eq 'hidden')
Check 'Squint Major: locked, one filled = blank cell (keeps its place)' ((Get-SlotView @($o1, $f1, $e2) $e2 $true) -eq 'blank')
Check 'Squint: Narrator sides left/right' ((Get-SlotSide @($o1, $e1, $e2) $e1) -eq 'left' -and (Get-SlotSide @($o1, $e1, $e2) $e2) -eq 'right' -and (Get-SlotSide @($o1, $f1, $e2) $e2) -eq 'right')
Check 'Squint: remove confirm text' ((Get-RemoveSlotText $f1) -ceq 'Remove "Schedule" from this panel?' -and (Get-RemoveSlotText ([pscustomobject]@{ slot = 'custom'; label = 'Big\nSched' })) -ceq 'Remove "Big Sched" from this panel?')
Check 'Squint: disabled row label carries the reason' ((Get-RemoveRowLabel $false) -ceq 'Remove this row (remove both buttons first)' -and (Get-RemoveRowLabel $true) -ceq 'Remove this row')
Check 'Squint: Remove this button confirms with No default before clearing' ($sm.Contains("[System.Windows.MessageBox]::Show((Get-RemoveSlotText `$btn), 'Remove button', 'YesNo', 'Question', 'No') -ne 'Yes') { return }") -and $sm.IndexOf('Get-RemoveSlotText') -lt $sm.IndexOf('Clear-CustomSlot'))
Check 'Squint Major: locked +Add slot is a plain blank cell (no handlers, not focusable, not hit-testable, same height) returned before any tile/dash/text/name' ($as -match "if \(\[bool\]\`$global:cfg\.locked\) \{[^}]*\`$wrap\.Height = \`$h; \`$wrap\.Focusable = \`$false; \`$wrap\.IsHitTestVisible = \`$false\s+return \`$wrap \}" -and $as.IndexOf('return $wrap }') -lt $as.IndexOf('SetName') -and $as.IndexOf('return $wrap }') -lt $as.IndexOf('Add_MouseLeftButtonUp'))
Check 'Squint Major: click and Enter/Space also refuse while locked' ($as.Contains("Add_MouseLeftButtonUp({ `$_.Handled = `$true; if (-not [bool]`$global:cfg.locked) { Edit-CustomSlot") -and $as.Contains("`$_.Handled = `$true; if (-not [bool]`$global:cfg.locked) { Edit-CustomSlot `$p `$btn } } }"))
$tr = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Add-TileRows' }, $true).Extent.Text
$al = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Apply-Lock' }, $true).Extent.Text
Check 'Squint Major: hidden slots are skipped (no gap); lock/unlock rebuilds every panel' ($tr.Contains("(Get-SlotView `$p.items `$btn `$locked) -eq 'hidden') { continue }") -and $al.Contains('foreach ($p in $global:panels) { Build-Panel $p }'))
Check 'Kern: focus ring margin -3, radius 15' ($as.Contains("`$ring.Margin = '-3'; `$ring.CornerRadius = '15'"))
Check 'Kern: hover brightens dash #B3FFFFFF and text #FFFFFF, restores on leave, no lift/glow' ($as.Contains("`$dash.Stroke = Brush '#B3FFFFFF'; `$txt.Foreground = Brush '#FFFFFF'") -and $as.Contains("`$dash.Stroke = Brush '#73FFFFFF'; `$txt.Foreground = Brush '#C8C8D0'") -and $as -notmatch 'Start-Anim|New-GlowBrush|TranslateTransform|Effect')
$nc = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:New-Content' }, $true).Extent.Text
$nt = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:New-Tile' }, $true).Extent.Text
$mf = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Set-MaxLines' }, $true).Extent.Text
Invoke-Expression $mf; $tb = [pscustomobject]@{ TextTrimming = $null; Uid = ''; MaxHeight = 0; LineHeight = 15.6 }; Set-MaxLines $tb 3
Check 'Kern: custom labels max 3 lines with ellipsis, kept after scaling, full name tooltip' ($tb.TextTrimming -eq 'CharacterEllipsis' -and [Math]::Abs($tb.MaxHeight - 46.8) -lt 0.01 -and $tb.Uid -eq 'maxlines=3' -and $nc.Contains('Set-MaxLines $main 3') -and $src.Contains("if ([string]`$tb.Uid -match '^maxlines=(\d)`$') { `$tb.MaxHeight") -and $nt.Contains('(Get-CustomFullName $btn) + "`n"'))
Remove-Item -LiteralPath $tmp -Recurse -Force
# LJ: setup check at draw time touches only local fixed-drive paths (drive types mocked: C fixed, Z mapped network)
foreach ($n in 'Expand', 'Is-Todo', 'Test-LocalFixedPath', 'Test-SafeIconSource', 'Resolve-IconTarget', 'Get-SetupState', 'Test-ButtonSetUpQuick') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
$dt = { param($r) switch ($r.Substring(0, 1).ToUpperInvariant()) { 'C' { 'Fixed' } 'D' { 'Fixed' } 'S' { 'Fixed' } 'T' { 'Fixed' } 'M' { 'Fixed' } 'Z' { 'Network' } default { 'NoRootDirectory' } } }
# R6-L2/OP-N2 probes: S = subst onto a share, T = subst onto C:\Tools, M = \Device\Mup; attributes by path
$global:attrs = @{ 'C:\Junction' = 0x410; 'C:\OneDrive\cloud.exe' = 0x400000; 'C:\OneDrive\open.exe' = 0x40000; 'C:\Arch\off.exe' = 0x1001; 'C:\Apps' = 0x10; 'C:\Tools\Sub\link.exe' = 0x420 }
$global:PathProbe = @{ DriveType = $dt
    DosDevice = { param($d) switch ($d.ToUpperInvariant()) { 'S:' { '\??\UNC\srv\share' } 'T:' { '\??\C:\Tools' } 'M:' { '\Device\Mup\;Z:\srv\x' } default { '\Device\HarddiskVolume3' } } }
    Attr = { param($p) [void]$global:attrReads.Add($p); if ($global:attrs.ContainsKey($p)) { $global:attrs[$p] } elseif ($p -match 'absent') { $null } else { 0x10 } } }
$global:attrReads = New-Object System.Collections.ArrayList
foreach ($c in @(@('S:\app.exe', $false), @('T:\app.exe', $true), @('T:\Sub\link.exe', $false), @('M:\app.exe', $false), @('C:\Apps\here.exe', $true), @('C:\Junction\app.exe', $false),
                 @('C:\Junction', $false), @('C:\OneDrive\cloud.exe', $false), @('C:\OneDrive\open.exe', $false), @('C:\Arch\off.exe', $false), @('D:\plain\x.exe', $true))) {
    Check ("R6-L2/OP-N2: local fixed path '{0}' -> {1}" -f $c[0], $c[1]) ((Test-LocalFixedPath $c[0]) -eq $c[1]) }
$global:attrReads.Clear(); $jr = Test-LocalFixedPath 'C:\Junction\deep\x.exe'
Check 'R7-L1: walk is root-down and stops at the first link (nothing past it read)' (-not $jr -and (@($global:attrReads) -join '|') -eq 'C:\Junction')
$global:attrReads.Clear(); [void](Test-LocalFixedPath 'C:\Apps\absent\more\x.exe')
Check 'R7-L1: stops at the first missing folder' ((@($global:attrReads) -join '|') -eq 'C:\Apps|C:\Apps\absent')
Check 'R6-L2: subst onto a share is unchecked, not missing' ((Get-SetupState ([pscustomobject]@{ type = 'program'; target = 'S:\app.exe' }) $dt { @{} }) -eq 'unchecked')
# OP-N3: icons come from the checked target, never the .lnk's own icon location
$rlI = { param($l) @{ target = 'C:\Apps\real.exe'; icon = 'C:\Apps\other.ico,0' } }
Check 'OP-N3: .lnk icon taken from its checked target' ((Resolve-IconTarget 'C:\Links\a.lnk' $dt $rlI) -eq 'C:\Apps\real.exe')
Check 'OP-N3: .lnk to a share -> no icon read' ($null -eq (Resolve-IconTarget 'C:\Links\a.lnk' $dt { param($l) @{ target = '\\srv\s\a.exe' } }))
Check 'OP-N3: plain local target is its own icon source' ((Resolve-IconTarget 'C:\Apps\here.exe' $dt $rlI) -eq 'C:\Apps\here.exe')
Check 'OP-N3: UNC target -> no icon read' ($null -eq (Resolve-IconTarget '\\srv\s\a.exe' $dt $rlI))
$gii = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Get-IconImage' }, $true).Extent.Text
Check 'R6-L2: big tiles gate own-icon extraction through Resolve-IconTarget before Test-Path' ($gii -match '(?s)Resolve-IconTarget \$p.*?Test-Path -LiteralPath \$p' -and $gii -notmatch 'Test-Path \$p\)')
$global:touched = New-Object System.Collections.ArrayList
$global:present = @('C:\Apps\here.exe', 'C:\Links\net.lnk', 'C:\Links\loc.lnk')
function global:Test-Path { param([string]$LiteralPath) [void]$global:touched.Add($LiteralPath); $global:present -contains $LiteralPath }
function global:Get-ChildItem { param([string]$Path) [void]$global:touched.Add($Path); $null }
$rl = { param($l) if ($l -like '*net.lnk') { @{ target = '\\srv\share\app.exe' } } else { @{ target = 'C:\Apps\here.exe' } } }
function P($t) { [pscustomobject]@{ type = 'program'; target = $t } }
foreach ($c in @(@('\\srv\share\app.exe', 'unchecked'), @('//srv/share/app.exe', 'unchecked'), @('\\?\UNC\srv\share\app.exe', 'unchecked'), @('\\.\pipe\x', 'unchecked'),
                 @('Z:\apps\app.exe', 'unchecked'), @('C:\Apps\gone.exe', 'missing'), @('C:\Apps\here.exe', 'ok'), @('C:\Links\net.lnk', 'unchecked'), @('C:\Links\loc.lnk', 'ok'), @('notepad.exe', 'ok'), @('TODO', 'missing'))) {
    $global:touched.Clear(); $r = Get-SetupState (P $c[0]) $dt $rl
    $noNet = -not (@($global:touched) | Where-Object { $_ -match '^(\\\\|//|[Zz]:)' })
    Check ("setup state '{0}' -> {1}, nothing non-local touched" -f $c[0], $c[1]) ($r -eq $c[1] -and $noNet) }
$global:touched.Clear()
Check 'website unaffected' ((Get-SetupState ([pscustomobject]@{ type = 'website'; target = '\\srv\x' }) $dt $rl) -eq 'ok' -and $global:touched.Count -eq 0)
$dbtn = [pscustomobject]@{ type = 'program'; target = 'TODO'; detect = [pscustomobject]@{ paths = @('\\srv\share\*.exe', 'Z:\x\*.exe') } }
Check 'detect paths: non-local only -> unchecked, never listed' ((Get-SetupState $dbtn $dt $rl) -eq 'unchecked' -and $global:touched.Count -eq 0)
$global:touched.Clear()
Check 'Test-ButtonSetUpQuick: UNC is not missing (no dot) and not touched' ((Test-ButtonSetUpQuick (P '\\srv\share\app.exe')) -and $global:touched.Count -eq 0)
Check 'tile: only missing gets the dot; unchecked gets a tooltip' ($src -match "if \(\`$ss -eq 'missing'\) \{ \[void\]\`$g\.Children\.Add\(\(New-MissingDot" -and $src -match 'not checked until you click')
# TS-L2 (a): tile pictures on a share -> default art, the share is never touched
foreach ($n in 'Get-DefaultPic', 'Resolve-Img', 'Get-PicSource', 'Test-ButtonReady', 'Find-LocalMatch', 'Find-LnkLocal', 'Find-Detected') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
function global:Join-Path { param([string]$Path, [string]$ChildPath) $Path.TrimEnd('\') + '\' + $ChildPath }
function global:Resolve-Img($path) { if ($path -match '^(\\\\|//|[A-Za-z]:)') { $path } else { Join-Path $global:here $path } }   # Windows IsPathRooted
$global:here = 'C:\BL'; $global:touched.Clear()
[void](Get-PicSource ([pscustomobject]@{ type = 'program'; target = 'x'; image = '\\host\x.png' }) 32)
[void](Get-PicSource ([pscustomobject]@{ type = 'website'; target = 'x'; image = 'Z:\pics\x.png' }) 96)
Check 'TS-L2a: non-local picture never touched; default art for its type checked instead' (-not (@($global:touched) | Where-Object { $_ -match '^(\\\\|[Zz]:)' }) -and (@($global:touched) | Where-Object { $_ -like '*register*.png' }) -and (@($global:touched) | Where-Object { $_ -like '*globe.png' }))
# TS-L2 (b): first-run readiness and detect are local-only
$global:touched.Clear()
Check 'TS-L2b: Test-ButtonReady: UNC target = not listed, not touched' ((Test-ButtonReady (P '\\srv\share\app.exe')) -and $global:touched.Count -eq 0)
Check 'TS-L2b: Test-ButtonReady: mapped-drive target = not listed, not touched' ((Test-ButtonReady (P 'Z:\app.exe')) -and $global:touched.Count -eq 0)
Check 'TS-L2b: Test-ButtonReady: local missing still listed' (-not (Test-ButtonReady (P 'C:\Apps\gone.exe')))
Check 'TS-L2b: Test-ButtonReady: local present ready' (Test-ButtonReady (P 'C:\Apps\here.exe'))
# Find-Detected / Find-LocalMatch with a fake tree: C:\Prog\Jartrek1 (real dir), C:\Prog\JartrekLink (junction off-PC)
$global:tree = @{ 'C:\' = @(@{ n = 'Prog'; d = $true; a = 0x10 }); 'C:\Prog' = @(@{ n = 'JartrekLink'; d = $true; a = 0x410 }, @{ n = 'Jartrek1'; d = $true; a = 0x10 })
                  'C:\Prog\Jartrek1' = @(@{ n = 'jt.exe'; d = $false; a = 0x20 }, @{ n = 'ln.exe'; d = $false; a = 0x420 }); 'C:\Prog\JartrekLink' = @(@{ n = 'jt.exe'; d = $false; a = 0x20 }) }
function global:Get-ChildItem { param([string]$LiteralPath, [string]$Path, [switch]$Force, [switch]$File, [switch]$Recurse, [string]$Filter)
    $k = if ($LiteralPath) { $LiteralPath } else { $Path }; [void]$global:touched.Add($k)
    foreach ($e in @($global:tree[$k.TrimEnd('\') + $(if ($k.Length -le 3) { '\' } else { '' })])) { if ($e) { [pscustomobject]@{ Name = $e.n; PSIsContainer = $e.d; Attributes = [IO.FileAttributes]$e.a; FullName = ($k.TrimEnd('\') + '\' + $e.n) } } } }
$global:touched.Clear()
$hit = Find-Detected ([pscustomobject]@{ detect = [pscustomobject]@{ paths = @('\\srv\share\jt.exe', 'Z:\x\jt.exe', 'C:\Prog\Jartrek*\jt.exe') } })
Check 'TS-L2b: Find-Detected skips non-local detect paths (not touched)' (-not (@($global:touched) | Where-Object { $_ -match '^(\\\\|[Zz]:)' }))
Check 'I-R6c: wildcard match that is a junction is never entered' ($hit -eq 'C:\Prog\Jartrek1\jt.exe' -and @($global:touched) -notcontains 'C:\Prog\JartrekLink')
Check 'I-R6c: file link matches are ignored' ($null -eq (Find-LocalMatch 'C:\Prog\Jartrek1\ln*.exe'))
$global:touched.Clear()
# R8-N1: brackets in folder names are literal
$global:tree['C:\Prog\App [x86]'] = @(@{ n = 'a.exe'; d = $false; a = 0x20 }); $global:tree['C:\Prog\Appx'] = @(@{ n = 'a.exe'; d = $false; a = 0x20 })
$global:tree['C:\Prog'] = @($global:tree['C:\Prog']) + @(@{ n = 'App [x86]'; d = $true; a = 0x10 }, @{ n = 'Appx'; d = $true; a = 0x10 })
Check 'R8-N1: [x86] folder matches itself, not as a character class' ((Find-LocalMatch 'C:\Prog\App [x86]\a.exe') -eq 'C:\Prog\App [x86]\a.exe' -and $null -eq (Find-LocalMatch 'C:\Prog\App[x]\a.exe'))
Check 'R8-N1: * still a wildcard' ((Find-LocalMatch 'C:\Prog\App*\a.exe') -in 'C:\Prog\App [x86]\a.exe', 'C:\Prog\Appx\a.exe')
# R8-L1: .lnk walk skips link folders, exact names, depth cap 6
$global:tree['C:\SM'] = @(@{ n = 'Lnkd'; d = $true; a = 0x410 }, @{ n = 'L1'; d = $true; a = 0x10 }); $global:tree['C:\SM\Lnkd'] = @(@{ n = 'Jt [1].lnk'; d = $false; a = 0x20 })
$global:tree['C:\SM\L1'] = @(@{ n = 'Jt [1].lnk'; d = $false; a = 0x20 })
$deep = 'C:\D'; foreach ($i in 1..8) { $global:tree[$deep] = @(@{ n = "d$i"; d = $true; a = 0x10 }); $deep += "\d$i" }; $global:tree[$deep] = @(@{ n = 'Far.lnk'; d = $false; a = 0x20 })
$global:touched.Clear(); $lk = Find-LnkLocal 'C:\SM' 'Jt [1].lnk'
Check 'R8-L1: finds the .lnk by exact name (brackets literal), never enters a junction' ($lk.FullName -eq 'C:\SM\L1\Jt [1].lnk' -and @($global:touched) -notcontains 'C:\SM\Lnkd')
Check 'R8-L1: depth capped at 6' ($null -eq (Find-LnkLocal 'C:\D' 'Far.lnk') -and @($global:touched) -notcontains 'C:\D\d1\d2\d3\d4\d5\d6\d7\d8')
Check 'R8-L1: no recursive Get-ChildItem left in Find-Detected' ($src -notmatch 'Get-ChildItem -Path \$r -Recurse')
# Lockjaw R7-I2: -small sibling goes through the local check
Check 'R7-I2: -small sibling checked with Test-LocalFixedPath first' ($src -match '\(Test-LocalFixedPath \$sm\) -and \(Test-Path -LiteralPath \$sm\)')
Check 'click path: Find-Detected -AllowNetwork may look at a share' (([void](Find-Detected ([pscustomobject]@{ detect = [pscustomobject]@{ paths = @('\\srv\share\jt.exe') } }) -AllowNetwork)) -eq $null -and @($global:touched) -contains '\\srv\share\jt.exe')
Check 'Resolve-ButtonPath (click) passes -AllowNetwork' ($src -match 'Find-Detected \$btn -AllowNetwork')
# D2 fill table: every Option B default fill has Kern's seven D2 stops; custom colours get a derived set
$okD2 = $true
foreach ($k in 'Red Dog|#0B6E99', 'View Register|#0E7A4B', 'Internet|#7B4FD6', 'Email|#FACC15', 'Guides|#5F6368', 'PLCE|#C40000', 'Revenue|#F0E68C', 'Jartrek|#8A6100') {
    $hex = $k.Split('|')[1]; if (-not $global:D2Fill.ContainsKey($hex) -or @($global:D2Fill[$hex]).Count -ne 7 -or ((Get-D2Fill $hex $false) -join ',') -ne ($global:D2Fill[$hex] -join ',')) { $okD2 = $false } }
Check 'D2: Kern''s eight default fills each have a 7-stop D2 row' ($okD2 -and @($global:D2Fill['restart']).Count -eq 7)
Check 'D2: Email rest is #FAD028 -> #D7AF12' (((Get-D2Fill '#facc15' $false)[0..1] -join ',') -eq '#FAD028,#D7AF12')
Check 'D2: restarts use the dark fill and red glow' (((Get-D2Fill '#0B6E99' $true)[0, 6] -join ',') -eq '#2E2E2E,#E5484D')
if ('System.Windows.Media.Color' -as [type]) { $cd = Get-D2Fill '#336699' $false
Check 'D2: custom colour derives 7 hex stops, rest top = its own colour' (@($cd).Count -eq 7 -and $cd[0] -eq '#336699' -and @($cd | Where-Object { $_ -notmatch '^#[0-9A-F]{6}$' }).Count -eq 0) } else { 'SKIP  D2 derived colour (needs WPF: real Windows)' }

# ---- v1.3.0 round 3 (Kern) ----
Check 'Kern M1: glow Margin -6, radius rad+6, radial 100% at 0.45 -> 0, RadiusX 0.62 / RadiusY 0.75' ($tileSrc -match "\`$glow\.Margin = '-6'" -and $tileSrc -match 'CornerRadius = \[string\]\(\$rad \+ 6\)' -and $tileSrc -match 'New-GlowBrush \$f\[6\] 1\.0 0\.45 0\.62 0\.75' -and $tileSrc -match 'ClipToBounds = \$false')
Check 'Kern M2: Restart Computer uses the arrows art; no plug plate remains' ($src -notmatch "#D9FFFFFF" -and $src -notmatch '\$pl\.Width = 28' -and $src -notmatch 'power\\\.png\$' -and (Get-FileHash (Join-Path $root 'images/power.png')).Hash -eq (Get-FileHash '/home/box/shared/button-launcher/art/fluent-3d/power-48.png').Hash)
Check 'Kern 3 / N2: inner corners 16 everywhere, none left at 14' ($src -match "'0,0,16,0'" -and $src -match "'16,0,0,0'" -and $src -notmatch "'0,0,14,0'|'14,0,0,0'|'0,0,0,14'|'0,14,0,0'")
Check 'Kern 4: Version 11 subtitle 12 px Regular, line 14, 85%' ($src -match 'New-Label \$lab\.sub \$fg 12; \$sl\.FontWeight = \[System\.Windows\.FontWeights\]::Normal; \$sl\.LineHeight = 14; \$sl\.Opacity = 0\.85')
Check 'Kern 5: Segoe UI Variable only when installed, else Segoe UI' ($src -match "if \(\`$f\.Source -eq 'Segoe UI Variable'\)" -and $src -match "return 'Segoe UI'\s*\r?\n\}" -and $src -match 'FontFamily \(Get-UiFontName\)')
Check 'Shadow: no DropShadowEffect on the panel; 1 px #66000000 hairline, padding shrinks so the window never grows' ($src -notmatch 'DropShadowEffect' -and $src -match "BorderBrush = Brush '#66000000'" -and $src -match 'Thickness \(3 - \$t\.Left\), \(3 - \$t\.Top\), \(3 - \$t\.Right\), \(3 - \$t\.Bottom\)')
Check 'Shadow: hairline only on the non-docked sides in one-panel; off with squarePanels' ($src -match "if \(\`$left\) \{ '0,0,1,1' \} else \{ '1,0,0,1' \}" -and $src -match "if \(\`$square\) \{ \`$w\.Content = \`$edge; \`$hair = \`$null \}")
Remove-Item Function:\global:Test-Path, Function:\global:Get-ChildItem, Function:\global:Join-Path

# Kern recheck: hover glow peak (glow colour at glowMax over the panel #1E1E22) is >= 1.5:1 against the panel
function RelL([string]$h) { $v = @(foreach ($i in 1, 3, 5) { $c = [Convert]::ToInt32($h.Substring($i, 2), 16) / 255.0; if ($c -le 0.03928) { $c / 12.92 } else { [Math]::Pow(($c + 0.055) / 1.055, 2.4) } }); 0.2126 * $v[0] + 0.7152 * $v[1] + 0.0722 * $v[2] }
function MixHex([string]$a, [string]$b, [double]$t) { '#' + (-join @(foreach ($i in 1, 3, 5) { '{0:X2}' -f [int][Math]::Round([Convert]::ToInt32($a.Substring($i, 2), 16) * $t + [Convert]::ToInt32($b.Substring($i, 2), 16) * (1 - $t)) })) }
$glows = [regex]::Matches($src, "'(#[0-9A-F]{6}|restart)' = @\((?:'#[0-9A-F]{6}', ){6}'(#[0-9A-F]{6})'\)")
Check 'Kern recheck: D2Fill glow colours found' ($glows.Count -ge 9)
foreach ($m in $glows) { $gm = if ($m.Groups[1].Value -eq 'restart') { 0.55 } else { 0.90 }; $c = MixHex $m.Groups[2].Value '#1E1E22' $gm
    $cr = ((RelL $c) + 0.05) / ((RelL '#1E1E22') + 0.05); Check ("Kern recheck: glow {0} at {1} = {2:N2}:1 >= 1.5:1" -f $m.Groups[2].Value, $gm, $cr) ($cr -ge 1.5) }
Check 'Kern recheck: dialog button glow Margin -6, radius 16' ($src -match '<Border x:Name="glow" CornerRadius="16" Margin="-6"')
Check 'Kern recheck: disabled menu item #9A9A9A' ($src -match '<Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#9A9A9A"/><Setter TargetName="gt" Property="Foreground" Value="#9A9A9A"/>')
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
