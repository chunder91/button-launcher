# Button Launcher - PowerShell 5.1 + WPF. Floating panels anchored to screen edges; all settings in buttons.json.
# Right-click a button or empty panel space for edit options.

# Per-monitor DPI awareness (PerMonitorV2) must be set before any window or WPF assembly loads.
Add-Type -Namespace BL -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
[DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
[DllImport("shell32.dll")] public static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA d);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct APPBARDATA { public uint cbSize; public IntPtr hWnd; public uint msg; public uint edge; public RECT rc; public IntPtr lParam; }
'@
$global:dpiCtxOk = $false
try { $global:dpiCtxOk = [BL.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}   # -4 = PER_MONITOR_AWARE_V2
try { [AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false) } catch {}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms, Microsoft.VisualBasic

# ---------- shared state (all $global:, initialised before any function or window runs) ----------
$global:here         = Split-Path -Parent $MyInvocation.MyCommand.Path
$global:cfgPath      = Join-Path $global:here 'buttons.json'
$global:cfgDefault   = Join-Path $global:here 'buttons.default.json'   # R-M2: shipped default, copied once when buttons.json is missing
$global:logPath      = Join-Path $global:here 'launcher-error.log'
$global:cfg          = $null
$global:panels       = New-Object System.Collections.ArrayList   # each: @{ cfg; items; win; stack; ... }
$global:BaseWidth    = 290                                        # design width; heights/fonts in buttons.json use these units
$global:SizePct      = @{ Small = 11; Medium = 14; Large = 18 }   # panel width as % of work-area width
$global:UiFont       = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text Semibold, Segoe UI Semibold, Segoe UI'
$global:Theme        = @{ panel = '#141414'; restartFill = '#2A2A2A'; restartRed = '#E5484D'; amber = '#F59E0B'; editText = '#111111' }
# Option B / Kern palette: old default fill -> @(new fill, label colour). All labels pass WCAG AA (4.5:1).
$global:ModernFill   = @{ '#3EC3EE' = @('#0B6E99', '#FFFFFF'); '#0E8A55' = @('#0E7A4B', '#FFFFFF'); '#B48CF5' = @('#7B4FD6', '#FFFFFF')
                          '#FFFF00' = @('#FACC15', '#111111'); '#7F7F7F' = @('#5F6368', '#FFFFFF'); '#FF0000' = @('#C40000', '#FFFFFF')
                          '#F0E68C' = @('#F0E68C', '#111111'); '#FA8072' = @('#B8432F', '#FFFFFF'); '#DAA520' = @('#8A6100', '#FFFFFF') }
$global:Acronyms     = @('PLCE', 'PC', 'POS', 'VNC', 'KBS', 'USB', 'TV', 'ID', 'IT', 'PA', 'DOR')
$global:app          = $null
$global:relayoutTimer = $null
$global:labelSink    = $null
$global:single       = $null                                      # one-panel layout window state (layout 'single')
$global:middle       = $null                                      # middle icons: @{ cols; items }
$global:tray         = $null
$global:hotkeySrc    = $null
$global:hotkeyOk     = $false
$global:iconCache    = @{}                                         # OP-L1: chip icons extracted once per target
$global:AppVersion   = '1.2.0'
$global:showEvent    = $null                                      # second launch signals this to bring panels forward                                      # labels collected while a panel is built (min font)

function global:Write-LauncherError($where, $err) {
    if ($err -is [Exception]) { $ex = $err; $trace = $err.StackTrace } else { $ex = $err.Exception; $trace = $err.ScriptStackTrace }
    $msg = "[{0}] {1}: {2}`r`n{3}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $where, $ex.Message, $trace
    try { Add-Content -Path $global:logPath -Value $msg -Encoding UTF8 } catch {}
    try { [System.Windows.MessageBox]::Show("The launcher hit a problem ($where):`n`n$($ex.Message)`n`nDetails were saved to launcher-error.log", 'Launcher') | Out-Null } catch {}
}

function global:Brush($hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }
function global:Expand($s) { [Environment]::ExpandEnvironmentVariables([string]$s) }

# ---------- running a button: Program / Website / File / Script / Built-in ----------
# CC-L1/LJ-L2: website buttons open only http, https or mailto. Bare addresses get https://. Returns $null if not allowed.
function global:Get-SafeUrl($u) {
    $u = ([string]$u).Trim(); if (-not $u) { return $null }
    if ($u -match '^(?i)(https?://|mailto:)') { return $u }
    if ($u -match '^[a-z][a-z0-9+.-]*:(?!\d)' -or $u -match '^[a-z]:' -or $u -match '^[\\/]') { return $null }   # other scheme, drive or UNC path
    return 'https://' + $u
}
function global:Is-Todo($t) { [string]::IsNullOrWhiteSpace($t) -or ([string]$t).Trim() -like 'TODO*' }

function global:Get-ButtonType($btn) {
    if ($btn.type) { return [string]$btn.type }
    $t = [string]$btn.target
    if ($t -match '^[a-z][a-z0-9+.-]*:' -and $t -notmatch '^[a-z]:\\') { return 'website' }
    if ($t -match '\.(ps1|bat|cmd|vbs)$') { return 'script' }
    if ($t -match '\.(exe|lnk)$' -or $t -notmatch '[\\/]') { return 'program' }
    return 'file'
}

function global:Find-Detected($btn) {
    $d = $btn.detect; if (-not $d) { return $null }
    foreach ($pat in @($d.paths)) {
        if (-not $pat) { continue }
        $hit = Get-ChildItem -Path (Expand $pat) -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    if ($d.lnkNames) {
        $roots = @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'),
                   [Environment]::GetFolderPath('CommonStartMenu'), [Environment]::GetFolderPath('StartMenu'))
        $ws = New-Object -ComObject WScript.Shell
        foreach ($r in $roots) {
            if (-not $r -or -not (Test-Path $r)) { continue }
            foreach ($n in @($d.lnkNames)) {
                $lnk = Get-ChildItem -Path $r -Recurse -Filter "$n.lnk" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($lnk) { $tp = $ws.CreateShortcut($lnk.FullName).TargetPath; if ($tp -and (Test-Path $tp)) { return $tp }; return $lnk.FullName }
            }
        }
    }
    return $null
}

function global:Ask-ForPath($btn, $kind) {
    $o = New-Object System.Windows.Forms.OpenFileDialog
    $label = ([string]$btn.label) -replace "`n", ' '
    $o.Title = if ($btn.askTitle) { $btn.askTitle } else { "Pick the file for $label" }
    $o.Filter = if ($btn.askFilter) { $btn.askFilter } elseif ($kind -eq 'program') { 'Programs and shortcuts|*.exe;*.lnk|All files|*.*' }
                elseif ($kind -eq 'script') { 'Scripts|*.ps1;*.bat;*.cmd;*.vbs|All files|*.*' } else { 'All files|*.*' }
    if ($o.ShowDialog() -eq 'OK') { return $o.FileName }
    return $null
}

# Returns a usable path, or $null. Auto-detects, else asks once, then saves the answer.
function global:Resolve-ButtonPath($btn, $kind) {
    $t = Expand $btn.target
    if (-not (Is-Todo $t)) {
        if (Test-Path $t) { return $t }
        if ($kind -eq 'program' -and $t -notmatch '[\\/]') { return $t }       # e.g. shutdown.exe, notepad
    }
    $canAsk = $btn.askTitle -or $btn.detect -or -not (Is-Todo $t)          # saved path missing on this PC -> ask too
    if (-not $canAsk) {
        [System.Windows.MessageBox]::Show("This button isn't set up yet.`nRight-click it > Edit this button to choose what it opens.", 'Launcher') | Out-Null
        return $null
    }
    $found = Find-Detected $btn
    if (-not $found) {
        $why = if (-not (Is-Todo $t)) { "Couldn't find:`n$t`n`nPlease pick it on this PC." } elseif ($btn.askTitle) { $btn.askTitle + '.' } else { 'Please pick the file for this button.' }
        [System.Windows.MessageBox]::Show($why + "`n`nIf you pick the wrong one, right-click the button > Edit this button to change it.", 'Launcher') | Out-Null
        $found = Ask-ForPath $btn $kind
    }
    if ($found) { Set-Prop $btn 'target' $found; Save-Config; return $found }
    return $null
}

function global:Restart-ScreenConnect {
    $res = Join-Path $env:TEMP ("bl-sc-" + [guid]::NewGuid() + '.txt')
    $resQ = $res.Replace("'", "''")   # CC-M5: profile paths like C:\Users\O'Brien
    $script = @"
`$out = @()
`$svcs = Get-Service -DisplayName 'ScreenConnect Client*' -ErrorAction SilentlyContinue
if (-not `$svcs) { `$svcs = Get-Service -Name 'ScreenConnect Client*' -ErrorAction SilentlyContinue }
if (-not `$svcs) { `$out += 'NONE' }
foreach (`$s in `$svcs) { try { Restart-Service -InputObject `$s -Force -ErrorAction Stop; `$out += 'OK|' + `$s.DisplayName } catch { `$out += 'FAIL|' + `$s.DisplayName + '|' + `$_.Exception.Message } }
Set-Content -LiteralPath '$resQ' -Value `$out -Encoding UTF8
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    try { $proc = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" }
    catch { [System.Windows.MessageBox]::Show("ScreenConnect was not restarted.`n(The admin prompt was cancelled.)", 'Restart ScreenConnect') | Out-Null; return $false }
    $timer = New-Object System.Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $start = Get-Date
    $timer.Add_Tick({
        if (-not $proc.HasExited -and ((Get-Date) - $start).TotalSeconds -lt 90) { return }
        $timer.Stop()
        $lines = if (Test-Path $res) { Get-Content $res } else { @('FAIL|ScreenConnect|No result (timed out or blocked).') }
        Remove-Item $res -ErrorAction SilentlyContinue
        if ($lines -contains 'NONE') { $msg = "No ScreenConnect Client service was found on this PC." }
        else {
            $ok = @($lines | Where-Object { $_ -like 'OK|*' } | ForEach-Object { '  OK: ' + $_.Split('|')[1] })
            $bad = @($lines | Where-Object { $_ -like 'FAIL|*' } | ForEach-Object { $x = $_.Split('|'); '  FAILED: ' + $x[1] + ' - ' + $x[2] })
            $msg = if ($bad.Count) { "Some ScreenConnect services did not restart:`n" + (($ok + $bad) -join "`n") } else { "ScreenConnect restarted:`n" + ($ok -join "`n") }
        }
        [System.Windows.MessageBox]::Show($msg, 'Restart ScreenConnect') | Out-Null
    }.GetNewClosure())
    $timer.Start()
    return $true
}

function global:Invoke-Button($btn) {
    $kind = Get-ButtonType $btn
    $cText = [string]$btn.confirm
    if (-not $cText.Trim() -and $kind -eq 'builtin' -and [string]$btn.action -eq 'restart-computer') {
        $cText = 'Restart this computer now? Unsaved work in open programs will be lost.'   # CC-M4/LJ-L3: force restart ALWAYS asks
    }
    if ($cText.Trim()) {
        $cTitle = (([string]$btn.label) -replace "`n", ' ').Trim(); if (-not $cTitle) { $cTitle = 'Please confirm' }
        $r = [System.Windows.MessageBox]::Show($cText, $cTitle, 'YesNo', 'Warning', 'No')   # focus defaults to No
        if ($r -ne 'Yes') { return $false }
    }
    $a = Expand $btn.args
    $verb = if ([bool]$btn.runAsAdmin) { @{ Verb = 'RunAs' } } else { @{} }
    try {
        switch ($kind) {
            'builtin' {
                switch ([string]$btn.action) {
                    'restart-screenconnect' { return (Restart-ScreenConnect) }
                    'restart-computer'      { Start-Process shutdown.exe -ArgumentList '/r /f /t 0' -WindowStyle Hidden; return $true }
                    default { [System.Windows.MessageBox]::Show("This button's built-in action isn't set.", 'Launcher') | Out-Null; return $false }
                }
            }
            'website' {
                $u = Expand $btn.target
                if (Is-Todo $u) { [System.Windows.MessageBox]::Show("This button isn't set up yet.`nRight-click it > Edit this button to add a web address.", 'Launcher') | Out-Null; return $false }
                $u = Get-SafeUrl $u
                if (-not $u) { [System.Windows.MessageBox]::Show("This button's web address isn't allowed.`nWebsite buttons can only open http, https or mailto addresses.`nRight-click it > Edit this button to fix it.", 'Launcher') | Out-Null; return $false }
                Start-Process $u; return $true
            }
            default {
                $path = Resolve-ButtonPath $btn $kind
                if (-not $path) { return $false }
                $wd = if ($path -match '[\\/]') { Split-Path -Parent $path } else { $global:here }
                if ($kind -eq 'script' -and $path -like '*.ps1') {
                    Start-Process powershell.exe -WorkingDirectory $wd @verb -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$path`" $a"
                } elseif ($a) { Start-Process -FilePath $path -ArgumentList $a -WorkingDirectory $wd @verb }
                else { Start-Process -FilePath $path -WorkingDirectory $wd @verb }
                return $true
            }
        }
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'canceled by the user|cancelled') { return $false }
        [System.Windows.MessageBox]::Show("Couldn't open it.`n`n$m", 'Launcher') | Out-Null; return $false
    }
}

function global:Get-IconImage($path) {
    try {
        $p = Expand $path
        if ($p -like 'TODO*' -or -not (Test-Path $p)) { $p = Join-Path $env:SystemRoot 'explorer.exe' }
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($p)
        return [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { return $null }
}


function global:Resolve-Img($path) { if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $global:here $path } }

function global:Get-PicSource($btn, $px) {
    if (-not $btn.image) { return $null }
    if ($btn.image -eq 'icon') { return Get-IconImage $btn.target }
    $p = Resolve-Img $btn.image
    if ($px -and $px -le 48) {   # small spots use "<name>-small.png" when it exists (e.g. Red Dog logo without the wordmark)
        $sm = Join-Path ([IO.Path]::GetDirectoryName($p)) ([IO.Path]::GetFileNameWithoutExtension($p) + '-small' + [IO.Path]::GetExtension($p))
        if (Test-Path -LiteralPath $sm) { $p = $sm }
    }
    if (-not (Test-Path $p)) { return $null }
    try {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        # CC-N2: load from a stream so paths with # or % work
        $fsm = [IO.File]::OpenRead($p)
        try { $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.StreamSource = $fsm; $bi.EndInit(); $bi.Freeze() } finally { $fsm.Dispose() }
        return $bi
    } catch { return $null }
}

# ---------- Modern look (Option B, approved by Charles): flat rounded tiles, Kern palette, Segoe UI Semibold ----------
function global:Get-Color($hex) { [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex) }
function global:Mix-Color($c, $toward, [double]$t) {   # $t of the way from colour $c toward colour $toward
    [System.Windows.Media.Color]::FromArgb($c.A, [byte]($c.R + ($toward.R - $c.R) * $t), [byte]($c.G + ($toward.G - $c.G) * $t), [byte]($c.B + ($toward.B - $c.B) * $t))
}
# Old default fills (and their labels) map to Kern's AA palette at draw time, so an existing buttons.json gets the new look
# without rewriting it. Any other colour the user picked is drawn as-is.
function global:Get-TileColors($btn) {
    $bg = ([string]$btn.bg).Trim().ToUpperInvariant(); if (-not $bg) { $bg = '#4472C4' }
    if ($global:ModernFill.ContainsKey($bg)) { $m = $global:ModernFill[$bg]; return @{ bg = $m[0]; fg = $m[1] } }
    $fg = [string]$btn.fg
    if (-not $fg) { $c = Get-Color $bg; $fg = if ((0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) -gt 150) { '#111111' } else { '#FFFFFF' } }
    return @{ bg = $bg; fg = $fg }
}
function global:Test-DangerButton($btn) {
    if ([string]$btn.group -eq 'danger') { return $true }
    return ((Get-ButtonType $btn) -eq 'builtin' -and [string]$btn.action -in 'restart-screenconnect', 'restart-computer')
}
# Title Case for display only. Stored labels are never rewritten; only ALL-CAPS labels are converted.
function global:Get-DisplayLabel($btn) {
    $raw = ([string]$btn.label) -replace '\\n', "`n"
    $lines = @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (($raw -cmatch '[A-Z]') -and ($raw -cnotmatch '[a-z]')) {
        $small = 'of', 'and', 'the', 'to', 'for', 'in', 'on', 'at', 'or'
        $i = 0   # word position across the whole label, so "OF" on its own line still stays lower case
        $lines = @(foreach ($ln in $lines) {
            $ln = $ln -replace '(?i)\bSCREEN\s+CONNECT\b', 'ScreenConnect'
            (@(foreach ($w in ($ln -split ' ')) {
                $out = if ($w -ceq 'ScreenConnect' -or $global:Acronyms -contains $w) { $w }
                       elseif ($i -gt 0 -and $small -contains $w.ToLowerInvariant()) { $w.ToLowerInvariant() }
                       elseif ($w.Length -gt 0) { $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1).ToLowerInvariant() } else { $w }
                $i++; $out })) -join ' ' })
    }
    $sub = $null
    if ($lines.Count -gt 1 -and $lines[-1] -match '^(?i)version\b') { $sub = $lines[-1]; $lines = @($lines[0..($lines.Count - 2)]) }
    $main = if ((Test-DangerButton $btn) -and $lines.Count -gt 1) { $lines[0] + "`n" + (($lines[1..($lines.Count - 1)]) -join ' ') } else { $lines -join ' ' }
    return @{ main = $main; sub = $sub }
}

function global:New-Label($text, $fg, $size) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = ($text -replace '\\n', "`n"); $tb.Foreground = Brush $fg
    $tb.FontFamily = $global:UiFont; $tb.FontWeight = [System.Windows.FontWeights]::SemiBold; $tb.FontSize = $size
    $tb.LineStackingStrategy = 'BlockLineHeight'; $tb.LineHeight = [Math]::Round($size * 1.2, 1)
    $tb.Tag = [double]$size                                  # design size; Apply-MinFont enforces the floor after scaling
    if ($global:labelSink -ne $null) { [void]$global:labelSink.Add($tb) }
    $tb.TextAlignment = 'Left'; $tb.TextWrapping = 'Wrap'
    $tb.HorizontalAlignment = 'Left'; $tb.VerticalAlignment = 'Center'
    return $tb
}

# Kern-3/UX-6: label floor of 12 DIP (13 for 3+ line labels) on screen, after the panel's scale is applied.
function global:Apply-MinFont($p) {
    if (-not $p.labels) { return }
    $s = [Math]::Max(0.1, [double]$p.scale.ScaleX)
    foreach ($tb in $p.labels) {
        $floor = if (([string]$tb.Text).Split("`n").Count -ge 3) { 13.0 } else { 12.0 }
        $tb.FontSize = [Math]::Max([double]$tb.Tag, $floor / $s)
        $tb.LineHeight = [Math]::Round($tb.FontSize * 1.2, 1)
    }
}

function global:Play-Click {
    if (-not [bool]$global:cfg.clickSound) { return }
    try {
        $wav = Join-Path $global:here 'click.wav'
        if (-not (Test-Path $wav)) { $wav = Join-Path $env:SystemRoot 'Media\Windows Navigation Start.wav' }
        if (Test-Path $wav) { (New-Object System.Media.SoundPlayer $wav).Play() } else { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch {}
}

# All tile motion runs as a WPF Storyboard of 150 ms or less. Nothing waits on it: the launch has already happened.
function global:Start-Anim($target, $prop, $to, [double]$ms, [switch]$Ease, [scriptblock]$OnDone) {
    $a = if ($to -is [System.Windows.Media.Color]) { New-Object System.Windows.Media.Animation.ColorAnimation } else { New-Object System.Windows.Media.Animation.DoubleAnimation }
    $a.To = $to; $a.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds([Math]::Min(150, $ms))
    if ($Ease) { $ce = New-Object System.Windows.Media.Animation.CubicEase; $ce.EasingMode = 'EaseOut'; $a.EasingFunction = $ce }
    $sb = New-Object System.Windows.Media.Animation.Storyboard
    [System.Windows.Media.Animation.Storyboard]::SetTarget($a, $target)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a, (New-Object System.Windows.PropertyPath $prop))
    if ($OnDone) { $sb.Add_Completed($OnDone) }
    [void]$sb.Children.Add($a); $sb.Begin()
}
function global:Start-Flash($flash) {   # launch flash: white 45%, 60 ms in, 240 ms out (starts after Start-Process returned)
    $k = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    [void]$k.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame 0.45, ([System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(60)))))
    [void]$k.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame 0.0, ([System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(300)))))
    $sb = New-Object System.Windows.Media.Animation.Storyboard
    [System.Windows.Media.Animation.Storyboard]::SetTarget($k, $flash)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($k, (New-Object System.Windows.PropertyPath ([System.Windows.UIElement]::OpacityProperty)))
    [void]$sb.Children.Add($k); $sb.Begin()
}

