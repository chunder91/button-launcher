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
Check 'v1.4.8: tile radius from Get-GlossRadius (18, clamped); sheen layer reused as the gloss band' ($tileSrc -match '\$rad = Get-GlossRadius \$h' -and $tileSrc -match 'Set-D2Surface \$tile \$rad 10 ' -and $tileSrc -match '\$sheen\.Background = New-GlossBand')
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
foreach ($b in 'C:\x\a.doc', 'C:\x\a.xls', 'C:\x\a.ppt', 'C:\x\a.odt', 'C:\x\a.ods', 'C:\x\a.rtf', 'C:\x\X~1.DOC', 'C:\PROGRA~1\a.pdf', '\\srv\SHARE~2\a.pdf') { Check "LJ M19-M1: file target refused: $b" ([bool](Test-CustomSlotTarget 'file' $b)) }
Check 'LJ M19-M1: short name refused for programs too, and after %VAR% expansion' ([bool](Test-CustomSlotTarget 'program' 'C:\PROGRA~1\App\app.exe') -and $(try { $env:BLT_SHORT = 'C:\PROGRA~1'; [bool](Test-CustomSlotTarget 'file' '%BLT_SHORT%\a.pdf') } finally { Remove-Item Env:BLT_SHORT -ErrorAction SilentlyContinue }))
Check 'LJ M19-M1: allowlist is exactly the 21 types' ($global:CustomFileExts.Count -eq 21 -and (($global:CustomFileExts | Sort-Object) -join ',') -eq 'avi,bmp,csv,docx,gif,jpeg,jpg,m4a,mov,mp3,mp4,pdf,png,pptx,tif,tiff,txt,wav,webp,wmv,xlsx')
Check 'LJ M19-M1: a tilde without a digit is fine (C:\My~Docs\a.pdf)' ($null -eq (Test-CustomSlotTarget 'file' 'C:\My~Docs\a.pdf'))
Check 'LJ M18: allowlist has no macro, archive, image or script types' (-not @($global:CustomFileExts | Where-Object { $_ -match '^(doc|xls|ppt|rtf|odt|ods|docm|xlsm|pptm|zip|iso|img|vhdx?|exe|bat|cmd|ps1|js|chm|jar)$' }).Count)
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
Check 'v1.4.2 / CC L1: fit-to-tile labels, no Viewbox (never below 12 px), 3-line cap with ellipsis, tooltip when 12 px overflows, bigger start sizes' ($nc -notmatch 'Viewbox' -and $nc.Contains('Set-MaxLines $main 3   # CC L1') -and $nc.Contains('if (-not (Set-FitFontSize $main $text ([double]$text.MaxWidth) $availH $fs)) { $main.ToolTip =') -and $nc.Contains("'hero' { 26 } 'full' { 20 } default { 16 }") -and $src -notmatch 'Controls\.Viewbox' -and $nt.Contains('(Get-CustomFullName $btn) + "`n"'))
Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue
if (-not ('System.Windows.Size' -as [type])) { Add-Type -TypeDefinition 'namespace System.Windows { public struct Size { public double Width; public double Height; public Size(double w, double h) { Width = w; Height = h; } } }' }
Invoke-Expression ($ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Set-FitFontSize' }, $true).Extent.Text)
function New-FakeLabel([int]$chars) { $m = [pscustomobject]@{ FontSize = 0.0; LineHeight = 0.0; Tag = $null; Name = ''; DesiredSize = $null; TextWrapping = 'Wrap' }; $t = [pscustomobject]@{ DesiredSize = $null; m = $m; chars = $chars }
    $t | Add-Member ScriptMethod Measure { param($sz) $perLine = [Math]::Max(1, [Math]::Floor($sz.Width / ($this.m.FontSize * 0.55))); $lines = [Math]::Ceiling($this.chars / $perLine); $this.m.DesiredSize = [pscustomobject]@{ Height = $lines * $this.m.LineHeight }; $this.DesiredSize = [pscustomobject]@{ Width = [Math]::Min($sz.Width, $this.chars * $this.m.FontSize * 0.55); Height = $lines * $this.m.LineHeight } }; return @($m, $t) }
$fk = New-FakeLabel 5; $ok = Set-FitFontSize $fk[0] $fk[1] 206 42 20
Check 'v1.4.2: a short label keeps the full start size (20 px on a full tile)' ($ok -and $fk[0].FontSize -eq 20 -and $fk[0].Tag -eq 20 -and $fk[0].Name -eq 'fitLabel')
$fk = New-FakeLabel 35; $ok = Set-FitFontSize $fk[0] $fk[1] 206 42 16
Check 'Kern 3 / Squint 1: wraps before shrinking (35 chars keep 16 px on 2 lines of a 64 px tile)' ($ok -and $fk[0].FontSize -eq 16 -and $fk[1].DesiredSize.Height -le 42)
$fk = New-FakeLabel 60; $ok = Set-FitFontSize $fk[0] $fk[1] 206 34 20
Check 'v1.4.2: a long label steps down until it fits, never below 12, Tag follows' ($ok -and $fk[0].FontSize -lt 20 -and $fk[0].FontSize -ge 12 -and $fk[1].DesiredSize.Height -le 34 -and $fk[0].Tag -eq $fk[0].FontSize)
$fk = New-FakeLabel 60; $ok = Set-FitFontSize $fk[0] $fk[1] 75 200 16
Check 'Kern 2 / CC A2: never more than 3 lines; a label past the fit gets the 3-line 13 px floor' (-not $ok -and $fk[0].FontSize -eq 13)
$fk = New-FakeLabel 400; $ok = Set-FitFontSize $fk[0] $fk[1] 75 58 16
Check 'Squint 3: too long at 12 px -> reports no fit; caller adds 3-line ellipsis + tooltip' (-not $ok -and $fk[0].FontSize -eq 13 -and $nc.Contains("`$main.ToolTip = (`$lab.main -replace"))
Invoke-Expression ($ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Set-RowSizes' }, $true).Extent.Text)
function New-RowLab([double]$sz, $tip) { [pscustomobject]@{ Tag = $sz; FontSize = $sz; LineHeight = 0.0; ToolTip = $tip } }
$r = @((New-RowLab 16 $null), (New-RowLab 12 $null)); Set-RowSizes $r
$fk = New-FakeLabel 30; $ok = Set-FitFontSize $fk[0] $fk[1] 75 200 16
Check 'CC A2: a fit that renders 3 lines is never below 13 px' ($ok -and $fk[0].FontSize -ge 13 -and [Math]::Round($fk[0].DesiredSize.Height / $fk[0].LineHeight) -le 3)
Check 'CC A2: Apply-MinFont uses the 13 px floor for rendered 3-line fitted labels' ($src.Contains("`$tb.Name -eq 'fitLabel' -and [double]`$tb.Tag -ge 13 -and `$tb.DesiredSize.Height -ge 2.5 * [double]`$tb.LineHeight"))
Check 'Squint ruling: row matching lowers a tile at most one step (16 -> 14), never below its row-mate' ($r[0].FontSize -eq 14 -and $r[0].Tag -eq 14 -and $r[1].FontSize -eq 12)
$r = @((New-RowLab 16 $null), (New-RowLab 12 'Customer Files and Old Invoices Archive')); Set-RowSizes $r
Check 'Squint ruling: a label that only fits with ... does not pull the row down' ($r[0].FontSize -eq 16 -and $r[1].FontSize -eq 12)
$r = @((New-RowLab 16 $null), (New-RowLab 15 $null)); Set-RowSizes $r
Check 'Kern 1: close sizes still match exactly' ($r[0].FontSize -eq 15 -and $r[1].FontSize -eq 15)
Check 'Kern 1: rows are synced when the second half tile is added' ($src.Contains('Sync-RowFontSize @($pendingHalf.Children)') -and $src.Contains("FindLogicalNode(`$e, 'fitLabel')"))
Check 'Kern 3: (needs admin) gets a non-breaking space' ((Get-DisplayLabel ([pscustomobject]@{ label = 'Restart ScreenConnect (needs admin)' })).main -ceq ('Restart ScreenConnect (needs' + [char]0xA0 + 'admin)'))
Check 'Squint 3: every tile names itself with the full label for Narrator' ($nt.Contains('[System.Windows.Automation.AutomationProperties]::SetName($tile, (($an -replace'))
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
foreach ($n in 'Get-DefaultPic', 'Resolve-Img', 'Get-PicSource', 'Test-ButtonReady', 'Test-VncPickerButton', 'Find-LocalMatch', 'Find-LnkLocal', 'Find-Detected') {
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
Check 'Kern 4 + v1.4.8 fix 1: Version 11 subtitle 12 px Regular, line 14, Opacity 1 (was 85%)' ($src -match 'New-Label \$lab\.sub \$fg 12; \$sl\.FontWeight = \[System\.Windows\.FontWeights\]::Normal; \$sl\.LineHeight = 14; \$sl\.Opacity = 1; \$sl\.Name = ''subLabel''')
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
# --- v1.4.8 glossy style C ---
foreach ($n in 'Get-GlossOutlineOffsets', 'Get-GlossRowBand', 'Get-GlossLabelRight', 'Get-GlossBandCorner', 'Get-GlossRadius', 'Test-GlossDarkLabel', 'Get-GlossOutlineWidth', 'Get-GlossOutlineHex', 'Get-GlossFillStops', 'Get-GlossBandHeight', 'Get-GlossFillShift', 'Test-GlossSparkle') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:Gloss\s*=') { Invoke-Expression $l.Extent.Text } }
if (-not ('System.Windows.Media.Color' -as [type])) {   # Linux box: plain RGB shims with the same maths
    function global:Get-Color($hex) { $h = $hex.TrimStart('#'); [pscustomobject]@{ A = 255; R = [Convert]::ToInt32($h.Substring(0, 2), 16); G = [Convert]::ToInt32($h.Substring(2, 2), 16); B = [Convert]::ToInt32($h.Substring(4, 2), 16) } }
    function global:Mix-Color($c, $toward, [double]$t) { [pscustomobject]@{ A = $c.A; R = [int][byte]($c.R + ($toward.R - $c.R) * $t); G = [int][byte]($c.G + ($toward.G - $c.G) * $t); B = [int][byte]($c.B + ($toward.B - $c.B) * $t) } } }
$G = $global:Gloss
Check 'v1.4.8 radius: 18 px, clamped to half the height/width (44 px tile -> 18, 30 px -> 15, 20 px wide -> 10)' ((Get-GlossRadius 80) -eq 18 -and (Get-GlossRadius 44) -eq 18 -and (Get-GlossRadius 30) -eq 15 -and (Get-GlossRadius 80 20) -eq 10 -and (Get-GlossRadius 120) -eq 18)
Check 'v1.4.8 gloss: white band alpha <= 0.30 (0.30 -> 0.045), inner glow 0.22, ends >= 2 px above caps' ($G.glossTop -le 0.30 -and $G.glossBottom -lt $G.glossTop -and $G.glow -eq 0.22 -and $G.capGap -ge 2 -and (Get-GlossBandHeight 30 80) -le (30 - 2) -and (Get-GlossBandHeight 14 44) -le 12 -and (Get-GlossBandHeight 5 44) -eq 0 -and (Get-GlossBandHeight 60 80) -le 24)
$fs = @(foreach ($fill in '#FF0000', '#C40000', '#0B6E99', '#F0E68C', '#DAA520', '#5F6368', '#000000', '#FA8072') { foreach ($y in 0.3, 0.4, 0.55, 0.65, 0.7) { foreach ($r in 0, 0.3, 0.55, 0.6) { Get-GlossFillShift $fill $y $r } } })
Check ('v1.4.8 Kern fix 4: fill behind the label (y 0.3-0.7, r <= 0.6) within 8 per channel, incl. PLCE red; worst ' + ($fs | Measure-Object -Maximum).Maximum) ((($fs | Measure-Object -Maximum).Maximum) -le 8)
Check 'v1.4.8 fill stops: middle stop is the configured colour; hover +10%, pressed 12% darker' ((Get-GlossFillStops '#F0E68C')[1] -eq '#F0E68C' -and (Get-GlossFillStops '#FF0000')[1] -eq '#FF0000' -and (Get-GlossFillStops '#000000' 'hover')[1] -eq '#1A1A1A' -and (Get-GlossFillStops '#FFFFFF' 'pressed')[1] -eq '#E0E0E0')
Check 'v1.4.8 outline: 2.4 px under 16 px, 3.2 px at 16+; colour is the fill''s own dark tone' ((Get-GlossOutlineWidth 15) -eq 2.4 -and (Get-GlossOutlineWidth 12) -eq 2.4 -and (Get-GlossOutlineWidth 16) -eq 3.2 -and (Get-GlossOutlineWidth 32) -eq 3.2 -and (Get-GlossOutlineHex '#7B4FD6') -eq '#22163C')
Check 'v1.4.8 Kern fix 1: dark labels (#111111 on #F0E68C) keep their colour and get no outline; white/yellow labels are outlined' ((Test-GlossDarkLabel '#111111') -and -not (Test-GlossDarkLabel '#FFFFFF') -and -not (Test-GlossDarkLabel '#FFFF00') -and $tileSrc -match 'if \(-not \(Test-GlossDarkLabel \$fgHex\)\) \{' -and $tileSrc -match 'if \(\$mainLab\) \{ \$ol = Add-GlossOutline \$mainLab \$olHex')
Check 'v1.4.8 sparkle: 12 px in, 2.6 px radius, >= 4 px inside the 18 px curve, hidden when within 8 px of the label' ($G.sparkleIn -eq 12 -and $G.sparkleR -eq 2.6 -and (Test-GlossSparkle 272 30 200 18) -and -not (Test-GlossSparkle 272 18 262 18) -and (Test-GlossSparkle 133 18 100 18) -and (Test-GlossSparkle 272 30 200 10))
$glossSrc = ([regex]::Match($src, '(?s)\$global:Gloss = .*?\r?\n# One tile')).Value
Check 'v1.4.8 no animation of gloss/sparkle, no Effect, frozen shared brushes' ($glossSrc -and $glossSrc -notmatch 'Start-Anim|Storyboard|Animation|DropShadowEffect|BlurEffect|\.Effect\s*=' -and $glossSrc -match '\$br\.Freeze\(\)' -and $glossSrc -match 'GlossCache\[\$key\] = \$br' -and $tileSrc -notmatch 'Start-Anim \$(spark|iglow)')
Check 'v1.4.8 states: hover fill +10% layer, pressed = no gloss + 12% darker layer, focus ring 2 px white + 2 px #111111 inside, edges 18/14' ($tileSrc -match "\`$hov\.Background = New-GlossFill \`$fillHex 'hover'" -and $tileSrc -match "\`$prs\.Background = New-GlossFill \`$fillHex 'pressed'" -and $tileSrc -match 'Start-Anim \$sheen \$oProp 0 60' -and $tileSrc -match "\`$rw\.BorderThickness = '2'.*White; \`$rw\.CornerRadius = \[string\]\`$rad" -and $tileSrc -match "\`$rk\.Margin = '2'; \`$rk\.BorderThickness = '2'; \`$rk\.BorderBrush = Brush '#111111'; \`$rk\.CornerRadius = \[string\]\(\[Math\]::Max\(0, \`$rad - 2\)\)" -and $tileSrc -notmatch "\`$ring\.Margin = '-4'")
Check 'v1.4.8 layout untouched: 12,8 content margin, 3 px wrap, 44 px minimum, same New-Content call, edit-mode outline and pictures kept' ($tileSrc -match "\`$c\.el\.Margin = '12,8'" -and $tileSrc -match "\`$wrap\.Margin = '3'" -and $tileSrc -match 'Max\(44, \$h\)' -and $tileSrc -match 'New-Content \$btn \$h \$cls \$danger \$fgHex' -and $tileSrc -match 'StrokeDashArray' -and $src -match 'function global:Get-PicSource')
# --- v1.4.8 follow-up: Kern/Squint fixes 1-4 + ClaudeCode notes ---
$finSrc = ([regex]::Match($src, '(?s)function global:Update-GlossFinish.*?\r?\n\}')).Value
$amfSrc = ([regex]::Match($src, '(?s)function global:Apply-MinFont.*?\r?\n\}')).Value
Check 'fix 1: light 12 px sub-labels get Add-GlossOutline 2.4 with the fill''s dark tone; dark labels skipped (same branch as the main label)' ($tileSrc -match "FindLogicalNode\(\`$c\.el, 'subLabel'\)" -and $tileSrc -match 'if \(\$subLab\) \{ \[void\]\(Add-GlossOutline \$subLab \$olHex 2\.4\) \}' -and ([regex]::Match($tileSrc, '(?s)if \(-not \(Test-GlossDarkLabel \$fgHex\)\) \{.*?Add-GlossOutline \$subLab')).Success)
$csub = @('#7F7F7F', '#FF0000', '#FA8072', '#DAA520', '#7B4FD6', '#2E8B57') | ForEach-Object { ((RelL '#FFFFFF') + 0.05) / ((RelL (Get-GlossOutlineHex $_)) + 0.05) }
Check ('fix 1: white sub-label on its outline >= 4.5:1 on grey/red/salmon/goldenrod/purple/green (worst {0:N2}:1)' -f ($csub | Measure-Object -Minimum).Minimum) ((($csub | Measure-Object -Minimum).Minimum) -ge 4.5)
Check 'fix 2: outline width re-picked in Update-GlossFinish from the final FontSize; Apply-MinFont (after row sync) calls it; Build-Panel hands the tiles over before Apply-MinFont' ($finSrc -match 'Set-GlossOutlineWidth \$e\.ol \(Get-GlossOutlineWidth \$fsz\)' -and $amfSrc -match 'if \(\$p\.gloss\) \{ Update-GlossFinish \$p\.gloss \}' -and $src -match '\$p\.gloss = \$global:glossSink; \$global:glossSink = \$null; Apply-MinFont \$p' -and $tileSrc -notmatch 'Test-GlossSparkle|Get-GlossBandHeight')
$o24 = Get-GlossOutlineOffsets 2.4; $o32 = Get-GlossOutlineOffsets 3.2
Check 'fix 2: a 16 -> 14 px label gets 2.4 px; offsets sides w/2, diagonals w/2 x 0.7071 (2.4: 1.2 / 0.85, 3.2: 1.6 / 1.13)' ((Get-GlossOutlineWidth 14) -eq 2.4 -and $o24.Count -eq 8 -and $o24[0][0] -eq 1.2 -and $o24[3][1] -eq -1.2 -and $o24[4][0] -eq 0.85 -and $o32[0][0] -eq 1.6 -and $o32[7][1] -eq -1.13)
Check 'fix 2: gloss end (capTop/band) recomputed in Update-GlossFinish after sizing' ($finSrc -match '\$e\.capTop = 8 \+' -and $finSrc -match '\$e\.band = Get-GlossBandHeight \$e\.capTop \$e\.h')
Check 'fix 3: one band per row = the row minimum; any tile under 4 px drops the row''s gloss' ((Get-GlossRowBand @(24, 7, 12)) -eq 7 -and (Get-GlossRowBand @(24)) -eq 24 -and (Get-GlossRowBand @(24, 0)) -eq 0 -and (Get-GlossRowBand @(3.5, 20)) -eq 0 -and (Get-GlossRowBand @()) -eq 0)
Check 'fix 3: rows grouped by a row id (full tile or half pair) and the band applied per row' ($finSrc -match 'Group-Object \{ \$_\.row \}' -and $finSrc -match 'Get-GlossRowBand' -and $src -match "if \(-not \(\`$btn\.width -eq 'half' -and \`$pendingHalf\)\) \{ \`$global:glossRow\+\+ \}")
$rn = Get-Content -Raw (Join-Path $root 'RELEASE-NOTES.md'); $v148 = ([regex]::Match($rn, '(?s)## v1\.4\.8:.*?(?=\r?\n## v)')).Value
Check 'fix 4: v1.4.8 release notes give the real review status, not "Pending review"' ($v148 -and $v148 -notmatch 'Pending review' -and $v148 -match 'Lockjaw' -and $v148 -match 'ClaudeCode' -and $v148 -match 'Kern')
Check 'ClaudeCode: centred labels measured from the middle of the content box for the sparkle gap' ((Get-GlossLabelRight 272 100 $false) -eq 112 -and (Get-GlossLabelRight 272 100 $true) -eq 186 -and (Get-GlossLabelRight 133 200 $true) -eq 121 -and $finSrc -match 'Get-GlossLabelRight \$e\.tileW \$ds\.Width \$centred')
Check 'ClaudeCode: band corner radius at most half the band height' ((Get-GlossBandCorner 18 24)[0] -eq 12 -and (Get-GlossBandCorner 18 7)[0] -eq 3 -and (Get-GlossBandCorner 18 7)[1] -eq 3 -and (Get-GlossBandCorner 18 40)[0] -eq 16 -and (Get-GlossBandCorner 18 40)[1] -eq 4)
$glossAll = ([regex]::Match($src, '(?s)\$global:Gloss = .*?\r?\nfunction global:New-Tile')).Value + $tileSrc
Check 'ClaudeCode: no culture-formatted numbers in gloss margins/corners (Thickness/CornerRadius built directly)' ($glossAll -notmatch "(Margin|CornerRadius) = \('[^']*\{0\}[^']*' -f" -and $glossAll -match 'New-Object System\.Windows\.Thickness 0, \(\$o - 1\)')
$ci = [System.Threading.Thread]::CurrentThread.CurrentCulture
try { [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'de-DE'
    $old = ('0,{0},{0},0' -f 8.4); $deOk = ($old -eq '0,8,4,8,4,0')   # proves the bug shape under de-DE
    $bc = Get-GlossBandCorner 18 7.5; $o = Get-GlossOutlineOffsets 2.4
    Check ('ClaudeCode: under de-DE the old -f margin broke ({0}); gloss maths stays numeric (corner {1}, offset {2})' -f $old, $bc[0], $o[4][0]) ($deOk -and $bc[0] -is [double] -and $bc[0] -eq 3 -and $o[4][0] -eq 0.85 -and (Get-GlossRowBand @(7.5, 24)) -eq 7.5 -and (Get-GlossLabelRight 272 100.5 $true) -eq 186.25) }
finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $ci }

# --- v1.4.8 Windows capture fixes (2871b6b at 100% / 144 DPI) ---
Invoke-Expression ($ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Get-LabelMaxWidth' }, $true).Extent.Text)
Check 'v1.4.9 (CC Low): label width = tile content minus the 1 px edge (normal) or 2 px red border (restart) each side (half 107 / restart 105, full 246 / restart 244)' ((Get-LabelMaxWidth 'half' $false) -eq 107 -and (Get-LabelMaxWidth 'half' $true) -eq 105 -and (Get-LabelMaxWidth 'full' $false) -eq 246 -and (Get-LabelMaxWidth 'full' $true) -eq 244)
Check 'capture fix 1: both icon-left and icon-above labels use Get-LabelMaxWidth $cls $danger' ($nc.Contains('$text.MaxWidth = (Get-LabelMaxWidth $cls $danger) - $iconW') -and $nc.Contains('if ($above) { $text.MaxWidth = Get-LabelMaxWidth $cls $danger }') -and $nc -notmatch '109 - \$iconW')
# word-aware fake: WrapWithOverflow keeps words whole, so an over-wide word widens DesiredSize (WPF behaviour); Wrap would split it by character
function New-WordLabel([string]$text) { $m = [pscustomobject]@{ FontSize = 0.0; LineHeight = 0.0; Tag = $null; Name = ''; DesiredSize = $null; TextWrapping = 'Wrap' }; $t = [pscustomobject]@{ DesiredSize = $null; m = $m; words = @($text -split ' ') }
    $t | Add-Member ScriptMethod Measure { param($sz) $cw = $this.m.FontSize * 0.55; $lines = 1; $cur = 0.0; $widest = 0.0
        foreach ($w in $this.words) { $ww = $w.Length * $cw
            if ($this.m.TextWrapping -eq 'Wrap' -and $ww -gt $sz.Width) { $ww = $sz.Width }   # Wrap: the word is cut to the line ('ScreenConnec' + 't')
            $add = if ($cur -gt 0) { $cw + $ww } else { $ww }
            if ($cur -gt 0 -and $cur + $add -gt $sz.Width) { $lines++; $cur = $ww } else { $cur += $add }
            if ($cur -gt $widest) { $widest = $cur } }
        if ($this.m.TextWrapping -eq 'Wrap') { $lines += @($this.words | Where-Object { $_.Length * $cw -gt $sz.Width }).Count }
        $this.m.DesiredSize = [pscustomobject]@{ Height = $lines * $this.m.LineHeight }; $this.DesiredSize = [pscustomobject]@{ Width = $widest; Height = $lines * $this.m.LineHeight } }; return @($m, $t) }
$fk = New-WordLabel 'Restart ScreenConnect'; $ok = Set-FitFontSize $fk[0] $fk[1] (Get-LabelMaxWidth 'half' $true) 40 16
Check ('capture fix 1: Restart ScreenConnect on a restart half tile fits whole-word at {0} px (13 chars x 0.55 em <= 105), WrapWithOverflow set' -f $fk[0].FontSize) ($ok -and $fk[0].TextWrapping -eq 'WrapWithOverflow' -and 13 * $fk[0].FontSize * 0.55 -le 105 -and $fk[1].DesiredSize.Width -le 105)
$fk = New-WordLabel 'Supercalifragilisticexpialidocious'; $ok = Set-FitFontSize $fk[0] $fk[1] 105 40 16
Check 'capture fix 1: a single word too wide even at 12 px reports no fit (ellipsis + tooltip), never a mid-word split' (-not $ok -and $fk[0].TextWrapping -eq 'WrapWithOverflow' -and $nc.Contains("WrapWithOverflow keeps words whole"))
$defs = Get-Content -Raw (Join-Path $root 'buttons.default.json') | ConvertFrom-Json; $bad = @()
foreach ($pn in $defs.panels) { foreach ($b in $pn.buttons) { if (-not $b.label) { continue }
    $dg = ([string]$b.label) -match '(?i)^restart'; $cls = if ($b.width -eq 'half') { 'half' } elseif ([double]$b.height -ge 110) { 'hero' } else { 'full' }
    $mw = Get-LabelMaxWidth $cls $dg; $longest = (@(([string]$b.label) -split '\s+') | Measure-Object -Property Length -Maximum).Maximum
    if ($longest * 12 * 0.62 -gt $mw) { $bad += [string]$b.label } } }   # 0.62 em: wide semibold caps estimate at the 12 px floor
Check ('capture fix 1: every default label''s longest word fits its tile at the 12 px floor (estimate); over: ' + ($bad -join ' | ')) ($bad.Count -eq 0)
$ms = Get-Content -Raw (Join-Path $root 'Launcher.ps1')
Invoke-Expression ([regex]::Match($ms, '(?m)^function global:Get-MailBadgeLeft.*?\r?\n\}', 'Singleline').Value)
Invoke-Expression ([regex]::Match($ms, '(?m)^function global:Get-MailBadgeWidth[^\r\n]*').Value)
$ov = foreach ($t in '1', '42', '99+') { $w = Get-MailBadgeWidth $t; (Get-MailBadgeLeft 24 $w 10) + $w }
Check ('capture fix 2: badge right edge stays >= 4 px short of the Email label (label at icon 24 + gap 10 = 34): right edges ' + ($ov -join ', ')) (@($ov | Where-Object { $_ -gt 30 }).Count -eq 0)
Check 'capture fix 2: same badge sizes (18/24/30) and colours; 1-digit stays near icon right - 8 (moved 4 px at most); label below the icon keeps icon right - 8' ((Get-MailBadgeWidth '99+') -eq 30 -and (Get-MailBadgeLeft 24 18 10) -ge 12 -and (Get-MailBadgeLeft 24 30 ([double]::PositiveInfinity)) -eq 16 -and $ms.Contains("`$bd.Background = Brush '#111111'") -and $ms.Contains("`$tx.Foreground = Brush '#FACC15'"))
Check 'capture fix 2: badge re-placed whenever its width changes; Email (dark label) keeps no outline' ($ms.Contains('$bd.Width = Get-MailBadgeWidth $txt; [System.Windows.Controls.Canvas]::SetLeft($bd, (Get-MailBadgeLeft $e.ipx $bd.Width $e.iconGap))') -and (Test-GlossDarkLabel '#111111'))
# --- v1.4.9 follow-ups (Kern r3 Minor 2 + 3, CC Low) ---
Invoke-Expression ([regex]::Match($ms, '(?m)^function global:Get-MailBadgeTop[^\r\n]*').Value)
Check 'v1.4.9: badges wider than 18 px (42, 99+) sit at Canvas.Top -10; 1 digit stays -6; set with every count' ((Get-MailBadgeTop (Get-MailBadgeWidth '1')) -eq -6 -and (Get-MailBadgeTop (Get-MailBadgeWidth '42')) -eq -10 -and (Get-MailBadgeTop (Get-MailBadgeWidth '99+')) -eq -10 -and $ms.Contains('SetTop($bd, (Get-MailBadgeTop $bd.Width))'))
# like New-WordLabel, but hard line breaks in the label (`n) start a new line, as WPF does
function New-HardLabel([string]$text) { $m = [pscustomobject]@{ TextTrimming = $null; Uid = ''; MaxHeight = 0.0; FontSize = 0.0; LineHeight = 0.0; Tag = $null; Name = ''; DesiredSize = $null; TextWrapping = 'Wrap' }; $t = [pscustomobject]@{ DesiredSize = $null; m = $m; paras = @($text -split "`n") }
    $t | Add-Member ScriptMethod Measure { param($sz) $cw = $this.m.FontSize * 0.55; $lines = 0; $widest = 0.0
        foreach ($pa in $this.paras) { $lines++; $cur = 0.0
            foreach ($w in @($pa -split ' ' | Where-Object { $_ })) { $ww = $w.Length * $cw; $add = if ($cur -gt 0) { $cw + $ww } else { $ww }
                if ($cur -gt 0 -and $cur + $add -gt $sz.Width) { $lines++; $cur = $ww } else { $cur += $add }
                if ($cur -gt $widest) { $widest = $cur } } }
        $this.m.DesiredSize = [pscustomobject]@{ Height = $lines * $this.m.LineHeight }; $this.DesiredSize = [pscustomobject]@{ Width = $widest; Height = $lines * $this.m.LineHeight } }; return @($m, $t) }
$fk = New-HardLabel "RESTART`nSCREEN CONNECT"; $ok9 = Set-FitFontSize $fk[0] $fk[1] 40 60 16; Invoke-Expression $mf; Set-MaxLines $fk[0] 3
$tip9 = $(if (-not $ok9) { "RESTART`nSCREEN CONNECT" -replace "`n", ' ' } else { $null })
Check 'v1.4.9 CC Low: a default label forced to overflow (40 px) reports no fit, ends in "..." with a 3-line cap, and New-Content gives it the full-name tooltip' (-not $ok9 -and $fk[0].TextTrimming -eq 'CharacterEllipsis' -and $fk[0].Uid -eq 'maxlines=3' -and $tip9 -eq 'RESTART SCREEN CONNECT' -and $nc.Contains('$availH $fs)) { $main.ToolTip = ($lab.main -replace') -and $nc -notmatch 'Test-CustomLabel|\$custom')
$bad9 = @(); $n9 = 0
foreach ($pn in $defs.panels) { foreach ($b in $pn.buttons) { if (-not $b.label) { continue }
    foreach ($w9 in 105, 244) { $n9++; $fk = New-HardLabel ([string]$b.label); $ok = Set-FitFontSize $fk[0] $fk[1] $w9 60 16
        if (-not $ok -or $fk[0].FontSize -lt 12 -or $fk[1].DesiredSize.Width -gt $w9) { $bad9 += ('{0}@{1}' -f $b.label, $w9) } } } }
Check ('v1.4.9 (Kern 3): every default label fits whole-word at 105 and 244 px with the 12-13 px floor (' + $n9 + ' checks); over: ' + ($bad9 -join ' | ')) ($n9 -gt 0 -and $bad9.Count -eq 0)
# --- v1.4.9 View Register tiles, option B (Charles 10:34 AM) ---
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(VncTiles|VncTileSize)\s*=') { Invoke-Expression $l.Extent.Text } }
foreach ($n in 'Get-VncPickerReason', 'Get-VncPickerHeight', 'Get-VncPickerRows', 'Get-VncTileLook', 'Get-VncTileState', 'Get-VncTileBandHeight') { Invoke-Expression ([regex]::Match($ms, '(?ms)^function global:' + $n + '\b.*?^\}|(?m)^function global:' + $n + '\b[^\r\n]*\}[^\r\n]*$').Value) }
$px = [regex]::Match($ms, "(?s)\`$global:VncPickerXaml = @'.*?'@").Value
$T = $global:VncTileSize
Check 'B geometry: two 271x72 tiles, 16 px gap (558 px), centred; 24 px label, 26 px icon visibly 8 px from it (6 / 4.5 box gap), 3.2 px outline, 18 px corners' ($T.w -eq 271 -and $T.h -eq 72 -and $T.gap -eq 16 -and (2 * $T.w + $T.gap) -eq 558 -and $T.font -eq 24 -and $global:VncTiles.view.iconGap -eq 6 -and $global:VncTiles.interact.iconGap -eq 4.5 -and $T.outline -eq 3.2 -and (Get-GlossOutlineWidth $T.font) -eq 3.2 -and (Get-GlossRadius 72 271) -eq 18 -and $px.Contains('<ColumnDefinition Width="271"/><ColumnDefinition Width="16"/><ColumnDefinition Width="271"/>') -and ([regex]::Matches($px, 'Style="\{StaticResource Tile\}" Height="72"')).Count -eq 2)
Check 'B colours: View only #0C6941 (eye), Interact #095F84 (hand); disabled #25352E / #253339 with #C4C4C8 label' ($global:VncTiles.view.fill -eq '#0C6941' -and $global:VncTiles.interact.fill -eq '#095F84' -and $global:VncTiles.view.label -eq 'View only' -and $global:VncTiles.interact.label -eq 'Interact' -and (Get-VncTileLook 'view' 'rest').stops[1] -eq '#0C6941' -and (Get-VncTileLook 'interact' 'rest').stops[1] -eq '#095F84' -and (Get-VncTileLook 'view' 'disabled').stops[1] -eq '#25352E' -and (Get-VncTileLook 'interact' 'disabled').stops[1] -eq '#253339')
$hv = Get-VncTileLook 'view' 'hover'; $pr = Get-VncTileLook 'view' 'pressed'; $rs = Get-VncTileLook 'interact' 'rest'
Check 'B states: hover +10% with gloss, pressed 12% darker with no gloss or sparkle, rest has gloss + sparkle, white label' ($hv.stops[1] -eq (Get-GlossFillStops '#0C6941' 'hover')[1] -and $hv.band -and $pr.stops[1] -eq (Get-GlossFillStops '#0C6941' 'pressed')[1] -and -not $pr.band -and -not $pr.sparkle -and $rs.band -and $rs.sparkle -and $rs.label -eq '#FFFFFF' -and $rs.outline -eq (Get-GlossOutlineHex '#095F84'))
$ds = Get-VncTileLook 'view' 'disabled'
Check 'B disabled: no gloss, no sparkle, label #C4C4C8; state order disabled > pressed > hover' (-not $ds.band -and -not $ds.sparkle -and $ds.label -eq '#C4C4C8' -and (Get-VncTileState ([pscustomobject]@{ IsEnabled = $false; IsPressed = $true; IsMouseOver = $true })) -eq 'disabled' -and (Get-VncTileState ([pscustomobject]@{ IsEnabled = $true; IsPressed = $true; IsMouseOver = $true })) -eq 'pressed' -and (Get-VncTileState ([pscustomobject]@{ IsEnabled = $true; IsPressed = $false; IsMouseOver = $true })) -eq 'hover')
Check 'B disabled reason: "Pick a computer to view or control it." when nothing is selected, nothing otherwise; wired to selection + refresh' ((Get-VncPickerReason $false) -ceq 'Pick a computer to view or control it.' -and (Get-VncPickerReason $true) -eq '' -and ([regex]::Matches($ms, 'Get-VncPickerReason \$has')).Count -eq 2)
Check 'B Enter = View only: View is the default button, Interact never; Enter on a list row runs View only, Ctrl+Enter Interact (unchanged)' ($px -match 'x:Name="View"[^>]*IsDefault="True"' -and $px -notmatch 'x:Name="Interact"[^>]*IsDefault' -and $ms.Contains("elseif (`$k -eq 'Return' -and `$lv.IsKeyboardFocusWithin) { `$_.Handled = `$true; `$ui.go.Invoke(`$true) }") -and $ms.Contains("if (`$k -eq 'Return' -and `$ctrl) { `$_.Handled = `$true; `$ui.go.Invoke(`$false) }"))
Check 'B keyboard: Tab order list (0), View only (1), Interact (2); Alt+V / Alt+I keys (enabled tiles only, same calls as the clicks); tile style keeps no focus-visual dots (own 18/14 ring)' ($px -match 'x:Name="List"[^>]*TabIndex="0"' -and $px -match 'x:Name="View"[^>]*TabIndex="1"' -and $px -match 'x:Name="Interact"[^>]*TabIndex="2"' -and $ms.Contains("`$_.SystemKey -eq 'V' -and `$bView.IsEnabled) { `$_.Handled = `$true; `$ui.go.Invoke(`$true) }") -and $ms.Contains("`$_.SystemKey -eq 'I' -and `$bInt.IsEnabled) { `$_.Handled = `$true; `$ui.go.Invoke(`$false) }") -and $px.Contains('<Setter Property="FocusVisualStyle" Value="{x:Null}"/>'))
Check 'B window: 480 -> 522 px (+42), min 360 -> 410; list rows kept when it fits; past the work area it shrinks but keeps >= 4 rows' ($px.Contains('Width="620" Height="522" MinWidth="616" MinHeight="410"') -and (Get-VncPickerHeight 522 1040) -eq 522 -and (Get-VncPickerHeight 522 500) -eq 500 -and (Get-VncPickerHeight 522 300) -eq 410 -and (Get-VncPickerRows (Get-VncPickerHeight 522 300)) -ge 4 -and (Get-VncPickerRows 522) -gt (Get-VncPickerRows 480))
Check 'B icons: constant Lucide path data (eye, hand) parsed once, no file or network loads; Lucide ISC licence in README' ($global:VncTiles.view.icon -match '^M2\.062,12\.348' -and $global:VncTiles.interact.icon -match '^M18,11' -and $ms.Contains("[System.Windows.Media.Geometry]::Parse(`$t.icon)") -and ([regex]::Match($ms, '(?ms)^function global:New-VncTileFace.*?^\}').Value) -notmatch 'Get-Content|ReadAll|Uri|WebClient|BitmapImage|Invoke-WebRequest' -and (Get-Content -Raw ([IO.Path]::Combine($root, 'README.txt'))) -match 'Lucide.*ISC')
Check 'B look only: the launch path is untouched (clicks still call $ui.go; Start-VncViewer unchanged)' ($ms.Contains('$bView.Add_Click({ $ui.go.Invoke($true) }.GetNewClosure())') -and $ms.Contains('$bInt.Add_Click({ $ui.go.Invoke($false) }.GetNewClosure())'))
Check ('Kern Minor 2: tile gloss band = min(cap top, ink top = box top + 1.5) - 4.5 = ' + (Get-VncTileBandHeight)) ((Get-VncTileBandHeight) -eq 20)
Check 'Kern Minor 2: one band height for both tiles' ($ms.Contains('$bandH = Get-VncTileBandHeight;') -and -not $ms.Contains('$bandH = Get-GlossBandHeight $capTop $S.h; $bc'))
Check 'Kern Minor 1: icon box margin uses the per-tile numeric gap (culture-safe)' $ms.Contains('Thickness 0, 0, ([double]$t.iconGap), 0')
Check 'CC Low 2: picker MinWidth 616 >= two 271 px tiles + 16 gap + margins; height floor = XAML MinHeight 402' ((2 * 271 + 16) -le 616 -and $ms.Contains('MinWidth="616" MinHeight="410"') -and (Get-VncPickerHeight 522 100) -eq 410)
Check 'CC Low 3: tile IsPressed watcher kept on the face and removed for both tiles when the picker closes' ($ms.Contains('$g.Tag = [EventHandler]$upd') -and $ms.Contains('RemoveValueChanged($b, $b.Content.Tag)') -and $ms.Contains('Remove-VncTileWatch $bView; Remove-VncTileWatch $bInt'))
Check 'v1.4.10 list text + v1.4.12 status: headers 14, rows 16, status label 16 SemiBold with ellipsis and full-text tooltip, star 16; header 32 px, rows 38 px, pill 18' ($px.Contains('<RowDefinition Height="32"/><RowDefinition Height="*"/></Grid.RowDefinitions>') -and $px.Contains('TextElement.FontSize="14" TextElement.FontWeight="SemiBold" TextElement.Foreground="#A0A0A0"') -and $px.Contains('Foreground="#FFFFFF" FontSize="16" Padding="0,4"') -and $px.Contains('Text="{Binding statusText}" ToolTip="{Binding statusTip}" FontSize="16" FontWeight="SemiBold"') -and $px.Contains('TextTrimming="CharacterEllipsis"') -and $px.Contains('<Grid Margin="4,0" Height="38">') -and $px.Contains('Width="3" Height="18"'))
Check 'v1.4.10 columns: Address 180 (192.168.20.51:5900 ~145 px at 16), Seen 160 (Not found last scan ~146 px at 16), same in header and rows; Name keeps >= 160 px even with the 17 px scrollbar at MinWidth 616 (16 frame, 40 margin, 2 border, 8 row margin)' (([regex]::Matches($px, '<ColumnDefinition Width="28"/><ColumnDefinition Width="\*"/><ColumnDefinition Width="180"/><ColumnDefinition Width="160"/>')).Count -eq 2 -and (616 - 16 - 40 - 2 - 8 - 28 - 180 - 160 - 17) -ge 160)
Check 'v1.4.10 rows: >= 4 rows at MinHeight 410 and 7 at 522 (chrome 240, row 38)' ((Get-VncPickerRows 410) -ge 4 -and (Get-VncPickerRows 522) -eq 7 -and (Get-VncPickerHeight 522 100) -eq 410)
Invoke-Expression ([regex]::Match($ms, '(?m)^function global:Get-VncHeaderInset\b[^\r\n]*$').Value)
Check 'Kern/Squint: header right inset = 4 + scrollbar width only while the list scrollbar shows; hooked on ScrollChanged + SizeChanged' ((Get-VncHeaderInset 'Visible' 17) -eq 21 -and (Get-VncHeaderInset 'Collapsed' 17) -eq 4 -and (Get-VncHeaderInset 'Hidden' 17) -eq 4 -and $px.Contains('<Grid x:Name="Hdr" Margin="4,0"') -and $ms.Contains('$sv.Add_ScrollChanged($fix); $sv.Add_SizeChanged($fix)') -and $ms.Contains('[System.Windows.SystemParameters]::VerticalScrollBarWidth'))
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
