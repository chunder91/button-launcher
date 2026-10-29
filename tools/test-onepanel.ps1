# One-panel layout checks that run without Windows: layout setting, middle schema, empty-state hint, overflow math,
# chip label trimming, and source checks for click-through, tray, hotkey, menus and cleanup.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Launcher.ps1'), [ref]$null, [ref]$null)
$src = $ast.Extent.Text
foreach ($n in 'Expand', 'Get-ButtonType', 'Set-Prop', 'Get-LayoutMode', 'Get-MiddleHint', 'Get-OverflowSplit', 'Get-ChipLabel', 'New-MiddleState', 'Is-Todo', 'Test-LocalFixedPath', 'Test-SafeIconSource', 'Get-ChipFallbackPic') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
$global:PathProbe = @{ DosDevice = { param($d) '\Device\HarddiskVolume3' }; Attr = { param($p) $null } }   # R6-L2 probes: plain local volume, no special attributes
# Layout setting
Check "layout default is 'two'" ((Get-LayoutMode ([pscustomobject]@{})) -eq 'two')
Check "layout 'single'" ((Get-LayoutMode ([pscustomobject]@{ layout = 'single' })) -eq 'single')
Check "unknown layout falls back to 'two'" ((Get-LayoutMode ([pscustomobject]@{ layout = 'sideways' })) -eq 'two')
$def = Get-Content (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
Check "buttons.default.json: layout 'two'" ($def.layout -eq 'two')
Check 'buttons.default.json: middle starts empty, 2 columns' ($def.middle -and @($def.middle.items).Count -eq 0 -and $def.middle.columns -eq 2)
# Middle schema: same target types as tiles
$m = New-MiddleState ([pscustomobject]@{ middle = [pscustomobject]@{ columns = 9; items = @(
    [pscustomobject]@{ label = 'Notepad'; type = 'program'; target = 'notepad.exe'; image = 'icon' },
    [pscustomobject]@{ label = 'KBS Portal'; type = 'website'; target = 'https://example.invalid' },
    [pscustomobject]@{ label = 'Price List.pdf'; type = 'file'; target = 'C:\Docs\Price List.pdf' },
    [pscustomobject]@{ label = ''; type = 'script'; target = 'C:\Scripts\Daily Backup.ps1' }) } })
Check 'middle: items kept in order' ($m.items.Count -eq 4 -and $m.items[0].label -eq 'Notepad')
Check 'middle: columns clamped to 1-4' ($m.cols -eq 4)
$cfgNo = [pscustomobject]@{}; $m0 = New-MiddleState $cfgNo
Check 'middle: missing group created empty' ($m0.items.Count -eq 0 -and $m0.cols -eq 2 -and $cfgNo.middle -and @($cfgNo.middle.items).Count -eq 0)
foreach ($b in $m.items) { Check ("middle item type '{0}' is a known target type" -f $b.type) ($b.type -in 'program', 'website', 'file', 'script', 'builtin') }
# Empty-state hint
Check 'hint: empty + unlocked' ((Get-MiddleHint 0 $false) -eq 'Unlock and right-click to add icons')
Check 'hint: empty + locked shows nothing' ($null -eq (Get-MiddleHint 0 $true))
Check 'hint: not empty shows nothing' ($null -eq (Get-MiddleHint 3 $false))
# Overflow math (chips 64, gap 6, "+N more" row 28)
foreach ($c in @(@(0, 500, 0, 0), @(4, 140, 4, 0), @(5, 140, 2, 3), @(8, 300, 8, 0), @(9, 280, 6, 3), @(3, 40, 0, 3), @(10, 0, 0, 10), @(2, 64, 2, 0))) {
    $r = Get-OverflowSplit $c[0] $c[1] 2
    Check ("overflow total={0} avail={1}: shown {2}, +{3} more" -f $c[0], $c[1], $r.shown, $r.more) ($r.shown -eq $c[2] -and $r.more -eq $c[3] -and ($r.shown + $r.more) -eq $c[0]) }
$r3 = Get-OverflowSplit 7 140 3; Check 'overflow 3 columns: 7 in 140 -> 3 shown, +4' ($r3.shown -eq 3 -and $r3.more -eq 4)
# Labels: one line, extensions hidden (not for websites)
foreach ($c in @(@('Price List.pdf', 'file', 'Price List'), @('Daily Backup.ps1', 'script', 'Daily Backup'), @('Nightly Report.xlsx', 'file', 'Nightly Report'),
                 @("Two`nLines", 'program', 'Two Lines'), @('example.com', 'website', 'example.com'), @('v1.2 notes', 'file', 'v1.2 notes'))) {
    $got = Get-ChipLabel ([pscustomobject]@{ label = $c[0]; type = $c[1]; target = 'x' })
    Check ("chip label '{0}' -> '{1}'" -f ($c[0] -replace "`n", '|'), $got) ($got -ceq $c[2]) }
Check 'chip label from target when empty' ((Get-ChipLabel ([pscustomobject]@{ label = ''; type = 'script'; target = 'C:\Scripts\Daily Backup.ps1' })) -eq 'Daily Backup')
# OP-L1: icon extraction only for local fixed-drive paths (drive types mocked: C fixed, Z mapped network, E removable)
$dt = { param($r) switch ($r.Substring(0, 1).ToUpperInvariant()) { 'C' { 'Fixed' } 'D' { 'Fixed' } 'Z' { 'Network' } 'E' { 'Removable' } 'Q' { throw 'no such drive' } default { 'NoRootDirectory' } } }
foreach ($c in @(@('C:\Program Files\App\app.exe', $true), @('d:/tools/x.exe', $true), @('\\server\share\app.exe', $false), @('//server/share/app.exe', $false),
                 @('\\?\UNC\server\share\app.exe', $false), @('\\?\C:\app.exe', $false), @('\\.\pipe\x', $false), @('\\.\C:\app.exe', $false),
                 @('Z:\apps\app.exe', $false), @('E:\usb\app.exe', $false), @('Q:\gone.exe', $false), @('notepad.exe', $false), @('', $false), @('"C:\x y\a.exe"', $true))) {
    Check ("local fixed path '{0}' -> {1}" -f $c[0], $c[1]) ((Test-LocalFixedPath $c[0] $dt) -eq $c[1]) }
$lnk = { param($l) switch -Wildcard ($l) { '*local.lnk' { @{ target = 'C:\App\app.exe'; icon = 'C:\App\app.exe,0' } } '*unctarget.lnk' { @{ target = '\\srv\s\app.exe'; icon = '' } }
                                           '*uncicon.lnk' { @{ target = 'C:\App\app.exe'; icon = '\\srv\s\icons.dll,3' } } '*mapped.lnk' { @{ target = 'Z:\app.exe'; icon = ',0' } } default { @{ target = ''; icon = '' } } } }
$script:lnkRead = 0; $lnkCount = { param($l) $script:lnkRead++; & $lnk $l }
Check 'lnk: local lnk, local target + icon -> extract' (Test-SafeIconSource 'C:\Users\a\Desktop\local.lnk' $dt $lnkCount)
Check 'lnk: target on a share -> fallback' (-not (Test-SafeIconSource 'C:\d\unctarget.lnk' $dt $lnk))
Check 'lnk: icon location on a share -> fallback' (-not (Test-SafeIconSource 'C:\d\uncicon.lnk' $dt $lnk))
Check 'lnk: target on a mapped drive -> fallback' (-not (Test-SafeIconSource 'C:\d\mapped.lnk' $dt $lnk))
$script:lnkRead = 0; [void](Test-SafeIconSource '\\srv\share\local.lnk' $dt $lnkCount); [void](Test-SafeIconSource 'Z:\local.lnk' $dt $lnkCount)
Check 'lnk on a share or mapped drive is never read' ($script:lnkRead -eq 0)
Check 'reader error -> fallback' (-not (Test-SafeIconSource 'C:\d\x.lnk' $dt { throw 'COM failed' }))
foreach ($c in @(@('program', 'images/register.png'), @('file', 'images/guide.png'), @('script', 'images/screenconnect.png'), @('website', 'images/globe.png'))) {
    Check ("fallback icon for {0}: {1}" -f $c[0], $c[1]) ((Get-ChipFallbackPic $c[0]) -eq $c[1] -and (Test-Path (Join-Path $root $c[1]))) }
# OP-L3: Get-ChipIcon run for real with mocks: cache key = path|mtime, no file access for non-local targets
$gci = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Get-ChipIcon' }, $true)
Invoke-Expression $gci.Extent.Text
function global:Get-PicSource($b, $s) { 'fallback' }; function global:Resolve-Img($i) { $i }
$global:safeOk = $true; function global:Resolve-IconTarget($t) { if (-not $global:safeOk) { return $null }; if ($global:lnkTo -and $t -like '*.lnk') { return $global:lnkTo }; $t }
$global:iconCacheOrder = New-Object System.Collections.ArrayList; $global:IconCacheMax = 256
$tf = Join-Path ([IO.Path]::GetTempPath()) ('chip-' + [guid]::NewGuid() + '.exe'); Set-Content $tf 'x'
$global:iconCache = @{}; $global:iconCacheOrder.Clear(); $cb = [pscustomobject]@{ type = 'program'; target = $tf; image = 'icon' }
[void](Get-ChipIcon $cb); [void](Get-ChipIcon $cb)
$k1 = @($global:iconCache.Keys)
Check 'OP-L3: one cache entry keyed path|LastWriteTimeUtc ticks after two draws' ($k1.Count -eq 1 -and $k1[0] -eq ($tf.ToLowerInvariant() + '|' + (Get-Item $tf).LastWriteTimeUtc.Ticks))
(Get-Item $tf).LastWriteTimeUtc = (Get-Date).AddDays(-1).ToUniversalTime(); [void](Get-ChipIcon $cb)
Check 'OP-L3: changed file -> new cache entry' ($global:iconCache.Count -eq 2)
Check 'OP-L3: extraction only when the key is new' ($gci.Extent.Text -match '(?s)if \(-not \$global:iconCache\.ContainsKey\(\$ck\)\) \{.*?ExtractAssociatedIcon')
$global:safeOk = $false; $global:iconCache = @{}; $global:iconCacheOrder.Clear(); $script:gi = 0
function global:Get-Item { $script:gi++; Microsoft.PowerShell.Management\Get-Item @args }
Check 'OP-L1/L3: non-local target -> fallback, file never touched, nothing cached' ((Get-ChipIcon $cb) -eq 'fallback' -and $script:gi -eq 0 -and $global:iconCache.Count -eq 0)
Remove-Item Function:\global:Get-Item
# OP-N3: a .lnk chip caches/extracts its checked target, not the .lnk
$global:safeOk = $true; $global:iconCache = @{}; $global:iconCacheOrder.Clear(); $global:lnkTo = $tf
$lf = Join-Path ([IO.Path]::GetTempPath()) ('chip-' + [guid]::NewGuid() + '.lnk'); Set-Content $lf 'l'
[void](Get-ChipIcon ([pscustomobject]@{ type = 'program'; target = $lf; image = 'icon' }))
Check 'OP-N3: .lnk chip icon keyed and extracted from its checked target' (@($global:iconCache.Keys).Count -eq 1 -and @($global:iconCache.Keys)[0] -like ($tf.ToLowerInvariant() + '|*') -and $gci.Extent.Text -match 'ExtractAssociatedIcon\(\$src\)' -and $gci.Extent.Text -notmatch 'ExtractAssociatedIcon\(\$t\)')
$global:lnkTo = $null; Remove-Item -LiteralPath $lf
# R6-N2: cache capped, oldest dropped first
$global:IconCacheMax = 3; $global:iconCache = @{}; $global:iconCacheOrder.Clear(); $fs = @()
foreach ($i in 1..5) { $f = Join-Path ([IO.Path]::GetTempPath()) ('cap-' + $i + '-' + [guid]::NewGuid() + '.exe'); Set-Content $f 'x'; $fs += $f; [void](Get-ChipIcon ([pscustomobject]@{ type = 'program'; target = $f; image = 'icon' })) }
$keys = @($global:iconCache.Keys)
Check 'R6-N2: icon cache capped at IconCacheMax, oldest dropped' ($keys.Count -eq 3 -and $global:iconCacheOrder.Count -eq 3 -and -not ($keys | Where-Object { $_ -like ($fs[0].ToLowerInvariant() + '|*') -or $_ -like ($fs[1].ToLowerInvariant() + '|*') }) -and ($keys | Where-Object { $_ -like ($fs[4].ToLowerInvariant() + '|*') }))
Check 'R6-N2: default cap 256' ($src -match '\$global:IconCacheMax = 256')
foreach ($f in $fs) { Remove-Item -LiteralPath $f }; $global:IconCacheMax = 256
Remove-Item -LiteralPath $tf
Check 'Get-ChipIcon checks Resolve-IconTarget (local-only) before touching the file' ($gci.Extent.Text -match '(?s)\$src = Resolve-IconTarget \$t\s+if \(\$src\) \{\s+\$fi = \$null; try \{ \$fi = Get-Item -LiteralPath \$src')
Check 'chip dot: only Get-SetupState missing (local-only check)' ($src -match '\$ss = Get-SetupState \$btn[^\n]*\n\s+if \(\$ss -eq ''missing''\) \{ \[void\]\$g\.Children\.Add\(\(New-MissingDot')
Check 'helpers defined once' (([regex]::Matches($src, 'function global:Test-LocalFixedPath')).Count -eq 1 -and ([regex]::Matches($src, 'function global:Test-SafeIconSource')).Count -eq 1 -and ([regex]::Matches($src, 'function global:Get-DriveTypeName')).Count -eq 1)
# Source checks
Check 'click-through: middle Background $null when locked' ($src -match "\`$mid\.Background = if \(\`$locked\) \{ \`$null \}")
Check 'single window uses per-pixel alpha' ($src -match '\$w\.AllowsTransparency = \$true; \$w\.Background = \$null')
Check 'single window not topmost unless it already was' ($src -match '\$w\.Topmost = \[bool\]\$pcs\[0\]\.alwaysOnTop')
Check 're-dock on display/work-area/DPI change' ($src -match 'if \(\$global:single\) \{ Layout-Single \}' -and $src -match '0x007E, 0x001A, 0x02E0')
Check 'chips: 65% fill, 16% white outline' ($src -match "Brush '#A6141414'" -and $src -match "Brush '#29FFFFFF'")
Check 'chips: 12 px one-line label with ellipsis' ($src -match "New-Label \(Get-ChipLabel \`$btn\) '#FFFFFF' 12; \`$tb\.TextWrapping = 'NoWrap'; \`$tb\.TextTrimming = 'CharacterEllipsis'")
Check '+N more is a 28 px button opening a flyout' ($src -match '\$more\.Height = 28' -and $src -match 'Primitives\.Popup')
Check 'chips: icon from ExtractAssociatedIcon, Set A fallback' ($src -match 'ExtractAssociatedIcon\(\$src\)' -and $src -match "'website' \{ 'images/globe\.png' \}")
Check 'chips: same right-click menu kinds (edit/move/remove)' ($src -match "'Edit this icon\.\.\.'" -and $src -match "'Remove this icon'" -and $src -match "'Move earlier'")
Check 'chips: whole chip drags in edit mode' ($src -match 'DragDrop\]::DoDragDrop\(\$chip')
Check 'remove: 5 s Undo toast' ($src -match 'FromSeconds\(5\)' -and $src -match "Content = 'Undo'")
Check 'columns same locked and unlocked' ($src -notmatch 'cols \+ 1' -and $src -match 'New-ChipGrid @\(\$items\[0\.\.\(\$split\.shown - 1\)\]\) \$global:middle\.cols')
Check 'Editing bar leads with Lock when done' ($src -match "'Editing\. Lock when done\.'")
Check 'tray: NotifyIcon with images\app.ico, Show/Lock/Settings/Exit' ($src -match 'Forms\.NotifyIcon' -and $src -match "images\\app\.ico" -and $src -match "Add\('Show'" -and $src -match "Add\('Settings'" -and $src -match "Add\('Exit'")
Check 'tray: left click brings it forward' ($src -match 'MouseButtons\]::Left\) \{ Show-AllPanels \}')
Check 'hotkey: Ctrl+Alt+L on a message-only window' ($src -match 'RegisterHotKey\(\$global:hotkeySrc\.Handle, 0xB10, 0x4003, 0x4C\)' -and $src -match 'ParentWindow = \[IntPtr\]\(-3\)')
Check 'hotkey taken: logged, tray kept' ($src -match 'Ctrl\+Alt\+L is already used')
Check 'exit: unregister hotkey and dispose tray' ($src -match 'UnregisterHotKey' -and $src -match '\$global:tray\.Dispose\(\)' -and $src -match 'Add_Exit\(\{ Stop-TrayAndHotkey \}\)')
Check 'tray + hotkey in both layouts' ($src -match '(?s)else \{ foreach \(\$pc in @\(\$global:cfg\.panels\)\) \{ \[void\]\(Open-Panel \$pc\) \} \}.*Start-TrayAndHotkey')
Check 'second launch raises the single window' ($src -match '(?s)function global:Show-AllPanels \{\s+if \(\$global:single\)')
Check 'Setup > Layout menu' ($src -match "\`$lay\.Header = 'Layout'" -and $src -match "'One panel, docked to the edge'")
Check 'Save keeps panels 3+ in single layout' ($src -match "if \(-not \`$global:single\) \{ \`$global:cfg\.panels = ")
Check 'restart confirm default No kept' ($src -match "\[System\.Windows\.MessageBox\]::Show\(\`$cText, \`$cTitle, 'YesNo', 'Warning', 'No'\)")
Check 'chip Enter/Space ignore key repeat' ($src -match "\`$chip\.Add_KeyDown\(\{ if \(\(\`$_\.Key -eq 'Enter' -or \`$_\.Key -eq 'Space'\) -and -not \`$_\.IsRepeat\)")
$stf = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Stop-TrayAndHotkey' }, $true)
Invoke-Expression $stf.Extent.Text
$global:dispN = 0; $mk = { $o = [pscustomobject]@{ Visible = $true }; $o | Add-Member ScriptMethod Dispose { $global:dispN++ }; $o }
$global:tray = & $mk; $global:trayIcon = & $mk; $global:hotkeySrc = $null; $global:hotkeyOk = $false
Stop-TrayAndHotkey; Stop-TrayAndHotkey
# OP-N1
Check 'OP-N1: tray and its app.ico Icon each disposed once, even when cleanup runs twice' ($global:dispN -eq 2 -and $null -eq $global:tray -and $null -eq $global:trayIcon)
Check 'OP-N1: app.ico Icon kept in $global:trayIcon' ($src -match '\$global:trayIcon = New-Object System\.Drawing\.Icon \$ico; \$ni\.Icon = \$global:trayIcon')
# OP-M1: tray + hotkey cleaned up even when startup fails after Start-TrayAndHotkey; cleanup safe to run twice
Check 'OP-M1: main try has finally { Stop-TrayAndHotkey }' ($src -match "(?s)Write-LauncherError 'starting up' \`$_\s+exit 1\s+\}\s+finally \{ Stop-TrayAndHotkey \}")
# CC OP-L1: one shared Undo timer, restarted on every Remove
$ut = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Show-UndoToast' }, $true).Extent.Text
Check 'CC OP-L1: Undo toast uses one shared timer, restarted each time' ($ut -match 'if \(-not \$global:toastTimer\)' -and $ut -match '\$global:toastTimer\.Stop\(\); \$global:toastTimer\.Start\(\)' -and ([regex]::Matches($ut, 'New-Object System\.Windows\.Threading\.DispatcherTimer')).Count -eq 1 -and $ut -notmatch '\$timer\b')
# OP-L2: chips capture on press and launch only on a release inside, after their own press
$nc = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:New-Chip' }, $true).Extent.Text
Check 'OP-L2: chip captures the mouse on press' ($nc -match 'Add_MouseLeftButtonDown\(\{ \$st\.down = \$true;[^}]*\[void\]\$chip\.CaptureMouse\(\)')
Check 'OP-L2: release launches only after own press, inside the chip' ($nc -match '(?s)if \(-not \$st\.down\) \{ return \}; \$st\.down = \$false; \$chip\.ReleaseMouseCapture\(\).*?\$inside = .*?if \(\$inside -and -not \$st\.dragged\) \{ \$ok = Invoke-Button')
Check 'OP-L2: lost capture clears the press; drag releases capture' ($nc -match 'Add_LostMouseCapture\(\{ \$st\.down = \$false \}' -and $nc -match '\$st\.dragged = \$true; \$st\.down = \$false; \$chip\.ReleaseMouseCapture\(\)')
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