# Missing-program dot (cheap: no shortcut search while drawing; Set up this PC does the full search).
function global:Test-ButtonSetUpQuick($btn) {
    $kind = Get-ButtonType $btn
    if ($kind -notin 'program', 'file', 'script') { return $true }
    $t = Expand $btn.target
    if (-not (Is-Todo $t)) {
        if ($kind -eq 'program' -and $t -notmatch '[\\/]') { return $true }
        if (Test-Path -LiteralPath $t) { return $true }
    }
    if ($btn.detect) { foreach ($pat in @($btn.detect.paths)) { if ($pat -and (Get-ChildItem -Path (Expand $pat) -File -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true } } }
    return $false
}
function global:New-MissingDot($tip) {
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 11; $dot.Height = 11   # 8 px amber + 1.5 px panel-colour ring
    $dot.Fill = Brush $global:Theme.amber; $dot.Stroke = Brush $global:Theme.panel; $dot.StrokeThickness = 1.5
    $dot.HorizontalAlignment = 'Right'; $dot.VerticalAlignment = 'Top'; $dot.Margin = '0,4.5,4.5,0'
    $dot.ToolTip = $tip
    return $dot
}

# Tile content: Set A icon left of the label (or above it on tall half tiles and the restart tiles).
function global:New-Content($btn, $h, $cls, $danger, $fg) {
    $fs = switch ($cls) { 'hero' { 22 } 'full' { 16 } default { 13 } }
    $ipx = switch ($cls) { 'hero' { 40 } 'full' { 32 } default { 24 } }
    $above = $danger -or ($cls -eq 'half' -and $h -gt 80) -or ([string]$btn.imageMode -eq 'above' -and $cls -eq 'half' -and $h -gt 80)
    $lab = Get-DisplayLabel $btn
    $text = New-Object System.Windows.Controls.StackPanel; $text.VerticalAlignment = 'Center'
    $main = New-Label $lab.main $fg $fs; [void]$text.Children.Add($main)
    if ($lab.sub) { $sl = New-Label $lab.sub $fg 11; $sl.Opacity = 0.85; [void]$text.Children.Add($sl) }
    $isRedDog = ([string]$btn.image) -match '(?i)reddog'
    if ($isRedDog -and $cls -eq 'hero') { $ipx = 64 }
    $src = Get-PicSource $btn $ipx
    $missingPic = (-not $src) -and $btn.image -and [string]$btn.image -ne 'icon'
    if ($missingPic) {
        Add-Content -LiteralPath $global:logPath -Value ("{0}  picture not found for '{1}': {2}" -f (Get-Date -Format s), (([string]$btn.label) -replace "`n", ' '), (Resolve-Img ([string]$btn.image))) -ErrorAction SilentlyContinue }
    $icon = $null
    if ($src) {
        if ($danger) {   # Rev 2: red #E5484D icon, drawn through the white Set A picture as a mask
            $icon = New-Object System.Windows.Shapes.Rectangle; $icon.Width = $ipx; $icon.Height = $ipx; $icon.Fill = Brush $global:Theme.restartRed
            $ib = New-Object System.Windows.Media.ImageBrush $src; $ib.Stretch = 'Uniform'; $icon.OpacityMask = $ib
        } else {
            $img = New-Object System.Windows.Controls.Image; $img.Source = $src; $img.Stretch = 'Uniform'; $img.Width = $ipx; $img.Height = $ipx
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
            if ($isRedDog) {   # full-colour Red Dog on a white 8 px plate (its red is under 3:1 on the cyan fill alone)
                $plate = New-Object System.Windows.Controls.Border; $plate.Background = [System.Windows.Media.Brushes]::White
                $plate.CornerRadius = '8'; $plate.Padding = '4'; $plate.Child = $img; $icon = $plate
            } else { $icon = $img }
        }
    }
    $sp = New-Object System.Windows.Controls.StackPanel
    if ($above) {
        $sp.HorizontalAlignment = 'Center'; $sp.VerticalAlignment = 'Center'
        $main.TextAlignment = 'Center'; $main.HorizontalAlignment = 'Center'; if ($lab.sub) { $text.Children[1].TextAlignment = 'Center'; $text.Children[1].HorizontalAlignment = 'Center' }
        if ($icon) { $icon.HorizontalAlignment = 'Center'; $icon.Margin = '0,0,0,6'; [void]$sp.Children.Add($icon) }
    } else {
        $sp.Orientation = 'Horizontal'; $sp.HorizontalAlignment = 'Left'; $sp.VerticalAlignment = 'Center'
        if ($icon) { $icon.VerticalAlignment = 'Center'; $icon.Margin = '0,0,10,0'; [void]$sp.Children.Add($icon) }
        $iconW = if ($icon) { $ipx + 10 + $(if ($isRedDog) { 8 } else { 0 }) } else { 0 }
        $text.MaxWidth = if ($cls -eq 'half') { 109 - $iconW } else { 248 - $iconW }   # 290 panel - 12 padding - 6 gap - 24 tile padding
    }
    [void]$sp.Children.Add($text)
    return @{ el = $sp; missingPic = $missingPic }
}

# One tile: rounded 8 px fill, 1 px top highlight, hover lift + shadow, press, launch flash, 2 px focus ring,
# dashed outline while editing, amber dot when not set up.
function global:New-Tile($p, $btn) {
    $h = if ($btn.height) { [double]$btn.height } else { 80 }
    $h = [Math]::Max(44, $h)                                  # 44 px minimum tile
    $cls = if ($btn.width -eq 'half') { 'half' } elseif ($h -ge 110) { 'hero' } else { 'full' }
    $danger = Test-DangerButton $btn
    $col = Get-TileColors $btn
    $fillHex = if ($danger) { $global:Theme.restartFill } else { $col.bg }
    $fgHex = if ($danger) { '#FFFFFF' } else { $col.fg }
    $base = Get-Color $fillHex
    $hoverC = Mix-Color $base (Get-Color '#FFFFFF') 0.06; $pressC = Mix-Color $base (Get-Color '#000000') 0.08
    $fill = New-Object System.Windows.Media.SolidColorBrush $base

    $wrap = New-Object System.Windows.Controls.Grid; $wrap.Margin = '3'                  # 3 + 3 = Kern's 6 px gap
    $tile = New-Object System.Windows.Controls.Border; $tile.CornerRadius = '8'; $tile.Background = $fill; $tile.Height = $h
    if ($danger) { $tile.BorderBrush = Brush $global:Theme.restartRed; $tile.BorderThickness = '2' }
    $lift = New-Object System.Windows.Media.TranslateTransform 0, 0; $tile.RenderTransform = $lift
    $tile.Cursor = [System.Windows.Input.Cursors]::Hand; $tile.Focusable = $true; $tile.FocusVisualStyle = $null
    $tile.ToolTip = $btn.target
    $g = New-Object System.Windows.Controls.Grid
    $c = New-Content $btn $h $cls $danger $fgHex
    $c.el.Margin = '12,8'; [void]$g.Children.Add($c.el)
    $hl = New-Object System.Windows.Controls.Border; $hl.IsHitTestVisible = $false; $hl.BorderThickness = '0,1,0,0'
    $hl.BorderBrush = Brush '#14FFFFFF'; $hl.CornerRadius = '8,8,0,0'; [void]$g.Children.Add($hl)
    $flash = New-Object System.Windows.Controls.Border; $flash.IsHitTestVisible = $false; $flash.Opacity = 0
    $flash.Background = [System.Windows.Media.Brushes]::White; $flash.CornerRadius = '7'; [void]$g.Children.Add($flash)
    if (-not [bool]$global:cfg.locked) {   # edit mode: 2 px dashed white outline at 60% inside the tile
        $eo = New-Object System.Windows.Shapes.Rectangle; $eo.IsHitTestVisible = $false; $eo.Stroke = Brush '#99FFFFFF'; $eo.StrokeThickness = 2
        $eo.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (,[double[]](4, 3)); $eo.RadiusX = 6; $eo.RadiusY = 6; $eo.Margin = '2'
        [void]$g.Children.Add($eo) }
    if ($c.missingPic) { [void]$g.Children.Add((New-MissingDot ("Picture not found: " + [string]$btn.image))) }
    elseif (-not (Test-ButtonSetUpQuick $btn)) { [void]$g.Children.Add((New-MissingDot 'Not set up on this PC yet')) }
    $g.Background = [System.Windows.Media.Brushes]::Transparent
    $tile.Child = $g
    $ring = New-Object System.Windows.Controls.Border; $ring.IsHitTestVisible = $false; $ring.Margin = '-4'; $ring.CornerRadius = '12'
    $ring.BorderThickness = '2'; $ring.BorderBrush = [System.Windows.Media.Brushes]::White; $ring.Visibility = 'Hidden'
    [void]$wrap.Children.Add($tile); [void]$wrap.Children.Add($ring)

    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 10; $shadow.ShadowDepth = 4; $shadow.Direction = 270; $shadow.Color = [System.Windows.Media.Colors]::Black; $shadow.Opacity = 0
    $st = @{ down = $false }
    $colorProp = [System.Windows.Media.SolidColorBrush]::ColorProperty; $yProp = [System.Windows.Media.TranslateTransform]::YProperty
    $toHover = { $tile.Effect = $shadow
        Start-Anim $lift $yProp -1 120 -Ease; Start-Anim $shadow ([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty) 0.35 120 -Ease
        Start-Anim $fill $colorProp $hoverC 120 -Ease }.GetNewClosure()
    # MB-N1: the shadow fades out, then the effect is removed (only if the pointer didn't come back meanwhile).
    $dropFx = { if (-not $tile.IsMouseOver -and $shadow.Opacity -le 0.001) { $tile.Effect = $null } }.GetNewClosure()
    $toRest = { Start-Anim $lift $yProp 0 120 -Ease; Start-Anim $fill $colorProp $base 120 -Ease
        Start-Anim $shadow ([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty) 0 120 -Ease -OnDone $dropFx }.GetNewClosure()
    $run = {
        $ok = Invoke-Button $btn                   # launch first; the flash never delays it
        if ($ok -eq $true) { Start-Flash $flash } }.GetNewClosure()
    $tile.Add_MouseEnter({ if (-not $st.down) { & $toHover } }.GetNewClosure())
    $tile.Add_MouseLeave({ if (-not $st.down) { & $toRest } }.GetNewClosure())
    $tile.Add_MouseLeftButtonDown({
        $st.down = $true; [void]$tile.CaptureMouse(); $_.Handled = $true
        $tile.Effect = $null; Start-Anim $lift $yProp 0 60; Start-Anim $fill $colorProp $pressC 60
        Play-Click
    }.GetNewClosure())
    $tile.Add_MouseLeftButtonUp({
        if (-not $st.down) { return }
        $st.down = $false; $tile.ReleaseMouseCapture(); $_.Handled = $true
        $pos = $_.GetPosition($tile); $inside = ($pos.X -ge 0 -and $pos.Y -ge 0 -and $pos.X -le $tile.ActualWidth -and $pos.Y -le $tile.ActualHeight)
        if ($inside) { & $toHover; & $run } else { & $toRest }
    }.GetNewClosure())
    $tile.Add_LostMouseCapture({ if ($st.down) { $st.down = $false; & $toRest } }.GetNewClosure())
    $tile.Add_IsKeyboardFocusedChanged({ $ring.Visibility = if ($tile.IsKeyboardFocused) { 'Visible' } else { 'Hidden' } }.GetNewClosure())
    # MB-M1: one launch per key press. Held keys auto-repeat KeyDown, so ignore repeats.
    $tile.Add_KeyDown({ if (($_.Key -eq 'Enter' -or $_.Key -eq 'Space') -and -not $_.IsRepeat) { $_.Handled = $true; Start-Anim $fill $colorProp $pressC 60; & $run; Start-Anim $fill $colorProp $base 120 }
                        elseif ($_.Key -eq 'Enter' -or $_.Key -eq 'Space') { $_.Handled = $true } }.GetNewClosure())
    $tile.Add_MouseRightButtonDown({ [void]$tile.Focus() }.GetNewClosure())
    $tile.ContextMenu = Button-Menu $p $btn
    if ($btn.width -eq 'half') { $wrap.Tag = 'half' } else { $wrap.Tag = 'full' }
    return $wrap
}

function global:Pick-Color($current) {
    $d = New-Object System.Windows.Forms.ColorDialog; $d.FullOpen = $true
    try { $d.Color = [System.Drawing.ColorTranslator]::FromHtml($current) } catch {}
    if ($d.ShowDialog() -eq 'OK') { return ('#{0:X2}{1:X2}{2:X2}' -f $d.Color.R, $d.Color.G, $d.Color.B) }
    return $current
}

function global:Set-Prop($o, $name, $val) {
    if ($o.PSObject.Properties[$name]) { $o.$name = $val } else { $o | Add-Member -NotePropertyName $name -NotePropertyValue $val }
}

# ---------- edit dialog ----------
function global:Edit-Button($btn) {
    $d = New-Object System.Windows.Window
    $d.Title = 'Edit button'; $d.Width = 520; $d.SizeToContent = 'Height'; $d.WindowStartupLocation = 'CenterScreen'; $d.Topmost = $true
    $g = New-Object System.Windows.Controls.Grid; $g.Margin = '10'
    $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = 120 })) | Out-Null
    $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) | Out-Null
    $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' })) | Out-Null
    $rows = @{}
    function AddRow($key, $caption, $ctrl, $extra) {
        $i = $g.RowDefinitions.Count
        $g.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' })) | Out-Null
        $l = New-Object System.Windows.Controls.Label; $l.Content = $caption
        [System.Windows.Controls.Grid]::SetRow($l, $i); $g.Children.Add($l) | Out-Null
        $ctrl.Margin = '2'; [System.Windows.Controls.Grid]::SetRow($ctrl, $i); [System.Windows.Controls.Grid]::SetColumn($ctrl, 1); $g.Children.Add($ctrl) | Out-Null
        if ($extra) { $extra.Margin = '2'; [System.Windows.Controls.Grid]::SetRow($extra, $i); [System.Windows.Controls.Grid]::SetColumn($extra, 2); $g.Children.Add($extra) | Out-Null }
        $rows[$key] = @($l, $ctrl, $extra) | Where-Object { $_ }
        return $l
    }
    function TB($v) { $t = New-Object System.Windows.Controls.TextBox; $t.Text = [string]$v; $t }
    function Btn($txt) { $b = New-Object System.Windows.Controls.Button; $b.Content = $txt; $b.Padding = '6,0'; $b }
    function Combo($items, $sel) { $c = New-Object System.Windows.Controls.ComboBox; foreach ($x in $items) { [void]$c.Items.Add($x) }; $c.SelectedItem = $sel; $c }

    # --- What it does (Type first) ---
    $types = [ordered]@{ program = 'Program'; website = 'Website'; file = 'File / PDF'; script = 'Script'; builtin = 'Built-in action' }
    $cType = Combo @($types.Values) $types[(Get-ButtonType $btn)]; $cType.FontWeight = 'Bold'
    [void](AddRow 'type' 'Type' $cType $null)
    $tT = TB $btn.target; $bBrowse = Btn 'Browse...'; $bTest = Btn 'Test'
    $tLbl = AddRow 'target' 'Path' $tT $bBrowse
    $tUrl = TB $btn.target; [void](AddRow 'url' 'Web address' $tUrl $bTest)
    $bTest.Add_Click({ if (-not $tUrl.Text.Trim()) { return }; $u = Get-SafeUrl $tUrl.Text
        if ($u) { try { Start-Process $u } catch {} } else { [System.Windows.MessageBox]::Show('Only http, https or mailto addresses can be opened.', 'Test') | Out-Null } }.GetNewClosure())
    $tA = TB $btn.args; $tA.ToolTip = 'Optional, e.g. a host:port for VNC'; [void](AddRow 'args' 'Arguments' $tA $null)
    $chAdmin = New-Object System.Windows.Controls.CheckBox; $chAdmin.Content = 'Run as admin (Windows will ask)'; $chAdmin.IsChecked = [bool]$btn.runAsAdmin
    [void](AddRow 'admin' '' $chAdmin $null)
    $actions = [ordered]@{ 'restart-screenconnect' = 'Restart ScreenConnect service'; 'restart-computer' = 'Restart computer (force)' }
    $cAct = Combo @($actions.Values) $(if ($btn.action -and $actions[[string]$btn.action]) { $actions[[string]$btn.action] } else { $actions['restart-computer'] })
    [void](AddRow 'action' 'Action' $cAct $null)
    $tC = TB $btn.confirm; $tC.ToolTip = 'Optional. If filled in, asks Yes/No (No is the default) before running. Restart computer always asks, even when blank.'
    [void](AddRow 'confirm' 'Ask first (Yes/No)' $tC $null)
    $bBrowse.Add_Click({
        $k = ($types.GetEnumerator() | Where-Object { $_.Value -eq $cType.SelectedItem }).Key
        $p = Ask-ForPath ([pscustomobject]@{ label = $btn.label; askTitle = $null; askFilter = $(if ($k -eq 'file') { 'Documents|*.pdf;*.doc;*.docx;*.xlsx;*.txt|All files|*.*' } else { $null }) }) $k
        if ($p) { $tT.Text = $p } }.GetNewClosure())
    $show = {
        $k = ($types.GetEnumerator() | Where-Object { $_.Value -eq $cType.SelectedItem }).Key
        $vis = @{ target = $k -in 'program','file','script'; url = $k -eq 'website'; args = $k -in 'program','script'; admin = $k -in 'program','script'; action = $k -eq 'builtin' }
        foreach ($r in $vis.Keys) { foreach ($c in $rows[$r]) { $c.Visibility = $(if ($vis[$r]) { 'Visible' } else { 'Collapsed' }) } }
        $tLbl.Content = switch ($k) { 'program' { 'Program' } 'file' { 'File' } 'script' { 'Script' } default { 'Path' } }
    }.GetNewClosure()
    $cType.Add_SelectionChanged($show)

    # --- Look ---
    $sep = New-Object System.Windows.Controls.Separator; [void](AddRow 'sep' '' $sep $null)
    $tLabel = TB ($([string]$btn.label) -replace "`n", '\n'); $tLabel.ToolTip = 'Use \n for a new line'
    [void](AddRow 'label' 'Label' $tLabel $null)
    $tBg = TB $btn.bg; $bBg = Btn 'Pick...'; $bBg.Add_Click({ $tBg.Text = Pick-Color $tBg.Text }.GetNewClosure()); [void](AddRow 'bg' 'Background' $tBg $bBg)
    $tFg = TB $btn.fg; $bFg = Btn 'Pick...'; $bFg.Add_Click({ $tFg.Text = Pick-Color $tFg.Text }.GetNewClosure()); [void](AddRow 'fg' 'Text color' $tFg $bFg)
    $tH = TB $btn.height; [void](AddRow 'h' 'Height' $tH $null)
    $tFs = TB $btn.fontSize; [void](AddRow 'fs' 'Font size' $tFs $null)
    $cW = Combo @('full','half') $(if ($btn.width -eq 'half') { 'half' } else { 'full' }); [void](AddRow 'w' 'Width' $cW $null)
    $tI = TB $btn.image; $tI.ToolTip = 'Blank = none, "icon" = the target''s own icon, or a picture file'
    $bI = Btn 'Picture...'
    $bI.Add_Click({
        $o = New-Object System.Windows.Forms.OpenFileDialog; $o.Filter = 'Pictures|*.png;*.jpg;*.jpeg;*.ico;*.bmp;*.gif'
        if ($o.ShowDialog() -eq 'OK') {
            $dir = Join-Path $global:here 'images'; if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
            $fn = [IO.Path]::GetFileName($o.FileName); $dest = Join-Path $dir $fn
            if ($o.FileName -ne $dest) {
                # CC-L3: never overwrite a different picture with the same name; add -1, -2, ...
                $base = [IO.Path]::GetFileNameWithoutExtension($fn); $ext = [IO.Path]::GetExtension($fn); $i = 0
                while ((Test-Path -LiteralPath $dest) -and ((Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath $o.FileName).Hash)) {
                    $i++; $fn = "$base-$i$ext"; $dest = Join-Path $dir $fn }
                if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $o.FileName -Destination $dest }
            }
            $tI.Text = 'images/' + $fn } }.GetNewClosure())
    [void](AddRow 'img' 'Picture' $tI $bI)
    $bIco = Btn 'Use icon'; $bIco.Add_Click({ $tI.Text = 'icon' }.GetNewClosure())
    $cM = Combo @('left','above','only','background') $(if ($btn.imageMode) { $btn.imageMode } else { 'left' }); [void](AddRow 'mode' 'Picture spot' $cM $bIco)
    & $show

    $ok = Btn 'Save'; $ok.IsDefault = $true; $cancel = Btn 'Cancel'; $cancel.IsCancel = $true
    $bar = New-Object System.Windows.Controls.StackPanel; $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.Margin = '10'
    $bar.Children.Add($ok) | Out-Null; $bar.Children.Add($cancel) | Out-Null
    $outer = New-Object System.Windows.Controls.StackPanel; $outer.Children.Add($g) | Out-Null; $outer.Children.Add($bar) | Out-Null
    $d.Content = $outer
    $ok.Add_Click({ $d.DialogResult = $true }.GetNewClosure())
    if (-not $d.ShowDialog()) { return $false }

    $k = 'program'; foreach ($e in $types.GetEnumerator()) { if ($e.Value -eq $cType.SelectedItem) { $k = $e.Key } }
    Set-Prop $btn 'type' $k
    if ($k -eq 'website') { Set-Prop $btn 'target' $tUrl.Text }
    elseif ($k -ne 'builtin') { Set-Prop $btn 'target' $tT.Text }
    if ($k -eq 'builtin') { foreach ($e in $actions.GetEnumerator()) { if ($e.Value -eq $cAct.SelectedItem) { Set-Prop $btn 'action' $e.Key } } }
    Set-Prop $btn 'args' $tA.Text; Set-Prop $btn 'runAsAdmin' ([bool]$chAdmin.IsChecked); Set-Prop $btn 'confirm' $tC.Text
    Set-Prop $btn 'label' ($tLabel.Text -replace '\\n', "`n")
    Set-Prop $btn 'bg' $tBg.Text; Set-Prop $btn 'fg' $tFg.Text
    $n = 0; if ([double]::TryParse($tH.Text, [ref]$n)) { Set-Prop $btn 'height' $n }
    if ([double]::TryParse($tFs.Text, [ref]$n)) { Set-Prop $btn 'fontSize' $n }
    Set-Prop $btn 'width' $cW.SelectedItem; Set-Prop $btn 'image' $tI.Text; Set-Prop $btn 'imageMode' $cM.SelectedItem
    return $true
}

