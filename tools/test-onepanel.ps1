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
Check 'Get-ChipIcon checks Test-SafeIconSource before Test-Path and caches per target' ($src -match '\(Test-SafeIconSource \$t\) -and \(Test-Path -LiteralPath \$t -PathType Leaf\)' -and $src -match '\$global:iconCache\[\$t\] = \$bs')
Check 'chip dot: no existence check on non-local paths' ($src -match '\(Test-LocalFixedPath \$ct\) -and -not \(Test-ButtonSetUpQuick \$btn\)')
# Source checks
Check 'click-through: middle Background $null when locked' ($src -match "\`$mid\.Background = if \(\`$locked\) \{ \`$null \}")
Check 'single window uses per-pixel alpha' ($src -match '\$w\.AllowsTransparency = \$true; \$w\.Background = \$null')
Check 'single window not topmost unless it already was' ($src -match '\$w\.Topmost = \[bool\]\$pcs\[0\]\.alwaysOnTop')
Check 're-dock on display/work-area/DPI change' ($src -match 'if \(\$global:single\) \{ Layout-Single \}' -and $src -match '0x007E, 0x001A, 0x02E0')
Check 'chips: 65% fill, 16% white outline' ($src -match "Brush '#A6141414'" -and $src -match "Brush '#29FFFFFF'")
Check 'chips: 12 px one-line label with ellipsis' ($src -match "New-Label \(Get-ChipLabel \`$btn\) '#FFFFFF' 12; \`$tb\.TextWrapping = 'NoWrap'; \`$tb\.TextTrimming = 'CharacterEllipsis'")
Check '+N more is a 28 px button opening a flyout' ($src -match '\$more\.Height = 28' -and $src -match 'Primitives\.Popup')
Check 'chips: icon from ExtractAssociatedIcon, Set A fallback' ($src -match 'ExtractAssociatedIcon\(\$t\)' -and $src -match "'website' \{ 'images/globe\.png' \}")
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
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
