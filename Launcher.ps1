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
$global:logPath      = Join-Path $global:here 'launcher-error.log'
$global:cfg          = $null
$global:panels       = New-Object System.Collections.ArrayList   # each: @{ cfg; items; win; stack; ... }
$global:BaseWidth    = 290                                        # design width; heights/fonts in buttons.json use these units
$global:SizePct      = @{ Small = 11; Medium = 14; Large = 18 }   # panel width as % of work-area width
$global:RaisedBrush  = $null
$global:SunkenBrush  = $null
$global:app          = $null
$global:relayoutTimer = $null
$global:labelSink    = $null                                      # labels collected while a panel is built (min font)

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

function global:New-Bevel($bg, $content, $h) {
    # Outer light/dark border gives the raised 3D edge
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush $bg; $b.Height = $h; $b.Margin = '2'
    $b.BorderThickness = '3'
    $lg = New-Object System.Windows.Media.LinearGradientBrush
    $lg.StartPoint = '0,0'; $lg.EndPoint = '1,1'
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(200,255,255,255)), 0.0))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(200,255,255,255)), 0.49))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(200,40,40,40)), 0.51))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(200,40,40,40)), 1.0))
    $b.BorderBrush = $lg
    $b.Child = $content
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    return $b
}

function global:New-Label($text, $fg, $size) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = ($text -replace '\\n', "`n"); $tb.Foreground = Brush $fg
    $tb.FontFamily = 'Arial'; $tb.FontWeight = 'Bold'; $tb.FontSize = $size
    $tb.Tag = [double]$size                                  # design size; Apply-MinFont enforces the floor after scaling
    if ($global:labelSink -ne $null) { [void]$global:labelSink.Add($tb) }
    $tb.TextAlignment = 'Center'; $tb.TextWrapping = 'Wrap'
    $tb.HorizontalAlignment = 'Center'; $tb.VerticalAlignment = 'Center'
    $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
    $fx.ShadowDepth = 1.5; $fx.BlurRadius = 2; $fx.Opacity = 0.6
    $tb.Effect = $fx
    return $tb
}


# ---------- button visual states: hover / press (sunken bevel) / launch flash / click sound ----------
# Kern-3/UX-6: label floor of 12 DIP (13 for 3+ line labels) on screen, after the panel's scale is applied.
function global:Apply-MinFont($p) {
    if (-not $p.labels) { return }
    $s = [Math]::Max(0.1, [double]$p.scale.ScaleX)
    foreach ($tb in $p.labels) {
        $floor = if (([string]$tb.Text).Split("`n").Count -ge 3) { 13.0 } else { 12.0 }
        $tb.FontSize = [Math]::Max([double]$tb.Tag, $floor / $s)
    }
}

function global:New-BevelBrush($sunken) {
    $light = [System.Windows.Media.Color]::FromArgb(200,255,255,255); $dark = [System.Windows.Media.Color]::FromArgb(200,40,40,40)
    $a = if ($sunken) { $dark } else { $light }; $b = if ($sunken) { $light } else { $dark }
    $lg = New-Object System.Windows.Media.LinearGradientBrush; $lg.StartPoint = '0,0'; $lg.EndPoint = '1,1'
    foreach ($st in @(@($a,0.0),@($a,0.49),@($b,0.51),@($b,1.0))) { $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop $st[0], $st[1])) }
    $lg.Freeze(); return $lg
}

function global:Play-Click {
    if (-not [bool]$global:cfg.clickSound) { return }
    try {
        $wav = Join-Path $global:here 'click.wav'
        if (-not (Test-Path $wav)) { $wav = Join-Path $env:SystemRoot 'Media\Windows Navigation Start.wav' }
        if (Test-Path $wav) { (New-Object System.Media.SoundPlayer $wav).Play() } else { [System.Media.SystemSounds]::Asterisk.Play() }
    } catch {}
}

