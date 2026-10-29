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
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr mon, int type, out uint dpiX, out uint dpiY);
[StructLayout(LayoutKind.Sequential)] public struct APPBARDATA { public uint cbSize; public IntPtr hWnd; public uint msg; public uint edge; public RECT rc; public IntPtr lParam; }
'@
# R6-L2: subst drive targets, for the local-only path check
Add-Type -Namespace BL -Name Dos -MemberDefinition @'
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint QueryDosDevice(string name, System.Text.StringBuilder target, int max);
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
# Kern: Segoe UI Variable (Windows 11) when installed, else plain Segoe UI; every label also sets FontWeight SemiBold,
# so the fallback is Segoe UI Semibold with identical metrics, never a silent per-glyph substitute.
function global:Get-UiFontName {
    try { foreach ($f in [System.Windows.Media.Fonts]::SystemFontFamilies) { if ($f.Source -eq 'Segoe UI Variable') { return 'Segoe UI Variable Text Semibold, Segoe UI Semibold, Segoe UI' } } } catch {}
    return 'Segoe UI'
}
$global:UiFont       = New-Object System.Windows.Media.FontFamily (Get-UiFontName)
$global:Theme        = @{ panel = '#141414'; restartFill = '#2A2A2A'; restartRed = '#E5484D'; amber = '#F59E0B'; editText = '#111111' }
# Option B / Kern palette: old default fill -> @(new fill, label colour). All labels pass WCAG AA (4.5:1).
$global:ModernFill   = @{ '#3EC3EE' = @('#0B6E99', '#FFFFFF'); '#0E8A55' = @('#0E7A4B', '#FFFFFF'); '#B48CF5' = @('#7B4FD6', '#FFFFFF')
                          '#FFFF00' = @('#FACC15', '#111111'); '#7F7F7F' = @('#5F6368', '#FFFFFF'); '#FF0000' = @('#C40000', '#FFFFFF')
                          '#F0E68C' = @('#F0E68C', '#111111'); '#FA8072' = @('#B8432F', '#FFFFFF'); '#DAA520' = @('#8A6100', '#FFFFFF') }
$global:Acronyms     = @('PLCE', 'PC', 'POS', 'VNC', 'KBS', 'USB', 'TV', 'ID', 'IT', 'PA', 'DOR')
$global:app          = $null
$global:relayoutTimer = $null
$global:forceRelayout = $false                                   # R10-L1: next relayout runs even if nothing seems changed
$global:lastLayoutSig = $null                                     # idle CPU: last laid-out state
$global:labelSink    = $null
$global:single       = $null                                      # one-panel layout window state (layout 'single')
$global:middle       = $null                                      # middle icons: @{ cols; items }
$global:tray         = $null
$global:hotkeySrc    = $null
$global:hotkeyOk     = $false
$global:trayIcon     = $null                                      # OP-N1: app.ico Icon behind the tray, disposed on exit
$global:toastTimer   = $null                                      # CC OP-L1: one Undo-toast timer for all removes
$global:iconCache    = @{}                                         # OP-L1/OP-L3: chip icons, key = path|LastWriteTimeUtc ticks
$global:iconCacheOrder = New-Object System.Collections.ArrayList          # R6-N2: insertion order for the cap
$global:IconCacheMax = 256
$global:AppVersion   = '1.3.0'
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