# ---------- UX-2a: "Set up this PC" - pick every missing program/file once, right after install ----------
function global:Test-ButtonReady($btn) {
    $kind = Get-ButtonType $btn
    if ($kind -notin 'program', 'file', 'script') { return $true }
    $t = Expand $btn.target
    if (-not (Is-Todo $t)) {
        if (Test-Path -LiteralPath $t) { return $true }
        if ($kind -eq 'program' -and $t -notmatch '[\\/]') { return $true }
    }
    $found = Find-Detected $btn
    if ($found) { Set-Prop $btn 'target' $found; return $true }
    return $false
}

function global:Show-SetupWindow([switch]$OnlyIfNeeded) {
    $todo = @()
    foreach ($p in $global:panels) { foreach ($b in $p.items) { if (-not (Test-ButtonReady $b)) { $todo += $b } } }
    Save-Config   # keeps anything Find-Detected just found
    if ($OnlyIfNeeded -and $todo.Count -eq 0) { return }
    $d = New-Object System.Windows.Window; $d.Title = 'Set up this PC'; $d.SizeToContent = 'WidthAndHeight'; $d.WindowStartupLocation = 'CenterScreen'
    $d.Topmost = $true; $d.ResizeMode = 'NoResize'
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '14'
    $hd = New-Object System.Windows.Controls.TextBlock; $hd.FontSize = 14; $hd.TextWrapping = 'Wrap'; $hd.MaxWidth = 460; $hd.Margin = '0,0,0,10'
    $hd.Text = if ($todo.Count) { "These buttons need a program or file on this PC. Click Pick... for each one. You can also do this later: right-click a panel (unlocked) > Set up this PC..." } else { 'Every button is set up on this PC.' }
    [void]$sp.Children.Add($hd)
    foreach ($b in $todo) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,3'
        $pick = New-Object System.Windows.Controls.Button; $pick.Content = 'Pick...'; $pick.Padding = '10,2'; $pick.Margin = '10,0,0,0'
        [System.Windows.Controls.DockPanel]::SetDock($pick, 'Right'); [void]$row.Children.Add($pick)
        $st = New-Object System.Windows.Controls.TextBlock; $st.Width = 90; $st.Text = 'Needs setup'; $st.Foreground = Brush '#B06000'; $st.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($st, 'Right'); [void]$row.Children.Add($st)
        $nm = New-Object System.Windows.Controls.TextBlock; $nm.Text = (([string]$b.label) -replace "`n", ' '); $nm.FontWeight = 'Bold'; $nm.VerticalAlignment = 'Center'; $nm.MinWidth = 240
        [void]$row.Children.Add($nm)
        $pick.Add_Click({
            $f = Ask-ForPath $b (Get-ButtonType $b)
            if ($f) { Set-Prop $b 'target' $f; Save-Config; $st.Text = 'Done'; $st.Foreground = Brush '#0B7A4A' }
        }.GetNewClosure())
        [void]$sp.Children.Add($row)
    }
    $close = New-Object System.Windows.Controls.Button; $close.Content = 'Close'; $close.Padding = '14,3'; $close.HorizontalAlignment = 'Right'; $close.Margin = '0,12,0,0'; $close.IsCancel = $true
    $close.Add_Click({ $d.Close() }.GetNewClosure()); [void]$sp.Children.Add($close)
    $d.Content = $sp; [void]$d.ShowDialog()
}