function global:Wire-Button($p, $el, $action) {
    # $el = bevel Border. Wrap its content: [content (shifts on press)] + [shade] + [white flash]
    $content = $el.Child; $el.Child = $null
    $g = New-Object System.Windows.Controls.Grid
    $shift = New-Object System.Windows.Media.TranslateTransform 0, 0
    $content.RenderTransform = $shift
    $shade = New-Object System.Windows.Controls.Border; $shade.IsHitTestVisible = $false; $shade.Opacity = 0; $shade.Background = [System.Windows.Media.Brushes]::White
    $flash = New-Object System.Windows.Controls.Border; $flash.IsHitTestVisible = $false; $flash.Opacity = 0; $flash.Background = [System.Windows.Media.Brushes]::White
    [void]$g.Children.Add($content); [void]$g.Children.Add($shade); [void]$g.Children.Add($flash)
    $g.Background = [System.Windows.Media.Brushes]::Transparent
    $el.Child = $g; $el.BorderBrush = $global:RaisedBrush; $el.Cursor = [System.Windows.Input.Cursors]::Hand
    $st = @{ down = $false }
    $anim = { param($obj, $prop, $to, $ms)
        $da = New-Object System.Windows.Media.Animation.DoubleAnimation $to, ([System.Windows.Duration][TimeSpan]::FromMilliseconds($ms))
        $obj.BeginAnimation($prop, $da) }
    $hover = { $shade.Background = [System.Windows.Media.Brushes]::White; & $anim $shade ([System.Windows.UIElement]::OpacityProperty) 0.10 80 }.GetNewClosure()
    $release = {
        $el.BorderBrush = $global:RaisedBrush
        & $anim $shift ([System.Windows.Media.TranslateTransform]::XProperty) 0 100
        & $anim $shift ([System.Windows.Media.TranslateTransform]::YProperty) 0 100
    }.GetNewClosure()
    $el.Add_MouseEnter({ if (-not $st.down) { & $hover } }.GetNewClosure())
    $el.Add_MouseLeave({ if (-not $st.down) { & $anim $shade ([System.Windows.UIElement]::OpacityProperty) 0 100 } }.GetNewClosure())
    $el.Add_MouseLeftButtonDown({
        $st.down = $true; [void]$el.CaptureMouse(); $_.Handled = $true
        $el.BorderBrush = $global:SunkenBrush
        $d = 2.0 / [Math]::Max(0.1, $p.scale.ScaleX)       # 2 device-ish px at any scale
        $shift.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null); $shift.X = $d
        $shift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null); $shift.Y = $d
        $shade.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $shade.Background = [System.Windows.Media.Brushes]::Black; $shade.Opacity = 0.15
        Play-Click
    }.GetNewClosure())
    $el.Add_MouseLeftButtonUp({
        if (-not $st.down) { return }
        $st.down = $false; $el.ReleaseMouseCapture(); $_.Handled = $true
        $pos = $_.GetPosition($el); $inside = ($pos.X -ge 0 -and $pos.Y -ge 0 -and $pos.X -le $el.ActualWidth -and $pos.Y -le $el.ActualHeight)
        & $release
        if ($inside) { & $hover } else { & $anim $shade ([System.Windows.UIElement]::OpacityProperty) 0 100 }
        if ($inside) {
            $ok = & $action
            if ($ok -eq $true) {
                $flash.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $flash.Opacity = 0.8
                & $anim $flash ([System.Windows.UIElement]::OpacityProperty) 0 300
            }
        }
    }.GetNewClosure())
    $el.Add_LostMouseCapture({ if ($st.down) { $st.down = $false; & $release; & $anim $shade ([System.Windows.UIElement]::OpacityProperty) 0 100 } }.GetNewClosure())
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

function global:Get-PicSource($btn) {
    if (-not $btn.image) { return $null }
    if ($btn.image -eq 'icon') { return Get-IconImage $btn.target }
    $p = Resolve-Img $btn.image
    if (-not (Test-Path $p)) { return $null }
    try {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        # CC-N2: load from a stream so paths with # or % work
        $fsm = [IO.File]::OpenRead($p)
        try { $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.StreamSource = $fsm; $bi.EndInit(); $bi.Freeze() } finally { $fsm.Dispose() }
        return $bi
    } catch { return $null }
}