# I-R6c: files matching a detect pattern, walked one path segment at a time so wildcard matches that are links
# (junctions/symlinks) are never entered; only a local fixed-drive result is returned.
function global:Find-LocalMatch([string]$pattern) {
    $x = ([string]$pattern).Replace('/', '\')
    if (-not (Test-LocalFixedPath $x)) { return $null }
    $segs = @($x.Substring(3).Split([char]'\') | Where-Object { $_ })
    $cur = @($x.Substring(0, 3))
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $last = ($i -eq $segs.Count - 1); $next = @()
        foreach ($c in $cur) {
            $seg = $segs[$i] -replace '([\[\]`])', '`$1'   # R8-N1: [ ] in folder names match themselves; only * and ? are wildcards
            foreach ($it in @(Get-ChildItem -LiteralPath $c -Force -ErrorAction SilentlyContinue)) {
                if (-not ($it.Name -like $seg) -or ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                if ($last -and -not $it.PSIsContainer) { $next += $it.FullName } elseif (-not $last -and $it.PSIsContainer) { $next += $it.FullName } } }
        $cur = $next; if (-not $cur) { return $null } }
    foreach ($f in $cur) { if (Test-LocalFixedPath $f) { return $f } }
    return $null
}
# R8-L1: find a shortcut by exact file name under $root; never enters junction/symlink folders; at most 6 levels deep
function global:Find-LnkLocal([string]$root, [string]$name, [int]$depth = 0) {
    if ($depth -gt 6) { return $null }
    $dirs = @()
    foreach ($it in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
        if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($it.PSIsContainer) { $dirs += $it.FullName } elseif ($it.Name -eq $name) { return $it } }
    foreach ($d in $dirs) { $f = Find-LnkLocal $d $name ($depth + 1); if ($f) { return $f } }
    return $null
}
function global:Find-Detected($btn, [switch]$AllowNetwork) {   # TS-L2: automatic (first-run) use skips non-local detect paths
    $d = $btn.detect; if (-not $d) { return $null }
    foreach ($pat in @($d.paths)) {
        if (-not $pat) { continue }
        $e = Expand $pat
        if (Test-LocalFixedPath $e) { $hit = Find-LocalMatch $e; if ($hit) { return $hit }; continue }
        if (-not $AllowNetwork) { continue }
        $hit = Get-ChildItem -Path $e -File -ErrorAction SilentlyContinue | Select-Object -First 1   # the user clicked: a network path is fine
        if ($hit) { return $hit.FullName }
    }
    if ($d.lnkNames) {
        $roots = @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'),
                   [Environment]::GetFolderPath('CommonStartMenu'), [Environment]::GetFolderPath('StartMenu'))
        $ws = New-Object -ComObject WScript.Shell
        foreach ($r in $roots) {
            if (-not $r -or (-not $AllowNetwork -and -not (Test-LocalFixedPath $r)) -or -not (Test-Path $r)) { continue }   # TS-L2: folders redirected to a share
            foreach ($n in @($d.lnkNames)) {
                $lnk = Find-LnkLocal $r ($n + '.lnk')   # R8-L1: manual walk, skips links, depth 6
                if ($lnk) { $tp = $ws.CreateShortcut($lnk.FullName).TargetPath; if ($tp -and ($AllowNetwork -or (Test-LocalFixedPath $tp)) -and (Test-Path $tp)) { return $tp }; return $lnk.FullName }
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
    $found = Find-Detected $btn -AllowNetwork   # the user clicked: network detect paths are fine
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
                if (Test-VncPickerButton $btn) { Show-VncPicker $btn; return $false }   # v1.3.0: View Register opens the picker (no flash)
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
        if ($p -like 'TODO*') { $p = $null } else { $p = Resolve-IconTarget $p }    # R6-L2/OP-N3: draw-time icons only from local fixed-drive files
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { $p = Join-Path $env:SystemRoot 'explorer.exe' }
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($p)
        return [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { return $null }
}


function global:Get-DefaultPic([string]$kind) { switch ($kind) { 'website' { 'images/globe.png' } 'file' { 'images/guide.png' } 'script' { 'images/screenconnect.png' } 'builtin' { 'images/power.png' } default { 'images/register.png' } } }
function global:Resolve-Img($path) { if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $global:here $path } }

function global:Get-PicSource($btn, $px) {
    if (-not $btn.image) { return $null }
    if ($btn.image -eq 'icon') { return Get-IconImage $btn.target }
    $p = Resolve-Img $btn.image
    if (-not (Test-LocalFixedPath $p)) { $p = Resolve-Img (Get-DefaultPic (Get-ButtonType $btn)) }   # TS-L2: non-local picture -> default art, never touched
    if ($px -and $px -le 48) {   # small spots use "<name>-small.png" when it exists (e.g. Red Dog logo without the wordmark)
        $sm = Join-Path ([IO.Path]::GetDirectoryName($p)) ([IO.Path]::GetFileNameWithoutExtension($p) + '-small' + [IO.Path]::GetExtension($p))
        if ((Test-LocalFixedPath $sm) -and (Test-Path -LiteralPath $sm)) { $p = $sm }   # Lockjaw R7-I2
    }
    if (-not (Test-Path -LiteralPath $p)) { return $null }
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
# ---------- Direction 2 "Fluent 3D" (v1.3.0, approved by Charles). Kern's spec: frozen gradient brushes per state, a
# pre-built glow layer, no per-tile effects and no blur. Only Opacity and transforms animate, so idle CPU is unchanged.
# Key = the Option B fill; value = rest top/bottom, hover top/bottom, pressed top/bottom, glow.
$global:D2Fill = @{
    '#0B6E99' = @('#0B6E99', '#085171', '#15749D', '#095A7D', '#0A638A', '#074B68', '#549AB8')
    '#0E7A4B' = @('#0E7A4B', '#0A5A38', '#187F52', '#0B643E', '#0D6E44', '#0A5333', '#56A281')
    '#7B4FD6' = @('#7B4FD6', '#5B3A9E', '#8056D8', '#6541AF', '#6F47C1', '#543692', '#A384E2')
    '#FACC15' = @('#FAD028', '#D7AF12', '#FBD336', '#EBC014', '#EBC014', '#C39F10', '#FCDB5B')
    '#5F6368' = @('#5F6368', '#46494D', '#65696E', '#4E5155', '#56595E', '#414347', '#8F9295')
    '#C40000' = @('#C40000', '#910000', '#C60A0A', '#A10000', '#B00000', '#850000', '#D64C4C')
    '#F0E68C' = @('#F1E895', '#CEC678', '#F2EA9C', '#E2D884', '#E2D884', '#BBB36D', '#F4EEAE')
    '#8A6100' = @('#8A6100', '#664800', '#8F670A', '#715000', '#7C5700', '#5E4200', '#AD904C')
    'restart' = @('#2E2E2E', '#1E1E1E', '#333333', '#242424', '#242424', '#1A1A1A', '#E5484D') }
function global:ConvertTo-Hex($x) { '#{0:X2}{1:X2}{2:X2}' -f $x.R, $x.G, $x.B }
function global:Get-D2Fill([string]$bg, [bool]$danger) {   # any other colour the user picked gets the same recipe, derived
    if ($danger) { return $global:D2Fill['restart'] }
    $k = $bg.Trim().ToUpperInvariant()
    if ($global:D2Fill.ContainsKey($k)) { return $global:D2Fill[$k] }
    $c = Get-Color $k; $w = Get-Color '#FFFFFF'; $b = Get-Color '#000000'
    return @((ConvertTo-Hex $c), (ConvertTo-Hex (Mix-Color $c $b 0.26)), (ConvertTo-Hex (Mix-Color $c $w 0.04)), (ConvertTo-Hex (Mix-Color $c $b 0.18)),
             (ConvertTo-Hex (Mix-Color $c $b 0.10)), (ConvertTo-Hex (Mix-Color $c $b 0.33)), (ConvertTo-Hex (Mix-Color $c $w 0.30)))
}
function global:New-VGrad([string]$top, [string]$bottom) {   # frozen top-to-bottom gradient
    $g = New-Object System.Windows.Media.LinearGradientBrush ((Get-Color $top), (Get-Color $bottom), 90.0); $g.Freeze(); return $g
}
function global:New-GlowBrush([string]$hex, [double]$alpha, [double]$inner = 0.55, [double]$rx = 0.5, [double]$ry = 0.5) {   # soft radial glow, pre-built once (no blur effect)
    $c = Get-Color $hex; $a = [byte][Math]::Round(255 * $alpha)
    $g = New-Object System.Windows.Media.RadialGradientBrush; $g.RadiusX = $rx; $g.RadiusY = $ry
    [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb($a, $c.R, $c.G, $c.B)), $inner))
    [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0, $c.R, $c.G, $c.B)), 1.0))
    $g.Freeze(); return $g
}
$global:D2IconShadow = $null   # built on first use (WPF must be loaded)
function global:Set-D2Surface($b, [double]$radius, [int]$sheenPx, [string]$sheenTop) {   # gradient rim; returns the top sheen layer
    $b.BorderBrush = New-VGrad '#47FFFFFF' '#0FFFFFFF'; $b.BorderThickness = '1'; $b.CornerRadius = [string]$radius
    $sh = New-Object System.Windows.Controls.Border; $sh.IsHitTestVisible = $false; $sh.Height = $sheenPx; $sh.VerticalAlignment = 'Top'
    $r = [Math]::Max(0, $radius - 1); $sh.CornerRadius = ('{0},{0},0,0' -f $r); $sh.Background = New-VGrad $sheenTop '#00FFFFFF'
    return $sh
}
function global:Set-D2Hairline($hair, $edge, [string]$sides) {   # Kern: 1 px #66000000 just outside the rim on the non-docked sides.
    # The edge padding shrinks by the same 1 px on those sides, so the window never grows.
    $t = [System.Windows.Thickness](New-Object System.Windows.ThicknessConverter).ConvertFromString($sides)
    $hair.BorderBrush = Brush '#66000000'; $hair.BorderThickness = $t
    $edge.Padding = New-Object System.Windows.Thickness (3 - $t.Left), (3 - $t.Top), (3 - $t.Right), (3 - $t.Bottom)
    $r = $edge.CornerRadius
    $hair.CornerRadius = New-Object System.Windows.CornerRadius ($(if ($r.TopLeft) { $r.TopLeft + 1 } else { 0 })), ($(if ($r.TopRight) { $r.TopRight + 1 } else { 0 })), ($(if ($r.BottomRight) { $r.BottomRight + 1 } else { 0 })), ($(if ($r.BottomLeft) { $r.BottomLeft + 1 } else { 0 }))
}
function global:Set-D2Panel($edge, [string]$corners) {   # panel: dark glass gradient at 90%, 12% rim, 18% top highlight
    $edge.Background = New-VGrad '#E626262C' '#E616161A'; $edge.BorderBrush = New-VGrad '#2EFFFFFF' '#1FFFFFFF'; $edge.BorderThickness = '1'
    $edge.CornerRadius = $corners
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
# LJ: draw-time checks touch only local fixed-drive paths (no SMB/NTLM traffic just from drawing a panel).
function global:Get-DriveTypeName([string]$root) { ([IO.DriveInfo]::new($root)).DriveType.ToString() }
function global:Get-DosDeviceTarget([string]$drive) {   # 'C:' -> '\Device\HarddiskVolume3'; a subst drive -> '\??\D:\dir' or '\??\UNC\srv\share'
    $sb = New-Object System.Text.StringBuilder 1024
    if ([BL.Dos]::QueryDosDevice($drive, $sb, 1024) -eq 0) { return $null }
    return $sb.ToString() }
function global:Get-PathAttr([string]$p) { try { [int][IO.File]::GetAttributes($p) } catch { $null } }   # $null = not there
# Draw-time probes; tests swap these for mocks.
$global:PathProbe = @{ DriveType = { param($r) Get-DriveTypeName $r }; DosDevice = { param($d) Get-DosDeviceTarget $d }; Attr = { param($p) Get-PathAttr $p } }
# True only for a path on this PC's own fixed disk: no UNC (\\, //, \\?\, \\?\UNC, \\.\), no mapped network drive, no subst drive
# onto a share (R6-L2), and no reparse point (symlink/junction, OP-N2) or cloud/offline placeholder (R6-L2) in the path or any parent.
function global:Test-LocalFixedPath([string]$path, [scriptblock]$DriveType, [int]$depth = 0) {
    if (-not $DriveType) { $DriveType = $global:PathProbe.DriveType }
    $x = ([string]$path).Trim().Trim('"')
    if (-not $x -or $depth -gt 4) { return $false }
    if ($x.StartsWith('\\') -or $x.StartsWith('//') -or $x.StartsWith('\/') -or $x.StartsWith('/\')) { return $false }   # UNC, \\?\, \\?\UNC, \\.\
    if ($x -notmatch '^[A-Za-z]:[\\/]') { return $false }                                     # relative or odd paths: no
    try { $t = [string](& $DriveType ($x.Substring(0, 2) + '\')) } catch { return $false }
    if ($t -ne 'Fixed') { return $false }
    $dd = $null; try { $dd = [string](& $global:PathProbe.DosDevice $x.Substring(0, 2)) } catch {}
    if ($dd -match '^\\\?\?\\(.*)$') {                                                          # subst: check what it points at
        $inner = $matches[1]; if ($inner -match '^(?i)UNC\\') { return $false }
        return (Test-LocalFixedPath ($inner.TrimEnd('\') + '\' + $x.Substring(3)) $DriveType ($depth + 1)) }
    if ($dd -match '^(?i)\\Device\\(Mup|LanmanRedirector|WebDavRedirector)') { return $false }
    $bad = 0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000                                      # ReparsePoint, Offline, RECALL_ON_OPEN, RECALL_ON_DATA_ACCESS
    # R7-L1: root-down (drive root's first folder, then each deeper one); stop at the first link so nothing past it is read
    $cur = $x.Substring(0, 2)
    foreach ($seg in @($x.Substring(3).Replace('/', '\').Split([char]'\') | Where-Object { $_ })) {
        $cur = $cur + '\' + $seg
        $a = & $global:PathProbe.Attr $cur
        if ($a -eq $null) { break }                                                             # not there yet: nothing deeper to read
        if ([int]$a -band $bad) { return $false } }
    return $true
}
# OP-N3: the file whose icon is drawn: the checked target itself, or for a .lnk its checked target (never the .lnk's own
# icon location). $null when nothing local is safe to read.
function global:Resolve-IconTarget([string]$t, [scriptblock]$DriveType, [scriptblock]$ReadLnk) {
    if (-not (Test-SafeIconSource $t $DriveType $ReadLnk)) { return $null }
    if ($t -notmatch '(?i)\.lnk$') { return $t }
    if (-not $ReadLnk) { $ReadLnk = { param($l) @{ target = (New-Object -ComObject WScript.Shell).CreateShortcut($l).TargetPath } } }
    try { $lt = Expand ([string](& $ReadLnk $t).target) } catch { return $null }
    if ($lt -and (Test-LocalFixedPath $lt $DriveType)) { return $lt }
    return $null
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
# 'ok', 'missing' or 'unchecked'. Non-local targets (UNC, \\?\UNC, \\.\, mapped network drives, a .lnk pointing off
# this PC) are 'unchecked': never touched while drawing and never shown as missing; they are resolved on click.
function global:Get-SetupState($btn, [scriptblock]$DriveType, [scriptblock]$ReadLnk) {
    $kind = Get-ButtonType $btn
    if ($kind -notin 'program', 'file', 'script') { return 'ok' }
    $t = Expand $btn.target
    $unchecked = $false
    if (-not (Is-Todo $t)) {
        if ($kind -eq 'program' -and $t -notmatch '[\\/]') { return 'ok' }
        if (-not (Test-LocalFixedPath $t $DriveType)) { $unchecked = $true }
        elseif (-not (Test-Path -LiteralPath $t)) { }
        elseif ($t -match '(?i)\.lnk$') {
            $lt = ''; try { $lt = Expand ([string](& $(if ($ReadLnk) { $ReadLnk } else { { param($l) @{ target = (New-Object -ComObject WScript.Shell).CreateShortcut($l).TargetPath } } }) $t).target) } catch {}
            if (-not $lt -or (Test-LocalFixedPath $lt $DriveType)) { return 'ok' }
            return 'unchecked' }
        else { return 'ok' }
    }
    if ($btn.detect) { foreach ($pat in @($btn.detect.paths)) { $e = Expand $pat
        if (-not $e) { continue }
        if (-not (Test-LocalFixedPath $e $DriveType)) { $unchecked = $true; continue }
        if (Get-ChildItem -Path $e -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return 'ok' } } }
    if ($unchecked) { return 'unchecked' }
    return 'missing'
}
function global:Test-ButtonSetUpQuick($btn) { (Get-SetupState $btn) -ne 'missing' }   # draw-time: only 'missing' gets the dot
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
    if ($lab.sub) { $sl = New-Label $lab.sub $fg 12; $sl.FontWeight = [System.Windows.FontWeights]::Normal; $sl.LineHeight = 14; $sl.Opacity = 0.85; [void]$text.Children.Add($sl) }   # Kern: 12 px Regular
    $isRedDog = ([string]$btn.image) -match '(?i)reddog'
    if ($isRedDog -and $cls -eq 'hero') { $ipx = 64 }
    $src = Get-PicSource $btn $ipx
    $missingPic = (-not $src) -and $btn.image -and [string]$btn.image -ne 'icon'
    if ($missingPic) {
        Add-Content -LiteralPath $global:logPath -Value ("{0}  picture not found for '{1}': {2}" -f (Get-Date -Format s), (([string]$btn.label) -replace "`n", ' '), (Resolve-Img ([string]$btn.image))) -ErrorAction SilentlyContinue }
    $icon = $null
    if ($src) {
        # D2: restart icons keep their own emoji colours; the red 2 px outline carries the danger cue
        $img = New-Object System.Windows.Controls.Image; $img.Source = $src; $img.Stretch = 'Uniform'; $img.Width = $ipx; $img.Height = $ipx
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
        if ($isRedDog) {   # full-colour Red Dog on a white 8 px plate (its red is under 3:1 on the cyan fill alone)
            $plate = New-Object System.Windows.Controls.Border; $plate.Background = [System.Windows.Media.Brushes]::White
            $plate.CornerRadius = '8'; $plate.Padding = '4'; $plate.Child = $img; $icon = $plate
        } else {   # pre-baked soft contact shadow under the emoji (a static gradient, not an effect)
            if (-not $global:D2IconShadow) { $global:D2IconShadow = New-GlowBrush '#000000' 0.30 }
            $ig = New-Object System.Windows.Controls.Grid; $ig.Width = $ipx; $ig.Height = $ipx
            $sh = New-Object System.Windows.Shapes.Ellipse; $sh.Width = $ipx * 0.72; $sh.Height = [Math]::Max(4, $ipx * 0.16)
            $sh.VerticalAlignment = 'Bottom'; $sh.Margin = ('0,0,0,{0}' -f (-[Math]::Round($ipx * 0.06))); $sh.Fill = $global:D2IconShadow
            [void]$ig.Children.Add($sh); [void]$ig.Children.Add($img); $icon = $ig }
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
    return @{ el = $sp; missingPic = $missingPic; icon = $icon }
}

# One tile (D2 Fluent 3D): 12 px gradient fill, gradient rim, top sheen, pre-built glow, hover lift + glow, press 0.97, launch flash, 2 px focus ring,
# dashed outline while editing, amber dot when not set up.
function global:New-Tile($p, $btn) {
    $h = if ($btn.height) { [double]$btn.height } else { 80 }
    $h = [Math]::Max(44, $h)                                  # 44 px minimum tile
    $cls = if ($btn.width -eq 'half') { 'half' } elseif ($h -ge 110) { 'hero' } else { 'full' }
    $danger = Test-DangerButton $btn
    $col = Get-TileColors $btn
    $fillHex = if ($danger) { $global:Theme.restartFill } else { $col.bg }
    $fgHex = if ($danger) { '#FFFFFF' } else { $col.fg }
    # D2: three frozen gradient layers (rest, hover, pressed) stacked; only their Opacity animates, never a brush or an effect
    $f = Get-D2Fill $fillHex $danger
    $rad = if ($cls -eq 'hero') { 14 } else { 12 }
    $oProp = [System.Windows.UIElement]::OpacityProperty

    $wrap = New-Object System.Windows.Controls.Grid; $wrap.Margin = '3'                  # 3 + 3 = Kern's 6 px gap
    $glowMax = if ($danger) { 0.35 } else { 0.70 }
    # Kern v1.3.0 Major 1: 6 px halo (inside the panel's 3+3 padding and the 6 px gaps); radial 85% at 0.70 -> 0 at 1.0
    $glow = New-Object System.Windows.Controls.Border; $glow.IsHitTestVisible = $false; $glow.Margin = '-6'; $glow.Opacity = 0
    $glow.CornerRadius = [string]($rad + 6); $glow.Background = New-GlowBrush $f[6] 0.85 0.70 0.62 0.75; $glow.Height = $h + 12
    $wrap.ClipToBounds = $false
    $tile = New-Object System.Windows.Controls.Border; $tile.Background = New-VGrad $f[0] $f[1]; $tile.Height = $h
    $sheen = Set-D2Surface $tile $rad 10 '#4DFFFFFF'; $sheen.Opacity = 0.73   # 30% brush: 22% at rest, 30% hover, 12% pressed
    if ($danger) { $tile.BorderBrush = Brush $global:Theme.restartRed; $tile.BorderThickness = '2' }
    $lift = New-Object System.Windows.Media.TranslateTransform 0, 0
    $press = New-Object System.Windows.Media.ScaleTransform 1, 1
    $tg = New-Object System.Windows.Media.TransformGroup; $tg.Children.Add($press); $tg.Children.Add($lift)
    $tile.RenderTransform = $tg; $tile.RenderTransformOrigin = '0.5,0.5'
    $glowLift = New-Object System.Windows.Media.TranslateTransform 0, 0; $glow.RenderTransform = $glowLift
    $tile.Cursor = [System.Windows.Input.Cursors]::Hand; $tile.Focusable = $true; $tile.FocusVisualStyle = $null
    $tile.ToolTip = $btn.target
    $g = New-Object System.Windows.Controls.Grid
    $ir = [string]([Math]::Max(0, $rad - 1))
    $hov = New-Object System.Windows.Controls.Border; $hov.IsHitTestVisible = $false; $hov.Opacity = 0; $hov.CornerRadius = $ir; $hov.Background = New-VGrad $f[2] $f[3]
    $prs = New-Object System.Windows.Controls.Border; $prs.IsHitTestVisible = $false; $prs.Opacity = 0; $prs.CornerRadius = $ir; $prs.Background = New-VGrad $f[4] $f[5]
    $shade = New-Object System.Windows.Controls.Border; $shade.IsHitTestVisible = $false; $shade.BorderThickness = '0,0,0,1'
    $shade.BorderBrush = Brush '#40000000'; $shade.CornerRadius = ('0,0,{0},{0}' -f $ir)
    [void]$g.Children.Add($hov); [void]$g.Children.Add($prs); [void]$g.Children.Add($sheen); [void]$g.Children.Add($shade)
    $c = New-Content $btn $h $cls $danger $fgHex
    $c.el.Margin = '12,8'; [void]$g.Children.Add($c.el)
    $iscale = New-Object System.Windows.Media.ScaleTransform 1, 1
    if ($c.icon) { $c.icon.RenderTransform = $iscale; $c.icon.RenderTransformOrigin = '0.5,0.5' }
    $flash = New-Object System.Windows.Controls.Border; $flash.IsHitTestVisible = $false; $flash.Opacity = 0
    $flash.Background = [System.Windows.Media.Brushes]::White; $flash.CornerRadius = $ir; [void]$g.Children.Add($flash)
    if (-not [bool]$global:cfg.locked) {   # edit mode: 2 px dashed white outline at 60% inside the tile
        $eo = New-Object System.Windows.Shapes.Rectangle; $eo.IsHitTestVisible = $false; $eo.Stroke = Brush '#99FFFFFF'; $eo.StrokeThickness = 2
        $eo.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (,[double[]](4, 3)); $eo.RadiusX = $rad - 2; $eo.RadiusY = $rad - 2; $eo.Margin = '2'
        [void]$g.Children.Add($eo) }
    if ($c.missingPic) { [void]$g.Children.Add((New-MissingDot ("Picture not found: " + [string]$btn.image))) }
    else { $ss = Get-SetupState $btn
        if ($ss -eq 'missing') { [void]$g.Children.Add((New-MissingDot 'Not set up on this PC yet')) }
        elseif ($ss -eq 'unchecked') { $tile.ToolTip = [string]$btn.target + "`n(network location: not checked until you click)" } }
    $g.Background = [System.Windows.Media.Brushes]::Transparent
    $tile.Child = $g
    $ring = New-Object System.Windows.Controls.Border; $ring.IsHitTestVisible = $false; $ring.Margin = '-4'; $ring.CornerRadius = [string]($rad + 4)
    $ring.BorderThickness = '2'; $ring.BorderBrush = [System.Windows.Media.Brushes]::White; $ring.Visibility = 'Hidden'
    [void]$wrap.Children.Add($glow); [void]$wrap.Children.Add($tile); [void]$wrap.Children.Add($ring)

    $st = @{ down = $false }
    $yProp = [System.Windows.Media.TranslateTransform]::YProperty
    $sxProp = [System.Windows.Media.ScaleTransform]::ScaleXProperty; $syProp = [System.Windows.Media.ScaleTransform]::ScaleYProperty
    $toHover = {
        Start-Anim $lift $yProp -2 120 -Ease; Start-Anim $glowLift $yProp -2 120 -Ease
        Start-Anim $press $sxProp 1 120 -Ease; Start-Anim $press $syProp 1 120 -Ease
        Start-Anim $glow $oProp $glowMax 120 -Ease; Start-Anim $hov $oProp 1 120 -Ease; Start-Anim $prs $oProp 0 120 -Ease
        Start-Anim $sheen $oProp 1 120 -Ease
        Start-Anim $iscale $sxProp 1.06 120 -Ease; Start-Anim $iscale $syProp 1.06 120 -Ease }.GetNewClosure()
    $toRest = {
        Start-Anim $lift $yProp 0 120 -Ease; Start-Anim $glowLift $yProp 0 120 -Ease
        Start-Anim $press $sxProp 1 120 -Ease; Start-Anim $press $syProp 1 120 -Ease
        Start-Anim $glow $oProp 0 120 -Ease; Start-Anim $hov $oProp 0 120 -Ease; Start-Anim $prs $oProp 0 120 -Ease
        Start-Anim $sheen $oProp 0.73 120 -Ease
        Start-Anim $iscale $sxProp 1 120 -Ease; Start-Anim $iscale $syProp 1 120 -Ease }.GetNewClosure()
    $toPress = {
        Start-Anim $lift $yProp 0 60; Start-Anim $glowLift $yProp 0 60
        Start-Anim $press $sxProp 0.97 60; Start-Anim $press $syProp 0.97 60
        Start-Anim $glow $oProp ($glowMax * 0.43) 60; Start-Anim $prs $oProp 1 60; Start-Anim $sheen $oProp 0.4 60
        Start-Anim $iscale $sxProp 1 60; Start-Anim $iscale $syProp 1 60 }.GetNewClosure()
    $run = {
        $ok = Invoke-Button $btn                   # launch first; the flash never delays it
        if ($ok -eq $true) { Start-Flash $flash } }.GetNewClosure()
    $tile.Add_MouseEnter({ if (-not $st.down) { & $toHover } }.GetNewClosure())
    $tile.Add_MouseLeave({ if (-not $st.down) { & $toRest } }.GetNewClosure())
    $tile.Add_MouseLeftButtonDown({
        $st.down = $true; [void]$tile.CaptureMouse(); $_.Handled = $true
        & $toPress
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
    $tile.Add_KeyDown({ if (($_.Key -eq 'Enter' -or $_.Key -eq 'Space') -and -not $_.IsRepeat) { $_.Handled = $true; & $toPress; & $run; if ($tile.IsMouseOver) { & $toHover } else { & $toRest } }
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
        if ($kind -eq 'program' -and $t -notmatch '[\\/]') { return $true }
        if (-not (Test-LocalFixedPath $t)) { return $true }   # TS-L2: non-local = not checked here (resolved on click), never listed as missing
        if (Test-Path -LiteralPath $t) { return $true }
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
    $close.IsDefault = $true; $d.Add_ContentRendered({ [void]$close.Focus() }.GetNewClosure())   # a stray Enter/Space closes it; a file picker only opens on a Pick... click
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

# R12-L2: DPI scale of the monitor holding a work area (the dock target), before the window is on it
function global:Get-WorkAreaDpi($wa, $fallbackPanel) {
    try {
        $pt = New-Object BL.Native+POINT; $pt.X = [int](($wa.L + $wa.R) / 2); $pt.Y = [int](($wa.T + $wa.B) / 2)
        $mon = [BL.Native]::MonitorFromPoint($pt, 2)                                    # MONITOR_DEFAULTTONEAREST
        $x = [uint32]0; $y = [uint32]0
        if ($mon -ne [IntPtr]::Zero -and [BL.Native]::GetDpiForMonitor($mon, 0, [ref]$x, [ref]$y) -eq 0 -and $x -gt 0) { return $x / 96.0 }   # MDT_EFFECTIVE_DPI
    } catch {}
    return (Get-Dpi $fallbackPanel) }
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

# Idle CPU: Windows sends WM_SETTINGCHANGE/WM_DEVICECHANGE often, and our own resizes raise SizeChanged. After the
# debounce, lay out only when something that affects layout changed (screens, work areas, DPI, settings).
function global:Get-LayoutSig {
    $scr = @(foreach ($x in [System.Windows.Forms.Screen]::AllScreens) { '{0}|{1}' -f $x.Bounds, $x.WorkingArea }) -join ';'
    $dp = @(foreach ($o in $global:panels) { '{0}:{1}:{2}' -f (Get-Dpi $o), [bool]$o.win.IsVisible, [bool]($o.hwnd -and $o.hwnd -ne [IntPtr]::Zero) }) -join ','
    $cf = $global:cfg | ConvertTo-Json -Depth 12 -Compress
    $rc = @(foreach ($h in @(@($global:panels | ForEach-Object { $_.hwnd }) + @($(if ($global:single) { $global:single.hwnd })))) {   # R10-L1: each window's own size/position
        if ($h -and $h -ne [IntPtr]::Zero) { $r = New-Object BL.Native+RECT; if ([BL.Native]::GetWindowRect($h, [ref]$r)) { '{0},{1},{2},{3}' -f $r.Left, $r.Top, $r.Right, $r.Bottom } } }) -join ';'
    $sh = if ($global:single) { [bool]($global:single.hwnd -and $global:single.hwnd -ne [IntPtr]::Zero) } else { 'none' }
    return "$scr#$dp#$rc#$sh#$($global:middle.items.Count)#$cf" }
function global:Invoke-Relayout([switch]$Force) {
    $sig = Get-LayoutSig
    if (-not $Force -and $sig -eq $global:lastLayoutSig) { return $false }   # nothing changed: no layout pass, no SetWindowPos
    $global:lastLayoutSig = $sig
    if ($global:single) { Layout-Single } else { foreach ($o in $global:panels) { Layout-Panel $o } }
    $global:lastLayoutSig = Get-LayoutSig   # after our own move/resize, so it doesn't count as a change next time
    return $true }
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
    $h2 = New-Object System.Windows.Controls.TextBlock; $h2.Text = $(if (Test-Path -LiteralPath (Join-Path $global:here 'Build-Installer.ps1')) { 'PC setup, panels, installer' } else { 'PC setup, panels' }); $h2.FontSize = 12; $h2.Foreground = Brush '#A0A0A0'
    [void]$hs.Children.Add($h1); [void]$hs.Children.Add($h2); $setup.Header = $hs
    [void](Add-MenuItem $setup 'Set up this PC...' { Show-SetupWindow })
    if (Test-Path -LiteralPath (Join-Path $global:here 'Build-Installer.ps1')) { [void](Add-MenuItem $setup 'Build installer...' { Save-Config; Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $global:here 'Build-Installer.ps1')`"" }) }   # installed copies ship without the builder
    [void](Add-MenuItem $setup 'View-only register password...' { [void](Show-VncPasswordDialog $null) })
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
    $edge = New-Object System.Windows.Controls.Border; $edge.Padding = '3'
    if ($bgc -eq $global:Theme.panel) { Set-D2Panel $edge $(if ($square) { '0' } else { '16' }) }   # D2 glass panel; a custom panel colour stays flat
    else { $edge.Background = Brush $bgc; $edge.CornerRadius = if ($square) { '0' } else { '16' } }
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
    $edge.Child = $dock
    if ($square) { $w.Content = $edge; $hair = $null }
    else { $hair = New-Object System.Windows.Controls.Border; $hair.Child = $edge; Set-D2Hairline $hair $edge '1,1,1,1'; $w.Content = $hair }   # floating: no docked side
    $p.win = $w; $p.stack = $stack; $p.grip = $grip; $p.edge = $edge; $p.scale = $scale; $p.hair = $hair
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
        $t = $w.Topmost; $w.Topmost = $true; $w.Topmost = $t; [void]$w.Activate(); $global:forceRelayout = $true; Request-Relayout; return }   # R10-L1
    $reopen = @($global:panels | Where-Object { -not $_.deleted -and -not $_.win.IsVisible })
    foreach ($p in $reopen) { [void]$global:panels.Remove($p); [void](Open-Panel $p.cfg) }
    if ($reopen.Count) { Apply-Lock }
    foreach ($p in $global:panels) {
        if ($p.win.WindowState -eq 'Minimized') { $p.win.WindowState = 'Normal' }
        $t = $p.win.Topmost; $p.win.Topmost = $true; $p.win.Topmost = $t
        [void]$p.win.Activate()
    }
    $global:forceRelayout = $true; Request-Relayout   # R10-L1: second launch, tray Show, Ctrl+Alt+L always re-dock
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
# One panel is the default; a saved value is kept (R9-N1: trimmed, any case). R9-M1: with no saved value, a config
# with more than 2 panels opens as two panels so no buttons are hidden.
function global:Get-LayoutMode($cfg) {
    $v = ([string]$cfg.layout).Trim().ToLowerInvariant()
    if ($v -eq 'two') { return 'two' }
    if ($v -eq 'single') { return 'single' }
    if (@($cfg.panels).Count -gt 2) { return 'two' }
    return 'single' }
# Judgement (R11): remember how many hidden panels were noticed; notice again only if more become hidden.
# Old builds wrote a boolean hiddenPanelsNoticeShown; it carries no count, so it reads as 0.
function global:Get-HiddenNoticed($cfg) { $v = $cfg.hiddenPanelsNoticed; if ($v -is [int] -or $v -is [long] -or $v -is [double]) { [int]$v } else { 0 } }
function global:Test-HiddenPanelsNotice($cfg, [bool]$single) { $hidden = @($cfg.panels).Count - 2; $single -and $hidden -gt 0 -and $hidden -gt (Get-HiddenNoticed $cfg) }
function global:Get-HiddenPanelsText($cfg) {
    $n = @($cfg.panels).Count - 2
    "The one-panel layout shows your first two panels. $n more panel$(if ($n -ne 1) { 's' }) and $(if ($n -ne 1) { 'their' } else { 'its' }) buttons are kept, just not shown.`n`nTo see every panel: unlock, right-click a panel > Setup > Layout > Two panels, then Setup > Reload." }
function global:Get-MiddleHint([int]$count, [bool]$locked) {   # empty + unlocked: a subtle hint; locked: nothing
    if ($count -eq 0 -and -not $locked) { return 'Right-click here to add icons' }   # laptop test: it is already unlocked here
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
function global:Get-ChipFallbackPic([string]$kind) {
    switch ($kind) { 'website' { 'images/globe.png' } 'file' { 'images/chip-document.png' } 'script' { 'images/chip-files.png' } default { 'images/register.png' } }
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
            # OP-L3: local fixed-drive targets only (OP-L1); cached by path + last-write time, so a rebuild never re-reads the file
            # OP-N3: the icon comes from the checked target (for a .lnk, its checked target), never the .lnk's own icon location
            $src = Resolve-IconTarget $t
            if ($src) {
                $fi = $null; try { $fi = Get-Item -LiteralPath $src -ErrorAction Stop } catch {}
                if ($fi -and -not $fi.PSIsContainer) {
                    $ck = $src.ToLowerInvariant() + '|' + $fi.LastWriteTimeUtc.Ticks
                    if (-not $global:iconCache.ContainsKey($ck)) {
                        $bs = $null
                        try { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($src)
                              $bs = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                              $ico.Dispose(); $bs.Freeze() } catch { $bs = $null }
                        while ($global:iconCacheOrder.Count -ge $global:IconCacheMax) {   # R6-N2: capped, oldest dropped first
                            [void]$global:iconCache.Remove($global:iconCacheOrder[0]); $global:iconCacheOrder.RemoveAt(0) }
                        $global:iconCache[$ck] = $bs; [void]$global:iconCacheOrder.Add($ck) }
                    if ($global:iconCache[$ck]) { return $global:iconCache[$ck] } } } }
    }
    return Get-PicSource ([pscustomobject]@{ image = (Get-ChipFallbackPic $kind) }) 32
}
function global:New-Chip($btn, [int]$index) {
    $chip = New-Object System.Windows.Controls.Border; $chip.Height = 64; $chip.Margin = '3'
    $chip.Background = Brush '#A6141414'; $chipSheen = Set-D2Surface $chip 10 8 '#24FFFFFF'   # D2: 65% fill, gradient rim, 8 px sheen at 14%
    $chip.Cursor = [System.Windows.Input.Cursors]::Hand; $chip.Focusable = $true; $chip.FocusVisualStyle = $null; $chip.AllowDrop = $true
    $full = (([string]$btn.label) -replace '\\n', ' ').Trim(); if (-not $full) { $full = [string]$btn.target }
    $chip.ToolTip = $full + $(if ($btn.target -and $full -ne [string]$btn.target) { "`n" + [string]$btn.target } else { '' })
    $g = New-Object System.Windows.Controls.Grid; [void]$g.Children.Add($chipSheen)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'; $sp.Margin = '8'
    $src = Get-ChipIcon $btn
    if ($src) { $img = New-Object System.Windows.Controls.Image; $img.Source = $src; $img.Width = 32; $img.Height = 32; $img.Margin = '0,0,0,6'
                [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality'); [void]$sp.Children.Add($img) }
    $tb = New-Label (Get-ChipLabel $btn) '#FFFFFF' 12; $tb.TextWrapping = 'NoWrap'; $tb.TextTrimming = 'CharacterEllipsis'
    $tb.HorizontalAlignment = 'Center'; $tb.TextAlignment = 'Center'; [void]$sp.Children.Add($tb)
    [void]$g.Children.Add($sp)
    $flash = New-Object System.Windows.Controls.Border; $flash.IsHitTestVisible = $false; $flash.Opacity = 0; $flash.CornerRadius = '9'
    $flash.Background = [System.Windows.Media.Brushes]::White; [void]$g.Children.Add($flash)
    if (-not [bool]$global:cfg.locked) {
        $eo = New-Object System.Windows.Shapes.Rectangle; $eo.IsHitTestVisible = $false; $eo.Stroke = Brush '#99FFFFFF'; $eo.StrokeThickness = 2
        $eo.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (,[double[]](4, 3)); $eo.RadiusX = 6; $eo.RadiusY = 6; $eo.Margin = '2'
        [void]$g.Children.Add($eo) }
    $ss = Get-SetupState $btn   # local-only: non-local targets are 'unchecked' (no dot, tooltip), resolved on click
    if ($ss -eq 'missing') { [void]$g.Children.Add((New-MissingDot 'Not set up on this PC yet')) }
    elseif ($ss -eq 'unchecked') { $chip.ToolTip = [string]$chip.ToolTip + "`n(network location: not checked until you click)" }
    $chip.Child = $g
    $st = @{ down = $false; start = $null; dragged = $false }
    # OP-L2: like tiles, capture on press; launch only on a release inside this chip that follows its own press
    $chip.Add_MouseLeftButtonDown({ $st.down = $true; $st.dragged = $false; $st.start = $_.GetPosition($null); [void]$chip.CaptureMouse(); $_.Handled = $true; Play-Click }.GetNewClosure())
    $chip.Add_MouseMove({
        if (-not $st.down -or [bool]$global:cfg.locked -or $_.LeftButton -ne 'Pressed') { return }
        $pt = $_.GetPosition($null)
        if ([Math]::Abs($pt.X - $st.start.X) -gt 4 -or [Math]::Abs($pt.Y - $st.start.Y) -gt 4) {   # edit mode: the whole chip drags
            $st.dragged = $true; $st.down = $false; $chip.ReleaseMouseCapture()
            [void][System.Windows.DragDrop]::DoDragDrop($chip, ('bl-chip:' + $index), [System.Windows.DragDropEffects]::Move) }
    }.GetNewClosure())
    $chip.Add_MouseLeftButtonUp({
        if (-not $st.down) { return }; $st.down = $false; $chip.ReleaseMouseCapture(); $_.Handled = $true
        $pos = $_.GetPosition($chip); $inside = ($pos.X -ge 0 -and $pos.Y -ge 0 -and $pos.X -le $chip.ActualWidth -and $pos.Y -le $chip.ActualHeight)
        if ($inside -and -not $st.dragged) { $ok = Invoke-Button $btn; if ($ok -eq $true) { Start-Flash $flash } }
    }.GetNewClosure())
    $chip.Add_LostMouseCapture({ $st.down = $false }.GetNewClosure())
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
    # CC OP-L1: one shared timer, restarted on every Remove, so an older toast's timer can't hide a newer toast early
    if (-not $global:toastTimer) {
        $global:toastTimer = New-Object System.Windows.Threading.DispatcherTimer; $global:toastTimer.Interval = [TimeSpan]::FromSeconds(5)
        $global:toastTimer.Add_Tick({ $global:toastTimer.Stop(); if ($global:single -and $global:single.toast) { $global:single.toast.Visibility = 'Collapsed' } }) }
    $ub.Add_Click({ $global:toastTimer.Stop(); $t.Visibility = 'Collapsed'; & $undo }.GetNewClosure())
    $global:toastTimer.Stop(); $global:toastTimer.Start()
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
        $more = New-Object System.Windows.Controls.Border; $more.Height = 28; $more.Margin = '3'
        $more.Background = Brush '#A6141414'; [void](Set-D2Surface $more 10 8 '#24FFFFFF'); $more.Cursor = [System.Windows.Input.Cursors]::Hand
        $mt = New-Label ("+{0} more {1}" -f $split.more, [char]0x25BE) '#FFFFFF' 12; $mt.HorizontalAlignment = 'Center'; $more.Child = $mt
        $pop = New-Object System.Windows.Controls.Primitives.Popup; $pop.StaysOpen = $false; $pop.PlacementTarget = $more; $pop.Placement = 'Left'
        $pop.AllowsTransparency = $true
        $pb = New-Object System.Windows.Controls.Border; Set-D2Panel $pb '12'; $pb.Padding = '3'; $pb.Width = 290
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
        $edge = New-Object System.Windows.Controls.Border; $edge.Padding = '3'
        Set-D2Panel $edge $(if ($gi -eq 0) { '0,0,0,16' } else { '16,0,0,0' })
        $dock = New-Object System.Windows.Controls.DockPanel
        $grip = New-Object System.Windows.Controls.Border
        if ($gi -eq 0) {   # Editing bar (top group only). Squint: lead with "Lock when done".
            $grip.Height = 28; $grip.Background = Brush $global:Theme.amber; $grip.CornerRadius = '8'; $grip.Margin = '3'; $grip.Padding = '10,0'
            $grip.ToolTip = 'Editing. Lock when done. Right-click a button or icon to change it.'
            $gt = New-Label 'Editing. Lock when done.' $global:Theme.editText 12; $gt.TextTrimming = 'CharacterEllipsis'; $gt.TextWrapping = 'NoWrap'; $grip.Child = $gt
            [System.Windows.Controls.DockPanel]::SetDock($grip, 'Top'); [void]$dock.Children.Add($grip) }
        $stack = New-Object System.Windows.Controls.StackPanel; [void]$dock.Children.Add($stack)
        $edge.Child = $dock
        $hair = New-Object System.Windows.Controls.Border; $hair.Child = $edge   # hairline sides set when docked (Set-SingleBounds)
        [System.Windows.Controls.Grid]::SetRow($hair, $(if ($gi -eq 0) { 0 } else { 2 })); [void]$root.Children.Add($hair)
        $p.win = $w; $p.stack = $stack; $p.grip = $grip; $p.edge = $edge; $p.scale = $scale; $p.menuHost = $edge; $p.hair = $hair
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
    $dpi = Get-WorkAreaDpi $wa $global:panels[0]   # R12-L2: target monitor's scale, so the first layout / a monitor move isn't sized for the old one
    if ([Math]::Abs((Get-Dpi $global:panels[0]) - $dpi) -gt 0.001) {   # on another monitor's scale: move there first, then size (WPF rescales on the move)
        [void][BL.Native]::SetWindowPos($s.hwnd, [IntPtr]::Zero, [int]$wa.L, [int]$wa.T, 0, 0, 0x0015) }
    $pct = if ($pc.size -is [string] -and $global:SizePct[[string]$pc.size]) { $global:SizePct[[string]$pc.size] } elseif ($pc.size) { [double]$pc.size } else { 14 }
    $wDip = [Math]::Max(180, [Math]::Min(560, ($wa.W * $pct / 100.0) / $dpi))
    $sc = $wDip / $global:BaseWidth
    $hDip = $wa.H / $dpi
    $s.scale.ScaleX = $sc; $s.scale.ScaleY = $sc
    $s.root.Height = $hDip / $sc
    $s.win.SizeToContent = 'Manual'; $s.win.Width = $global:BaseWidth * $sc; $s.win.Height = $hDip   # laptop fix: the window itself fills the work area (DIPs; root is scaled by $sc), so the bottom group isn't cut off
    foreach ($g in $global:panels) { Apply-MinFont $g }; Apply-MinFont $s
    $s.win.UpdateLayout()
    $groupsH = 0; foreach ($g in $global:panels) { $groupsH += $g.edge.ActualHeight }
    if ($groupsH -gt $s.root.Height) {   # groups alone don't fit: shrink to fit (tiles keep their 44 px minimum in layout units)
        $sc = $sc * $s.root.Height / $groupsH; $s.scale.ScaleX = $sc; $s.scale.ScaleY = $sc; $s.root.Height = $hDip / $sc; $s.win.Width = $global:BaseWidth * $sc; $s.win.Height = $hDip
        foreach ($g in $global:panels) { Apply-MinFont $g }; $s.win.UpdateLayout(); $groupsH = 0; foreach ($g in $global:panels) { $groupsH += $g.edge.ActualHeight } }
    $avail = [Math]::Max(0, $s.root.Height - $groupsH - 32)
    $need = Get-OverflowSplit $global:middle.items.Count $avail $global:middle.cols
    $s.availH = $avail
    if ($need.shown -ne $s.lastShown) { Build-Middle; $s.win.UpdateLayout() }
    $wPx = [int][Math]::Round($s.win.Width * $dpi)   # the size we just set (ActualWidth can lag a layout pass)
    $left = ([string]$pc.anchor) -like '*left*'
    $x = if ($left) { $wa.L } else { $wa.R - $wPx }
    foreach ($g in $global:panels) {   # Kern: 16 on the inner corners, 0 on the docked edge; hairline only on the sides away from the screen edge
        $top = ($g -eq $global:panels[0])
        $g.edge.CornerRadius = $(if ($top) { if ($left) { '0,0,16,0' } else { '0,0,0,16' } } else { if ($left) { '0,16,0,0' } else { '16,0,0,0' } })
        if ($g.hair) { Set-D2Hairline $g.hair $g.edge $(if ($top) { if ($left) { '0,0,1,1' } else { '1,0,0,1' } } else { if ($left) { '0,1,1,0' } else { '1,1,0,0' } }) } }
    [void][BL.Native]::SetWindowPos($s.hwnd, [IntPtr]::Zero, [int]$x, [int]$wa.T, $wPx, [int]$wa.H, 0x0014)   # NOZORDER|NOACTIVATE: exact work-area size in physical px
}

# ---------- tray icon + Ctrl+Alt+L (both layouts) ----------
function global:Start-TrayAndHotkey {
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ico = Join-Path $global:here 'images\app.ico'
        if (Test-Path -LiteralPath $ico) { $global:trayIcon = New-Object System.Drawing.Icon $ico; $ni.Icon = $global:trayIcon }   # OP-N1: disposed in Stop-TrayAndHotkey
        else { $ni.Icon = [System.Drawing.SystemIcons]::Application }
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
# R10-N2/R11-M1: event waits that post to the UI thread (second-launch signal, resume from sleep). C# 5, .NET 4.8.
$global:WaitsSource = @'
namespace BL {
public static class Waits {
    static Microsoft.Win32.PowerModeChangedEventHandler resume;
    public static void WatchHandle(System.Threading.WaitHandle h, System.Windows.Threading.Dispatcher d, System.Action a) {
        System.Threading.ThreadPool.RegisterWaitForSingleObject(h, delegate(object s, bool t) { d.BeginInvoke(a); }, null, -1, false); }
    public static void WatchResume(System.Windows.Threading.Dispatcher d, System.Action a) {
        UnwatchResume();
        resume = delegate(object s, Microsoft.Win32.PowerModeChangedEventArgs e) { if (e.Mode == Microsoft.Win32.PowerModes.Resume) d.BeginInvoke(a); };
        Microsoft.Win32.SystemEvents.PowerModeChanged += resume; }
    public static void UnwatchResume() {
        if (resume != null) { Microsoft.Win32.SystemEvents.PowerModeChanged -= resume; resume = null; } }
} }
'@
function global:Stop-TrayAndHotkey {
    try { if ($global:hotkeyOk -and $global:hotkeySrc) { [void][BL.Native]::UnregisterHotKey($global:hotkeySrc.Handle, 0xB10) } } catch {}
    try { if ($global:hotkeySrc) { $global:hotkeySrc.Dispose() } } catch {}
    try { if ($global:tray) { $global:tray.Visible = $false; $global:tray.Dispose() } } catch {}
    try { if ($global:trayIcon) { $global:trayIcon.Dispose() } } catch {}   # OP-N1
    try { if ('BL.Waits' -as [type]) { [BL.Waits]::UnwatchResume() } } catch {}   # R11-N1: drop the PowerModeChanged handler
    $global:hotkeyOk = $false; $global:hotkeySrc = $null; $global:tray = $null; $global:trayIcon = $null   # safe to call twice (Exit + finally)
}

# ---------- VNC register picker (v1.3.0) ----------
# View Register opens a picker of UltraVNC hosts found on this PC's own private subnets.
# UltraVNC viewer switches, checked against https://uvnc.com/docs/ultravnc-viewer/52-ultravnc-viewer-commandline-parameters.html
# and the viewer source (github.com/ultravnc/UltraVNC vncviewer/VNCOptions.cpp, ClientConnectionFile.cpp):
#   host::port   two colons = a TCP port (host:N with one colon is display N = port 5900+N), so we always use '::'
#   -viewonly    do not send keyboard or mouse events;   -autoscaling   scale the remote screen to fit
#   -config file load host, port and the obfuscated password from a .vnc file ([connection] host=, port=, password=<16 hex>)
# The -password switch is never used: a password must never be on a command line.
$global:VncDefaultPort = 5900
$global:VncTimeoutMs   = 300
$global:VncParallel    = 16
$global:VncPaceMs      = 40
$global:VncCacheMaxAge = [TimeSpan]::FromDays(1)
$global:VncEntropy     = [Text.Encoding]::UTF8.GetBytes('ButtonLauncher.VNC.ViewOnly.v1')
$global:VncDesKey      = [byte[]](0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0)   # vncauth.c fixedkey {23,82,107,6,35,78,88,7}, bit-reversed for standard DES. Obfuscation, not encryption.
$global:vncPicker      = $null

function global:Test-VncIPv4([string]$s) {
    if ($s -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($i in 1..4) { $o = $matches[$i]; if (($o.Length -gt 1 -and $o[0] -eq '0') -or [int]$o -gt 255) { return $false } }
    return $true
}
function global:Test-VncHost([string]$s) {   # untrusted: an IPv4 dotted quad, or a hostname of [A-Za-z0-9.-]
    if (-not $s -or $s.Length -gt 253) { return $false }
    if ($s -match '^[\d.]+$') { return (Test-VncIPv4 $s) }
    if ($s -cnotmatch '^[A-Za-z0-9.-]+$') { return $false }
    foreach ($l in $s.TrimEnd('.').Split('.')) { if ($l.Length -lt 1 -or $l.Length -gt 63 -or $l.StartsWith('-') -or $l.EndsWith('-')) { return $false } }
    return $true
}
function global:Get-VncPort($p) {   # an integer 1-65535, else $null
    $s = ([string]$p).Trim()
    if ($s -notmatch '^\d{1,5}$') { return $null }
    $n = [int]$s; if ($n -lt 1 -or $n -gt 65535) { return $null }
    return $n
}
function global:ConvertTo-VncEndpoint([string]$text, [int]$defaultPort = 5900) {   # 'host' or 'host:port' -> @{ host; port } or $null
    $t = ([string]$text).Trim(); $port = $defaultPort
    if ($t -match '^([^:]+)::?(\d+)$') { $t = $matches[1]; $port = Get-VncPort $matches[2]; if (-not $port) { return $null } }
    elseif ($t.Contains(':')) { return $null }
    if (-not (Test-VncHost $t)) { return $null }
    return @{ host = $t; port = [int]$port }
}
function global:Test-Rfc1918([string]$ip) {
    if (-not (Test-VncIPv4 $ip)) { return $false }
    $o = @($ip.Split('.') | ForEach-Object { [int]$_ })
    return ($o[0] -eq 10 -or ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) -or ($o[0] -eq 192 -and $o[1] -eq 168))
}
function global:ConvertTo-VncUInt([string]$ip) { $o = $ip.Split('.'); return ([uint32]$o[0] * 16777216 + [uint32]$o[1] * 65536 + [uint32]$o[2] * 256 + [uint32]$o[3]) }
function global:ConvertFrom-VncUInt([uint32]$n) { return ('{0}.{1}.{2}.{3}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255)) }
function global:Get-VncPrefix($cfgPrefix) {   # setting: default /24; never wider than /22; at most /30
    $p = 24; $s = ([string]$cfgPrefix).Trim(); if ($s -match '^\d{1,2}$') { $p = [int]$s }
    if ($p -lt 22) { $p = 22 }; if ($p -gt 30) { $p = 30 }
    return $p
}
# Addresses to probe around this PC's own address: never wider than the adapter's own subnet or the setting, private only.
function global:Get-VncScanTargets([string]$ip, [int]$adapterPrefix, $cfgPrefix) {
    if (-not (Test-Rfc1918 $ip)) { return @() }
    $p = [Math]::Max([int]$adapterPrefix, (Get-VncPrefix $cfgPrefix)); if ($p -gt 30) { return @() }
    $self = ConvertTo-VncUInt $ip
    $size = [uint32][Math]::Pow(2, 32 - $p); $net = [uint32]([Math]::Floor($self / $size) * $size)
    $out = New-Object System.Collections.Generic.List[string]
    for ($n = $net + 1; $n -lt $net + $size - 1; $n++) { if ($n -ne $self) { $a = ConvertFrom-VncUInt ([uint32]$n); if (Test-Rfc1918 $a) { $out.Add($a) } } }
    return $out.ToArray()
}
# H1: only Ethernet (6) / Wi-Fi (71) adapters that are up, not VPN/virtual by name, with an IPv4 gateway inside their own subnet. Never PPP.
$global:VncAdapterDeny = '(?i)VPN|\bTAP\b|TAP-|\bTUN\d*\b|WireGuard|Wintun|AnyConnect|GlobalProtect|PANGP|Forti|OpenVPN|Zscaler|Tailscale|ZeroTier|Juniper|Pulse Secure|Hyper-V|vEthernet|\bWSL\b|VirtualBox|VMware|Npcap|Loopback|WAN Miniport|Teredo|isatap|Virtual|Tunnel|NordLynx|WARP|Cloudflare|Surfshark|Mullvad|Proton|Windscribe|Sophos|Check ?Point|SonicWall|NetExtender|Citrix|Ivanti'
function global:Test-VncAdapter([string]$type, [string]$desc, [string]$name, [string]$ip, [int]$prefix, $gateways) {
    if ($type -notin 'Ethernet', 'GigabitEthernet', 'Wireless80211') { return $false }   # Ppp, Tunnel, Loopback, Unknown, ... never
    if (($desc -match $global:VncAdapterDeny) -or ($name -match $global:VncAdapterDeny)) { return $false }
    if (-not (Test-Rfc1918 $ip) -or $prefix -lt 1 -or $prefix -gt 30) { return $false }
    $size = [Math]::Pow(2, 32 - $prefix); $net = [Math]::Floor((ConvertTo-VncUInt $ip) / $size)
    foreach ($g in @($gateways)) { $gs = [string]$g; if ((Test-VncIPv4 $gs) -and $gs -ne '0.0.0.0' -and [Math]::Floor((ConvertTo-VncUInt $gs) / $size) -eq $net) { return $true } }
    return $false
}
function global:Get-VncRangeText([string]$ip, [int]$adapterPrefix, $cfgPrefix) {   # '192.168.1.0/24' (the range Get-VncScanTargets covers)
    $p = [Math]::Max($adapterPrefix, (Get-VncPrefix $cfgPrefix)); $size = [Math]::Pow(2, 32 - $p)
    return ('{0}/{1}' -f (ConvertFrom-VncUInt ([uint32]([Math]::Floor((ConvertTo-VncUInt $ip) / $size) * $size))), $p)
}
function global:Get-VncLocalSubnets {   # @{ ip; prefix; label } for adapters that pass Test-VncAdapter
    $res = @()
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        $props = $nic.GetIPProperties()
        $gws = @($props.GatewayAddresses | ForEach-Object { if ($_.Address.AddressFamily -eq 'InterNetwork') { $_.Address.ToString() } })
        foreach ($u in $props.UnicastAddresses) {
            if ($u.Address.AddressFamily -ne 'InterNetwork') { continue }
            $a = $u.Address.ToString(); $pl = 24; try { $pl = [int]$u.PrefixLength } catch {}
            if (-not (Test-VncAdapter ([string]$nic.NetworkInterfaceType) ([string]$nic.Description) ([string]$nic.Name) $a $pl $gws)) { continue }
            $lbl = if ([string]$nic.NetworkInterfaceType -eq 'Wireless80211') { 'Wi-Fi' } else { 'Ethernet' }
            $gw = Get-VncSubnetGateway $a $pl $gws
            $ix = $null; try { $ix = $props.GetIPv4Properties().Index } catch {}
            $res += @{ ip = $a; prefix = $pl; label = $lbl; gw = $gw; dns = [string]$props.DnsSuffix; gwId = (Get-VncGatewayId $gw $ix) } } }
    return $res
}
function global:Get-VncSubnetGateway([string]$ip, [int]$prefix, $gateways) {   # first IPv4 gateway inside the adapter's subnet, else ''
    $size = [Math]::Pow(2, 32 - $prefix); $net = [Math]::Floor((ConvertTo-VncUInt $ip) / $size)
    foreach ($g in @($gateways)) { $gs = [string]$g; if ((Test-VncIPv4 $gs) -and $gs -ne '0.0.0.0' -and [Math]::Floor((ConvertTo-VncUInt $gs) / $size) -eq $net) { return $gs } }
    return ''
}
function global:Get-VncRangeKey([string]$range, [string]$gw, [string]$dns, [string]$gwId) {   # R2-L1/R3-L1: same numbers on another network (home vs shop) ask again
    $d = ([string]$dns).Trim().ToLowerInvariant(); if ($d -notmatch '^[a-z0-9.-]{0,253}$') { $d = '?' }
    $i = ([string]$gwId).Trim().ToLowerInvariant(); if ($i -notmatch '^(mac=[0-9a-f-]{17}|net=[a-z0-9 ._-]{1,64})?$') { $i = '?' }
    return ('{0}|gw={1}|id={2}|dns={3}' -f $range, $gw, $i, $d)
}
function global:Test-VncRangeKeyCurrent([string]$key) { $key -match '\|id=[^|]*\|dns=' }   # R3-L1 migration: keys saved before v1.3.0 round 3 count as unconfirmed
function global:ConvertTo-VncGatewayId($mac, $profileName) {   # 'mac=aa-bb-cc-dd-ee-ff' from the ARP entry, else 'net=<profile name>', else ''
    $m = ([string]$mac).Trim().ToLowerInvariant() -replace ':', '-'
    if ($m -match '^[0-9a-f]{2}(-[0-9a-f]{2}){5}$' -and $m -ne '00-00-00-00-00-00' -and $m -ne 'ff-ff-ff-ff-ff-ff') { return 'mac=' + $m }
    $n = (([string]$profileName).Trim().ToLowerInvariant() -replace '[^a-z0-9 ._-]', '_'); if ($n.Length -gt 64) { $n = $n.Substring(0, 64) }
    if ($n) { return 'net=' + $n }
    return ''
}
$global:VncGwIdCache = @{}
function global:Get-VncGatewayId([string]$gw, $ifIndex) {   # the router's MAC (Get-NetNeighbor = the ARP table), else the Windows network profile name. Cached per session.
    if (-not $gw) { return '' }
    $ck = '{0}|{1}' -f $gw, $ifIndex; if ($global:VncGwIdCache.ContainsKey($ck)) { return $global:VncGwIdCache[$ck] }
    $mac = ''; $prof = ''
    try { $nbs = if ($ifIndex) { @(Get-NetNeighbor -IPAddress $gw -AddressFamily IPv4 -InterfaceIndex $ifIndex -ErrorAction Stop) } else { @(Get-NetNeighbor -IPAddress $gw -AddressFamily IPv4 -ErrorAction Stop) }
          $mac = Select-VncGatewayMac $nbs $ifIndex } catch {}
    if (-not $mac) { try { if ($ifIndex) { foreach ($cp in @(Get-NetConnectionProfile -InterfaceIndex $ifIndex -ErrorAction Stop)) { if (-not $prof) { $prof = [string]$cp.Name } } } } catch {} }
    $id = ConvertTo-VncGatewayId $mac $prof
    if ($id) { $global:VncGwIdCache[$ck] = $id }   # R4-L1: a failed lookup isn't cached, so the next open tries again
    return $id
}
function global:Select-VncGatewayMac($neighbors, $ifIndex) {   # R4-L1: first entry on this adapter with a real MAC (half-resolved, empty or all-zero entries skipped)
    foreach ($nb in @($neighbors)) {
        if (-not $nb) { continue }
        if ($ifIndex -and $nb.InterfaceIndex -and [int]$nb.InterfaceIndex -ne [int]$ifIndex) { continue }
        if ([string]$nb.State -in 'Unreachable', 'Incomplete') { continue }
        $m = [string]$nb.LinkLayerAddress
        if ((ConvertTo-VncGatewayId $m '') -like 'mac=*') { return $m } }
    return ''
}
function global:Get-VncNewRanges($ranges, $confirmed) { $c = @($confirmed); $out = @(); foreach ($r in @($ranges)) { if ($r -and $c -notcontains $r) { $out += $r } }; return $out }   # ranges never confirmed yet
function global:Get-VncRangeState([string]$key, $confirmed, $declined) { if (@($confirmed) -contains $key) { 'ok' } elseif (@($declined) -contains $key) { 'declined' } else { 'new' } }   # R2-L2
function global:Test-VncAutoScan([bool]$hasFavs, $cache, [datetime]$nowUtc, [bool]$hasNewRange) {   # favourites-first: with favourites, only a new (never answered) range scans on open
    if ($hasFavs) { return $hasNewRange }
    return ($hasNewRange -or (Test-VncCacheStale $cache $nowUtc))
}
function global:Get-SafeText([string]$s, [int]$max = 64) {   # display only: control characters out, length capped
    if (-not $s) { return '' }
    $t = [regex]::Replace($s, '[\x00-\x1F\x7F-\x9F]', '')
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }
    return $t
}
function global:Get-RfbBanner([byte[]]$bytes) {   # at most 12 bytes from the server; rfb only for exactly 'RFB ddd.ddd\n' (L4)
    if (-not $bytes -or $bytes.Length -eq 0) { return @{ text = ''; rfb = $false } }
    $n = [Math]::Min(12, $bytes.Length)
    $raw = -join ($bytes[0..($n - 1)] | ForEach-Object { [char]$_ })
    $isRfb = $raw -cmatch '^RFB \d{3}\.\d{3}\n$'
    return @{ text = (Get-SafeText ([regex]::Replace($raw, '[^\x20-\x7E]', '')) 12); rfb = [bool]$isRfb }
}
function global:Test-VncBannerText([string]$t) { $t -cmatch '^RFB \d{3}\.\d{3}$' }
function global:Get-VncDisplayName([string]$n, [int]$max = 40) {   # L5: shown with an ellipsis, never cut in config
    $t = Get-SafeText $n 1000; if ($t.Length -gt $max) { return ($t.Substring(0, $max - 1) + [char]0x2026) }; return $t
}
function global:Get-VncViewerArgs([string]$h, $port, [bool]$viewOnly, [string]$configFile) {   # an argument list; no shell
    if ($configFile) {
        if ($configFile -notmatch '^[A-Za-z]:\\[^"]+\.vnc$') { throw 'bad config path' }
        $a = @('-config', ('"' + $configFile + '"'))
    } else {
        $p = Get-VncPort $port
        if (-not (Test-VncHost $h) -or -not $p) { throw 'bad host or port' }
        $a = @(('{0}::{1}' -f $h, $p))
    }
    $a += '-autoscaling'
    if ($viewOnly) { $a += '-viewonly' }
    return $a
}
function global:ConvertTo-VncObfuscated([byte[]]$pw) {   # VNC password file form: first 8 bytes, zero padded, DES with the fixed key, as 16 hex digits
    $buf = New-Object byte[] 8
    $out = $null
    try {
        [Array]::Copy($pw, $buf, [Math]::Min(8, $pw.Length))
        $des = [System.Security.Cryptography.DES]::Create(); $des.Mode = 'ECB'; $des.Padding = 'None'
        $enc = $des.CreateEncryptor($global:VncDesKey, (New-Object byte[] 8))
        $out = $enc.TransformFinalBlock($buf, 0, 8); $enc.Dispose(); $des.Dispose()
        return (($out | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { [Array]::Clear($buf, 0, 8); if ($out) { [Array]::Clear($out, 0, $out.Length) } }
}
function global:New-VncConfigText([string]$h, [int]$port, [string]$hex, [bool]$viewOnly) {
    if (-not (Test-VncHost $h) -or -not (Get-VncPort $port) -or ($hex -notmatch '^[0-9a-f]{16}$')) { throw 'bad .vnc values' }
    $v = if ($viewOnly) { 1 } else { 0 }
    return "[connection]`r`nhost=$h`r`nport=$port`r`npassword=$hex`r`n[options]`r`nviewonly=$v`r`nAutoScaling=1`r`n"
}
# Config: buttons.json "vnc": { port, prefix, favorites: [ { host, port, name, pinned } ], viewOnlyAsked }
# Config: buttons.json "vnc": { port, prefix, favorites: [ { host, port, name, pinned } ], viewOnlyAsked, confirmedRanges }
function global:Get-VncState($cfg) {
    if (-not $cfg.vnc) { Set-Prop $cfg 'vnc' ([pscustomobject]@{ port = 5900; prefix = 24; favorites = @() }) }
    $v = $cfg.vnc
    $port = Get-VncPort $v.port; if (-not $port) { $port = 5900 }
    $favs = New-Object System.Collections.ArrayList; $bad = New-Object System.Collections.ArrayList
    foreach ($f in @($v.favorites)) {
        if (-not $f) { continue }
        if (-not (Test-VncHost ([string]$f.host)) -or ($f.port -ne $null -and -not (Get-VncPort $f.port))) { [void]$bad.Add($f); continue }   # L5: kept as-is, not shown
        $p = Get-VncPort $f.port; if (-not $p) { $p = $port }
        [void]$favs.Add([pscustomobject]@{ host = [string]$f.host; port = $p; name = [string]$f.name; pinned = [bool]$f.pinned }) }
    return @{ port = $port; prefix = (Get-VncPrefix $v.prefix); favorites = $favs; invalid = $bad; confirmed = @(@($v.confirmedRanges) | Where-Object { Test-VncRangeKeyCurrent ([string]$_) } | ForEach-Object { [string]$_ }); declined = @(@($v.declinedRanges) | Where-Object { Test-VncRangeKeyCurrent ([string]$_) } | ForEach-Object { [string]$_ }) }   # R3-L1: old keys dropped = unconfirmed
}
function global:Save-VncFavorites($cfg, $favs, $invalid) {   # invalid entries are written back untouched (L5)
    if (-not $cfg.vnc) { [void](Get-VncState $cfg) }
    $list = @($favs | ForEach-Object { [pscustomobject]@{ host = $_.host; port = $_.port; name = $_.name; pinned = [bool]$_.pinned } }) + @($invalid | Where-Object { $_ })
    Set-Prop $cfg.vnc 'favorites' $list
}
function global:Get-VncInvalidText($invalid) {
    $n = @($invalid).Count; if ($n -eq 0) { return '' }
    $what = (@($invalid | ForEach-Object { Get-VncDisplayName ([string]$_.host) 30 }) -join ', ')
    return ('{0} saved register(s) in buttons.json have an address that is not valid and are hidden: {1}' -f $n, $what)
}
function global:Set-VncFavorite($favs, [string]$h, [int]$port, $name, $pinned) {   # add or update; naming never pins (Squint 4); returns $false on bad input
    if (-not (Test-VncHost $h) -or -not (Get-VncPort $port)) { return $false }
    $f = $null; foreach ($x in $favs) { if ($x.host -eq $h -and $x.port -eq $port) { $f = $x; break } }
    if (-not $f) { $f = [pscustomobject]@{ host = $h; port = $port; name = ''; pinned = $false }; [void]$favs.Add($f) }
    if ($null -ne $name) { $f.name = Get-SafeText ([string]$name) 200 }   # $name untyped: [string] would turn $null into ''
    if ($pinned -ne $null) { $f.pinned = [bool]$pinned }
    return $true
}
function global:Read-VncCache([string]$path) {   # @{ time; hosts } ; hosts re-validated, RFB greetings only (L4)
    $r = @{ time = [datetime]::MinValue; hosts = @() }
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $r }
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $t = [datetime]::MinValue; if ($j.time -is [datetime]) { $r.time = $j.time.ToUniversalTime() } elseif ([datetime]::TryParse([string]$j.time, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { $r.time = $t.ToUniversalTime() }
        $r.hosts = @(@($j.hosts) | Where-Object { $_ -and (Test-VncIPv4 ([string]$_.host)) -and (Get-VncPort $_.port) -and (Test-VncBannerText ([string]$_.banner)) } | ForEach-Object {
            $nm = [string]$_.name; if (-not (Test-VncHost $nm)) { $nm = '' }
            [pscustomobject]@{ host = [string]$_.host; port = [int]$_.port; name = $nm; banner = [string]$_.banner } })
    } catch {}
    return $r
}
function global:Save-VncCache([string]$path, $hosts, [datetime]$time) {
    $o = [pscustomobject]@{ time = $time.ToUniversalTime().ToString('o'); hosts = @($hosts | ForEach-Object { [pscustomobject]@{ host = $_.host; port = $_.port; name = $_.name; banner = $_.banner } }) }
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}
function global:Test-VncCacheStale($cache, [datetime]$nowUtc) { return (($nowUtc - $cache.time) -gt $global:VncCacheMaxAge -or $cache.time -gt $nowUtc.AddMinutes(5)) }   # L3: by age only
function global:Get-VncAgeText($cacheTime, [datetime]$nowUtc) {   # '5 min ago', '3 h ago', '2 days ago'; '' if never
    if ($cacheTime -le [datetime]::MinValue) { return '' }
    $d = $nowUtc - $cacheTime; if ($d.TotalMinutes -lt 1) { return 'just now' }
    if ($d.TotalHours -lt 1) { return ('{0} min ago' -f [int][Math]::Floor($d.TotalMinutes)) }
    if ($d.TotalDays -lt 1) { return ('{0} h ago' -f [int][Math]::Floor($d.TotalHours)) }
    $n = [int][Math]::Floor($d.TotalDays); if ($n -eq 1) { return '1 day ago' }; return ('{0} days ago' -f $n)
}
function global:Merge-VncRows($favs, $hosts) {   # pinned first (by name), then the rest by address; seen = in the latest scan
    $rows = New-Object System.Collections.ArrayList
    foreach ($f in $favs) { $h = $null; foreach ($x in $hosts) { if ($x.host -eq $f.host -and $x.port -eq $f.port) { $h = $x; break } }
        [void]$rows.Add([pscustomobject]@{ host = $f.host; port = $f.port; name = $(if ($f.name) { $f.name } elseif ($h) { $h.name } else { '' }); banner = $(if ($h) { $h.banner } else { '' }); pinned = [bool]$f.pinned; fav = $true; seen = [bool]$h }) }
    foreach ($h in $hosts) { $isFav = $false; foreach ($x in $favs) { if ($x.host -eq $h.host -and $x.port -eq $h.port) { $isFav = $true } }; if (-not $isFav) {
        [void]$rows.Add([pscustomobject]@{ host = $h.host; port = $h.port; name = $h.name; banner = $h.banner; pinned = $false; fav = $false; seen = $true }) } }
    $sorted = @($rows | Sort-Object @{ e = { -not $_.pinned } }, @{ e = { if ($_.pinned) { $_.name } else { '' } } }, @{ e = { if (Test-VncIPv4 $_.host) { ConvertTo-VncUInt $_.host } else { [uint32]::MaxValue } } })
    return $sorted
}
function global:Get-VncRowView($r, [bool]$fresh, [bool]$scanning, [string]$age = '', [bool]$stale = $false) {   # display fields for one row (Squint 1, 3)
    $named = [bool]$r.name
    $seen = if ($r.seen) { if ($fresh) { 'Now' } else { 'Earlier' } } elseif ($scanning) { 'Looking...' } else { 'Not found last scan' }
    $dim = ((-not $r.seen) -and -not $scanning) -or ($r.seen -and $stale -and -not $fresh)
    $addr = if ($r.port -eq 5900) { $r.host } else { '{0}:{1}' -f $r.host, $r.port }
    $tip = $addr; if ($r.banner) { $tip += '   ' + (Get-SafeText $r.banner 12) }
    return [pscustomobject]@{
        star = $(if ($r.pinned) { [string][char]0xE735 } else { [string][char]0xE734 }); starOn = [bool]$r.pinned
        starName = $(if ($r.pinned) { 'Pinned' } else { 'Not pinned' })
        starTip = $(if ($r.pinned) { 'Pinned. Click or press Space to unpin.' } else { 'Not pinned. Click or press Space to pin.' })
        nameText = $(if ($named) { Get-VncDisplayName $r.name 40 } else { 'Unnamed (F2 to name)' })
        nameFg = $(if ($named -and -not $dim) { '#FFFFFF' } else { '#A0A0A0' }); addrFg = $(if ($dim) { '#A0A0A0' } else { '#FFFFFF' })
        addr = $addr; seen = $seen; tip = $tip; row = $r }
}
function global:Test-VncPickerButton($btn) {   # L2: the explicit flag, else only the stock View Register (label + stock askTitle or UltraVNC shortcut, no args)
    if ($btn.PSObject.Properties['vncPicker']) { return [bool]$btn.vncPicker }
    if ((Get-ButtonType $btn) -ne 'program' -or ([string]$btn.args).Trim()) { return $false }
    if ((([string]$btn.label) -replace '\s+', ' ').Trim() -ne 'VIEW REGISTER') { return $false }
    return (([string]$btn.askTitle) -eq 'Pick the UltraVNC Viewer (vncviewer.exe)' -or (@($btn.detect.lnkNames) -contains 'UltraVNC Viewer'))
}
function global:Test-VncUsePassword($row, [bool]$hasSecret) { $hasSecret -and [bool]$row.session -and (Test-VncBannerText ([string]$row.banner)) }   # L4 + V2-I1: only to a host that greeted RFB in this session's scan

# ----- view-only password: one shared value, DPAPI CurrentUser + app entropy, in vnc-viewonly.dat beside buttons.json -----
function global:Get-VncSecretPath { Join-Path (Split-Path -Parent $global:cfgPath) 'vnc-viewonly.dat' }
function global:Test-VncSecret { Test-Path -LiteralPath (Get-VncSecretPath) }
function global:Save-VncSecret([System.Security.SecureString]$ss) {   # $false (nothing saved) if any character is above 0xFF (V13-I1)
    Add-Type -AssemblyName System.Security
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss); $raw = $null; $prot = $null
    try {
        for ($i = 0; $i -lt $ss.Length; $i++) { if (([Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2) -band 0xFFFF) -gt 0xFF) { return $false } }
        $len = [Math]::Min(8, $ss.Length); $raw = New-Object byte[] $len   # UltraVNC uses the first 8 characters
        for ($i = 0; $i -lt $len; $i++) { $c = [Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2); $raw[$i] = [byte]($c -band 0xFF) }
        $prot = [System.Security.Cryptography.ProtectedData]::Protect($raw, $global:VncEntropy, 'CurrentUser')
        $p = Get-VncSecretPath; $tmp = $p + '.tmp'
        [IO.File]::WriteAllBytes($tmp, $prot)
        if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
        return $true
    } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); if ($raw) { [Array]::Clear($raw, 0, $raw.Length) } }
}
function global:Clear-VncSecret { $p = Get-VncSecretPath; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
function global:Get-VncSecretHex {   # obfuscated hex for the .vnc file, or $null; the plaintext bytes are zeroed
    $p = Get-VncSecretPath; if (-not (Test-Path -LiteralPath $p)) { return $null }
    Add-Type -AssemblyName System.Security
    $raw = $null
    try { $raw = [System.Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($p), $global:VncEntropy, 'CurrentUser'); return (ConvertTo-VncObfuscated $raw) }
    catch { return $null }
    finally { if ($raw) { [Array]::Clear($raw, 0, $raw.Length) } }
}
function global:Remove-VncTempDir([string]$dir) {   # V13-L1: only our bl-vnc-<guid> folder holding only c.vnc; no -Recurse. $true when gone.
    try {
        if ((Split-Path -Leaf $dir) -notmatch '^bl-vnc-[0-9a-f]{32}$') { return $false }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $true }
        $di = Get-Item -LiteralPath $dir -Force; if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        foreach ($it in $items) { if ($it.Name -ne 'c.vnc' -or $it.PSIsContainer -or ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false } }   # anything else: leave it alone
        $f = Join-Path $dir 'c.vnc'
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }
        [IO.Directory]::Delete($dir, $false)
        return $true
    } catch { return $false }
}
function global:Remove-VncTempLeftovers([int]$minAgeSec = 120) {   # old bl-vnc-* folders from a launch that couldn't clean up
    try { foreach ($d in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'bl-vnc-*' -Force -ErrorAction SilentlyContinue)) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if (((Get-Date) - $d.CreationTime).TotalSeconds -ge $minAgeSec) { [void](Remove-VncTempDir $d.FullName) } } } catch {}
}
# When to delete the .vnc (M2: polled, never blocks the UI thread). 'early' = the viewer quit within 6 s (likely a wrong saved password).
function global:Get-VncTempAction([double]$sec, [bool]$exited, [bool]$hasWindow, [double]$windowSec) {
    if ($exited) { if ($sec -lt 6) { return 'early' }; return 'delete' }
    if ($sec -ge 8 -or ($hasWindow -and ($sec - $windowSec) -ge 3)) { return 'delete' }
    return 'wait'
}
function global:Remove-VncTempSoon([string]$file, $proc, [scriptblock]$OnEarlyExit) {   # 1 s poll; delete 3 s after the viewer shows a window, or at 8 s; up to 5 more tries
    $dir = Split-Path -Parent $file; $state = @{ start = [DateTime]::UtcNow; win = -1.0; act = 'wait'; tries = 0 }
    $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds(1)
    $t.Add_Tick({
        $sec = ([DateTime]::UtcNow - $state.start).TotalSeconds
        if ($state.act -eq 'wait') {
            $ex = $true; $hw = $false; try { $proc.Refresh(); $ex = $proc.HasExited; $hw = (-not $ex) -and $proc.MainWindowHandle -ne [IntPtr]::Zero } catch {}
            if ($hw -and $state.win -lt 0) { $state.win = $sec }
            $state.act = Get-VncTempAction $sec $ex ($state.win -ge 0) $state.win
            if ($state.act -eq 'wait') { return }
            if ($state.act -eq 'early' -and $OnEarlyExit) { try { & $OnEarlyExit } catch {} } }
        $state.tries++
        if ((Remove-VncTempDir $dir) -or $state.tries -ge 6) { $t.Stop() } }.GetNewClosure())
    $t.Start()
}
function global:New-VncTempConfig([string]$h, [int]$port, [string]$hex) {   # %TEMP%\bl-vnc-<random>\c.vnc, folder ACL: this user only; nothing left behind on failure
    $dir = Join-Path $env:TEMP ('bl-vnc-' + [guid]::NewGuid().ToString('N'))
    $ok = $false
    try {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        $sec.SetOwner($me)
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        [void][IO.Directory]::CreateDirectory($dir, $sec)
        $f = Join-Path $dir 'c.vnc'
        $text = New-VncConfigText $h $port $hex $true
        $fs = New-Object IO.FileStream($f, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $b = [Text.Encoding]::ASCII.GetBytes($text); $fs.Write($b, 0, $b.Length); [Array]::Clear($b, 0, $b.Length) } finally { $fs.Dispose() }
        $ok = $true
        return $f
    } finally { if (-not $ok) { [void](Remove-VncTempDir $dir) } }
}
# ---------- D2 dialogs (Kern v1.3.0 Minor 6): panel gradient, 16 px padding, 32 px fields (radius 6, 6% fill, 12% rim, 2 px green focus line) ----------
$global:D2DialogRes = $null
function global:Get-D2DialogResources {   # the picker's button styles (Chip, Green, Blue), parsed once
    if (-not $global:D2DialogRes) {   # ClaudeCode N2: parse only the picker's <Window.Resources> block as a ResourceDictionary, not the whole window
        try { $m = [regex]::Match($global:VncPickerXaml, '(?s)<Window\.Resources>(.*?)</Window\.Resources>')
              $x = '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' + $m.Groups[1].Value + '</ResourceDictionary>'
              $global:D2DialogRes = [Windows.Markup.XamlReader]::Parse($x) } catch { Write-LauncherLog ('D2 dialog styles: ' + $_.Exception.Message) } }
    return $global:D2DialogRes
}
function global:New-D2Dialog([string]$title, $owner, [int]$width) {
    $d = New-Object System.Windows.Window; $d.Title = $title; $d.SizeToContent = 'WidthAndHeight'; $d.ResizeMode = 'NoResize'; $d.ShowInTaskbar = $false
    $d.WindowStartupLocation = if ($owner) { 'CenterOwner' } else { 'CenterScreen' }; if ($owner) { $d.Owner = $owner }
    $d.Background = New-VGrad '#26262C' '#16161A'; $d.FontFamily = $global:UiFont; $d.Foreground = Brush '#FFFFFF'
    $res = Get-D2DialogResources; if ($res) { foreach ($k in @($res.Keys)) { $d.Resources[$k] = $res[$k] } }   # copy the entries (a dictionary can't have two owners)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '16'; $sp.Width = $width; $d.Content = $sp
    return @{ win = $d; body = $sp }
}
function global:New-D2Label([string]$text, [string]$fg = '#FFFFFF', [int]$size = 14) {
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $text; $t.TextWrapping = 'Wrap'; $t.Foreground = Brush $fg; $t.FontSize = $size; $t.Margin = '0,0,0,8'; return $t
}
function global:New-D2Field($input) {   # wraps a TextBox or PasswordBox in the D2 field look
    $b = New-Object System.Windows.Controls.Border; $b.Height = 32; $b.CornerRadius = '6'; $b.Background = Brush '#0FFFFFFF'
    $b.BorderBrush = Brush '#1FFFFFFF'; $b.BorderThickness = '1'; $b.Margin = '0,0,0,16'
    $input.Background = [System.Windows.Media.Brushes]::Transparent; $input.BorderThickness = '0'; $input.Foreground = Brush '#FFFFFF'
    $input.CaretBrush = Brush '#FFFFFF'; $input.FontSize = 14; $input.VerticalContentAlignment = 'Center'; $input.Padding = '6,0'
    $line = New-Object System.Windows.Controls.Border; $line.Height = 2; $line.VerticalAlignment = 'Bottom'; $line.Background = Brush '#22C55E'; $line.Visibility = 'Hidden'
    $line.CornerRadius = '0,0,6,6'; $line.IsHitTestVisible = $false
    $g = New-Object System.Windows.Controls.Grid; [void]$g.Children.Add($input); [void]$g.Children.Add($line); $b.Child = $g
    $input.Add_GotKeyboardFocus({ $line.Visibility = 'Visible' }.GetNewClosure()); $input.Add_LostKeyboardFocus({ $line.Visibility = 'Hidden' }.GetNewClosure())
    return $b
}
function global:New-D2Button([string]$text, [string]$style, $dlg) {
    $b = New-Object System.Windows.Controls.Button; $b.Content = $text; $b.Margin = '8,0,0,0'; $b.MinWidth = 84
    $s = $null; try { $s = $dlg.win.TryFindResource($style) } catch {}
    if ($s) { $b.Style = $s } else { $b.Height = 32; $b.Padding = '14,0' }
    return $b
}
function global:Show-VncAddDialog($owner) {   # Squint 4 + Kern 6: one dialog, Address and Name (optional). Cancel adds nothing. Returns @{ addr; name } or $null.
    $dlg = New-D2Dialog 'Add a register' $owner 380
    [void]$dlg.body.Children.Add((New-D2Label 'Address (IP or name, optionally :port)'))
    $tA = New-Object System.Windows.Controls.TextBox; $tA.MaxLength = 260; [void]$dlg.body.Children.Add((New-D2Field $tA))
    [void]$dlg.body.Children.Add((New-D2Label 'Name (optional, e.g. Register 1). Leave empty to name it later with F2.'))
    $tN = New-Object System.Windows.Controls.TextBox; $tN.MaxLength = 64; [void]$dlg.body.Children.Add((New-D2Field $tN))
    $err = New-D2Label '' '#F59E0B' 12; $err.Visibility = 'Collapsed'; [void]$dlg.body.Children.Add($err)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'
    $res = @{ out = $null }
    $bOk = New-D2Button 'Add' 'Green' $dlg; $bOk.IsDefault = $true
    $bNo = New-D2Button 'Cancel' 'Chip' $dlg; $bNo.IsCancel = $true
    $bOk.Add_Click({
        if (-not $tA.Text.Trim()) { $err.Text = "Type the register's address first."; $err.Visibility = 'Visible'; [void]$tA.Focus(); return }
        $res.out = @{ addr = $tA.Text.Trim(); name = $tN.Text.Trim() }; $dlg.win.Close() }.GetNewClosure())
    $bNo.Add_Click({ $res.out = $null; $dlg.win.Close() }.GetNewClosure())
    [void]$row.Children.Add($bOk); [void]$row.Children.Add($bNo); [void]$dlg.body.Children.Add($row)
    $dlg.win.Add_ContentRendered({ [void]$tA.Focus() }.GetNewClosure())
    [void]$dlg.win.ShowDialog()
    return $res.out
}
function global:Show-VncPasswordDialog($owner) {   # set, replace or clear the shared view-only password; returns $true when one is saved
    $dlg = New-D2Dialog 'View-only password' $owner 380; $d = $dlg.win; $sp = $dlg.body   # Kern 6: D2 dialog
    $t = New-D2Label ''
    $t.Text = "If your registers have a view-only password, type it here. It's saved for this Windows user only and used for View only. Interact always asks for its own password.`n`nUltraVNC uses the first 8 characters (standard letters, numbers and symbols). If View only can't connect later, change it in Setup > View-only register password..."
    [void]$sp.Children.Add($t)
    $st = New-Object System.Windows.Controls.TextBlock; $st.Margin = '0,8,0,0'; $st.Foreground = Brush '#A0A0A0'; $st.FontSize = 12; $st.TextWrapping = 'Wrap'
    $st.Text = if (Test-VncSecret) { 'A view-only password is saved.' } else { 'No view-only password is saved: View only connects straight through.' }
    [void]$sp.Children.Add($st)
    $pb = New-Object System.Windows.Controls.PasswordBox; $pb.MaxLength = 64
    $pf = New-D2Field $pb; $pf.Margin = '0,8,0,16'; [void]$sp.Children.Add($pf)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'
    $res = @{ saved = $false }
    $bSave = New-D2Button 'Save' 'Green' $dlg; $bSave.IsDefault = $true
    $bNone = New-D2Button 'No password' 'Chip' $dlg
    $bCancel = New-D2Button 'Cancel' 'Chip' $dlg; $bCancel.IsCancel = $true
    $bSave.Add_Click({
        if ($pb.SecurePassword.Length -gt 0) {
            if (-not (Save-VncSecret $pb.SecurePassword)) {   # V13-I1: a character above 0xFF
                $pb.Clear(); $st.Text = "That password has a character UltraVNC can't use. Use standard letters, numbers and symbols, then Save again."; $st.Foreground = Brush '#F59E0B'; [void]$pb.Focus(); return }
            $res.saved = $true }
        $pb.Clear(); $d.Close() }.GetNewClosure())
    $bNone.Add_Click({ Clear-VncSecret; $pb.Clear(); $d.Close() }.GetNewClosure())
    $bCancel.Add_Click({ $pb.Clear(); $d.Close() }.GetNewClosure())
    foreach ($b in $bSave, $bNone, $bCancel) { [void]$row.Children.Add($b) }
    [void]$sp.Children.Add($row)
    $d.Add_ContentRendered({ [void]$pb.Focus() }.GetNewClosure())
    if ($global:cfg) { [void](Get-VncState $global:cfg); Set-Prop $global:cfg.vnc 'viewOnlyAsked' $true; Save-Config }
    [void]$d.ShowDialog()
    return $res.saved
}

function global:Find-VncViewer($btn) {   # local fixed path to vncviewer.exe, or $null; asks once and saves it on the button
    $t = Expand $btn.target
    if (-not (Is-Todo $t) -and (Test-LocalFixedPath $t) -and (Test-Path -LiteralPath $t -PathType Leaf)) { return $t }
    $f = Find-Detected $btn   # local detect paths only
    if (-not $f) { foreach ($k in 'HKCU:', 'HKLM:') { try {
        $v = [string](Get-ItemProperty -LiteralPath "$k\Software\Microsoft\Windows\CurrentVersion\App Paths\vncviewer.exe" -ErrorAction Stop).'(default)'
        $v = (Expand $v).Trim('"'); if ($v -and (Test-LocalFixedPath $v) -and (Test-Path -LiteralPath $v -PathType Leaf)) { $f = $v; break } } catch {} } }
    if (-not $f) {
        [System.Windows.MessageBox]::Show("Please pick the UltraVNC Viewer (vncviewer.exe) on this PC.", 'View Register') | Out-Null
        $f = Ask-ForPath $btn 'program' }
    if (-not $f) { return $null }
    if ($f -like '*.lnk') { try { $f = (New-Object -ComObject WScript.Shell).CreateShortcut($f).TargetPath } catch { $f = $null } }
    if (-not $f -or -not (Test-LocalFixedPath $f) -or -not (Test-Path -LiteralPath $f -PathType Leaf)) {
        [System.Windows.MessageBox]::Show("The viewer has to be on this PC's own drive (not a network share).", 'View Register') | Out-Null; return $null }
    if ($f -ne $t) { Set-Prop $btn 'target' $f; Save-Config }
    return $f
}
function global:Start-VncViewer($btn, $row, [bool]$viewOnly, $owner, [scriptblock]$OnEarlyExit) {
    $h = [string]$row.host; $p = Get-VncPort $row.port
    if (-not (Test-VncHost $h) -or -not $p) { [System.Windows.MessageBox]::Show("That address isn't valid.", 'View Register') | Out-Null; return $false }
    $exe = Find-VncViewer $btn; if (-not $exe) { return $false }
    $file = $null; $hex = $null
    try {
        if ($viewOnly) {   # Interact never uses the saved password
            if (-not (Test-VncSecret) -and -not [bool]$global:cfg.vnc.viewOnlyAsked) { [void](Show-VncPasswordDialog $owner) }   # first View only: ask once
            if (Test-VncUsePassword $row (Test-VncSecret)) {
                $hex = Get-VncSecretHex
                if ($hex) { $file = New-VncTempConfig $h $p $hex; $hex = $null } } }
        $proc = Start-Process -FilePath $exe -ArgumentList (Get-VncViewerArgs $h $p $viewOnly $file) -WorkingDirectory (Split-Path -Parent $exe) -PassThru
        if ($file) { Remove-VncTempSoon $file $proc $OnEarlyExit }
        return $true
    } catch {
        if ($file) { [void](Remove-VncTempDir (Split-Path -Parent $file)) }
        [System.Windows.MessageBox]::Show("Couldn't start the viewer.`n`n" + $_.Exception.Message, 'View Register') | Out-Null; return $false
    } finally { $hex = $null }
}

# Background scan: one runspace, 16 connects at a time, 300 ms each, paced; reads at most 12 bytes and closes. Never replies.
# Only hosts that greet with exactly 'RFB ddd.ddd\n' are reported (L4). Sockets are closed in finally, also on cancel.
$global:VncScanScript = {
    param($targets, [int]$port, [int]$timeoutMs, [int]$parallel, [int]$paceMs, $sync)
    for ($i = 0; $i -lt $targets.Count -and -not $sync.cancel; $i += $parallel) {
        $batch = @(); $end = [Math]::Min($targets.Count, $i + $parallel)
        try {
            for ($j = $i; $j -lt $end; $j++) { $c = New-Object System.Net.Sockets.TcpClient; $c.NoDelay = $true; $batch += @{ ip = $targets[$j]; c = $c; ar = $null }
                try { $batch[-1].ar = $c.BeginConnect($targets[$j], $port, $null, $null) } catch {} }
            $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
            foreach ($b in $batch) {
                if ($sync.cancel -or -not $b.ar) { continue }
                $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                $ok = $false; try { $ok = $b.ar.AsyncWaitHandle.WaitOne($left) -and $b.c.Connected } catch {}
                if (-not $ok) { continue }
                $buf = New-Object byte[] 12; $got = 0
                try { $s = $b.c.GetStream(); $s.ReadTimeout = $timeoutMs
                      while ($got -lt 12) { $n = $s.Read($buf, $got, 12 - $got); if ($n -le 0) { break }; $got += $n } } catch {}
                if ($got -eq 12 -and ([Text.Encoding]::ASCII.GetString($buf, 0, 12) -cmatch '^RFB \d{3}\.\d{3}\n$')) { $sync.found.Enqueue(@{ ip = $b.ip; bytes = $buf; n = $got }) } }
        } finally { foreach ($b in $batch) { try { $b.c.Close() } catch {} } }
        $sync.scanned = $end
        if ($paceMs -gt 0 -and -not $sync.cancel) { Start-Sleep -Milliseconds $paceMs } }
    $sync.done = $true
}
$global:VncNameScript = {   # reverse DNS for the hosts found, best effort, 800 ms each
    param($ips, $sync)
    try { foreach ($ip in $ips) { if ($sync.cancel) { break }
        try { $ar = [System.Net.Dns]::BeginGetHostEntry($ip, $null, $null)
              if ($ar.AsyncWaitHandle.WaitOne(800)) { $e = [System.Net.Dns]::EndGetHostEntry($ar); $sync.names.Enqueue(@{ ip = $ip; name = [string]$e.HostName }) } } catch {} } }
    finally { $sync.namesDone = $true }
}
function global:Get-VncWorkerFault($ps, [bool]$doneFlag) {   # M1: '' while fine; the reason when the worker failed or ended without finishing
    if (-not $ps) { return '' }
    $st = [string]$ps.InvocationStateInfo.State
    if ($st -eq 'Failed') { $r = $ps.InvocationStateInfo.Reason; if ($r) { return [string]$r.Message }; return 'the scan stopped unexpectedly' }
    if ($st -in 'Stopped', 'Completed' -and -not $doneFlag) { return 'the scan ended early' }
    return ''
}
function global:Get-VncScanPlan($ui, [bool]$Ask) {   # targets for confirmed networks. New: ask once. Declined: skipped, asked again only from Rescan ($Ask).
    $plan = @{ targets = @(); ranges = @(); labels = @(); none = $false; declined = $false }
    $nets = @(Get-VncLocalSubnets); if ($nets.Count -eq 0) { $plan.none = $true; return $plan }
    foreach ($n in $nets) {
        $rg = Get-VncRangeText $n.ip $n.prefix $ui.state.prefix; $key = Get-VncRangeKey $rg $n.gw $n.dns $n.gwId
        if ($plan.ranges -contains $key) { continue }
        $st = Get-VncRangeState $key $ui.state.confirmed $ui.state.declined
        if ($st -eq 'declined' -and -not $Ask) { $plan.declined = $true; continue }
        if ($st -ne 'ok') {
            # Squint: plain words; range and port only in the small print. Default Yes when Rescan asked on purpose, No on automatic opens.
            $a = [System.Windows.MessageBox]::Show(("Look for registers on this network ({1})?`n`nThis quickly checks the shop network for registers you can view. You'll only be asked again if the network changes.`n`n(Range {0}, port {2})" -f $rg, $n.label, $ui.state.port), 'View Register', 'YesNo', 'Question', $(if ($Ask) { 'Yes' } else { 'No' }))
            if ($a -ne 'Yes') {
                $plan.declined = $true
                if ($st -eq 'new') { $ui.state.declined = @($ui.state.declined) + $key; Set-Prop $global:cfg.vnc 'declinedRanges' @($ui.state.declined); Save-Config }
                continue }
            $keep = @(); foreach ($dk in @($ui.state.declined)) { if ($dk -ne $key) { $keep += $dk } }; $ui.state.declined = $keep; Set-Prop $global:cfg.vnc 'declinedRanges' @($ui.state.declined)
            $ui.state.confirmed = @($ui.state.confirmed) + $key; Set-Prop $global:cfg.vnc 'confirmedRanges' @($ui.state.confirmed); Save-Config }
        $plan.ranges += $key; $plan.labels += ('{0} ({1})' -f $rg, $n.label)
        $plan.targets += @(Get-VncScanTargets $n.ip $n.prefix $ui.state.prefix) }
    $plan.targets = @($plan.targets | Select-Object -Unique)
    return $plan
}
function global:Start-VncScan($ui, [switch]$Rescan) {
    Stop-VncScan $ui   # L1: a Rescan cancels the old workers, name lookups included
    $plan = Get-VncScanPlan $ui ([bool]$Rescan)
    if ($plan.none) { $ui.showEmpty.Invoke('nonet'); $ui.setStatus.Invoke('No shop network found on this PC, so nothing was scanned.'); return }
    if ($plan.targets.Count -eq 0) { $ui.setStatus.Invoke('Not scanned. Press Rescan (F5) to scan anyway, or use Add... to type an address.'); $ui.refresh.Invoke(); return }
    $sync = [hashtable]::Synchronized(@{ cancel = $false; done = $false; scanned = 0; total = $plan.targets.Count; found = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]); names = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]); namesDone = $false })
    $rs = $null; $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($global:VncScanScript).AddArgument([string[]]$plan.targets).AddArgument([int]$ui.state.port).AddArgument($global:VncTimeoutMs).AddArgument($global:VncParallel).AddArgument($global:VncPaceMs).AddArgument($sync)
        $ui.scan = @{ sync = $sync; ps = $ps; rs = $rs; handle = $ps.BeginInvoke(); hits = (New-Object System.Collections.ArrayList); nameps = $null; namers = $null; range = ($plan.labels -join ', ') }
    } catch {
        foreach ($x in $ps, $rs) { if ($x) { try { $x.Dispose() } catch {} } }
        $ui.setStatus.Invoke('Scan failed: ' + $_.Exception.Message); Write-LauncherLog ('VNC scan could not start: ' + $_.Exception.Message); return }
    $ui.fresh = $true; $ui.scanning = $true; $ui.scanned = $true; $ui.busy.Invoke($true)
    $ui.setStatus.Invoke(('Looking for registers on {0} (0 of {1})...' -f $ui.scan.range, $plan.targets.Count))
    $ui.timer.Start()
}
$global:VncDeadWorkers = New-Object System.Collections.ArrayList   # stopping workers, disposed once they have ended (never blocks the UI)
function global:Clear-VncDeadWorkers([switch]$All) {
    foreach ($w in @($global:VncDeadWorkers)) {
        $st = ''; try { $st = [string]$w.ps.InvocationStateInfo.State } catch {}
        if ($All -or $st -in 'Stopped', 'Completed', 'Failed', '') { try { $w.ps.Dispose() } catch {}; try { $w.rs.Dispose() } catch {}; $global:VncDeadWorkers.Remove($w) } }
}
function global:Stop-VncScan($ui) {
    if ($ui.timer) { $ui.timer.Stop() }
    $ui.scanning = $false; if ($ui.busy) { $ui.busy.Invoke($false) }
    Clear-VncDeadWorkers
    if (-not $ui.scan) { return }
    $ui.scan.sync.cancel = $true   # the workers check this between connects
    foreach ($pair in @(@($ui.scan.ps, $ui.scan.rs), @($ui.scan.nameps, $ui.scan.namers))) {
        if (-not $pair[0]) { if ($pair[1]) { try { $pair[1].Dispose() } catch {} }; continue }
        try { [void]$pair[0].BeginStop($null, $null) } catch {}   # nit: async stop, no UI freeze
        [void]$global:VncDeadWorkers.Add(@{ ps = $pair[0]; rs = $pair[1] }) }
    $ui.scan = $null
}
function global:Write-LauncherLog([string]$m) { Add-Content -LiteralPath $global:logPath -Value ("{0}  {1}" -f (Get-Date -Format s), $m) -ErrorAction SilentlyContinue }
function global:Step-VncScan($ui) {   # UI thread, every 200 ms while a scan runs: drain results, check the workers, update list + status
    $sc = $ui.scan; if (-not $sc) { $ui.timer.Stop(); return }
    $it = $null; $changed = $false
    while ($sc.sync.found.TryDequeue([ref]$it)) {
        if (-not (Test-VncIPv4 ([string]$it.ip))) { continue }
        $bn = Get-RfbBanner ([byte[]]$it.bytes); if (-not $bn.rfb) { continue }
        [void]$sc.hits.Add([pscustomobject]@{ host = [string]$it.ip; port = [int]$ui.state.port; name = ''; banner = $bn.text }); $ui.sessionSeen[('{0}:{1}' -f $it.ip, $ui.state.port)] = $true; $changed = $true }
    while ($sc.sync.names.TryDequeue([ref]$it)) {
        $nm = ([string]$it.name).TrimEnd('.'); if (-not (Test-VncHost $nm) -or $nm -eq $it.ip) { continue }
        foreach ($h in $sc.hits) { if ($h.host -eq $it.ip) { $h.name = $nm; $changed = $true } } }
    if ($changed) { $ui.hosts = @($sc.hits); $ui.refresh.Invoke() }
    $why = Get-VncWorkerFault $sc.ps ([bool]$sc.sync.done)
    if ($why) { Write-LauncherLog ('VNC scan failed: ' + $why); Stop-VncScan $ui; $ui.refresh.Invoke(); $ui.setStatus.Invoke('Scan failed: ' + (Get-SafeText $why 120) + '. Press Rescan (F5) to try again.'); return }
    if (-not $sc.sync.done) { $ui.setStatus.Invoke(('Looking for registers on {0} ({1} of {2})...' -f $sc.range, $sc.sync.scanned, $sc.sync.total)); return }
    if (-not $sc.nameps -and $sc.hits.Count -gt 0) {   # banners done: names, then save
        try { $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $ps = [powershell]::Create(); $ps.Runspace = $rs; $sc.namers = $rs; $sc.nameps = $ps
              [void]$ps.AddScript($global:VncNameScript).AddArgument([string[]]@($sc.hits | ForEach-Object { $_.host })).AddArgument($sc.sync); [void]$ps.BeginInvoke() }
        catch { $sc.sync.namesDone = $true } }
    if ($sc.hits.Count -gt 0 -and -not $sc.sync.namesDone) {
        if (Get-VncWorkerFault $sc.nameps $false) { $sc.sync.namesDone = $true }   # names are best effort: a failed lookup just ends it
        else { $ui.setStatus.Invoke(('Found {0}. Looking up names...' -f $sc.hits.Count)); return } }
    $found = $sc.hits.Count; $range = $sc.range
    $ui.hosts = @($sc.hits)
    Stop-VncScan $ui
    try { Save-VncCache $ui.cachePath $ui.hosts ([datetime]::UtcNow) } catch {}
    $ui.refresh.Invoke()
    $ui.setStatus.Invoke(('Found {0} register(s) on {1} at {2}. Press F5 to rescan.' -f $found, $range, (Get-Date -Format 't')))
}

# Picker window (Kern D2 + Squint). Standard window chrome stays, so the title shows once there; the client area is D2.
$global:VncPickerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="View Register" Width="620" Height="480" MinWidth="560" MinHeight="360" WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#26262C" Offset="0"/><GradientStop Color="#16161A" Offset="1"/></LinearGradientBrush></Window.Background>
  <Window.Resources>
    <LinearGradientBrush x:Key="Stroke" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#47FFFFFF" Offset="0"/><GradientStop Color="#0FFFFFFF" Offset="1"/></LinearGradientBrush>
    <ControlTemplate x:Key="ChipTpl" TargetType="Button">
      <Grid x:Name="root" RenderTransformOrigin="0.5,0.5" Background="Transparent">
        <Border x:Name="glow" CornerRadius="13" Margin="-3" Background="{TemplateBinding Tag}" Opacity="0" IsHitTestVisible="False"/>
        <Border x:Name="bg" CornerRadius="10" Background="{TemplateBinding Background}" BorderBrush="{StaticResource Stroke}" BorderThickness="1"/>
        <Border CornerRadius="9,9,0,0" Height="8" VerticalAlignment="Top" Margin="1,1,1,0" Background="#24FFFFFF" IsHitTestVisible="False"/>
        <Border CornerRadius="0,0,9,9" Height="1" VerticalAlignment="Bottom" Margin="2,0,2,1" Background="#40000000" IsHitTestVisible="False"/>
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
        <Border x:Name="ring" CornerRadius="12" Margin="-3" BorderBrush="#FFFFFF" BorderThickness="2" Visibility="Collapsed" IsHitTestVisible="False"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="root" Property="RenderTransform"><Setter.Value><TranslateTransform Y="-1"/></Setter.Value></Setter>
          <Setter TargetName="glow" Property="Opacity" Value="0.35"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="root" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.97" ScaleY="0.97"/></Setter.Value></Setter>
          <Setter TargetName="glow" Property="Opacity" Value="0.15"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ring" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bg" Property="Background" Value="#2A2A2A"/><Setter TargetName="glow" Property="Opacity" Value="0"/><Setter Property="Foreground" Value="#8A8A8A"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style x:Key="Chip" TargetType="Button">
      <Setter Property="Template" Value="{StaticResource ChipTpl}"/><Setter Property="Height" Value="32"/><Setter Property="Padding" Value="14,0"/>
      <Setter Property="FontSize" Value="14"/><Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Tag"><Setter.Value><SolidColorBrush Color="#26FFFFFF"/></Setter.Value></Setter>
      <Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#2E2E2E" Offset="0"/><GradientStop Color="#1E1E1E" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#333333" Offset="0"/><GradientStop Color="#242424" Offset="1"/></LinearGradientBrush></Setter.Value></Setter></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#242424" Offset="0"/><GradientStop Color="#1A1A1A" Offset="1"/></LinearGradientBrush></Setter.Value></Setter></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Green" TargetType="Button" BasedOn="{StaticResource Chip}">
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Tag"><Setter.Value><SolidColorBrush Color="#22C55E"/></Setter.Value></Setter>
      <Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0E7A4B" Offset="0"/><GradientStop Color="#0A5A38" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#187F52" Offset="0"/><GradientStop Color="#0B643E" Offset="1"/></LinearGradientBrush></Setter.Value></Setter></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0D6E44" Offset="0"/><GradientStop Color="#0A5333" Offset="1"/></LinearGradientBrush></Setter.Value></Setter></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Blue" TargetType="Button" BasedOn="{StaticResource Chip}">
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Tag"><Setter.Value><SolidColorBrush Color="#38BDF8"/></Setter.Value></Setter>
      <Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0B6E99" Offset="0"/><GradientStop Color="#085171" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#15749D" Offset="0"/><GradientStop Color="#095A7D" Offset="1"/></LinearGradientBrush></Setter.Value></Setter></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#0A638A" Offset="0"/><GradientStop Color="#074B68" Offset="1"/></LinearGradientBrush></Setter.Value></Setter></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ContextMenu">
      <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContextMenu">
        <Border Background="#26262C" BorderBrush="#1FFFFFFF" BorderThickness="1" CornerRadius="8" Padding="4"><ItemsPresenter/></Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="MenuItem">
      <Setter Property="Height" Value="36"/><Setter Property="FontSize" Value="14"/><Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
        <Border x:Name="hl" CornerRadius="6" Background="Transparent" Padding="12,0" MinWidth="220">
          <Grid VerticalAlignment="Center"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <ContentPresenter ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="gt" Grid.Column="1" Margin="24,0,0,0" Text="{TemplateBinding InputGestureText}" Foreground="#B4B4B4" VerticalAlignment="Center"/>
          </Grid>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="hl" Property="Background" Value="#37373C"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#8A8A8A"/><Setter TargetName="gt" Property="Foreground" Value="#8A8A8A"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Grid Margin="4,0" Height="32">
          <Border x:Name="bg" CornerRadius="6" Background="Transparent"/>
          <Rectangle x:Name="pill" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Fill="#22C55E" HorizontalAlignment="Left" Visibility="Collapsed"/>
          <ContentPresenter VerticalAlignment="Center"/>
          <Border x:Name="ring" CornerRadius="8" BorderBrush="#FFFFFF" BorderThickness="2" Visibility="Collapsed"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="#0DFFFFFF"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="bg" Property="Background" Value="#17FFFFFF"/><Setter TargetName="pill" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ring" Property="Visibility" Value="Visible"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
  </Window.Resources>
  <Grid Margin="20,14,20,16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="2"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Pick a register. View only to watch, Interact to take control." FontSize="13" Foreground="#A0A0A0" Margin="0,0,0,12"/>
    <Border Grid.Row="1" CornerRadius="10" Background="#2E000000" BorderBrush="#1FFFFFFF" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Grid Margin="4,0" TextElement.FontSize="12" TextElement.FontWeight="SemiBold" TextElement.Foreground="#A0A0A0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/><ColumnDefinition Width="130"/></Grid.ColumnDefinitions>
          <TextBlock Grid.Column="1" Text="Name" VerticalAlignment="Center" Margin="4,0"/><TextBlock Grid.Column="2" Text="Address" VerticalAlignment="Center"/><TextBlock Grid.Column="3" Text="Seen" VerticalAlignment="Center"/>
        </Grid>
        <Rectangle Grid.Row="0" Height="1" VerticalAlignment="Bottom" Fill="#14FFFFFF"/>
        <ListBox x:Name="List" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" FontSize="14" Padding="0,4"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled" HorizontalContentAlignment="Stretch" AutomationProperties.Name="Registers">
          <ListBox.ItemTemplate><DataTemplate>
            <Grid ToolTip="{Binding tip}">
              <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/><ColumnDefinition Width="130"/></Grid.ColumnDefinitions>
              <Border Tag="star" Background="Transparent" Cursor="Hand" ToolTip="{Binding starTip}" AutomationProperties.Name="{Binding starName}">
                <TextBlock x:Name="star" Text="{Binding star}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="#F59E0B" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"/>
              </Border>
              <TextBlock Grid.Column="1" Text="{Binding nameText}" Foreground="{Binding nameFg}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="4,0"/>
              <TextBlock Grid.Column="2" Text="{Binding addr}" Foreground="{Binding addrFg}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="3" Text="{Binding seen}" Foreground="#A0A0A0" FontSize="13" VerticalAlignment="Center"/>
            </Grid>
            <DataTemplate.Triggers>
              <MultiDataTrigger>
                <MultiDataTrigger.Conditions>
                  <Condition Binding="{Binding starOn}" Value="False"/>
                  <Condition Binding="{Binding IsMouseOver, RelativeSource={RelativeSource AncestorType=ListBoxItem}}" Value="False"/>
                  <Condition Binding="{Binding IsSelected, RelativeSource={RelativeSource AncestorType=ListBoxItem}}" Value="False"/>
                </MultiDataTrigger.Conditions>
                <Setter TargetName="star" Property="Opacity" Value="0"/>
              </MultiDataTrigger>
              <DataTrigger Binding="{Binding starOn}" Value="False"><Setter TargetName="star" Property="Foreground" Value="#80FFFFFF"/></DataTrigger>
            </DataTemplate.Triggers>
          </DataTemplate></ListBox.ItemTemplate>
        </ListBox>
        <StackPanel x:Name="Empty" Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center" MaxWidth="420" Visibility="Collapsed">
          <TextBlock x:Name="EmptyTitle" FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,0,0,6"/>
          <TextBlock x:Name="EmptyBody" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" TextAlignment="Center"/>
        </StackPanel>
      </Grid>
    </Border>
    <ProgressBar x:Name="Busy" Grid.Row="2" IsIndeterminate="False" Height="2" Margin="10,0" Foreground="#0E7A4B" Background="Transparent" BorderThickness="0" Visibility="Hidden"/>
    <Grid Grid.Row="3" Margin="0,12,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Button x:Name="View" Grid.Column="0" Style="{StaticResource Green}" Content="View only" MinWidth="104" IsDefault="True" ToolTip="Watch this register. Nothing you do reaches it. (Enter)"/>
      <Button x:Name="Interact" Grid.Column="1" Style="{StaticResource Blue}" Content="Interact" MinWidth="92" Margin="8,0,0,0" ToolTip="Take control of this register's mouse and keyboard. Asks for the full password. (Ctrl+Enter)"/>
      <Button x:Name="Rescan" Grid.Column="3" Style="{StaticResource Chip}" Content="Rescan" MinWidth="84" ToolTip="Look for registers on this network again (F5)"/>
      <Button x:Name="Add" Grid.Column="4" Style="{StaticResource Chip}" Content="Add..." MinWidth="72" Margin="8,0,0,0" ToolTip="Type a register's address"/>
      <Button x:Name="More" Grid.Column="5" Style="{StaticResource Chip}" Width="36" Padding="0" Margin="8,0,0,0" ToolTip="More actions" AutomationProperties.Name="More actions">
        <TextBlock Text="&#xE712;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16"/>
      </Button>
    </Grid>
    <TextBlock x:Name="Status" Grid.Row="4" FontSize="12" Foreground="#A0A0A0" Margin="0,10,0,0" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="34"/>
  </Grid>
</Window>
'@
function global:New-VncRowMenu($ui, [bool]$withLaunch) {   # Rename (F2), Pin/Unpin (Space), Remove from favourites (Del); the row menu adds View only / Interact
    $m = New-Object System.Windows.Controls.ContextMenu
    $s = $ui.list.SelectedItem
    if ($withLaunch) {
        $a = New-Object System.Windows.Controls.MenuItem; $a.Header = 'View only'; $a.InputGestureText = 'Enter'; $a.Add_Click({ $ui.go.Invoke($true) }.GetNewClosure()); [void]$m.Items.Add($a)
        $b = New-Object System.Windows.Controls.MenuItem; $b.Header = 'Interact'; $b.InputGestureText = 'Ctrl+Enter'; $b.Add_Click({ $ui.go.Invoke($false) }.GetNewClosure()); [void]$m.Items.Add($b)
        [void]$m.Items.Add((New-Object System.Windows.Controls.Separator)) }
    $r = New-Object System.Windows.Controls.MenuItem; $r.Header = 'Rename...'; $r.InputGestureText = 'F2'; $r.IsEnabled = [bool]$s; $r.Add_Click({ $ui.rename.Invoke() }.GetNewClosure()); [void]$m.Items.Add($r)
    $p = New-Object System.Windows.Controls.MenuItem; $p.Header = $(if ($s -and $s.row.pinned) { 'Unpin' } else { 'Pin' }); $p.InputGestureText = 'Space'; $p.IsEnabled = [bool]$s; $p.Add_Click({ $ui.togglePin.Invoke() }.GetNewClosure()); [void]$m.Items.Add($p)
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    $d = New-Object System.Windows.Controls.MenuItem; $d.Header = 'Remove from favourites'; $d.InputGestureText = 'Del'
    $d.IsEnabled = [bool]($s -and $s.row.fav); if (-not $d.IsEnabled) { $d.ToolTip = 'Only saved registers can be removed'; [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($d, $true) }
    $d.Add_Click({ $ui.remove.Invoke() }.GetNewClosure()); [void]$m.Items.Add($d)
    try { $m.Style = $ui.win.FindResource([System.Windows.Controls.ContextMenu]); $ms = $ui.win.FindResource([System.Windows.Controls.MenuItem])   # a code-built menu doesn't inherit the window's implicit styles
          foreach ($it in $m.Items) { if ($it -is [System.Windows.Controls.MenuItem]) { $it.Style = $ms } } } catch {}
    $m.Foreground = Brush '#FFFFFF'; $m.FontFamily = $global:UiFont; $m.FontSize = 14   # Kern Blocker: a popup doesn't inherit the window's text colour or font
    return $m
}
function global:Show-VncPicker($btn) {
    if ($global:vncPicker -and $global:vncPicker.win.IsVisible) { $global:vncPicker.win.Activate() | Out-Null; return }
    Remove-VncTempLeftovers
    $ui = @{ btn = $btn; state = (Get-VncState $global:cfg); cachePath = (Join-Path (Split-Path -Parent $global:cfgPath) 'vnc-cache.json'); scan = $null; hosts = @(); fresh = $false; scanning = $false; timer = $null; busy = $null; sessionSeen = @{}; ageText = ''; stale = $false; scanned = $false }
    $cache = Read-VncCache $ui.cachePath; $ui.hosts = @($cache.hosts)
    $ui.ageText = Get-VncAgeText $cache.time ([datetime]::UtcNow); $ui.stale = (Test-VncCacheStale $cache ([datetime]::UtcNow)) -and $cache.time -gt [datetime]::MinValue
    try { $w = [Windows.Markup.XamlReader]::Parse($global:VncPickerXaml) }
    catch { Write-LauncherLog ('VNC picker window could not load: ' + $_.Exception.Message)
            [System.Windows.MessageBox]::Show("The register picker couldn't open.`n`n" + $_.Exception.Message + "`n`nDetails are in launcher-error.log.", 'View Register', 'OK', 'Error') | Out-Null; return }
    $w.FontFamily = $global:UiFont
    $ui.win = $w
    $lv = $w.FindName('List'); $status = $w.FindName('Status'); $busyBar = $w.FindName('Busy'); $empty = $w.FindName('Empty'); $eT = $w.FindName('EmptyTitle'); $eB = $w.FindName('EmptyBody')
    $bView = $w.FindName('View'); $bInt = $w.FindName('Interact'); $bScan = $w.FindName('Rescan'); $bAdd = $w.FindName('Add'); $bMore = $w.FindName('More')
    $ui.list = $lv
    try { [System.Windows.Automation.AutomationProperties]::SetLiveSetting($status, 'Polite') } catch {}   # .NET 4.7.1+
    $ui.setStatus = [Action[string]]{ param($s) $status.Text = $s
        try { $pe = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($status); if ($pe) { $pe.RaiseAutomationEvent('LiveRegionChanged') } } catch {} }.GetNewClosure()
    $ui.busy = [Action[bool]]{ param($on) $busyBar.IsIndeterminate = $on; $busyBar.Visibility = $(if ($on) { 'Visible' } else { 'Hidden' }); $bScan.IsEnabled = -not $on }.GetNewClosure()
    $ui.showEmpty = [Action[string]]{ param($kind)
        if ($kind -eq 'nonet') { $eT.Text = "This PC isn't on the shop network."; $eB.Text = "Connect to the shop Wi-Fi or cable, then press Rescan (F5). Or use Add... to type a register's address." }
        elseif ($kind -eq 'notscanned') { $eT.Text = 'Not scanned yet.'; $eB.Text = 'Press Rescan (F5) to look for registers on this network, or use Add... to type an address.' }   # Squint Major
        else { $eT.Text = 'No registers found.'; $eB.Text = 'Check the register is turned on and on the shop network, then press Rescan (F5). Or use Add... to type its address.' }
        if ($lv.Items.Count -eq 0) { $empty.Visibility = 'Visible'; [void]$bAdd.Focus() } }.GetNewClosure()
    $ui.refresh = [Action]{
        $sel = $lv.SelectedItem; $lv.Items.Clear()
        foreach ($r in (Merge-VncRows $ui.state.favorites $ui.hosts)) {
            $r | Add-Member -NotePropertyName session -NotePropertyValue ([bool]$ui.sessionSeen[('{0}:{1}' -f $r.host, $r.port)]) -Force
            $v = Get-VncRowView $r ([bool]$ui.fresh) ([bool]$ui.scanning) $ui.ageText ([bool]$ui.stale)
            [void]$lv.Items.Add($v); if ($sel -and $sel.row.host -eq $r.host -and $sel.row.port -eq $r.port) { $lv.SelectedItem = $v } }
        if (-not $lv.SelectedItem -and $lv.Items.Count) { $lv.SelectedIndex = 0 }
        $has = [bool]$lv.SelectedItem; $bView.IsEnabled = $has; $bInt.IsEnabled = $has
        if ($lv.Items.Count -gt 0) { $empty.Visibility = 'Collapsed' }
        elseif (-not $ui.scanning) { $ui.showEmpty.Invoke($(if ($ui.scanned -or @($ui.hosts).Count -gt 0) { 'none' } else { 'notscanned' })) }   # never 'No registers found' before any scan
    }.GetNewClosure()
    $ui.timer = New-Object System.Windows.Threading.DispatcherTimer; $ui.timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $ui.timer.Add_Tick({ Step-VncScan $ui }.GetNewClosure())
    $wrongPw = { $ui.setStatus.Invoke("Couldn't connect with the saved view-only password. Change it in Setup > View-only register password...") }.GetNewClosure()
    $ui.go = [Action[bool]]{ param($vo) $s = $lv.SelectedItem; if (-not $s) { return }
        if ($vo -and (Test-VncSecret) -and -not (Test-VncUsePassword $s.row $true)) { $ui.setStatus.Invoke('The saved view-only password is only sent to registers found in this scan. The viewer will ask for it; press F5 first to use the saved one.') }
        [void](Start-VncViewer $ui.btn $s.row $vo $ui.win $wrongPw) }.GetNewClosure()
    $ui.saveFavs = [Action]{ Save-VncFavorites $global:cfg $ui.state.favorites $ui.state.invalid; Save-Config; $ui.refresh.Invoke() }.GetNewClosure()
    $ui.rename = [Action]{ $s = $lv.SelectedItem; if (-not $s) { return }
        $old = [string]$s.row.name
        $n = [Microsoft.VisualBasic.Interaction]::InputBox('Name for this register (e.g. Register 1). Leave it empty to clear the name.', 'Rename', $old)
        if ($n -eq '') {   # Cancel and an empty OK both return '': ask before clearing
            if (-not $old -or [System.Windows.MessageBox]::Show(("Clear the name ""{0}""?" -f (Get-VncDisplayName $old 40)), 'Rename', 'YesNo', 'Question', 'No') -ne 'Yes') { return } }
        [void](Set-VncFavorite $ui.state.favorites $s.row.host $s.row.port $n $null); $ui.saveFavs.Invoke() }.GetNewClosure()
    $ui.togglePin = [Action]{ $s = $lv.SelectedItem; if (-not $s) { return }
        [void](Set-VncFavorite $ui.state.favorites $s.row.host $s.row.port $null (-not [bool]$s.row.pinned)); $ui.saveFavs.Invoke() }.GetNewClosure()
    $ui.remove = [Action]{ $s = $lv.SelectedItem; if (-not $s -or -not $s.row.fav) { return }
        $nm = if ($s.row.name) { Get-VncDisplayName $s.row.name 40 } else { $s.addr }
        if ([System.Windows.MessageBox]::Show(("Remove ""{0}"" from your saved registers?" -f $nm), 'View Register', 'YesNo', 'Question', 'No') -ne 'Yes') { return }
        $f = $null; foreach ($x in $ui.state.favorites) { if ($x.host -eq $s.row.host -and $x.port -eq $s.row.port) { $f = $x } }
        if ($f) { $ui.state.favorites.Remove($f) }; $ui.saveFavs.Invoke() }.GetNewClosure()
    $bView.Add_Click({ $ui.go.Invoke($true) }.GetNewClosure()); $bInt.Add_Click({ $ui.go.Invoke($false) }.GetNewClosure())
    $bScan.Add_Click({ Start-VncScan $ui -Rescan }.GetNewClosure())
    $bMore.Add_Click({ $m = New-VncRowMenu $ui $false; $m.PlacementTarget = $bMore; $m.Placement = 'Top'; $m.VerticalOffset = -4   # Kern: above the row, right edges aligned, 4 px gap
        $m.Add_Opened({ $m.HorizontalOffset = $bMore.ActualWidth - $m.ActualWidth }.GetNewClosure()); $m.IsOpen = $true }.GetNewClosure())
    $lv.Add_SelectionChanged({ $has = [bool]$lv.SelectedItem; $bView.IsEnabled = $has; $bInt.IsEnabled = $has }.GetNewClosure())
    $lv.Add_MouseDoubleClick({ if ($lv.SelectedItem) { $ui.go.Invoke($true) } }.GetNewClosure())
    $lv.Add_PreviewMouseLeftButtonUp({   # star column toggles pin
        $o = $_.OriginalSource; while ($o -and -not ($o -is [System.Windows.FrameworkElement] -and [string]$o.Tag -eq 'star')) { if ($o -is [System.Windows.Media.Visual]) { $o = [System.Windows.Media.VisualTreeHelper]::GetParent($o) } else { $o = $null } }
        if ($o -and $o.DataContext) { $lv.SelectedItem = $o.DataContext; $_.Handled = $true; $ui.togglePin.Invoke() } }.GetNewClosure())
    $lv.Add_PreviewMouseRightButtonUp({
        $o = $_.OriginalSource; while ($o -and -not ($o -is [System.Windows.Controls.ListBoxItem])) { if ($o -is [System.Windows.Media.Visual]) { $o = [System.Windows.Media.VisualTreeHelper]::GetParent($o) } else { $o = $null } }
        if ($o) { $o.IsSelected = $true; $m = New-VncRowMenu $ui $true; $m.PlacementTarget = $o; $m.IsOpen = $true; $_.Handled = $true } }.GetNewClosure())
    $w.Add_PreviewKeyDown({
        $k = $_.Key; $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        $inList = $lv.IsKeyboardFocusWithin
        if ($k -eq 'Return' -and $ctrl) { $_.Handled = $true; $ui.go.Invoke($false) }
        elseif ($k -eq 'Return' -and $inList) { $_.Handled = $true; $ui.go.Invoke($true) }
        elseif ($k -eq 'F2') { $_.Handled = $true; $ui.rename.Invoke() }
        elseif ($k -eq 'Delete' -and $inList) { $_.Handled = $true; $ui.remove.Invoke() }
        elseif ($k -eq 'Space' -and $inList) { $_.Handled = $true; $ui.togglePin.Invoke() }
        elseif ($k -eq 'F5') { $_.Handled = $true; Start-VncScan $ui -Rescan }
        elseif ($k -eq 'Escape') { $_.Handled = $true; $w.Close() } }.GetNewClosure())   # Esc: cancels a scan and closes (Closed handler)
    $bAdd.Add_Click({
        $in = Show-VncAddDialog $ui.win
        if (-not $in) { return }   # Squint 4: Cancel adds nothing
        $ep = ConvertTo-VncEndpoint $in.addr $ui.state.port
        if (-not $ep) { [System.Windows.MessageBox]::Show("That isn't a valid address. Use an IP like 192.168.1.20 or a name like REG1, optionally with :port.", 'Add a register') | Out-Null; return }
        $n = $in.name
        [void](Set-VncFavorite $ui.state.favorites $ep.host $ep.port $n $null); $ui.saveFavs.Invoke() }.GetNewClosure())
    # N1: -All cleanup after close. Workers were told to stop (BeginStop); give them 3 s so Dispose never blocks the UI thread.
    $w.Add_Closed({ Stop-VncScan $ui; $global:vncPicker = $null
        $ct = New-Object System.Windows.Threading.DispatcherTimer; $ct.Interval = [TimeSpan]::FromSeconds(3)
        $ct.Add_Tick({ $ct.Stop(); if (-not $global:vncPicker) { Clear-VncDeadWorkers -All } }.GetNewClosure()); $ct.Start() }.GetNewClosure())
    $global:vncPicker = $ui
    $ui.refresh.Invoke()
    $bad = Get-VncInvalidText $ui.state.invalid
    if ($cache.time -gt [datetime]::MinValue) { $ui.setStatus.Invoke(('Last scan {0}{1}. Press F5 to rescan.' -f $(if ($cache.time.ToLocalTime().Date -eq (Get-Date).Date) { $cache.time.ToLocalTime().ToString('t') } else { $cache.time.ToLocalTime().ToString('g') }), $(if ($ui.stale) { ' (out of date)' } else { '' }))) }
    if ($bad) { $ui.setStatus.Invoke($bad) }   # L5: visible warning
    $w.Show(); [void]$lv.Focus()
    # Favourites-first (H1): with saved registers, only a new network range scans on open; otherwise a scan older than a day. Never at startup.
    $ranges = @(); try { foreach ($n in @(Get-VncLocalSubnets)) { $ranges += (Get-VncRangeKey (Get-VncRangeText $n.ip $n.prefix $ui.state.prefix) $n.gw $n.dns $n.gwId) } } catch {}
    $hasNew = @(Get-VncNewRanges $ranges (@($ui.state.confirmed) + @($ui.state.declined))).Count -gt 0
    $okRanges = @(Get-VncNewRanges $ranges $ui.state.declined).Count -gt 0
    if ($okRanges -and (Test-VncAutoScan ($ui.state.favorites.Count -gt 0) $cache ([datetime]::UtcNow) $hasNew)) { Start-VncScan $ui }
    elseif ($lv.Items.Count -eq 0 -and $ranges.Count -eq 0) { $ui.showEmpty.Invoke('nonet') }
    elseif ($ranges.Count -gt 0 -and -not $okRanges -and -not $bad) { $ui.setStatus.Invoke('Not scanned. Press Rescan (F5) to scan anyway, or use Add... to type an address.') }   # Squint Major: declined network
    elseif ($ui.state.favorites.Count -gt 0 -and -not $bad) {   # nit: favourites suppressed the scan, so say how old the list is
        $ui.setStatus.Invoke($(if ($ui.ageText) { 'Showing saved registers. Last scan {0}{1}. Press F5 to rescan.' -f $ui.ageText, $(if ($ui.stale) { ' (out of date)' } else { '' }) } else { 'Showing saved registers. Not scanned yet. Press F5 to look for others.' })) }
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
    $global:relayoutTimer.Add_Tick({ $global:relayoutTimer.Stop(); $f = [bool]$global:forceRelayout; $global:forceRelayout = $false; [void](Invoke-Relayout -Force:$f) })

    $global:middle = New-MiddleState $global:cfg
    if ((Get-LayoutMode $global:cfg) -eq 'single' -and @($global:cfg.panels).Count -ge 1) { Open-Single }
    else { foreach ($pc in @($global:cfg.panels)) { [void](Open-Panel $pc) } }
    Apply-Lock                                          # builds every panel (menus know every panel) + tool-window style + placement
    if ($global:panels.Count -eq 0) { throw 'No panels could be opened.' }
    Start-TrayAndHotkey                                 # Squint Major 1: tray icon + Ctrl+Alt+L bring the launcher forward (both layouts)
    $global:app.Add_Exit({ Stop-TrayAndHotkey; try { Clear-VncDeadWorkers -All } catch {} })   # N1
    # Idle CPU: wait for the "show" signal on a thread-pool wait instead of polling every 400 ms; it posts to the UI thread.
    # R11-M1: its own Add-Type (WPF is loaded by now; BL.Native stays exactly as before). On failure: log, 1 s poll.
    $showWatch = $false
    try {
        if (-not ('BL.Waits' -as [type])) { Add-Type -ReferencedAssemblies WindowsBase, System -TypeDefinition $global:WaitsSource }
        [BL.Waits]::WatchHandle($global:showEvent, $global:app.Dispatcher, [Action]{ Show-AllPanels }); $showWatch = $true
    } catch { Add-Content -LiteralPath $global:logPath -Value ("{0}  event waits unavailable ({1}); polling for the show signal instead" -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue }
    try { if ('BL.Waits' -as [type]) { [BL.Waits]::WatchResume($global:app.Dispatcher, [Action]{ $global:forceRelayout = $true; Request-Relayout }) } }   # R12-N1: own try; R10-L1 re-dock after sleep
    catch { Add-Content -LiteralPath $global:logPath -Value ("{0}  resume watch unavailable ({1})" -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue }
    if (-not $showWatch) {
        $showTimer = New-Object System.Windows.Threading.DispatcherTimer; $showTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
        $showTimer.Add_Tick({ if ($global:showEvent.WaitOne(0)) { Show-AllPanels } }); $showTimer.Start() }
    if (Test-HiddenPanelsNotice $global:cfg ([bool]$global:single)) {   # R10-N1: when a saved one-panel layout hides more panels than last noticed
        [void]$global:app.Dispatcher.BeginInvoke([Action]{
            [System.Windows.MessageBox]::Show((Get-HiddenPanelsText $global:cfg), 'Launcher', 'OK', 'Information') | Out-Null   # R11-L1: show first,
            Set-Prop $global:cfg 'hiddenPanelsNoticed' (@($global:cfg.panels).Count - 2); Save-Config }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) }   # then remember the count
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
finally { Stop-TrayAndHotkey }   # OP-M1: a startup error after Start-TrayAndHotkey must not leave the hotkey or tray icon behind