# ---------- config + layout: anchors are relative, so they work at any resolution / scaling ----------
function global:Save-Config {
    foreach ($p in $global:panels) { Set-Prop $p.cfg 'buttons' @($p.items.ToArray()) }
    if (-not $global:single) { $global:cfg.panels = @($global:panels | ForEach-Object { $_.cfg }) }   # single: panels 3+ stay as they are
    if ($global:middle) { if (-not $global:cfg.middle) { Set-Prop $global:cfg 'middle' ([pscustomobject]@{ columns = $global:middle.cols; items = @() }) }
                          Set-Prop $global:cfg.middle 'items' @($global:middle.items.ToArray()) }
    $json = $global:cfg | ConvertTo-Json -Depth 12
    # CC-M2: write to a temp file, then swap it in and keep the previous copy as buttons.json.bak
    $tmp = $global:cfgPath + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $global:cfgPath) { [IO.File]::Replace($tmp, $global:cfgPath, $global:cfgPath + '.bak') }
    else { [IO.File]::Move($tmp, $global:cfgPath) }
}

function global:Get-Screen($pc) {
    $all = [System.Windows.Forms.Screen]::AllScreens
    $i = if ($pc.monitor -ne $null) { [int]$pc.monitor } else { -1 }
    if ($i -ge 0 -and $i -lt $all.Count) { return $all[$i] }
    return [System.Windows.Forms.Screen]::PrimaryScreen
}

function global:Get-WorkArea($screen) {
    # Physical pixels; excludes a normal taskbar wherever it is. Auto-hide taskbars reserve
    # nothing, so leave a small strip on that edge so the panel never covers it.
    $wa = $screen.WorkingArea
    $r = @{ L = $wa.Left; T = $wa.Top; R = $wa.Right; B = $wa.Bottom }
    try {
        $d = New-Object BL.Native+APPBARDATA; $d.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($d)
        $state = [BL.Native]::SHAppBarMessage(4, [ref]$d).ToUInt32()          # ABM_GETSTATE
        if ($state -band 1) {                                                   # ABS_AUTOHIDE
            [void][BL.Native]::SHAppBarMessage(5, [ref]$d)                      # ABM_GETTASKBARPOS
            $tb = $d.rc; $b = $screen.Bounds
            if ($tb.Left -lt $b.Right -and $tb.Right -gt $b.Left -and $tb.Top -lt $b.Bottom -and $tb.Bottom -gt $b.Top) {
                switch ($d.edge) { 0 { $r.L += 4 } 1 { $r.T += 4 } 2 { $r.R -= 4 } 3 { $r.B -= 4 } }
            }
        }
    } catch {}
    $r.W = $r.R - $r.L; $r.H = $r.B - $r.T
    return $r
}

function global:Get-Dpi($p) { try { $d = [BL.Native]::GetDpiForWindow($p.hwnd); if ($d -gt 0) { return $d / 96.0 } } catch {}; return 1.0 }

function global:Layout-Panel($p) {
    if ($p.single) { Layout-Single; return }
    if (-not $p.hwnd -or $p.hwnd -eq [IntPtr]::Zero -or -not $p.win.IsVisible) { return }
    $pc = $p.cfg
    $wa = Get-WorkArea (Get-Screen $pc)
    $dpi = Get-Dpi $p
    $pct = if ($pc.size -is [string] -and $global:SizePct[[string]$pc.size]) { $global:SizePct[[string]$pc.size] } elseif ($pc.size) { [double]$pc.size } else { 14 }
    $minW = if ($pc.minWidth) { [double]$pc.minWidth } else { 180 }      # DIPs (scaled by Windows display scaling)
    $maxW = if ($pc.maxWidth) { [double]$pc.maxWidth } else { 560 }
    $wDip = [Math]::Max($minW, [Math]::Min($maxW, ($wa.W * $pct / 100.0) / $dpi))
    $s = $wDip / $global:BaseWidth
    $p.scale.ScaleX = $s; $p.scale.ScaleY = $s; Apply-MinFont $p
    $p.win.UpdateLayout()
    $hPx = $p.win.ActualHeight * $dpi
    $maxH = $wa.H
    if ($hPx -gt $maxH) { $s = $s * $maxH / $hPx; $p.scale.ScaleX = $s; $p.scale.ScaleY = $s; Apply-MinFont $p; $p.win.UpdateLayout() }
    # Use the window's real device-pixel size (no DIP rounding guesses)
    $wPx = [int][Math]::Round($p.win.ActualWidth * $dpi); $hPx = [int][Math]::Round($p.win.ActualHeight * $dpi)
    $rr = New-Object BL.Native+RECT
    if ([BL.Native]::GetWindowRect($p.hwnd, [ref]$rr) -and ($rr.Right - $rr.Left) -gt 0) {
        $rw = $rr.Right - $rr.Left; $rh = $rr.Bottom - $rr.Top
        if ([Math]::Abs($rw - $wPx) -le 3 -and [Math]::Abs($rh - $hPx) -le 3) { $wPx = $rw; $hPx = $rh }
    }
    $gap = if ($pc.gap) { [double]$pc.gap * $dpi } else { 0 }
    $anc = if ($pc.anchor) { [string]$pc.anchor } else { 'middle-right' }
    $ox = [Math]::Round([double]$pc.offsetX / 100.0 * $wa.W + $gap); $oy = [Math]::Round([double]$pc.offsetY / 100.0 * $wa.H + $gap)
    $x = if ($anc -like '*left*') { $wa.L + $ox } elseif ($anc -like '*right*') { $wa.R - $wPx - $ox } else { $wa.L + ($wa.W - $wPx) / 2 + $ox }
    $y = if ($anc -like 'top*') { $wa.T + $oy } elseif ($anc -like 'bottom*') { $wa.B - $hPx - $oy } else { $wa.T + ($wa.H - $hPx) / 2 + $oy }
    $x = [Math]::Round([Math]::Max($wa.L, [Math]::Min($x, $wa.R - $wPx))); $y = [Math]::Round([Math]::Max($wa.T, [Math]::Min($y, $wa.B - $hPx)))
    [void][BL.Native]::SetWindowPos($p.hwnd, [IntPtr]::Zero, [int]$x, [int]$y, 0, 0, 0x0015)   # NOSIZE|NOZORDER|NOACTIVATE
}

function global:Snap-Anchor($p) {
    # After a drag: nearest edge/corner on the panel's monitor; offsets saved as % of work area.
    $r = New-Object BL.Native+RECT; [void][BL.Native]::GetWindowRect($p.hwnd, [ref]$r)
    $scr = [System.Windows.Forms.Screen]::FromHandle($p.hwnd)
    $all = [System.Windows.Forms.Screen]::AllScreens
    $idx = [Array]::IndexOf($all, $scr); if ($scr.Primary) { $idx = -1 }
    $wa = Get-WorkArea $scr
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $dl = $r.Left - $wa.L; $dr = $wa.R - $r.Right; $dc = ($r.Left + $w / 2) - ($wa.L + $wa.W / 2)
    $dt = $r.Top - $wa.T;  $db = $wa.B - $r.Bottom; $dm = ($r.Top + $h / 2) - ($wa.T + $wa.H / 2)
    if ([Math]::Abs($dc) -lt [Math]::Min($dl, $dr)) { $hz = 'center'; $ox = $dc } elseif ($dl -le $dr) { $hz = 'left'; $ox = $dl } else { $hz = 'right'; $ox = $dr }
    if ([Math]::Abs($dm) -lt [Math]::Min($dt, $db)) { $vt = 'middle'; $oy = $dm } elseif ($dt -le $db) { $vt = 'top'; $oy = $dt } else { $vt = 'bottom'; $oy = $db }
    $oxp = [Math]::Round(100.0 * $ox / $wa.W, 2); $oyp = [Math]::Round(100.0 * $oy / $wa.H, 2)
    if ([Math]::Abs($oxp) -lt 3) { $oxp = 0 }; if ([Math]::Abs($oyp) -lt 3) { $oyp = 0 }   # within 3% = flush (offset exactly 0)
    $anc = if ($hz -eq 'center' -and $vt -eq 'middle') { 'center' } elseif ($hz -eq 'center') { "$vt-center" } else { "$vt-$hz" }
    Set-Prop $p.cfg 'anchor' $anc; Set-Prop $p.cfg 'offsetX' $oxp; Set-Prop $p.cfg 'offsetY' $oyp; Set-Prop $p.cfg 'monitor' $idx
    Save-Config; Layout-Panel $p
}

function global:Apply-Lock {
    $locked = [bool]$global:cfg.locked
    foreach ($p in $global:panels) { Build-Panel $p }   # UX-1: menus differ when locked, so rebuild them
    if ($global:single) { Build-Middle; $global:single.win.ShowInTaskbar = -not $locked }
    foreach ($p in $global:panels) {
        $p.grip.Visibility = if ($locked) { 'Collapsed' } else { 'Visible' }
        if ($p.hwnd -and $p.hwnd -ne [IntPtr]::Zero) {
            # Locked: tool window = no taskbar button, not in Alt+Tab
            $ex = [BL.Native]::GetWindowLongPtr($p.hwnd, -20).ToInt64()
            $ex = if ($locked) { ($ex -bor 0x80) -band (-bnot 0x40000) } else { ($ex -band (-bnot 0x80)) -bor 0x40000 }
            [void][BL.Native]::SetWindowLongPtr($p.hwnd, -20, [IntPtr]$ex)
            [void][BL.Native]::SetWindowPos($p.hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0037)   # FRAMECHANGED|NOMOVE|NOSIZE|NOZORDER|NOACTIVATE
        }
        Layout-Panel $p
    }
}