function global:New-Content($btn, $fs, $h) {
    $label = New-Label $btn.label $btn.fg $fs
    $src = Get-PicSource $btn
    if (-not $src) { return $label }
    $mode = if ($btn.imageMode) { $btn.imageMode } else { 'left' }
    $img = New-Object System.Windows.Controls.Image; $img.Source = $src; $img.Stretch = 'Uniform'
    switch ($mode) {
        'only'       { $img.Margin = '4'; return $img }
        'background' { $g = New-Object System.Windows.Controls.Grid; $img.Stretch = 'UniformToFill'
                       $g.Children.Add($img) | Out-Null; $g.Children.Add($label) | Out-Null; return $g }
        'above'      { $sp = New-Object System.Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'
                       $img.Height = [Math]::Max(16, $h * 0.4); $img.Margin = '0,0,0,2'
                       $sp.Children.Add($img) | Out-Null; $sp.Children.Add($label) | Out-Null; return $sp }
        default      { $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.HorizontalAlignment = 'Center'
                       $img.Height = [Math]::Min(48, $h * 0.6); $img.Margin = '0,0,6,0'
                       $sp.Children.Add($img) | Out-Null; $sp.Children.Add($label) | Out-Null; return $sp }
    }
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

# ---------- config + layout: anchors are relative, so they work at any resolution / scaling ----------
function global:Save-Config {
    foreach ($p in $global:panels) { Set-Prop $p.cfg 'buttons' @($p.items.ToArray()) }
    $global:cfg.panels = @($global:panels | ForEach-Object { $_.cfg })
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
    foreach ($p in $global:panels) {
        $p.grip.Visibility = if ($locked) { 'Collapsed' } else { 'Visible' }
        $p.edge.Padding = if ($locked) { '2' } else { '4' }
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

function global:Panel-Menu($p, $menu) {
    if ([bool]$global:cfg.locked) { Locked-Menu $p $menu; return }
    [void](Add-MenuItem $menu 'Add new button at end...' { $nb = New-DefaultButton; if (Edit-Button $nb) { [void]$p.items.Add($nb); Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure())
    $top = Add-MenuItem $menu 'Always on top' { $p.cfg.alwaysOnTop = -not [bool]$p.cfg.alwaysOnTop; $p.win.Topmost = [bool]$p.cfg.alwaysOnTop; Save-Config }.GetNewClosure()
    $top.IsCheckable = $true; $top.IsChecked = [bool]$p.cfg.alwaysOnTop
    $lk = Add-MenuItem $menu 'Lock panels' { $global:cfg.locked = -not [bool]$global:cfg.locked; Save-Config; Apply-Lock }
    $lk.IsCheckable = $true; $lk.IsChecked = [bool]$global:cfg.locked
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
    $cs = Add-MenuItem $menu 'Click sound' { $global:cfg.clickSound = -not [bool]$global:cfg.clickSound; Save-Config }
    $cs.IsCheckable = $true; $cs.IsChecked = [bool]$global:cfg.clickSound
    [void](Add-MenuItem $menu 'Rename panel...' { $n = [Microsoft.VisualBasic.Interaction]::InputBox('Panel name:', 'Rename panel', $p.cfg.name); if ($n) { $p.cfg.name = $n; $p.win.Title = $n; Save-Config } }.GetNewClosure())
    [void](Add-MenuItem $menu 'Add new panel...' { New-PanelFromMenu }.GetNewClosure())
    [void](Add-MenuItem $menu 'Delete this panel...' {
        if ([System.Windows.MessageBox]::Show("Delete the panel ""$($p.cfg.name)"" and all its buttons?", 'Launcher', 'YesNo', 'Warning') -eq 'Yes') {
            $global:panels.Remove($p); $p.deleted = $true; Save-Config; $p.win.Close()
            foreach ($o in $global:panels) { Build-Panel $o } } }.GetNewClosure())   # CC-L5: drop the deleted panel from Move menus
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    [void](Add-MenuItem $menu 'Build installer...' { Save-Config; Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $global:here 'Build-Installer.ps1')`"" })
    [void](Add-MenuItem $menu 'Edit buttons.json in Notepad' { Start-Process notepad.exe "`"$global:cfgPath`"" })
    [void](Add-MenuItem $menu 'Reload' { Save-Config; Start-Process wscript.exe "`"$(Join-Path $global:here 'Start Launcher.vbs')`""; $global:app.Shutdown() })
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

function global:Build-Panel($p) {
    $stack = $p.stack; $stack.Children.Clear()
    $global:labelSink = New-Object System.Collections.ArrayList
    $pendingHalf = $null
    foreach ($btn in $p.items) {
        $h = if ($btn.height) { [double]$btn.height } else { 80 }
        $fs = if ($btn.fontSize) { [double]$btn.fontSize } else { 18 }
        $el = New-Bevel $btn.bg (New-Content $btn $fs $h) $h
        $el.ClipToBounds = $true; $el.ToolTip = $btn.target
        Wire-Button $p $el ({ Invoke-Button $btn }.GetNewClosure())
        $el.ContextMenu = Button-Menu $p $btn
        if ($btn.width -eq 'half') {
            if ($pendingHalf) { [System.Windows.Controls.Grid]::SetColumn($el, 1); [void]$pendingHalf.Children.Add($el); $pendingHalf = $null }
            else {
                $g = New-Object System.Windows.Controls.Grid
                [void]$g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                [void]$g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                [void]$g.Children.Add($el); [void]$stack.Children.Add($g); $pendingHalf = $g
            }
        } else { $pendingHalf = $null; [void]$stack.Children.Add($el) }
    }
    if ($p.items.Count -eq 0) {
        $e = New-Object System.Windows.Controls.TextBlock; $e.Text = 'Empty panel - right-click to add a button'; $e.Foreground = Brush '#AAAAAA'
        $e.Margin = '10,20'; $e.TextWrapping = 'Wrap'; [void]$stack.Children.Add($e)
    }
    $p.labels = $global:labelSink; $global:labelSink = $null; Apply-MinFont $p
    $pm = New-Object System.Windows.Controls.ContextMenu; Panel-Menu $p $pm; $p.win.ContextMenu = $pm
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
    $bgc = if ($pc.background) { $pc.background } else { '#000000' }
    $edge = New-Object System.Windows.Controls.Border; $edge.Background = Brush '#3A3A3A'; $edge.Padding = '4'
    $dock = New-Object System.Windows.Controls.DockPanel; $dock.Background = Brush $bgc; $dock.Width = $global:BaseWidth
    $grip = New-Object System.Windows.Controls.Border; $grip.Height = 14; $grip.Background = Brush '#555555'; $grip.Cursor = 'SizeAll'
    $gt = New-Object System.Windows.Controls.TextBlock; $gt.Text = [string][char]0x2261 + '  ' + $w.Title + '  (drag to move)'; $gt.FontSize = 10
    $gt.Foreground = Brush '#DDDDDD'; $gt.HorizontalAlignment = 'Center'; $gt.VerticalAlignment = 'Center'; $grip.Child = $gt
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

# ================= MAIN (runs only after every function above is defined) =================
try {
    # CC-M3: one launcher per install folder. A Reload waits (up to 10 s) for the old copy to save and exit.
    $sha = New-Object System.Security.Cryptography.SHA1Managed
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($global:here.ToLowerInvariant()))) -replace '-', '').Substring(0, 16)
    $created = $false
    $global:mutex = New-Object System.Threading.Mutex($true, "Local\ButtonLauncher-$hash", [ref]$created)
    if (-not $created) {
        $got = $false
        try { $got = $global:mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { exit 0 }   # already running
    }
    try { $global:cfg = Get-Content -LiteralPath $global:cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json; if (-not $global:cfg) { throw 'buttons.json is empty.' } }
    catch {
        $why = $_.Exception.Message; $bak = $global:cfgPath + '.bak'   # CC-M2: fall back to the last good copy
        try { $global:cfg = Get-Content -LiteralPath $bak -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { $global:cfg = $null }
        if (-not $global:cfg) { throw "Couldn't read buttons.json: $why" }
        Add-Content -LiteralPath $global:logPath -Value ("{0}  buttons.json unreadable ({1}); loaded buttons.json.bak" -f (Get-Date -Format s), $why) -ErrorAction SilentlyContinue
    }
    if (-not $global:cfg.panels) { throw 'buttons.json has no "panels" list.' }
    if ($global:cfg.clickSound -eq $null) { $global:cfg | Add-Member -NotePropertyName clickSound -NotePropertyValue $false }
    if ($global:cfg.locked -eq $null) { $global:cfg | Add-Member -NotePropertyName locked -NotePropertyValue $true }

    if (-not $global:dpiCtxOk) {   # CC-N3: note once when the host already fixed DPI awareness (helps diagnose scaling)
        $dpiNote = Join-Path $global:here 'launcher-dpi.log'
        if (-not (Test-Path -LiteralPath $dpiNote)) { Set-Content -LiteralPath $dpiNote -Value ("{0}  SetProcessDpiAwarenessContext(PMv2) returned false (host manifest already set DPI mode)." -f (Get-Date -Format s)) -ErrorAction SilentlyContinue }
    }
    $global:RaisedBrush = New-BevelBrush $false
    $global:SunkenBrush = New-BevelBrush $true

    $global:app = New-Object System.Windows.Application
    $global:app.ShutdownMode = 'OnExplicitShutdown'
    # Errors inside click/menu handlers: log + message, keep running
    $global:app.Add_DispatcherUnhandledException({ Write-LauncherError 'while running' $_.Exception; $_.Handled = $true })
    $global:relayoutTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:relayoutTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $global:relayoutTimer.Add_Tick({ $global:relayoutTimer.Stop(); foreach ($o in $global:panels) { Layout-Panel $o } })

    foreach ($pc in @($global:cfg.panels)) { [void](Open-Panel $pc) }
    Apply-Lock                                          # builds every panel (menus know every panel) + tool-window style + placement
    if ($global:panels.Count -eq 0) { throw 'No panels could be opened.' }
    [void]$global:app.Run()
}
catch {
    Write-LauncherError 'starting up' $_
    exit 1
}