function global:Request-Relayout {
    # Debounce: Windows sends several messages for one change (resolution, DPI, taskbar, wake...)
    if ($global:relayoutTimer) { $global:relayoutTimer.Stop(); $global:relayoutTimer.Start() }
}

function global:New-DefaultButton {
    [pscustomobject]@{ label = 'NEW BUTTON'; bg = '#4472C4'; fg = '#FFFFFF'; width = 'full'; height = 80; fontSize = 20
                       type = 'program'; target = 'TODO: set a target'; args = ''; image = ''; imageMode = 'left' }
}

function global:Add-MenuItem($menu, $text, $action) {
    $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $text; $mi.Add_Click($action); [void]$menu.Items.Add($mi); return $mi
}

# UX-1: while locked, right-click offers only "Unlock to edit..." and "Close this panel".
function global:Locked-Menu($p, $menu) {
    [void](Add-MenuItem $menu 'Unlock to edit...' { $global:cfg.locked = $false; Save-Config; Apply-Lock })
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    [void](Add-MenuItem $menu 'Close this panel' { $p.win.Close() }.GetNewClosure())
}

# Menu tidy (Option B): everyday items, then edit items, then a Setup submenu, then the Close items.
# Locked: only Unlock and Close (Locked-Menu).
function global:Panel-Menu($p, $menu) {
    if ([bool]$global:cfg.locked) { Locked-Menu $p $menu; return }
    # everyday
    $lk = Add-MenuItem $menu 'Lock panels' { $global:cfg.locked = -not [bool]$global:cfg.locked; Save-Config; Apply-Lock }
    $lk.IsCheckable = $true; $lk.IsChecked = [bool]$global:cfg.locked
    $top = Add-MenuItem $menu 'Always on top' { $p.cfg.alwaysOnTop = -not [bool]$p.cfg.alwaysOnTop; $p.win.Topmost = [bool]$p.cfg.alwaysOnTop; Save-Config }.GetNewClosure()
    $top.IsCheckable = $true; $top.IsChecked = [bool]$p.cfg.alwaysOnTop
    $sz = New-Object System.Windows.Controls.MenuItem; $sz.Header = 'Size'
    foreach ($nm in 'Small','Medium','Large') {
        $si = Add-MenuItem $sz $nm { $p.cfg.size = $nm; Save-Config; Build-Panel $p; Layout-Panel $p }.GetNewClosure()
        $si.IsCheckable = $true; $si.IsChecked = ([string]$p.cfg.size -eq $nm) }
    [void]$menu.Items.Add($sz)
    $mon = New-Object System.Windows.Controls.MenuItem; $mon.Header = 'Monitor'
    $si = Add-MenuItem $mon 'Main monitor' { $p.cfg.monitor = -1; Save-Config; Layout-Panel $p }.GetNewClosure(); $si.IsCheckable = $true; $si.IsChecked = ([int]$p.cfg.monitor -lt 0)
    $all = [System.Windows.Forms.Screen]::AllScreens
    for ($k = 0; $k -lt $all.Count; $k++) { $kk = $k
        $si = Add-MenuItem $mon ("Monitor {0} ({1}x{2})" -f ($k + 1), $all[$k].Bounds.Width, $all[$k].Bounds.Height) { $p.cfg.monitor = $kk; Save-Config; Layout-Panel $p }.GetNewClosure()
        $si.IsCheckable = $true; $si.IsChecked = ([int]$p.cfg.monitor -eq $k) }
    [void]$menu.Items.Add($mon)
    $as = Add-MenuItem $menu 'Start with Windows' { Set-Autostart (-not (Get-Autostart)) }
    $as.IsCheckable = $true; $as.IsChecked = (Get-Autostart)
    $cs = Add-MenuItem $menu 'Click sound' { $global:cfg.clickSound = -not [bool]$global:cfg.clickSound; Save-Config }
    $cs.IsCheckable = $true; $cs.IsChecked = [bool]$global:cfg.clickSound
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    # edit
    [void](Add-MenuItem $menu 'Add new button at end...' { $nb = New-DefaultButton; if (Edit-Button $nb) { [void]$p.items.Add($nb); Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure())
    [void](Add-MenuItem $menu 'Rename panel...' { $n = [Microsoft.VisualBasic.Interaction]::InputBox('Panel name:', 'Rename panel', $p.cfg.name); if ($n) { $p.cfg.name = $n; $p.win.Title = $n; Save-Config } }.GetNewClosure())
    if ($global:single) { [void](Add-MenuItem $menu 'Add icon to the middle...' { Add-ChipFromMenu }) }
    if (-not $global:single) { [void](Add-MenuItem $menu 'Add new panel...' { New-PanelFromMenu }.GetNewClosure()) }
    if (-not $global:single) { [void](Add-MenuItem $menu 'Delete this panel...' {
        if ([System.Windows.MessageBox]::Show("Delete the panel ""$($p.cfg.name)"" and all its buttons?", 'Launcher', 'YesNo', 'Warning', 'No') -eq 'Yes') {
            $global:panels.Remove($p); $p.deleted = $true; Save-Config; $p.win.Close()
            foreach ($o in $global:panels) { Build-Panel $o } } }.GetNewClosure()) }   # CC-L5: drop the deleted panel from Move menus
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    # Setup submenu: 44 px item with a 12 px #A0A0A0 second line
    $setup = New-Object System.Windows.Controls.MenuItem; $setup.MinHeight = 44
    $hs = New-Object System.Windows.Controls.StackPanel
    $h1 = New-Object System.Windows.Controls.TextBlock; $h1.Text = 'Setup'
    $h2 = New-Object System.Windows.Controls.TextBlock; $h2.Text = 'PC setup, panels, installer'; $h2.FontSize = 12; $h2.Foreground = Brush '#A0A0A0'
    [void]$hs.Children.Add($h1); [void]$hs.Children.Add($h2); $setup.Header = $hs
    [void](Add-MenuItem $setup 'Set up this PC...' { Show-SetupWindow })
    [void](Add-MenuItem $setup 'Build installer...' { Save-Config; Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $global:here 'Build-Installer.ps1')`"" })
    [void](Add-MenuItem $setup 'Edit buttons.json in Notepad' { Start-Process notepad.exe "`"$global:cfgPath`"" })
    $lay = New-Object System.Windows.Controls.MenuItem; $lay.Header = 'Layout'
    foreach ($opt in @(@('two', 'Two panels'), @('single', 'One panel, docked to the edge'))) { $val = $opt[0]
        $li = Add-MenuItem $lay $opt[1] { Set-Prop $global:cfg 'layout' $val; Save-Config
            [System.Windows.MessageBox]::Show('Saved. Choose Setup > Reload to switch the layout.', 'Launcher') | Out-Null }.GetNewClosure()
        $li.IsCheckable = $true; $li.IsChecked = ((Get-LayoutMode $global:cfg) -eq $val) }
    [void]$setup.Items.Add($lay)
    $sq = Add-MenuItem $setup 'Square panel corners (for slow PCs)' { Set-Prop $global:cfg 'squarePanels' (-not [bool]$global:cfg.squarePanels); Save-Config
        [System.Windows.MessageBox]::Show('Saved. Choose Setup > Reload to apply it.', 'Launcher') | Out-Null }
    $sq.IsCheckable = $true; $sq.IsChecked = [bool]$global:cfg.squarePanels
    [void](Add-MenuItem $setup 'Reload' { Save-Config   # CC-M3: the new copy waits on the mutex until this one has saved and exited
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$(Join-Path $global:here 'Launcher.ps1')`" -Reload"
        $global:app.Shutdown() })
    [void]$menu.Items.Add($setup)
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    # close
    [void](Add-MenuItem $menu 'Close this panel' { $p.win.Close() }.GetNewClosure())
    [void](Add-MenuItem $menu 'Close all' { $global:app.Shutdown() })
}

function global:Button-Menu($p, $btn) {
    $m = New-Object System.Windows.Controls.ContextMenu
    if ([bool]$global:cfg.locked) { Locked-Menu $p $m; return $m }
    [void](Add-MenuItem $m 'Edit this button...' { if (Edit-Button $btn) { Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure())
    [void](Add-MenuItem $m 'Move up' { $i = $p.items.IndexOf($btn); if ($i -gt 0) { $p.items.RemoveAt($i); $p.items.Insert($i - 1, $btn); Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure())
    [void](Add-MenuItem $m 'Move down' { $i = $p.items.IndexOf($btn); if ($i -lt $p.items.Count - 1) { $p.items.RemoveAt($i); $p.items.Insert($i + 1, $btn); Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure())
    $mv = New-Object System.Windows.Controls.MenuItem; $mv.Header = 'Move button to other panel'
    foreach ($o in $global:panels) {
        if ($o -eq $p) { continue }
        [void](Add-MenuItem $mv $o.cfg.name { $p.items.Remove($btn); [void]$o.items.Add($btn); Save-Config; Build-Panel $p; Build-Panel $o; Layout-Panel $p; Layout-Panel $o }.GetNewClosure())
    }
    $mv.IsEnabled = $mv.Items.Count -gt 0; [void]$m.Items.Add($mv)
    [void](Add-MenuItem $m 'Add new button below...' { $nb = New-DefaultButton; if (Edit-Button $nb) { $p.items.Insert($p.items.IndexOf($btn) + 1, $nb); Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure())
    [void](Add-MenuItem $m 'Delete this button' { $dn = (([string]$btn.label) -replace "`n", ' ').Trim(); if (-not $dn) { $dn = 'this' }
        if ([System.Windows.MessageBox]::Show("Delete the $dn button? This can't be undone.", 'Delete button', 'YesNo', 'Warning', 'No') -eq 'Yes') { $p.items.Remove($btn); Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure())
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    Panel-Menu $p $m
    return $m
}

function global:Add-TileRows($p, $target, $list) {
    $pendingHalf = $null
    foreach ($btn in $list) {
        $el = New-Tile $p $btn
        if ($btn.width -eq 'half') {
            if ($pendingHalf) { [System.Windows.Controls.Grid]::SetColumn($el, 1); [void]$pendingHalf.Children.Add($el); $pendingHalf = $null }
            else {
                $g = New-Object System.Windows.Controls.Grid
                [void]$g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                [void]$g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                [void]$g.Children.Add($el); [void]$target.Children.Add($g); $pendingHalf = $g
            }
        } else { $pendingHalf = $null; [void]$target.Children.Add($el) }
    }
}

function global:Build-Panel($p) {
    $stack = $p.stack; $stack.Children.Clear()
    $global:labelSink = New-Object System.Collections.ArrayList
    $normal = @($p.items | Where-Object { -not (Test-DangerButton $_) })
    $danger = @($p.items | Where-Object { Test-DangerButton $_ })
    Add-TileRows $p $stack $normal
    if ($danger.Count) {   # Restarts: grouped at the very bottom, 12 px gap, caption, red-tinted outlined group
        $cap = New-Object System.Windows.Controls.TextBlock; $cap.Text = 'Restarts'; $cap.FontFamily = $global:UiFont
        $cap.FontWeight = [System.Windows.FontWeights]::SemiBold; $cap.FontSize = 12; $cap.Tag = [double]12; $cap.Foreground = Brush '#A0A0A0'
        $cap.Margin = $(if ($normal.Count) { '6,12,0,2' } else { '6,0,0,2' }); [void]$global:labelSink.Add($cap); [void]$stack.Children.Add($cap)
        $dz = New-Object System.Windows.Controls.Border; $dz.CornerRadius = '10'; $dz.Padding = '0'
        $dz.Background = Brush '#24B3261E'; $dz.BorderBrush = Brush '#73B3261E'; $dz.BorderThickness = '1'
        $inner = New-Object System.Windows.Controls.StackPanel; $dz.Child = $inner
        Add-TileRows $p $inner $danger
        [void]$stack.Children.Add($dz)
    }
    if ($p.items.Count -eq 0) {
        $e = New-Object System.Windows.Controls.TextBlock; $e.Text = 'Empty panel - right-click to add a button'; $e.Foreground = Brush '#AAAAAA'
        $e.FontFamily = $global:UiFont; $e.Margin = '10,20'; $e.TextWrapping = 'Wrap'; [void]$stack.Children.Add($e)
    }
    $p.labels = $global:labelSink; $global:labelSink = $null; Apply-MinFont $p
    $pm = New-Object System.Windows.Controls.ContextMenu; Panel-Menu $p $pm
    if ($p.menuHost) { $p.menuHost.ContextMenu = $pm } else { $p.win.ContextMenu = $pm }
}

function global:Open-Panel($pc) {
    foreach ($k in @{ anchor = 'middle-right'; offsetX = 0; offsetY = 0; monitor = -1; size = 'Medium' }.GetEnumerator()) {
        if ($pc.($k.Key) -eq $null) { Set-Prop $pc $k.Key $k.Value } }
    $p = @{ cfg = $pc; items = (New-Object System.Collections.ArrayList); deleted = $false; hwnd = [IntPtr]::Zero }
    foreach ($b in $pc.buttons) { [void]$p.items.Add($b) }
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.ShowInTaskbar = -not [bool]$global:cfg.locked
    $w.Title = if ($pc.name) { $pc.name } else { 'Panel' }
    $w.SizeToContent = 'WidthAndHeight'; $w.WindowStartupLocation = 'Manual'; $w.Left = -32000; $w.Top = -32000
    $w.Topmost = [bool]$pc.alwaysOnTop
    # Option B panel: #141414, 6 px padding, 14 px rounded corners. Rounded corners need a per-pixel-alpha window
    # (AllowsTransparency); "squarePanels": true in buttons.json (menu: Setup > Square panel corners) turns that off for slow PCs.
    $bgc = if ($pc.background -and ([string]$pc.background).ToUpperInvariant() -ne '#000000') { $pc.background } else { $global:Theme.panel }
    $square = [bool]$global:cfg.squarePanels
    if (-not $square) { $w.AllowsTransparency = $true; $w.Background = [System.Windows.Media.Brushes]::Transparent }
    else { $w.Background = Brush $bgc }
    $edge = New-Object System.Windows.Controls.Border; $edge.Background = Brush $bgc; $edge.Padding = '3'
    $edge.CornerRadius = if ($square) { '0' } else { '14' }
    $dock = New-Object System.Windows.Controls.DockPanel; $dock.Width = $global:BaseWidth - 6
    # Edit mode: 28 px amber "Editing" bar (also the drag handle). Locked: hidden, so the panel is clean.
    $grip = New-Object System.Windows.Controls.Border; $grip.Height = 28; $grip.Background = Brush $global:Theme.amber; $grip.Cursor = 'SizeAll'
    $grip.CornerRadius = '8'; $grip.Margin = '3,3,3,3'; $grip.Padding = '10,0'
    $grip.ToolTip = 'Editing. Lock when done. Right-click a button to change it. Drag this bar to move the panel.'
    $gt = New-Object System.Windows.Controls.TextBlock; $gt.Text = 'Editing. Lock when done.'
    $gt.FontFamily = $global:UiFont; $gt.FontWeight = [System.Windows.FontWeights]::SemiBold; $gt.FontSize = 12
    $gt.TextTrimming = 'CharacterEllipsis'; $gt.TextWrapping = 'NoWrap'
    $gt.Foreground = Brush $global:Theme.editText; $gt.VerticalAlignment = 'Center'; $grip.Child = $gt
    [System.Windows.Controls.DockPanel]::SetDock($grip, 'Top'); [void]$dock.Children.Add($grip)
    $stack = New-Object System.Windows.Controls.StackPanel; [void]$dock.Children.Add($stack)
    $scale = New-Object System.Windows.Media.ScaleTransform 1, 1
    $edge.LayoutTransform = $scale      # scales buttons, text and pictures together (vector, stays crisp)
    $edge.Child = $dock; $w.Content = $edge
    $p.win = $w; $p.stack = $stack; $p.grip = $grip; $p.edge = $edge; $p.scale = $scale
    $w.Add_MouseLeftButtonDown({
        if ([bool]$global:cfg.locked) { return }
        if ($_.OriginalSource -eq $edge -or $grip.IsMouseOver) { try { $w.DragMove() } catch {}; Snap-Anchor $p } }.GetNewClosure())
    $w.Add_SourceInitialized({
        $p.hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($p.hwnd)
        $src.AddHook([System.Windows.Interop.HwndSourceHook]{
            param($h, $msg, $wp, $lp, [ref]$handled)
            # WM_DISPLAYCHANGE, WM_SETTINGCHANGE (work area/taskbar), WM_DPICHANGED, WM_POWERBROADCAST (wake), WM_DEVICECHANGE-ish monitor changes
            if ($msg -in 0x007E, 0x001A, 0x02E0, 0x0218, 0x0219) { Request-Relayout }
            return [IntPtr]::Zero })
    }.GetNewClosure())
    $w.Add_ContentRendered({ Request-Relayout })
    $w.Add_SizeChanged({ Request-Relayout })
    $w.Add_Closed({
        if (-not $p.deleted) { Save-Config }
        $open = @($global:panels | Where-Object { $_.win.IsVisible }).Count
        if ($open -eq 0) { $global:app.Shutdown() } }.GetNewClosure())
    [void]$global:panels.Add($p)
    Build-Panel $p
    $w.Show()
    return $p
}

# Option B: Start Jartrek Security moves above the Restarts group. Only a buttons.json whose bottom panel still has the
# exact old default order (same labels, same order) is migrated; anything the user rearranged is left alone.
function global:Update-OldDefaultOrder {
    $lv = 0   # MB-L1: a missing or bad layoutVersion counts as 1
    if (-not [int]::TryParse([string]$global:cfg.layoutVersion, [ref]$lv)) { $lv = 1 }
    if ($lv -ge 2) { return }
    $old = @("BACK OFFICE`nUSER GUIDE`nVERSION 11", "REGISTER`nUSER GUIDE`nVERSION 11", 'PLCE', "DEPARTMENT`nOF`nREVENUE",
             "RESTART`nSCREEN CONNECT", "START`nJARTREK`nSECURITY", "RESTART`nCOMPUTER")
    $changed = $false
    foreach ($pc in @($global:cfg.panels)) {
        $bs = @($pc.buttons); $labels = @($bs | ForEach-Object { ([string]$_.label) -replace '\r', '' })
        if ($labels.Count -ne $old.Count) { continue }
        $same = $true; for ($i = 0; $i -lt $old.Count; $i++) { if ($labels[$i] -cne $old[$i]) { $same = $false; break } }
        if (-not $same) { continue }
        $sec = $bs[5]   # MB-L3: move only. Width, height and font size stay exactly as the user has them.
        $pc.buttons = @($bs[0], $bs[1], $bs[2], $bs[3], $sec, $bs[4], $bs[6]); $changed = $true
    }
    Set-Prop $global:cfg 'layoutVersion' 2
    if ($changed) { Add-Content -LiteralPath $global:logPath -Value ("{0}  moved Start Jartrek Security above the Restarts (old default order)" -f (Get-Date -Format s)) -ErrorAction SilentlyContinue }
    # No panels are open yet, so Save-Config (which rebuilds the list from open panels) can't be used here.
    try {   # MB-L2: if the write fails, log it and keep going with the migrated config in memory
        $tmp = $global:cfgPath + '.tmp'
        [IO.File]::WriteAllText($tmp, ($global:cfg | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $global:cfgPath) { [IO.File]::Replace($tmp, $global:cfgPath, $global:cfgPath + '.bak') } else { [IO.File]::Move($tmp, $global:cfgPath) }
    } catch {
        Add-Content -LiteralPath $global:logPath -Value ("{0}  couldn't save the migrated buttons.json ({1}); using it in memory" -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue
    }
}

# Second launch (Start menu, exe, shortcut) while running: show every panel and bring it to the front.
function global:Show-AllPanels {
    if ($global:single) {   # one-panel layout: one window to restore and raise
        $w = $global:single.win
        if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
        $t = $w.Topmost; $w.Topmost = $true; $w.Topmost = $t; [void]$w.Activate(); Request-Relayout; return }
    $reopen = @($global:panels | Where-Object { -not $_.deleted -and -not $_.win.IsVisible })
    foreach ($p in $reopen) { [void]$global:panels.Remove($p); [void](Open-Panel $p.cfg) }
    if ($reopen.Count) { Apply-Lock }
    foreach ($p in $global:panels) {
        if ($p.win.WindowState -eq 'Minimized') { $p.win.WindowState = 'Normal' }
        $t = $p.win.Topmost; $p.win.Topmost = $true; $p.win.Topmost = $t
        [void]$p.win.Activate()
    }
}

# R-L1/R-L2: same name rules as Build-Installer.ps1 (tools/test-installer-dryrun.ps1 checks the two copies match).
function global:Get-SafeAppName([string]$n) {
    $reserved = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
    $raw = ([string]$n).Trim()
    if ((($raw -split '\.')[0]).Trim() -match $reserved) { return 'Launcher' }
    $s = (($raw -replace '[^A-Za-z0-9 _-]', '') -replace '\s+', ' ').Trim()
    if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
    $s = $s.TrimEnd('.', ' ')
    if (-not $s -or $s -match $reserved) { return 'Launcher' }
    return $s
}
function global:Get-AppKeyName {
    $AppName = Get-SafeAppName ([string]$global:cfg.title)
    if ($AppName -eq 'Launcher') { return 'ButtonLauncher' } else { return 'ButtonLauncher-' + $AppName }
}
# Start with Windows: per-user HKCU Run value named by Get-AppKeyName (no admin), same name the installer writes.
function global:Get-AutostartCommand {
    $exe = Join-Path $global:here 'ButtonLauncher.exe'
    if (Test-Path -LiteralPath $exe) { return '"' + $exe + '"' }
    return 'wscript.exe "' + (Join-Path $global:here 'Start Launcher.vbs') + '"'
}
function global:Get-Autostart {
    $n = Get-AppKeyName
    $v = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $n -ErrorAction SilentlyContinue).$n
    return [bool]$v
}
function global:Set-Autostart([bool]$on) {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $n = Get-AppKeyName
    if ($on) { New-ItemProperty -LiteralPath $k -Name $n -Value (Get-AutostartCommand) -PropertyType String -Force | Out-Null }
    else { Remove-ItemProperty -LiteralPath $k -Name $n -ErrorAction SilentlyContinue }
}

function global:New-PanelFromMenu {
    $n = [Microsoft.VisualBasic.Interaction]::InputBox('Name for the new panel:', 'Add new panel', 'New panel')
    if (-not $n) { return }
    $pc = [pscustomobject]@{ name = $n; anchor = 'center'; offsetX = 0; offsetY = 0; monitor = -1; size = 'Medium'; alwaysOnTop = $false; background = '#000000'; buttons = @() }
    $p = Open-Panel $pc
    if ([bool]$global:cfg.locked) { $global:cfg.locked = $false; Apply-Lock }   # unlock so the new panel can be placed
    Layout-Panel $p
    Save-Config
    # rebuild others so "Move to other panel" lists the new one
    foreach ($o in $global:panels) { if ($o -ne $p) { Build-Panel $o } }
}

# ================= One-panel layout ("layout": "single"), tray icon and Ctrl+Alt+L =================
# Pure helpers first (tools/test-onepanel.ps1 runs these without Windows).
function global:Get-LayoutMode($cfg) { if ([string]$cfg.layout -eq 'single') { 'single' } else { 'two' } }
function global:Get-MiddleHint([int]$count, [bool]$locked) {   # empty + unlocked: a subtle hint; locked: nothing
    if ($count -eq 0 -and -not $locked) { return 'Unlock and right-click to add icons' }
    return $null
}
# How many chips fit, and whether a "+N more" row is needed. Chips 64 high, 6 gap, "+N more" row 28 high.
function global:Get-OverflowSplit([int]$total, [double]$availH, [int]$cols = 2, [double]$chipH = 64, [double]$gap = 6, [double]$moreH = 28) {
    if ($total -le 0) { return @{ shown = 0; more = 0 } }
    $rowsAll = [Math]::Floor(($availH + $gap) / ($chipH + $gap))
    if ($rowsAll * $cols -ge $total) { return @{ shown = $total; more = 0 } }
    $rows = [Math]::Max(0, [Math]::Floor(($availH - $moreH) / ($chipH + $gap)))   # room for the 28 px row plus its gap
    $shown = [int]([Math]::Min($total, $rows * $cols))
    return @{ shown = $shown; more = $total - $shown }
}
function global:Get-ChipLabel($btn) {   # one-line label, file extensions hidden (full name goes in the tooltip)
    $l = ([string]$btn.label) -replace '\\n', ' ' -replace '\s+', ' '
    $l = $l.Trim()
    if (-not $l) { $t = Expand $btn.target; if ($t) { $l = @($t.TrimEnd('\', '/') -split '[\\/]')[-1] } }
    if ((Get-ButtonType $btn) -ne 'website') { $l = $l -replace '(?i)\.(exe|lnk|url|pdf|xlsx?|xlsm|docx?|pptx?|csv|txt|rtf|ps1|bat|cmd|vbs|png|jpe?g)$', '' }
    if (-not $l) { $l = 'Icon' }
    return $l
}
function global:New-MiddleState($cfg) {   # normalises buttons.json "middle": { "columns": 2, "items": [ ... ] }
    if (-not $cfg.middle) { Set-Prop $cfg 'middle' ([pscustomobject]@{ columns = 2; items = @() }) }
    if ($cfg.middle.items -eq $null) { Set-Prop $cfg.middle 'items' @() }
    $cols = 2; if ($cfg.middle.columns) { $cols = [Math]::Max(1, [Math]::Min(4, [int]$cfg.middle.columns)) }
    $list = New-Object System.Collections.ArrayList
    foreach ($b in @($cfg.middle.items)) { if ($b) { [void]$list.Add($b) } }
    return @{ cols = $cols; items = $list }
}
function global:New-DefaultChip { [pscustomobject]@{ label = 'New icon'; type = 'program'; target = 'TODO: set a target'; args = ''; image = 'icon' } }

# ---------- chips ----------
# OP-L1: only touch local fixed-drive paths when drawing. Opening a UNC path, a \\?\UNC or \\.\ device path, or a mapped
# network drive (or a .lnk that points or takes its icon from one) makes Windows send NTLM credentials to that server.
function global:Get-DriveTypeName([string]$root) { ([IO.DriveInfo]::new($root)).DriveType.ToString() }
function global:Test-LocalFixedPath([string]$path, [scriptblock]$DriveType) {
    if (-not $DriveType) { $DriveType = { param($r) Get-DriveTypeName $r } }
    $x = ([string]$path).Trim().Trim('"')
    if (-not $x) { return $false }
    if ($x.StartsWith('\\') -or $x.StartsWith('//') -or $x.StartsWith('\/') -or $x.StartsWith('/\')) { return $false }   # UNC, \\?\, \\?\UNC, \\.\
    if ($x -notmatch '^[A-Za-z]:[\\/]') { return $false }                                     # relative or odd paths: no
    try { $t = [string](& $DriveType ($x.Substring(0, 2) + '\')) } catch { return $false }
    return ($t -eq 'Fixed')
}
function global:Test-SafeIconSource([string]$t, [scriptblock]$DriveType, [scriptblock]$ReadLnk) {
    if (-not (Test-LocalFixedPath $t $DriveType)) { return $false }
    if ($t -notmatch '(?i)\.lnk$') { return $true }
    if (-not $ReadLnk) { $ReadLnk = { param($l) $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($l); @{ target = $sc.TargetPath; icon = $sc.IconLocation } } }
    try { $info = & $ReadLnk $t } catch { return $false }                                     # the .lnk itself is local (checked above)
    $lt = Expand ([string]$info.target)
    $li = Expand ((([string]$info.icon) -replace ',\s*-?\d+\s*$', '').Trim())
    if ($lt -and -not (Test-LocalFixedPath $lt $DriveType)) { return $false }
    if ($li -and -not (Test-LocalFixedPath $li $DriveType)) { return $false }
    return $true
}
function global:Get-ChipFallbackPic([string]$kind) {
    switch ($kind) { 'website' { 'images/globe.png' } 'file' { 'images/guide.png' } 'script' { 'images/screenconnect.png' } default { 'images/register.png' } }
}
function global:Get-ChipIcon($btn) {   # the target's own icon (local fixed drives only, cached), else a Set A icon for its type
    $kind = Get-ButtonType $btn
    $im = [string]$btn.image
    if ($im -and $im -ne 'icon') {
        $ip = Resolve-Img $im
        if (Test-LocalFixedPath $ip) { $s = Get-PicSource $btn 32; if ($s) { return $s } } }
    if ($kind -ne 'website') {
        $t = Expand $btn.target
        if ($t -and -not (Is-Todo $t)) {
            if ($global:iconCache.ContainsKey($t)) { if ($global:iconCache[$t]) { return $global:iconCache[$t] } }
            else {
                $bs = $null
                if ((Test-SafeIconSource $t) -and (Test-Path -LiteralPath $t -PathType Leaf)) {
                    try { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($t)
                          $bs = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                          $ico.Dispose(); $bs.Freeze() } catch { $bs = $null } }
                $global:iconCache[$t] = $bs                                                     # extracted once per target, not on every draw
                if ($bs) { return $bs } } }
    }
    return Get-PicSource ([pscustomobject]@{ image = (Get-ChipFallbackPic $kind) }) 32
}
function global:New-Chip($btn, [int]$index) {
    $chip = New-Object System.Windows.Controls.Border; $chip.Height = 64; $chip.Margin = '3'; $chip.CornerRadius = '8'
    $chip.Background = Brush '#A6141414'; $chip.BorderBrush = Brush '#29FFFFFF'; $chip.BorderThickness = '1'   # Kern: 65% fill, 16% outline
    $chip.Cursor = [System.Windows.Input.Cursors]::Hand; $chip.Focusable = $true; $chip.FocusVisualStyle = $null; $chip.AllowDrop = $true
    $full = (([string]$btn.label) -replace '\\n', ' ').Trim(); if (-not $full) { $full = [string]$btn.target }
    $chip.ToolTip = $full + $(if ($btn.target -and $full -ne [string]$btn.target) { "`n" + [string]$btn.target } else { '' })
    $g = New-Object System.Windows.Controls.Grid
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'; $sp.Margin = '8'
    $src = Get-ChipIcon $btn
    if ($src) { $img = New-Object System.Windows.Controls.Image; $img.Source = $src; $img.Width = 32; $img.Height = 32; $img.Margin = '0,0,0,6'
                [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality'); [void]$sp.Children.Add($img) }
    $tb = New-Label (Get-ChipLabel $btn) '#FFFFFF' 12; $tb.TextWrapping = 'NoWrap'; $tb.TextTrimming = 'CharacterEllipsis'
    $tb.HorizontalAlignment = 'Center'; $tb.TextAlignment = 'Center'; [void]$sp.Children.Add($tb)
    [void]$g.Children.Add($sp)
    $flash = New-Object System.Windows.Controls.Border; $flash.IsHitTestVisible = $false; $flash.Opacity = 0; $flash.CornerRadius = '7'
    $flash.Background = [System.Windows.Media.Brushes]::White; [void]$g.Children.Add($flash)
    if (-not [bool]$global:cfg.locked) {
        $eo = New-Object System.Windows.Shapes.Rectangle; $eo.IsHitTestVisible = $false; $eo.Stroke = Brush '#99FFFFFF'; $eo.StrokeThickness = 2
        $eo.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (,[double[]](4, 3)); $eo.RadiusX = 6; $eo.RadiusY = 6; $eo.Margin = '2'
        [void]$g.Children.Add($eo) }
    $ct = Expand $btn.target   # OP-L1: no existence check on network paths while drawing
    if ((Is-Todo $ct) -or ((Test-LocalFixedPath $ct) -and -not (Test-ButtonSetUpQuick $btn))) { [void]$g.Children.Add((New-MissingDot 'Not set up on this PC yet')) }
    $chip.Child = $g
    $st = @{ down = $false; start = $null; dragged = $false }
    $chip.Add_MouseLeftButtonDown({ $st.down = $true; $st.dragged = $false; $st.start = $_.GetPosition($null); $_.Handled = $true; Play-Click }.GetNewClosure())
    $chip.Add_MouseMove({
        if (-not $st.down -or [bool]$global:cfg.locked -or $_.LeftButton -ne 'Pressed') { return }
        $pt = $_.GetPosition($null)
        if ([Math]::Abs($pt.X - $st.start.X) -gt 4 -or [Math]::Abs($pt.Y - $st.start.Y) -gt 4) {   # edit mode: the whole chip drags
            $st.dragged = $true; $st.down = $false
            [void][System.Windows.DragDrop]::DoDragDrop($chip, ('bl-chip:' + $index), [System.Windows.DragDropEffects]::Move) }
    }.GetNewClosure())
    $chip.Add_MouseLeftButtonUp({
        if (-not $st.down) { return }; $st.down = $false; $_.Handled = $true
        if (-not $st.dragged) { $ok = Invoke-Button $btn; if ($ok -eq $true) { Start-Flash $flash } }
    }.GetNewClosure())
    $chip.Add_KeyDown({ if (($_.Key -eq 'Enter' -or $_.Key -eq 'Space') -and -not $_.IsRepeat) { $_.Handled = $true; $ok = Invoke-Button $btn; if ($ok -eq $true) { Start-Flash $flash } } }.GetNewClosure())
    $chip.Add_Drop({
        $d = [string]$_.Data.GetData([string])
        if ($d -match '^bl-chip:(\d+)$') { Move-Chip ([int]$matches[1]) $index; $_.Handled = $true } }.GetNewClosure())
    $chip.ContextMenu = Chip-Menu $btn
    return $chip
}
function global:Move-Chip([int]$from, [int]$to) {
    $it = $global:middle.items
    if ($from -eq $to -or $from -lt 0 -or $from -ge $it.Count -or $to -lt 0 -or $to -ge $it.Count) { return }
    $b = $it[$from]; $it.RemoveAt($from); $it.Insert($to, $b); Save-Config; Build-Middle
}
function global:Remove-Chip($btn) {   # removes now, Undo for 5 seconds
    $i = $global:middle.items.IndexOf($btn); if ($i -lt 0) { return }
    $global:middle.items.RemoveAt($i); Save-Config; Build-Middle
    Show-UndoToast ("Removed " + (Get-ChipLabel $btn)) { if ($global:middle.items.IndexOf($btn) -lt 0) { $global:middle.items.Insert([Math]::Min($i, $global:middle.items.Count), $btn); Save-Config; Build-Middle } }.GetNewClosure()
}
function global:Show-UndoToast($text, $undo) {
    $t = $global:single.toast; if (-not $t) { return }
    $t.Child = $null
    $dp = New-Object System.Windows.Controls.DockPanel
    $ub = New-Object System.Windows.Controls.Button; $ub.Content = 'Undo'; $ub.Padding = '10,2'; $ub.Margin = '8,0,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($ub, 'Right'); [void]$dp.Children.Add($ub)
    $tx = New-Label $text '#FFFFFF' 12; $tx.TextTrimming = 'CharacterEllipsis'; $tx.TextWrapping = 'NoWrap'; [void]$dp.Children.Add($tx)
    $t.Child = $dp; $t.Visibility = 'Visible'
    $timer = New-Object System.Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromSeconds(5)
    $timer.Add_Tick({ $timer.Stop(); $t.Visibility = 'Collapsed' }.GetNewClosure())
    $ub.Add_Click({ $timer.Stop(); $t.Visibility = 'Collapsed'; & $undo }.GetNewClosure())
    $timer.Start()
}
function global:Add-ChipFromMenu([int]$at = -1) {
    $nb = New-DefaultChip
    if (Edit-Button $nb) { if ($at -ge 0 -and $at -le $global:middle.items.Count) { $global:middle.items.Insert($at, $nb) } else { [void]$global:middle.items.Add($nb) }; Save-Config; Build-Middle }
}
# Chips get the same kind of menu as group tiles: Edit, Move, Add, Remove, then the panel menu.
function global:Chip-Menu($btn) {
    $m = New-Object System.Windows.Controls.ContextMenu
    $hostP = $global:panels[0]
    if ([bool]$global:cfg.locked) { Locked-Menu $hostP $m; return $m }
    [void](Add-MenuItem $m 'Edit this icon...' { if (Edit-Button $btn) { Save-Config; Build-Middle } }.GetNewClosure())
    [void](Add-MenuItem $m 'Move earlier' { $i = $global:middle.items.IndexOf($btn); Move-Chip $i ($i - 1) }.GetNewClosure())
    [void](Add-MenuItem $m 'Move later' { $i = $global:middle.items.IndexOf($btn); Move-Chip $i ($i + 1) }.GetNewClosure())
    [void](Add-MenuItem $m 'Add new icon after...' { Add-ChipFromMenu ($global:middle.items.IndexOf($btn) + 1) }.GetNewClosure())
    [void](Add-MenuItem $m 'Remove this icon' { Remove-Chip $btn }.GetNewClosure())
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    Panel-Menu $hostP $m
    return $m
}
function global:Middle-Menu {
    $m = New-Object System.Windows.Controls.ContextMenu
    $hostP = $global:panels[0]
    if ([bool]$global:cfg.locked) { Locked-Menu $hostP $m; return $m }
    [void](Add-MenuItem $m 'Add icon...' { Add-ChipFromMenu })
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    Panel-Menu $hostP $m
    return $m
}
function global:New-ChipGrid($list, [int]$cols, [int]$offset) {
    $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Columns = $cols
    for ($i = 0; $i -lt $list.Count; $i++) { [void]$ug.Children.Add((New-Chip $list[$i] ($offset + $i))) }
    return $ug
}
# Middle area: Background $null when locked, so empty pixels click through to the desktop; only chips are hit-testable.
function global:Build-Middle {
    $s = $global:single; if (-not $s) { return }
    $mid = $s.middle; $mid.Children.Clear()
    $global:labelSink = New-Object System.Collections.ArrayList
    $locked = [bool]$global:cfg.locked
    $mid.Background = if ($locked) { $null } else { Brush '#01000000' }   # edit mode catches right-click and drops
    $mid.ContextMenu = if ($locked) { $null } else { Middle-Menu }
    $items = @($global:middle.items)
    $hint = Get-MiddleHint $items.Count $locked
    if ($hint) {
        $h = New-Label $hint '#B3FFFFFF' 12; $h.HorizontalAlignment = 'Center'; $h.TextAlignment = 'Center'; $h.VerticalAlignment = 'Center'
        $h.IsHitTestVisible = $false; [void]$mid.Children.Add($h) }
    if ($hint -or $items.Count -eq 0) { $s.labels = $global:labelSink; $global:labelSink = $null; Apply-MinFont $s; return }
    $split = Get-OverflowSplit $items.Count $s.availH $global:middle.cols
    $s.lastShown = $split.shown
    $col = New-Object System.Windows.Controls.StackPanel; $col.VerticalAlignment = 'Center'; $col.Margin = '3,16'   # >= 16 px to the groups
    if ($split.shown -gt 0) { [void]$col.Children.Add((New-ChipGrid @($items[0..($split.shown - 1)]) $global:middle.cols 0)) }
    if ($split.more -gt 0) {
        $more = New-Object System.Windows.Controls.Border; $more.Height = 28; $more.Margin = '3'; $more.CornerRadius = '8'
        $more.Background = Brush '#A6141414'; $more.BorderBrush = Brush '#29FFFFFF'; $more.BorderThickness = '1'; $more.Cursor = [System.Windows.Input.Cursors]::Hand
        $mt = New-Label ("+{0} more {1}" -f $split.more, [char]0x25BE) '#FFFFFF' 12; $mt.HorizontalAlignment = 'Center'; $more.Child = $mt
        $pop = New-Object System.Windows.Controls.Primitives.Popup; $pop.StaysOpen = $false; $pop.PlacementTarget = $more; $pop.Placement = 'Left'
        $pop.AllowsTransparency = $true
        $pb = New-Object System.Windows.Controls.Border; $pb.Background = Brush $global:Theme.panel; $pb.CornerRadius = '12'; $pb.Padding = '3'; $pb.Width = 290
        $pb.Child = New-ChipGrid @($items[$split.shown..($items.Count - 1)]) $global:middle.cols $split.shown
        $pop.Child = $pb
        $more.Add_MouseLeftButtonUp({ $pop.IsOpen = -not $pop.IsOpen }.GetNewClosure())
        [void]$col.Children.Add($more); [void]$col.Children.Add($pop)
    }
    [void]$mid.Children.Add($col)
    $s.labels = $global:labelSink; $global:labelSink = $null; Apply-MinFont $s   # 12 px floor for chip labels too
}

# ---------- the single docked window ----------
function global:Open-Single {
    $pcs = @($global:cfg.panels)
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.ShowInTaskbar = -not [bool]$global:cfg.locked
    $w.Title = if ($global:cfg.title) { [string]$global:cfg.title } else { 'Launcher' }
    $w.SizeToContent = 'Width'; $w.WindowStartupLocation = 'Manual'; $w.Left = -32000; $w.Top = -32000
    $w.Topmost = [bool]$pcs[0].alwaysOnTop                   # not topmost unless the panel already was
    $w.AllowsTransparency = $true; $w.Background = $null      # per-pixel alpha: transparent pixels click through
    $scale = New-Object System.Windows.Media.ScaleTransform 1, 1
    $root = New-Object System.Windows.Controls.Grid; $root.Width = $global:BaseWidth; $root.LayoutTransform = $scale
    foreach ($r in 'Auto', '*', 'Auto', 'Auto') { $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = (New-Object System.Windows.GridLengthConverter).ConvertFromString($r); [void]$root.RowDefinitions.Add($rd) }
    $w.Content = $root
    $global:single = @{ win = $w; root = $root; scale = $scale; middle = $null; toast = $null; availH = 0; lastShown = -1; hwnd = [IntPtr]::Zero; labels = $null }
    $groups = @()
    for ($gi = 0; $gi -lt [Math]::Min(2, $pcs.Count); $gi++) {
        $pc = $pcs[$gi]
        $p = @{ cfg = $pc; items = (New-Object System.Collections.ArrayList); deleted = $false; hwnd = [IntPtr]::Zero; single = $true }
        foreach ($b in $pc.buttons) { [void]$p.items.Add($b) }
        $edge = New-Object System.Windows.Controls.Border; $edge.Background = Brush $global:Theme.panel; $edge.Padding = '3'
        $edge.CornerRadius = $(if ($gi -eq 0) { '0,0,0,14' } else { '14,0,0,0' })
        $dock = New-Object System.Windows.Controls.DockPanel
        $grip = New-Object System.Windows.Controls.Border
        if ($gi -eq 0) {   # Editing bar (top group only). Squint: lead with "Lock when done".
            $grip.Height = 28; $grip.Background = Brush $global:Theme.amber; $grip.CornerRadius = '8'; $grip.Margin = '3'; $grip.Padding = '10,0'
            $grip.ToolTip = 'Editing. Lock when done. Right-click a button or icon to change it.'
            $gt = New-Label 'Editing. Lock when done.' $global:Theme.editText 12; $gt.TextTrimming = 'CharacterEllipsis'; $gt.TextWrapping = 'NoWrap'; $grip.Child = $gt
            [System.Windows.Controls.DockPanel]::SetDock($grip, 'Top'); [void]$dock.Children.Add($grip) }
        $stack = New-Object System.Windows.Controls.StackPanel; [void]$dock.Children.Add($stack)
        $edge.Child = $dock
        [System.Windows.Controls.Grid]::SetRow($edge, $(if ($gi -eq 0) { 0 } else { 2 })); [void]$root.Children.Add($edge)
        $p.win = $w; $p.stack = $stack; $p.grip = $grip; $p.edge = $edge; $p.scale = $scale; $p.menuHost = $edge
        [void]$global:panels.Add($p); $groups += $p
    }
    $mid = New-Object System.Windows.Controls.Grid; [System.Windows.Controls.Grid]::SetRow($mid, 1); [void]$root.Children.Add($mid)
    $toast = New-Object System.Windows.Controls.Border; $toast.Visibility = 'Collapsed'; $toast.Background = Brush '#2B2B2B'; $toast.CornerRadius = '8'
    $toast.Padding = '10,6'; $toast.Margin = '6'; [System.Windows.Controls.Grid]::SetRow($toast, 3); [void]$root.Children.Add($toast)
    $global:single.middle = $mid; $global:single.toast = $toast
    $w.Add_SourceInitialized({
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
        $global:single.hwnd = $h; foreach ($g in $global:panels) { $g.hwnd = $h }
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
        $src.AddHook([System.Windows.Interop.HwndSourceHook]{
            param($hh, $msg, $wp, $lp, [ref]$handled)
            if ($msg -in 0x007E, 0x001A, 0x02E0, 0x0218, 0x0219) { Request-Relayout }   # display, work area, DPI, power, devices
            return [IntPtr]::Zero })
    }.GetNewClosure())
    $w.Add_ContentRendered({ Request-Relayout })
    $w.Add_Closed({ Save-Config; $global:app.Shutdown() })
    foreach ($p in $groups) { Build-Panel $p }
    Build-Middle
    $w.Show()
}
# Dock: the panels' edge (left if the top panel was anchored left, else right), full work-area height of that monitor.
function global:Layout-Single {
    $s = $global:single; if (-not $s -or -not $s.hwnd -or $s.hwnd -eq [IntPtr]::Zero) { return }
    $pc = $global:panels[0].cfg
    $wa = Get-WorkArea (Get-Screen $pc)
    $dpi = Get-Dpi $global:panels[0]
    $pct = if ($pc.size -is [string] -and $global:SizePct[[string]$pc.size]) { $global:SizePct[[string]$pc.size] } elseif ($pc.size) { [double]$pc.size } else { 14 }
    $wDip = [Math]::Max(180, [Math]::Min(560, ($wa.W * $pct / 100.0) / $dpi))
    $sc = $wDip / $global:BaseWidth
    $hDip = $wa.H / $dpi
    $s.scale.ScaleX = $sc; $s.scale.ScaleY = $sc
    $s.root.Height = $hDip / $sc
    foreach ($g in $global:panels) { Apply-MinFont $g }; Apply-MinFont $s
    $s.win.UpdateLayout()
    $groupsH = 0; foreach ($g in $global:panels) { $groupsH += $g.edge.ActualHeight }
    if ($groupsH -gt $s.root.Height) {   # groups alone don't fit: shrink to fit (tiles keep their 44 px minimum in layout units)
        $sc = $sc * $s.root.Height / $groupsH; $s.scale.ScaleX = $sc; $s.scale.ScaleY = $sc; $s.root.Height = $hDip / $sc
        foreach ($g in $global:panels) { Apply-MinFont $g }; $s.win.UpdateLayout(); $groupsH = 0; foreach ($g in $global:panels) { $groupsH += $g.edge.ActualHeight } }
    $avail = [Math]::Max(0, $s.root.Height - $groupsH - 32)
    $need = Get-OverflowSplit $global:middle.items.Count $avail $global:middle.cols
    $s.availH = $avail
    if ($need.shown -ne $s.lastShown) { Build-Middle; $s.win.UpdateLayout() }
    $wPx = [int][Math]::Round($s.win.ActualWidth * $dpi)
    $left = ([string]$pc.anchor) -like '*left*'
    $x = if ($left) { $wa.L } else { $wa.R - $wPx }
    foreach ($g in $global:panels) { $g.edge.CornerRadius = $(if ($g -eq $global:panels[0]) { if ($left) { '0,0,14,0' } else { '0,0,0,14' } } else { if ($left) { '0,14,0,0' } else { '14,0,0,0' } }) }
    [void][BL.Native]::SetWindowPos($s.hwnd, [IntPtr]::Zero, [int]$x, [int]$wa.T, 0, 0, 0x0015)
}

# ---------- tray icon + Ctrl+Alt+L (both layouts) ----------
function global:Start-TrayAndHotkey {
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ico = Join-Path $global:here 'images\app.ico'
        $ni.Icon = if (Test-Path -LiteralPath $ico) { New-Object System.Drawing.Icon $ico } else { [System.Drawing.SystemIcons]::Application }
        $ni.Text = 'Button Launcher (Ctrl+Alt+L)'
        $cm = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$cm.Items.Add('Show', $null, { Show-AllPanels })
        $lk = $cm.Items.Add('Unlock', $null, { $global:cfg.locked = -not [bool]$global:cfg.locked; Save-Config; Apply-Lock })
        [void]$cm.Items.Add('Settings', $null, { Show-AllPanels; Show-SetupWindow })
        [void]$cm.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        [void]$cm.Items.Add('Exit', $null, { $global:app.Shutdown() })
        $cm.Add_Opening({ $lk.Text = if ([bool]$global:cfg.locked) { 'Unlock' } else { 'Lock' } }.GetNewClosure())
        $ni.ContextMenuStrip = $cm
        $ni.Add_MouseClick({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-AllPanels } })
        $ni.Visible = $true
        $global:tray = $ni
    } catch { Write-LauncherError 'starting the tray icon' $_ }
    try {   # hidden message-only window (HWND_MESSAGE) receives WM_HOTKEY
        $hp = New-Object System.Windows.Interop.HwndSourceParameters 'ButtonLauncherHotkey'
        $hp.ParentWindow = [IntPtr](-3); $hp.Width = 0; $hp.Height = 0; $hp.WindowStyle = 0
        $global:hotkeySrc = New-Object System.Windows.Interop.HwndSource $hp
        $global:hotkeySrc.AddHook([System.Windows.Interop.HwndSourceHook]{
            param($hh, $msg, $wp, $lp, [ref]$handled)
            if ($msg -eq 0x0312 -and $wp.ToInt64() -eq 0xB10) { Show-AllPanels; $handled.Value = $true }
            return [IntPtr]::Zero })
        $global:hotkeyOk = [BL.Native]::RegisterHotKey($global:hotkeySrc.Handle, 0xB10, 0x4003, 0x4C)   # MOD_CONTROL|MOD_ALT|MOD_NOREPEAT, 'L'
        if (-not $global:hotkeyOk) { Add-Content -LiteralPath $global:logPath -Value ("{0}  Ctrl+Alt+L is already used by another program; use the tray icon instead." -f (Get-Date -Format s)) -ErrorAction SilentlyContinue }
    } catch { Write-LauncherError 'registering Ctrl+Alt+L' $_ }
}
function global:Stop-TrayAndHotkey {
    try { if ($global:hotkeyOk -and $global:hotkeySrc) { [void][BL.Native]::UnregisterHotKey($global:hotkeySrc.Handle, 0xB10) } } catch {}
    try { if ($global:hotkeySrc) { $global:hotkeySrc.Dispose() } } catch {}
    try { if ($global:tray) { $global:tray.Visible = $false; $global:tray.Dispose() } } catch {}
}

# ================= MAIN (runs only after every function above is defined) =================
try {
    # CC-M3: one launcher per install folder. A Reload waits (up to 10 s) for the old copy to save and exit.
    $sha = New-Object System.Security.Cryptography.SHA1Managed
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($global:here.ToLowerInvariant()))) -replace '-', '').Substring(0, 16)
    $created = $false
    $global:mutex = New-Object System.Threading.Mutex($true, "Local\ButtonLauncher-$hash", [ref]$created)
    $global:showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\ButtonLauncher-$hash-show")
    if (-not $created) {
        $got = $false
        if ($args -contains '-Reload') {   # Reload: wait for the old copy to save and exit
            try { $got = $global:mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
            if (-not $got) {   # R-L3/R3-L1: the old copy didn't exit in 10 s. Ask (default No); never silently run two copies.
                $ans = [System.Windows.MessageBox]::Show("The old launcher isn't closing. Start anyway? Changes from the old one may be lost.", 'Launcher', 'YesNo', 'Warning', 'No')
                if ($ans -ne 'Yes') { exit 0 }
                Add-Content -LiteralPath $global:logPath -Value ("{0}  Reload: the previous copy did not exit within 10 s; user chose to start anyway." -f (Get-Date -Format s)) -ErrorAction SilentlyContinue
                $got = $true
            }
        }
        if (-not $got) { [void]$global:showEvent.Set(); exit 0 }   # already running: ask it to show its panels, then quit quietly
    }
    if (-not (Test-Path -LiteralPath $global:cfgPath) -and (Test-Path -LiteralPath $global:cfgDefault)) { Copy-Item -LiteralPath $global:cfgDefault -Destination $global:cfgPath }
    try { $global:cfg = Get-Content -LiteralPath $global:cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json; if (-not $global:cfg) { throw 'buttons.json is empty.' } }
    catch {
        $why = $_.Exception.Message; $bak = $global:cfgPath + '.bak'   # CC-M2: fall back to the last good copy
        try { $global:cfg = Get-Content -LiteralPath $bak -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { $global:cfg = $null }
        if (-not $global:cfg) { throw "Couldn't read buttons.json: $why" }
        Add-Content -LiteralPath $global:logPath -Value ("{0}  buttons.json unreadable ({1}); loaded buttons.json.bak" -f (Get-Date -Format s), $why) -ErrorAction SilentlyContinue
    }
    if (-not $global:cfg.panels) { throw 'buttons.json has no "panels" list.' }
    Update-OldDefaultOrder
    if ($global:cfg.clickSound -eq $null) { $global:cfg | Add-Member -NotePropertyName clickSound -NotePropertyValue $false }
    if ($global:cfg.locked -eq $null) { $global:cfg | Add-Member -NotePropertyName locked -NotePropertyValue $true }

    if (-not $global:dpiCtxOk) {   # CC-N3: note once when the host already fixed DPI awareness (helps diagnose scaling)
        $dpiNote = Join-Path $global:here 'launcher-dpi.log'
        if (-not (Test-Path -LiteralPath $dpiNote)) { Set-Content -LiteralPath $dpiNote -Value ("{0}  SetProcessDpiAwarenessContext(PMv2) returned false (host manifest already set DPI mode)." -f (Get-Date -Format s)) -ErrorAction SilentlyContinue }
    }

    $global:app = New-Object System.Windows.Application
    $global:app.ShutdownMode = 'OnExplicitShutdown'
    # Errors inside click/menu handlers: log + message, keep running
    $global:app.Add_DispatcherUnhandledException({ Write-LauncherError 'while running' $_.Exception; $_.Handled = $true })
    $global:relayoutTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:relayoutTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $global:relayoutTimer.Add_Tick({ $global:relayoutTimer.Stop(); if ($global:single) { Layout-Single } else { foreach ($o in $global:panels) { Layout-Panel $o } } })

    $global:middle = New-MiddleState $global:cfg
    if ((Get-LayoutMode $global:cfg) -eq 'single' -and @($global:cfg.panels).Count -ge 1) { Open-Single }
    else { foreach ($pc in @($global:cfg.panels)) { [void](Open-Panel $pc) } }
    Apply-Lock                                          # builds every panel (menus know every panel) + tool-window style + placement
    if ($global:panels.Count -eq 0) { throw 'No panels could be opened.' }
    Start-TrayAndHotkey                                 # Squint Major 1: tray icon + Ctrl+Alt+L bring the launcher forward (both layouts)
    $global:app.Add_Exit({ Stop-TrayAndHotkey })
    $showTimer = New-Object System.Windows.Threading.DispatcherTimer; $showTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $showTimer.Add_Tick({ if ($global:showEvent.WaitOne(0)) { Show-AllPanels } }); $showTimer.Start()
    if (-not [bool]$global:cfg.setupDone) {   # UX-2a: first run (right after install) lists every button that still needs a file
        Set-Prop $global:cfg 'setupDone' $true
        [void]$global:app.Dispatcher.BeginInvoke([Action]{ Show-SetupWindow -OnlyIfNeeded }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    }
    [void]$global:app.Run()
}
catch {
    Write-LauncherError 'starting up' $_
    exit 1
}
