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
$global:AppVersion   = '1.4.9'
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
    $custom = Test-CustomSlot $btn
    $o.Filter = if ($custom) { if ($kind -eq 'program') { 'Programs|*.exe' } else { $global:CustomFileFilter } }   # LJ M18-L1
                elseif ($btn.askFilter) { $btn.askFilter } elseif ($kind -eq 'program') { 'Programs and shortcuts|*.exe;*.lnk|All files|*.*' }
                elseif ($kind -eq 'script') { 'Scripts|*.ps1;*.bat;*.cmd;*.vbs|All files|*.*' } else { 'All files|*.*' }
    if ($o.ShowDialog() -ne 'OK') { return $null }
    if ($custom) { $why = Test-CustomSlotTarget $kind $o.FileName   # LJ M18-L1: a pick for a custom button passes the same check, or nothing runs
        if ($why) { [System.Windows.MessageBox]::Show("That can't be opened by this button.`n$why", 'Launcher') | Out-Null; return $null } }
    return $o.FileName
}

# Returns a usable path, or $null. Auto-detects, else asks once, then saves the answer.
function global:Resolve-ButtonPath($btn, $kind) {
    $t = Expand $btn.target
    if (-not (Is-Todo $t)) {
        if (Test-Path -LiteralPath $t) { return $t }   # LJ M18-M2: never a wildcard match
        if ($kind -eq 'program' -and $t -notmatch '[\\/]' -and -not (Test-CustomSlot $btn)) { return $t }       # e.g. shutdown.exe, notepad
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

function global:Start-CustomTarget([string]$path) {   # LJ M18-M2: Process.Start takes the path literally (Start-Process -FilePath would expand * ? [ ])
    $si = New-Object System.Diagnostics.ProcessStartInfo; $si.FileName = $path; $si.Arguments = ''; $si.UseShellExecute = $true
    $si.WorkingDirectory = [System.IO.Path]::GetDirectoryName($path)
    [void][System.Diagnostics.Process]::Start($si)
}
function global:Invoke-Button($btn) {
    $kind = Get-ButtonType $btn
    if (Test-CustomSlot $btn) {   # untrusted target: re-checked on every click; no args, never elevated
        if (Test-SlotEmpty $btn) { return $false }
        $why = Test-CustomSlotTarget $kind ([string]$btn.target)
        if ($why) { [System.Windows.MessageBox]::Show("This button can't open its target.`n$why`nRight-click it > Edit this button to fix it.", 'Launcher') | Out-Null; return $false }
        $btn = [pscustomobject]@{ slot = 'custom'; empty = $false; type = $kind; target = [string]$btn.target; args = ''; runAsAdmin = $false; label = [string]$btn.label; image = [string]$btn.image }
    }
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
                if (Test-CustomSlot $btn) {   # LJ M18-M2: launch exactly the path that passed the check, via ShellExecute (no wildcard resolution)
                    $why = Test-CustomSlotTarget $kind $path
                    if ($why) { [System.Windows.MessageBox]::Show("This button can't open its target.`n$why", 'Launcher') | Out-Null; return $false }
                    Start-CustomTarget $path; return $true }
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
# v1.4.0 custom row: two user tiles (slot = 'custom') where Start Jartrek Security was. A slot is empty (+ Add) or filled.
# Only Program, Website (http/https) or File; never a script, never arguments, never elevated. Targets are untrusted input.
$global:CustomSlotTypes = @('program', 'website', 'file')
$global:CustomSlotBadExt = '(?i)\.(ps1|psm1|psd1|bat|cmd|vbs|vbe|js|jse|wsf|wsh|hta|msc|scr|pif|com|cpl|reg|inf|msi|msp|application|appref-ms|url|scf|lnk)$'
# LJ M18-M1/M19-M1: File targets are an ALLOWLIST of documents, pictures and media: only the macro-free OOXML Office types (no .doc/.xls/.ppt/.rtf/.odt/.ods, which can carry macros or embedded objects), no archives or disk images
$global:CustomFileExts = @('pdf', 'txt', 'csv', 'docx', 'xlsx', 'pptx', 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'tif', 'tiff', 'mp3', 'wav', 'm4a', 'mp4', 'mov', 'wmv', 'avi')
$global:CustomFileFilter = 'Documents, pictures and media|' + (($global:CustomFileExts | ForEach-Object { '*.' + $_ }) -join ';')
function global:Test-CustomSlot($btn) { return ($null -ne $btn -and [string]$btn.slot -eq 'custom') }
function global:Test-SlotEmpty($btn) { return ((Test-CustomSlot $btn) -and [bool]$btn.empty) }
function global:New-EmptySlot {
    [pscustomobject]@{ slot = 'custom'; empty = $true; label = ''; bg = '#3A3A44'; fg = '#FFFFFF'; width = 'half'; height = 82; fontSize = 13
                       type = 'program'; target = ''; args = ''; image = ''; imageMode = 'above'; runAsAdmin = $false }
}
function global:Clear-CustomSlot($btn) {   # "Remove this button": the slot stays, empty, so the row keeps its shape
    $e = New-EmptySlot; foreach ($pr in $e.PSObject.Properties) { Set-Prop $btn $pr.Name $pr.Value }
    foreach ($n in 'action', 'confirm', 'group', 'detect', 'askTitle', 'askFilter', 'vncPicker', 'email') { if ($btn.PSObject.Properties[$n]) { $btn.PSObject.Properties.Remove($n) } }
}
function global:Test-CustomFileExt([string]$t) { $m = [regex]::Match($t, '\.([A-Za-z0-9]{1,5})$'); return ($m.Success -and $global:CustomFileExts -contains $m.Groups[1].Value.ToLowerInvariant()) }
function global:Test-CustomSlotTarget([string]$type, [string]$target) {   # $null = OK, else a fixed message
    if ($type -notin $global:CustomSlotTypes) { return 'Custom buttons can only open a Program, a Website or a File.' }
    $t = ([string]$target).Trim()
    if (-not $t -or (Is-Todo $t)) { return $(if ($type -eq 'website') { 'Type a web address.' } else { 'Pick the program or file.' }) }
    if ($t -match '[\x00-\x1F"<>|]') { return "That target has characters that aren't allowed." }
    if ($type -eq 'website') {
        $u = Get-SafeUrl $t
        if (-not $u -or $u -notmatch '^(?i)https?://[^\s/?#]+') { return 'Web addresses must start with http:// or https://.' }
        $ux = $null   # LJ M18-I2: no user@ part, so the address shown is the site it opens
        if ($u -match '^(?i)https?://[^/?#]*@' -or -not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$ux) -or $ux.UserInfo) { return "Web addresses can't contain a user name or '@' before the site." }
        return $null }
    if ($t -match '^[a-z][a-z0-9+.-]*:(?![\\/])' -and $t -notmatch '^[a-zA-Z]:\\') { return 'Pick a file on this PC or the network, not a link.' }
    if ($t -notmatch '^([a-zA-Z]:\\|\\\\|%[A-Za-z_()0-9]+%\\)') { return 'Use the full path (Browse...).' }
    if ($t -match '[*?\[\]]') { return "That target has characters that aren't allowed." }   # LJ M18-M2: no wildcards in a path
    if ($t.Contains('%')) {   # CC L1: check the path as it will run (env vars expanded once); the expanded form must pass on its own
        $x = [Environment]::ExpandEnvironmentVariables($t)
        if ($x.Contains('%') -or $x -notmatch '^([a-zA-Z]:\\|\\\\)') { return 'Use the full path (Browse...).' }
        return (Test-CustomSlotTarget $type $x) }
    if (([string]$target).TrimStart() -match '[. ]$') { return "That path isn't allowed (a name ends with a dot or a space)." }   # checked before Trim: 'run.bat ' must not pass
    if (($t -replace '^[a-zA-Z]:', '').Contains(':')) { return "That path isn't allowed (':' after the drive letter)." }   # LJ M18-M1: no alternate data streams
    if (@($t -split '\\' | Where-Object { $_ -match '~\d' }).Count) { return "Use the full long path, not a short 8.3 name (like PROGRA~1). Browse... gives the full path." }   # LJ M19-M1: x.docm -> X~1.DOC
    if (@($t -split '\\' | Where-Object { $_ -match '[. ]$' }).Count) { return "That path isn't allowed (a name ends with a dot or a space)." }   # Windows drops them: run.bat. runs run.bat
    if ($t -match $global:CustomSlotBadExt) { return "Scripts and shortcuts can't be custom buttons. Pick the program or file itself." }
    if ($type -eq 'program' -and $t -notmatch '(?i)\.exe$') { return 'A program must be an .exe file.' }
    if ($type -eq 'file' -and -not (Test-CustomFileExt $t)) { return 'Files can only be documents, pictures or media (like .pdf, .docx, .xlsx, .jpg, .mp4).' }
    return $null
}
function global:ConvertTo-CustomSlot($btn) {   # after a good edit: always half width, no args, never elevated
    Set-Prop $btn 'slot' 'custom'; Set-Prop $btn 'empty' $false; Set-Prop $btn 'width' 'half'; Set-Prop $btn 'args' ''; Set-Prop $btn 'runAsAdmin' $false
    foreach ($n in 'action', 'confirm', 'group', 'detect', 'vncPicker', 'email') { if ($btn.PSObject.Properties[$n]) { $btn.PSObject.Properties.Remove($n) } }
}
function global:Get-CustomFullName($btn) { $n = ((([string]$btn.label) -replace '\\n', ' ') -replace '\s+', ' ').Trim(); if ($n) { $n } else { 'this button' } }
function global:Get-SlotSide($items, $btn) {   # 'left' / 'right' by order among the custom slots
    $sl = @($items | Where-Object { Test-CustomSlot $_ }); $i = [array]::IndexOf($sl, $btn); if ($i -eq 1) { 'right' } else { 'left' }
}
function global:Get-SlotView($items, $btn, [bool]$locked) {   # Squint Major: 'add' (edit mode), 'blank' (locked, keeps its 82 DIP cell), 'hidden' (locked and both empty)
    if (-not $locked) { return 'add' }
    if (@($items | Where-Object { (Test-CustomSlot $_) -and -not (Test-SlotEmpty $_) }).Count) { return 'blank' }
    return 'hidden'
}
function global:Remove-CustomRow($items) {   # only when every slot is empty; returns $true when the row went
    $slots = @($items | Where-Object { Test-CustomSlot $_ }); if (-not $slots.Count) { return $false }
    if (@($slots | Where-Object { -not (Test-SlotEmpty $_) }).Count) { return $false }
    foreach ($x in $slots) { [void]$items.Remove($x) }; return $true
}
function global:Add-CustomRow($items) {   # puts 2 empty slots back just above the Restarts; $false if the panel already has the row
    if (@($items | Where-Object { Test-CustomSlot $_ }).Count) { return $false }
    $at = $items.Count; for ($i = 0; $i -lt $items.Count; $i++) { if (Test-DangerButton $items[$i]) { $at = $i; break } }
    $items.Insert($at, (New-EmptySlot)); $items.Insert($at + 1, (New-EmptySlot)); return $true
}
function global:Test-SecurityLabel($btn) { return (-not (Test-CustomSlot $btn) -and ((([string]$btn.label) -replace '\r', '' -replace '\\n', "`n").Trim() -ceq "START`nJARTREK`nSECURITY")) }
function global:Test-StockSecurityTile($btn) {   # LJ M18-I3 / CC M1: the stock label AND the stock (unset) target
    return ((Test-SecurityLabel $btn) -and (([string]$btn.target).Trim() -ceq 'TODO: set the Jartrek Security program' -or -not ([string]$btn.target).Trim()))
}
function global:Get-SecurityMigration($btn) {   # CC M1: 'drop' (stock, unset) | 'convert' (user set a target that a custom slot allows) | 'keep' | $null (not this tile)
    if (-not (Test-SecurityLabel $btn)) { return $null }
    if (Test-StockSecurityTile $btn) { return 'drop' }
    $t = ([string]$btn.target).Trim(); $k = if ($t -match '(?i)\.exe$') { 'program' } else { 'file' }
    if (-not (Test-CustomSlotTarget $k $t)) { return 'convert' }
    return 'keep'
}
function global:ConvertTo-SecuritySlot($btn) {   # CC M1: the user's configured tile becomes the LEFT custom slot (label, picture, colours, target kept; no args, never admin)
    $t = ([string]$btn.target).Trim(); $n = New-EmptySlot
    foreach ($pr in 'label', 'image', 'bg', 'fg') { if ($btn.PSObject.Properties[$pr] -and [string]$btn.$pr) { Set-Prop $n $pr $btn.$pr } }
    Set-Prop $n 'target' $t; Set-Prop $n 'type' $(if ($t -match '(?i)\.exe$') { 'program' } else { 'file' }); ConvertTo-CustomSlot $n
    return $n
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
    $main = $main -replace '\(needs admin\)', ('(needs' + [char]0xA0 + 'admin)')   # Kern 3: '(needs admin)' never splits
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
function global:Set-MaxLines($tb, [int]$n) {   # WPF has no MaxLines: cap the height at n lines and trim the rest with an ellipsis (every label)
    $tb.TextTrimming = 'CharacterEllipsis'; $tb.Uid = ('maxlines=' + $n); $tb.MaxHeight = $n * [double]$tb.LineHeight
}
function global:Apply-MinFont($p) {
    $s = [Math]::Max(0.1, [double]$p.scale.ScaleX)
    if ($p.grip -and $p.grip.Child -is [System.Windows.Controls.TextBlock]) { $p.grip.Child.FontSize = [Math]::Max(12.0, 12.0 / $s) }   # Kern 12 px floor: the Editing bar too (built outside the label sink)
    if (-not $p.labels) { return }
    foreach ($tb in $p.labels) {
        $floor = if (([string]$tb.Text).Split("`n").Count -ge 3 -or ($tb.Name -eq 'fitLabel' -and [double]$tb.Tag -ge 13 -and $tb.DesiredSize.Height -ge 2.5 * [double]$tb.LineHeight)) { 13.0 } else { 12.0 }   # CC A2: rendered 3-line labels too
        $tb.FontSize = [Math]::Max([double]$tb.Tag, $floor / $s)
        $tb.LineHeight = [Math]::Round($tb.FontSize * 1.2, 1)
        if ([string]$tb.Uid -match '^maxlines=(\d)$') { $tb.MaxHeight = [int]$Matches[1] * $tb.LineHeight }   # keep the 3-line cap after scaling
    }
    if ($p.gloss) { Update-GlossFinish $p.gloss }   # v1.4.8 Kern fixes 3+4: after the final label sizes
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

function global:Get-LabelMaxWidth([string]$cls, [bool]$danger) {   # 290 panel - 12 padding - 6 gap - 24 tile padding; restart tiles also lose their 2 px red border on each side (the root cause of 'ScreenConnec' + 't')
    $w = if ($cls -eq 'half') { 109 } else { 248 }; $w -= $(if ($danger) { 4 } else { 2 }); return $w   # v1.4.9 (CC Low): normal tiles' 1 px edge each side -> 107/246; restart tiles' 2 px border -> 105/244
}
function global:Set-FitFontSize($main, $text, [double]$maxW, [double]$maxH, [double]$fs) {   # v1.4.2 (Kern/Squint): wrap first (up to 3 lines), then shrink to 12; returns $true when it fits
    if (-not ($maxW -gt 0)) { $maxW = [double]::PositiveInfinity }
    $main.TextWrapping = 'WrapWithOverflow'   # v1.4.8 Windows capture fix: never break inside a word ('ScreenConnec' + 't'); an over-wide word widens DesiredSize, so the width test below rejects that size
    $fits = $false
    for ($size = $fs; $size -ge 12; $size--) {   # measured on the real TextBlock in layout units (DIP), so DPI scaling and 'Make text bigger' don't change the fit
        $main.FontSize = $size; $main.LineHeight = [Math]::Round($size * 1.2, 1)
        $text.Measure((New-Object System.Windows.Size($maxW, [double]::PositiveInfinity)))
        $lines = [Math]::Round($main.DesiredSize.Height / $main.LineHeight)
        if ($lines -le 3 -and ($lines -lt 3 -or $size -ge 13) -and $text.DesiredSize.Height -le $maxH -and $text.DesiredSize.Width -le $maxW) { $fits = $true; break } }   # CC A2: 13 px floor when 3 lines render
    if (-not $fits) { $size = 13 }   # past the fit it renders 3 lines with '...', so the 3-line floor applies
    $main.FontSize = $size; $main.LineHeight = [Math]::Round($size * 1.2, 1); $main.Tag = [double]$size   # Apply-MinFont keeps this as the design size
    $main.Name = 'fitLabel'
    return $fits
}
function global:Sync-RowFontSize($els) {   # Squint ruling: tiles in a row match the smallest fitted size, but none drops more than one step (2 px); a label that only fits with '...' never pulls the row down
    $labs = @(foreach ($e in $els) { $f = $null; try { $f = [System.Windows.LogicalTreeHelper]::FindLogicalNode($e, 'fitLabel') } catch {}; if ($f) { $f } })
    if ($labs.Count -ge 2) { Set-RowSizes $labs }
}
function global:Set-RowSizes($labs) {   # the row rule on the labels themselves (testable without WPF)
    $fit = @($labs | Where-Object { $null -eq $_.ToolTip })
    if ($fit.Count -eq 0) { return }
    $min = ($fit | ForEach-Object { [double]$_.Tag } | Measure-Object -Minimum).Minimum
    foreach ($l in $fit) { $sz = [Math]::Max($min, [double]$l.Tag - 2); $l.Tag = $sz; $l.FontSize = $sz; $l.LineHeight = [Math]::Round($sz * 1.2, 1) }
}

# Tile content: Set A icon left of the label (or above it on tall half tiles and the restart tiles).
function global:New-Content($btn, $h, $cls, $danger, $fg) {
    $fs = switch ($cls) { 'hero' { 26 } 'full' { 20 } default { 16 } }   # v1.4.2 (Charles: bigger text, maximize the space): larger start size; Set-FitFontSize steps it down to fit (12 px floor)
    $ipx = switch ($cls) { 'hero' { 40 } 'full' { 32 } default { 24 } }
    $above = $danger -or ($cls -eq 'half' -and $h -gt 80) -or ([string]$btn.imageMode -eq 'above' -and $cls -eq 'half' -and $h -gt 80)
    $lab = Get-DisplayLabel $btn
    $text = New-Object System.Windows.Controls.StackPanel; $text.VerticalAlignment = 'Center'
    $main = New-Label $lab.main $fg $fs; [void]$text.Children.Add($main)
    if ($lab.sub) { $sl = New-Label $lab.sub $fg 12; $sl.FontWeight = [System.Windows.FontWeights]::Normal; $sl.LineHeight = 14; $sl.Opacity = 1; $sl.Name = 'subLabel'; [void]$text.Children.Add($sl) }   # Kern: 12 px Regular; v1.4.8 fix: full opacity, outlined in New-Tile when light
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
        $text.MaxWidth = (Get-LabelMaxWidth $cls $danger) - $iconW
    }
    if ($above) { $text.MaxWidth = Get-LabelMaxWidth $cls $danger }   # wrap width for centred labels too
    $availH = [Math]::Max(12, [double]$h - 22 - $(if ($above -and $icon) { $ipx + 6 + $(if ($isRedDog) { 8 } else { 0 }) } else { 0 }))   # tile minus 3+3 margin and 8+8 content margin, minus the icon above
    if (-not (Set-FitFontSize $main $text ([double]$text.MaxWidth) $availH $fs)) { $main.ToolTip = ($lab.main -replace "`n", ' ') }   # Squint 3 / v1.4.9 CC Low: ANY label (default or custom) still too long at the floor -> full name in the tooltip; default labels are tested to fit, so this is an edge-case safety net
    Set-MaxLines $main 3   # CC L1: never scaled below 12 px; WrapWithOverflow keeps words whole, and a word that still can't fit (or 3+ lines, or a raised floor at panel scale < 1) ends in '...'
    [void]$sp.Children.Add($text)
    return @{ el = $sp; missingPic = $missingPic; icon = $icon }
}

# ---------- v1.4.8 glossy style C "rounder candy gloss" (Charles 8:44 AM Nov 4). Same colours, sizes, fonts and layout as D2; only the finish changes.
# Smudge v2 C + Kern fixes: 18 px corners (clamped), white gloss band <= 0.30 alpha ending >= 2 px above the caps, fill shift top +4% / bottom -6%,
# inner glow 0.22, outlined light labels (2.4 px under 16 px, 3.2 px at 16+), dark labels unchanged, one static sparkle. Frozen brushes, cached and shared.
$global:Gloss = @{ radius = 18; glossTop = 0.30; glossBottom = 0.045; glow = 0.22; fillTop = 0.04; fillBottom = 0.06; hover = 0.10; pressed = 0.12; capGap = 2; sparkleIn = 12; sparkleR = 2.6; labelGap = 8 }
$global:GlossCache = @{}
function global:Get-GlossRadius([double]$h, [double]$w = 0) {   # 18 px, never more than half the tile's height (or width), so small/half tiles keep a clean shape
    $r = [double]$global:Gloss.radius; $r = [Math]::Min($r, [Math]::Floor($h / 2)); if ($w -gt 0) { $r = [Math]::Min($r, [Math]::Floor($w / 2)) }; return [Math]::Max(0, $r)
}
function global:Test-GlossDarkLabel([string]$fg) {   # dark label (e.g. #111111 on #F0E68C): drawn as configured, no outline (Kern fix 1)
    $c = Get-Color $fg; return ((0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) -le 150)
}
function global:Get-GlossOutlineWidth([double]$fontSize) { if ($fontSize -ge 16) { 3.2 } else { 2.4 } }   # Kern fix 2/5
function global:Get-GlossOutlineOffsets([double]$width) {   # 8 copies: sides at w/2, diagonals at w/2 x 0.7071 (round outline, no scallops)
    $d = $width / 2; $dd = [Math]::Round($d * 0.7071, 2)
    return @(@($d, 0), @(-$d, 0), @(0, $d), @(0, -$d), @($dd, $dd), @(-$dd, $dd), @($dd, -$dd), @(-$dd, -$dd))
}
function global:Get-GlossRowBand($bands) {   # Kern fix 4: one band per row = the row's smallest; a 0 (under 4 px of room) drops the gloss for the whole row
    $b = @($bands); if ($b.Count -eq 0) { return 0 }
    $m = ($b | ForEach-Object { [double]$_ } | Measure-Object -Minimum).Minimum; if ($m -lt 4) { return 0 }; return $m
}
function global:Get-GlossLabelRight([double]$tileW, [double]$inkW, [bool]$centred) {   # ClaudeCode: right edge of the label ink; centred labels sit in the middle of the 12 px-margined content box
    if ($centred) { return 12 + ((($tileW - 24) + [Math]::Min($inkW, $tileW - 24)) / 2) }; return 12 + $inkW
}
function global:Get-GlossBandCorner([double]$rad, [double]$bandH) {   # ClaudeCode: band corners never more than half the band's height; returns @(top, bottom)
    $half = [Math]::Floor($bandH / 2); return @([double][Math]::Max(0.0, [Math]::Min($rad - 2, $half)), [double][Math]::Max(0.0, [Math]::Min(4.0, $half)))
}
function global:Get-GlossOutlineHex([string]$fill) { ConvertTo-Hex (Mix-Color (Get-Color $fill) (Get-Color '#000000') 0.72) }   # dark tone of the button's own fill
function global:Get-GlossFillStops([string]$fill, [string]$state = 'rest') {   # 3 stops (top, 0.55 = the configured colour, bottom); hover +10% toward white, pressed 12% darker
    $c = Get-Color $fill; $w = Get-Color '#FFFFFF'; $b = Get-Color '#000000'; $G = $global:Gloss
    if ($state -eq 'hover') { $c = Mix-Color $c $w $G.hover } elseif ($state -eq 'pressed') { $c = Mix-Color $c $b $G.pressed }
    return @((ConvertTo-Hex (Mix-Color $c $w $G.fillTop)), (ConvertTo-Hex $c), (ConvertTo-Hex (Mix-Color $c $b $G.fillBottom)))
}
function global:Get-GlossBrush([string]$key, [scriptblock]$make) {   # one frozen brush per key, shared by every tile
    if (-not $global:GlossCache.ContainsKey($key)) { $br = & $make; if ($br.CanFreeze) { $br.Freeze() }; $global:GlossCache[$key] = $br }
    return $global:GlossCache[$key]
}
function global:New-GlossFill([string]$fill, [string]$state) {
    Get-GlossBrush ('fill|' + $fill + '|' + $state) { $st = Get-GlossFillStops $fill $state
        $g = New-Object System.Windows.Media.LinearGradientBrush; $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
        foreach ($i in 0..2) { [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop (Get-Color $st[$i]), (@(0.0, 0.55, 1.0)[$i]))) }; $g }.GetNewClosure()
}
function global:New-GlossBand {   # white top band: alpha 0.30 -> 0.045
    Get-GlossBrush 'band' { $G = $global:Gloss
        $g = New-Object System.Windows.Media.LinearGradientBrush; $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb([byte][Math]::Round(255 * $G.glossTop), 255, 255, 255)), 0.0))
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb([byte][Math]::Round(255 * $G.glossBottom), 255, 255, 255)), 1.0)); $g }
}
function global:New-GlossInnerGlow {   # soft inner glow: clear to 0.55 of the radius, 0.22 white at the rim
    Get-GlossBrush 'glow' { $g = New-Object System.Windows.Media.RadialGradientBrush; $g.Center = '0.5,0.55'; $g.GradientOrigin = '0.5,0.55'; $g.RadiusX = 0.75; $g.RadiusY = 0.75
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255)), 0.55))
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb([byte][Math]::Round(255 * $global:Gloss.glow), 255, 255, 255)), 1.0)); $g }
}
function global:Get-GlossBandHeight([double]$capTop, [double]$h) {   # ends >= 2 px above the caps; at most 30% of the tile; 0 = no band (too little room)
    $hb = [Math]::Min([Math]::Floor($capTop - $global:Gloss.capGap - 1.5), [Math]::Round($h * 0.30, 1))
    if ($hb -lt 4) { return 0 }; return $hb
}
function global:Get-GlossFillShift([string]$fill, [double]$yFrac, [double]$rNorm) {   # max channel shift vs the configured fill at a point (yFrac 0..1 down the tile, rNorm = radial distance / radius)
    $c = Get-Color $fill; $st = Get-GlossFillStops $fill 'rest'
    $a = Get-Color $(if ($yFrac -le 0.55) { $st[0] } else { $st[2] }); $t = if ($yFrac -le 0.55) { (0.55 - $yFrac) / 0.55 } else { ($yFrac - 0.55) / 0.45 }
    $m = Mix-Color $c $a $t
    $ga = if ($rNorm -le 0.55) { 0 } else { [Math]::Min(1, ($rNorm - 0.55) / 0.45) * $global:Gloss.glow }
    $m = Mix-Color $m (Get-Color '#FFFFFF') $ga
    return [Math]::Max([Math]::Abs([int]$m.R - $c.R), [Math]::Max([Math]::Abs([int]$m.G - $c.G), [Math]::Abs([int]$m.B - $c.B)))
}
function global:Test-GlossSparkle([double]$tileW, [double]$capTop, [double]$labelRight, [double]$radius) {   # >= 8 px from the label ink, >= 4 px inside the corner curve
    $G = $global:Gloss; $cx = $tileW - $G.sparkleIn; $cy = $G.sparkleIn
    $clearV = $capTop - ($cy + $G.sparkleR); $clearH = ($cx - $G.sparkleR) - $labelRight
    $toArc = $radius - [Math]::Sqrt(2 * [Math]::Pow($radius - $G.sparkleIn, 2)) - $G.sparkleR   # sparkle centre is on the corner's diagonal
    if ($radius -le $G.sparkleIn) { $toArc = $G.sparkleIn - $G.sparkleR }   # small radius: the curve ends before the sparkle
    return (($clearV -ge $G.labelGap -or $clearH -ge $G.labelGap) -and $toArc -ge 4)
}
function global:New-GlossSparkle {   # static 4-point star, 2.6 px radius; never animated
    $pth = New-Object System.Windows.Shapes.Path; $pth.IsHitTestVisible = $false; $pth.Width = 5.2; $pth.Height = 5.2; $pth.Stretch = 'None'
    $pth.Data = Get-GlossBrush 'sparkleGeo' { [System.Windows.Media.Geometry]::Parse('M2.6,0 L3.2,2 5.2,2.6 3.2,3.2 2.6,5.2 2,3.2 0,2.6 2,2 Z') }
    $pth.Fill = Get-GlossBrush 'sparkleFill' { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(230, 255, 255, 255)) }
    $pth.HorizontalAlignment = 'Right'; $pth.VerticalAlignment = 'Top'
    $o = $global:Gloss.sparkleIn - $global:Gloss.sparkleR; $pth.Margin = New-Object System.Windows.Thickness 0, ($o - 1), ($o - 1), 0   # inside the 1 px rim; built directly so a comma-decimal PC still gets 8.4 (ClaudeCode)
    return $pth
}
function global:Add-GlossOutline($main, [string]$hex, [double]$width) {   # no Effect (D2 rule): 8 dark copies offset by width/2 behind the label, bound to it so fit/row sizing follow
    $par = $main.Parent; if (-not $par) { return }
    $i = $par.Children.IndexOf($main); $par.Children.RemoveAt($i)
    $gr = New-Object System.Windows.Controls.Grid; $gr.HorizontalAlignment = $main.HorizontalAlignment; $gr.VerticalAlignment = $main.VerticalAlignment
    $br = Get-GlossBrush ('ol|' + $hex) { New-Object System.Windows.Media.SolidColorBrush (Get-Color $hex) }.GetNewClosure()
    foreach ($o in @((Get-GlossOutlineOffsets $width) + ,@(0, 0.96))) {
        $t = New-Object System.Windows.Controls.TextBlock; $t.IsHitTestVisible = $false; $t.Foreground = $br
        foreach ($pr in 'Text', 'FontSize', 'LineHeight', 'FontFamily', 'FontWeight', 'TextAlignment', 'TextTrimming', 'MaxHeight', 'TextWrapping', 'LineStackingStrategy', 'HorizontalAlignment') {
            $bd = New-Object System.Windows.Data.Binding $pr; $bd.Source = $main; $bd.Mode = 'OneWay'
            $dp = if ($pr -in 'MaxHeight', 'HorizontalAlignment') { [System.Windows.FrameworkElement]::($pr + 'Property') } else { [System.Windows.Controls.TextBlock]::($pr + 'Property') }
            [void]$t.SetBinding($dp, $bd) }
        $t.RenderTransform = New-Object System.Windows.Media.TranslateTransform $o[0], $o[1]
        [void]$gr.Children.Add($t) }
    [void]$gr.Children.Add($main); $par.Children.Insert($i, $gr); $gr.Tag = [double]$width
    return $gr
}
function global:Set-GlossOutlineWidth($gr, [double]$width) {   # re-place the 8 copies (the 9th is the 0.96 px drop) for a new width
    if (-not $gr -or [double]$gr.Tag -eq $width) { return }
    $off = Get-GlossOutlineOffsets $width
    for ($k = 0; $k -lt 8; $k++) { $t = $gr.Children[$k].RenderTransform; $t.X = $off[$k][0]; $t.Y = $off[$k][1] }
    $gr.Tag = [double]$width
}
# Kern fixes 3+4: the outline width, the gloss band and the sparkle are picked after row sync and Apply-MinFont, from the final label size, one band per row.
function global:Update-GlossFinish($entries) {
    if (-not $entries) { return }
    foreach ($e in $entries) {
        $fsz = if ($e.lab) { [double]$e.lab.FontSize } else { 0 }
        if ($e.ol) { Set-GlossOutlineWidth $e.ol (Get-GlossOutlineWidth $fsz) }
        $e.el.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity))); $ds = $e.el.DesiredSize
        $e.capTop = 8 + [Math]::Max(0, ($e.h - 16 - $ds.Height) / 2) + $fsz * 0.2
        $e.band = Get-GlossBandHeight $e.capTop $e.h
        $centred = ([string]$e.el.HorizontalAlignment -eq 'Center') -or ($e.lab -and [string]$e.lab.TextAlignment -eq 'Center')
        $e.labelRight = Get-GlossLabelRight $e.tileW $ds.Width $centred }
    foreach ($grp in @($entries | Group-Object { $_.row })) {
        $bandH = Get-GlossRowBand @($grp.Group | ForEach-Object { $_.band })
        foreach ($e in $grp.Group) {
            if ($bandH -gt 0) { $e.sheen.Height = $bandH; $e.sheen.Margin = New-Object System.Windows.Thickness 3.7, 0.5, 3.7, 0; $bc = Get-GlossBandCorner $e.rad $bandH; $e.sheen.CornerRadius = New-Object System.Windows.CornerRadius $bc[0], $bc[0], $bc[1], $bc[1]; $e.sheen.Visibility = 'Visible' } else { $e.sheen.Visibility = 'Collapsed' }
            $e.spark.Visibility = $(if (Test-GlossSparkle $e.tileW $e.capTop $e.labelRight $e.rad) { 'Visible' } else { 'Collapsed' }) } }
}
# One tile (v1.4.8 glossy style C): 18 px clamped corners, gradient fill (+4%/-6%), white gloss band (one height per row), inner glow, dark outline copies on light labels,
# static sparkle, hover +10% lift + glow, pressed 12% darker with no gloss, inset 18/14 focus ring, launch flash, dashed outline while editing, amber dot when not set up.
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
    $rad = Get-GlossRadius $h   # v1.4.8 style C: 18 px for every size (was 12, hero 14), clamped to half the height
    $oProp = [System.Windows.UIElement]::OpacityProperty

    $wrap = New-Object System.Windows.Controls.Grid; $wrap.Margin = '3'                  # 3 + 3 = Kern's 6 px gap
    $glowMax = if ($danger) { 0.55 } else { 0.90 }   # Kern recheck: hover glow >= 1.5:1 against the panel
    # Kern v1.3.0 Major 1: 6 px halo (inside the panel's 3+3 padding and the 6 px gaps); radial 85% at 0.70 -> 0 at 1.0
    $glow = New-Object System.Windows.Controls.Border; $glow.IsHitTestVisible = $false; $glow.Margin = '-6'; $glow.Opacity = 0
    $glow.CornerRadius = [string]($rad + 6); $glow.Background = New-GlowBrush $f[6] 1.0 0.45 0.62 0.75; $glow.Height = $h + 12
    $wrap.ClipToBounds = $false
    $tile = New-Object System.Windows.Controls.Border; $tile.Background = New-GlossFill $fillHex 'rest'; $tile.Height = $h
    $sheen = Set-D2Surface $tile $rad 10 '#4DFFFFFF'; $sheen.Background = New-GlossBand; $sheen.Opacity = 1   # v1.4.8: gloss band 0.30 -> 0.045 at rest and hover, 0 pressed; height set from the label below
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
    $hov = New-Object System.Windows.Controls.Border; $hov.IsHitTestVisible = $false; $hov.Opacity = 0; $hov.CornerRadius = $ir; $hov.Background = New-GlossFill $fillHex 'hover'
    $prs = New-Object System.Windows.Controls.Border; $prs.IsHitTestVisible = $false; $prs.Opacity = 0; $prs.CornerRadius = $ir; $prs.Background = New-GlossFill $fillHex 'pressed'
    $shade = New-Object System.Windows.Controls.Border; $shade.IsHitTestVisible = $false; $shade.BorderThickness = '0,0,0,1'
    $shade.BorderBrush = Brush '#40000000'; $shade.CornerRadius = New-Object System.Windows.CornerRadius 0, 0, ([double]$ir), ([double]$ir)
    $iglow = New-Object System.Windows.Controls.Border; $iglow.IsHitTestVisible = $false; $iglow.CornerRadius = $ir; $iglow.Background = New-GlossInnerGlow
    [void]$g.Children.Add($hov); [void]$g.Children.Add($prs); [void]$g.Children.Add($iglow); [void]$g.Children.Add($sheen); [void]$g.Children.Add($shade)
    $c = New-Content $btn $h $cls $danger $fgHex
    $c.el.Margin = '12,8'; [void]$g.Children.Add($c.el)
    # v1.4.8: gloss band height from where the caps start (label centred in the 8 px content margin), sparkle only where it clears the label
    $mainLab = $null; try { $mainLab = [System.Windows.LogicalTreeHelper]::FindLogicalNode($c.el, 'fitLabel') } catch {}
    $subLab = $null; try { $subLab = [System.Windows.LogicalTreeHelper]::FindLogicalNode($c.el, 'subLabel') } catch {}
    $tileW = if ($cls -eq 'half') { 133 } else { 272 }   # 290 panel - 12 padding - 6 gap; halves split it
    $ol = $null
    if (-not (Test-GlossDarkLabel $fgHex)) {   # Kern fix 1: dark labels unchanged; light labels and their 12 px sub-labels outlined
        $olHex = Get-GlossOutlineHex $fillHex
        if ($mainLab) { $ol = Add-GlossOutline $mainLab $olHex (Get-GlossOutlineWidth ([double]$mainLab.FontSize)) }   # width re-picked in Update-GlossFinish
        if ($subLab) { [void](Add-GlossOutline $subLab $olHex 2.4) } }   # v1.4.8 fix 1: 12 px sub-label, 2.4 px, Opacity 1
    $spark = New-GlossSparkle; $spark.Visibility = 'Collapsed'; [void]$g.Children.Add($spark)
    $sheen.Visibility = 'Collapsed'   # band height, outline width and sparkle are set by Update-GlossFinish after row sync + Apply-MinFont
    if ($null -ne $global:glossSink) { [void]$global:glossSink.Add(@{ row = $global:glossRow; el = $c.el; lab = $mainLab; ol = $ol; sheen = $sheen; spark = $spark; h = $h; rad = $rad; tileW = $tileW; capTop = 0; band = 0; labelRight = 0 }) }
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
    if (Test-CustomSlot $btn) { $tile.ToolTip = (Get-CustomFullName $btn) + "`n" + [string]$tile.ToolTip }   # Kern: full name, since the label may be trimmed
    $an = Get-DisplayLabel $btn; $an = (@($(if (Test-CustomSlot $btn) { Get-CustomFullName $btn } else { $an.main }), $an.sub) | Where-Object { $_ }) -join ', '
    [System.Windows.Automation.AutomationProperties]::SetName($tile, (($an -replace "`n", ' ') -replace [char]0xA0, ' '))   # Squint 3: Narrator reads the full label
    $g.Background = [System.Windows.Media.Brushes]::Transparent
    $tile.Child = $g
    # v1.4.8 (Kern fix 3): focus = 2 px white + 2 px dark ring inside the button, edges 18/14 (concentric), moves with the tile
    $ring = New-Object System.Windows.Controls.Grid; $ring.IsHitTestVisible = $false; $ring.Visibility = 'Hidden'; $ring.Height = $h; $ring.VerticalAlignment = $tile.VerticalAlignment; $ring.RenderTransform = $tg; $ring.RenderTransformOrigin = '0.5,0.5'
    $rw = New-Object System.Windows.Controls.Border; $rw.BorderThickness = '2'; $rw.BorderBrush = [System.Windows.Media.Brushes]::White; $rw.CornerRadius = [string]$rad
    $rk = New-Object System.Windows.Controls.Border; $rk.Margin = '2'; $rk.BorderThickness = '2'; $rk.BorderBrush = Brush '#111111'; $rk.CornerRadius = [string]([Math]::Max(0, $rad - 2))
    [void]$ring.Children.Add($rw); [void]$ring.Children.Add($rk)
    [void]$wrap.Children.Add($glow); [void]$wrap.Children.Add($tile); [void]$wrap.Children.Add($ring)

    $st = @{ down = $false }
    $yProp = [System.Windows.Media.TranslateTransform]::YProperty
    $sxProp = [System.Windows.Media.ScaleTransform]::ScaleXProperty; $syProp = [System.Windows.Media.ScaleTransform]::ScaleYProperty
    $toHover = {
        Start-Anim $lift $yProp -2 120 -Ease; Start-Anim $glowLift $yProp -2 120 -Ease
        Start-Anim $press $sxProp 1 120 -Ease; Start-Anim $press $syProp 1 120 -Ease
        Start-Anim $glow $oProp $glowMax 120 -Ease; Start-Anim $hov $oProp 1 120 -Ease; Start-Anim $prs $oProp 0 120 -Ease
        Start-Anim $sheen $oProp 1 120 -Ease   # v1.4.8: hover = fill +10% (gloss stays <= 0.30)
        Start-Anim $iscale $sxProp 1.06 120 -Ease; Start-Anim $iscale $syProp 1.06 120 -Ease }.GetNewClosure()
    $toRest = {
        Start-Anim $lift $yProp 0 120 -Ease; Start-Anim $glowLift $yProp 0 120 -Ease
        Start-Anim $press $sxProp 1 120 -Ease; Start-Anim $press $syProp 1 120 -Ease
        Start-Anim $glow $oProp 0 120 -Ease; Start-Anim $hov $oProp 0 120 -Ease; Start-Anim $prs $oProp 0 120 -Ease
        Start-Anim $sheen $oProp 1 120 -Ease
        Start-Anim $iscale $sxProp 1 120 -Ease; Start-Anim $iscale $syProp 1 120 -Ease }.GetNewClosure()
    $toPress = {
        Start-Anim $lift $yProp 0 60; Start-Anim $glowLift $yProp 0 60
        Start-Anim $press $sxProp 0.97 60; Start-Anim $press $syProp 0.97 60
        Start-Anim $glow $oProp ($glowMax * 0.43) 60; Start-Anim $prs $oProp 1 60; Start-Anim $sheen $oProp 0 60
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
    if (Test-MailTile $btn) { try { Add-MailOverlay $tile $wrap $g $c $ir $btn; Add-MailMenu $tile.ContextMenu } catch { Add-Content -LiteralPath $global:logPath -Value ('{0}  email count tile: {1}' -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue } }   # v1.4.0
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
function global:Edit-Button($btn, [switch]$Custom) {
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
    if ($Custom) { $types = [ordered]@{ program = 'Program'; website = 'Website'; file = 'File / PDF' }; $d.Title = $(if (Test-SlotEmpty $btn) { 'Add a button' } else { 'Edit button' }) }
    $selType = $types[(Get-ButtonType $btn)]; if (-not $selType) { $selType = $types['program'] }
    $cType = Combo @($types.Values) $selType; $cType.FontWeight = 'Bold'
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
        $p = Ask-ForPath ([pscustomobject]@{ slot = $(if ($Custom) { 'custom' } else { '' }); label = $btn.label; askTitle = $null; askFilter = $(if ($k -eq 'file') { 'Documents|*.pdf;*.doc;*.docx;*.xlsx;*.txt|All files|*.*' } else { $null }) }) $k
        if ($p) { $tT.Text = $p } }.GetNewClosure())
    $show = {
        $k = ($types.GetEnumerator() | Where-Object { $_.Value -eq $cType.SelectedItem }).Key
        $vis = @{ target = $k -in 'program','file','script'; url = $k -eq 'website'; args = $k -in 'program','script'; admin = $k -in 'program','script'; action = $k -eq 'builtin' }
        if ($Custom) { $vis.args = $false; $vis.admin = $false; $vis.action = $false; $vis.confirm = $false; $vis.w = $false }
        foreach ($r in $vis.Keys) { if (-not $rows.ContainsKey($r)) { continue }; foreach ($c in $rows[$r]) { $c.Visibility = $(if ($vis[$r]) { 'Visible' } else { 'Collapsed' }) } }
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
    $ok.Add_Click({
        if ($Custom) {   # untrusted target: refuse to save a bad one, keep the dialog open
            $kk = 'program'; foreach ($e in $types.GetEnumerator()) { if ($e.Value -eq $cType.SelectedItem) { $kk = $e.Key } }
            $why = Test-CustomSlotTarget $kk $(if ($kk -eq 'website') { $tUrl.Text } else { $tT.Text })
            if ($why) { [System.Windows.MessageBox]::Show($why, 'Custom button') | Out-Null; return } }
        $d.DialogResult = $true }.GetNewClosure())
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
    if ($Custom) { ConvertTo-CustomSlot $btn; if (-not ([string]$btn.label).Trim()) { Set-Prop $btn 'label' ([IO.Path]::GetFileNameWithoutExtension(([string]$btn.target).TrimEnd('/'))) } }
    return $true
}

# ---------- UX-2a: "Set up this PC" - pick every missing program/file once, right after install ----------
function global:Test-ButtonReady($btn) {
    if (Test-SlotEmpty $btn) { return $true }
    $kind = Get-ButtonType $btn
    if ($kind -notin 'program', 'file', 'script') { return $true }
    if (Test-VncPickerButton $btn) { return $true }   # LJ M41-L1: View Register finds its viewer itself (Program Files search); never save a detect/.lnk hit as its override
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
# v1.3.0 left-clip fix: the scale WPF actually draws this window at. It can lag the monitor's DPI (window created at
# -32000 on a 125% monitor, then moved to a 100% one), so content drew 1.25x wider than the window and was cut off.
function global:Get-WpfDpi($win) { try { $ps = [System.Windows.PresentationSource]::FromVisual($win); if ($ps -and $ps.CompositionTarget) { $m = $ps.CompositionTarget.TransformToDevice.M11; if ($m -gt 0) { return [double]$m } } } catch {}; return 0.0 }
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
    $dp = @(foreach ($o in $global:panels) { '{0}:{1}:{2}:{3}' -f (Get-Dpi $o), (Get-WpfDpi $o.win), [bool]$o.win.IsVisible, [bool]($o.hwnd -and $o.hwnd -ne [IntPtr]::Zero) }) -join ','
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

function global:Get-LauncherVersionText { 'Button Launcher ' + $global:AppVersion }   # v1.4.6: Setup menu version line
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
    $ver = New-Object System.Windows.Controls.MenuItem; $ver.Header = Get-LauncherVersionText; $ver.IsEnabled = $false; [void]$setup.Items.Add($ver)   # v1.4.6: version, first, not clickable
    [void](Add-MenuItem $setup 'Set up this PC...' { Show-SetupWindow })
    if (Test-Path -LiteralPath (Join-Path $global:here 'Build-Installer.ps1')) { [void](Add-MenuItem $setup 'Build installer...' { Save-Config; Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $global:here 'Build-Installer.ps1')`"" }) }   # installed copies ship without the builder
    [void](Add-MenuItem $setup 'Allowed computers (admin)...' { Show-VncAllowedDialog $null })   # v1.4.1: elevated save (UAC)
    [void](Add-MenuItem $setup 'View-only password (for viewing computers)...' { [void](Show-VncPasswordDialog $null) })   # v1.4.4: back, new per-user store
    [void](Add-MenuItem $setup 'Unread email count...' { [void](Show-MailSetupDialog $null) })   # v1.4.0, opt-in
    if (-not @($p.items | Where-Object { Test-CustomSlot $_ }).Count) {
        [void](Add-MenuItem $setup 'Add the row of 2 custom buttons' { if (Add-CustomRow $p.items) { Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure()) }
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
    if (Test-CustomSlot $btn) { Slot-Menu $p $btn $m; return $m }
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

function global:Get-RemoveSlotText($btn) { 'Remove "{0}" from this panel?' -f (Get-CustomFullName $btn) }
function global:Get-RemoveRowLabel([bool]$can) { if ($can) { 'Remove this row' } else { 'Remove this row (remove both buttons first)' } }
function global:Slot-Menu($p, $btn, $m) {   # custom row: Add/Edit, Remove this button (empties the slot), Remove this row (only when both are empty)
    if (Test-SlotEmpty $btn) { [void](Add-MenuItem $m 'Add a button here...' { Edit-CustomSlot $p $btn }.GetNewClosure()) }
    else {
        [void](Add-MenuItem $m 'Edit this button...' { Edit-CustomSlot $p $btn }.GetNewClosure())
        [void](Add-MenuItem $m 'Remove this button' {   # Squint: confirm, No is the default
            if ([System.Windows.MessageBox]::Show((Get-RemoveSlotText $btn), 'Remove button', 'YesNo', 'Question', 'No') -ne 'Yes') { return }
            Clear-CustomSlot $btn; Save-Config; Build-Panel $p; Layout-Panel $p }.GetNewClosure()) }
    $canRow = -not @($p.items | Where-Object { (Test-CustomSlot $_) -and -not (Test-SlotEmpty $_) }).Count
    $rr = Add-MenuItem $m (Get-RemoveRowLabel $canRow) { if (Remove-CustomRow $p.items) { Save-Config; Build-Panel $p; Layout-Panel $p } }.GetNewClosure()
    $rr.IsEnabled = $canRow   # Squint: disabled items show no tooltip, so the reason is in the label
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    Panel-Menu $p $m
}
function global:Edit-CustomSlot($p, $btn) {   # edits a copy, so Cancel or a refused target leaves the slot as it was
    $tmp = $btn | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    if (Test-SlotEmpty $tmp) { Set-Prop $tmp 'label' '' }
    if (-not (Edit-Button $tmp -Custom)) { return }
    foreach ($pr in $tmp.PSObject.Properties) { Set-Prop $btn $pr.Name $pr.Value }
    Save-Config; Build-Panel $p; Layout-Panel $p
}
function global:New-AddSlot($p, $btn) {   # empty slot: subtle dashed "+ Add", same size as a half tile; click or Enter adds (edit mode only)
    $h = if ($btn.height) { [Math]::Max(44, [double]$btn.height) } else { 82 }
    $wrap = New-Object System.Windows.Controls.Grid; $wrap.Margin = '3'; $wrap.Tag = 'half'
    if ([bool]$global:cfg.locked) {   # Squint Major: locked = plain blank cell, same 82 DIP so the grid doesn't shift (Kern); nothing to click, focus or read
        $wrap.Height = $h; $wrap.Focusable = $false; $wrap.IsHitTestVisible = $false
        return $wrap }
    $side = Get-SlotSide $p.items $btn
    $tile = New-Object System.Windows.Controls.Border; $tile.Height = $h; $tile.CornerRadius = '12'; $tile.Background = Brush '#0AFFFFFF'
    $tile.Focusable = $true; $tile.FocusVisualStyle = $null; $tile.Cursor = [System.Windows.Input.Cursors]::Hand; $tile.ToolTip = 'Add a button'
    [System.Windows.Automation.AutomationProperties]::SetName($tile, ('Add a button, ' + $side))   # Squint: Narrator tells the two apart
    $g = New-Object System.Windows.Controls.Grid; $g.Background = [System.Windows.Media.Brushes]::Transparent
    $dash = New-Object System.Windows.Shapes.Rectangle; $dash.IsHitTestVisible = $false; $dash.Stroke = Brush '#73FFFFFF'; $dash.StrokeThickness = 1.5
    $dash.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (,[double[]](4, 3)); $dash.RadiusX = 11; $dash.RadiusY = 11
    $txt = New-Label ('+  Add') '#C8C8D0' 14; $txt.HorizontalAlignment = 'Center'; $txt.VerticalAlignment = 'Center'; $txt.IsHitTestVisible = $false
    [void]$g.Children.Add($dash); [void]$g.Children.Add($txt); $tile.Child = $g
    $ring = New-Object System.Windows.Controls.Border; $ring.IsHitTestVisible = $false; $ring.Margin = '-3'; $ring.CornerRadius = '15'   # Kern: pulled in so it doesn't crowd the next tile
    $ring.BorderThickness = '2'; $ring.BorderBrush = [System.Windows.Media.Brushes]::White; $ring.Visibility = 'Hidden'
    [void]$wrap.Children.Add($tile); [void]$wrap.Children.Add($ring)
    # Kern: hover brightens the dash and the text only (no lift, no glow)
    $tile.Add_MouseEnter({ $tile.Background = Brush '#17FFFFFF'; $dash.Stroke = Brush '#B3FFFFFF'; $txt.Foreground = Brush '#FFFFFF' }.GetNewClosure())
    $tile.Add_MouseLeave({ $tile.Background = Brush '#0AFFFFFF'; $dash.Stroke = Brush '#73FFFFFF'; $txt.Foreground = Brush '#C8C8D0' }.GetNewClosure())
    # Squint Major: belt and braces, the handlers also refuse while locked (the panel rebuilds on lock, but a stale tile must not add)
    $tile.Add_MouseLeftButtonUp({ $_.Handled = $true; if (-not [bool]$global:cfg.locked) { Edit-CustomSlot $p $btn } }.GetNewClosure())
    $tile.Add_KeyDown({ if (($_.Key -eq 'Enter' -or $_.Key -eq 'Space') -and -not $_.IsRepeat) { $_.Handled = $true; if (-not [bool]$global:cfg.locked) { Edit-CustomSlot $p $btn } } }.GetNewClosure())
    $tile.Add_IsKeyboardFocusedChanged({ $ring.Visibility = if ($tile.IsKeyboardFocused) { 'Visible' } else { 'Hidden' } }.GetNewClosure())
    $tile.Add_MouseRightButtonDown({ [void]$tile.Focus() }.GetNewClosure())
    $tile.ContextMenu = Button-Menu $p $btn
    return $wrap
}

function global:Add-TileRows($p, $target, $list) {
    $pendingHalf = $null
    $locked = [bool]$global:cfg.locked
    foreach ($btn in $list) {
        if ((Test-SlotEmpty $btn) -and (Get-SlotView $p.items $btn $locked) -eq 'hidden') { continue }   # locked, both empty: no row, no gap
        if (-not ($btn.width -eq 'half' -and $pendingHalf)) { $global:glossRow++ }   # one row id per full tile or half pair (one gloss band per row)
        $el = if (Test-SlotEmpty $btn) { New-AddSlot $p $btn } else { New-Tile $p $btn }
        if ($btn.width -eq 'half') {
            if ($pendingHalf) { [System.Windows.Controls.Grid]::SetColumn($el, 1); [void]$pendingHalf.Children.Add($el); Sync-RowFontSize @($pendingHalf.Children); $pendingHalf = $null }
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
    $global:labelSink = New-Object System.Collections.ArrayList; $global:glossSink = New-Object System.Collections.ArrayList; $global:glossRow = 0
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
    $p.labels = $global:labelSink; $global:labelSink = $null; $p.gloss = $global:glossSink; $global:glossSink = $null; Apply-MinFont $p
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
    $dock = New-Object System.Windows.Controls.DockPanel; $dock.Width = $global:BaseWidth - 8   # D2: 1 px rim + 3 px padding each side, so the panel stays exactly BaseWidth
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
    if ($lv -ge 3) { return }
    $changed = $false; $dropped = $false
    if ($lv -lt 2) {
    $old = @("BACK OFFICE`nUSER GUIDE`nVERSION 11", "REGISTER`nUSER GUIDE`nVERSION 11", 'PLCE', "DEPARTMENT`nOF`nREVENUE",
             "RESTART`nSCREEN CONNECT", "START`nJARTREK`nSECURITY", "RESTART`nCOMPUTER")
    foreach ($pc in @($global:cfg.panels)) {
        $bs = @($pc.buttons); $labels = @($bs | ForEach-Object { ([string]$_.label) -replace '\r', '' })
        if ($labels.Count -ne $old.Count) { continue }
        $same = $true; for ($i = 0; $i -lt $old.Count; $i++) { if ($labels[$i] -cne $old[$i]) { $same = $false; break } }
        if (-not $same) { continue }
        $sec = $bs[5]   # MB-L3: move only. Width, height and font size stay exactly as the user has them.
        $pc.buttons = @($bs[0], $bs[1], $bs[2], $bs[3], $sec, $bs[4], $bs[6]); $changed = $true
    }
    if ($changed) { Add-Content -LiteralPath $global:logPath -Value ("{0}  moved Start Jartrek Security above the Restarts (old default order)" -f (Get-Date -Format s)) -ErrorAction SilentlyContinue }
    }
    # v1.4.0 (layoutVersion 3): the stock Start Jartrek Security tile goes; 2 empty custom slots take its spot. Nothing else moves.
    foreach ($pc in @($global:cfg.panels)) {
        $bs = @($pc.buttons); $i = -1; $how = $null; for ($j = 0; $j -lt $bs.Count; $j++) { $how = Get-SecurityMigration $bs[$j]; if ($how) { $i = $j; break } }
        if ($i -lt 0 -or $how -eq 'keep') { continue }   # CC M1: a configured tile a custom slot can't hold stays exactly as it is (no data loss)
        $left = if ($how -eq 'convert') { ConvertTo-SecuritySlot $bs[$i] } else { New-EmptySlot }
        $nb = @(); if ($i -gt 0) { $nb += $bs[0..($i - 1)] }; $nb += $left; $nb += (New-EmptySlot); if ($i -lt $bs.Count - 1) { $nb += $bs[($i + 1)..($bs.Count - 1)] }
        $pc.buttons = $nb; $dropped = $true }
    if ($dropped) { Add-Content -LiteralPath $global:logPath -Value ("{0}  removed Start Jartrek Security; added the custom row" -f (Get-Date -Format s)) -ErrorAction SilentlyContinue }
    $keep = $global:cfgPath + '.pre-v1.4.bak'   # a one-time copy of the old file, never overwritten
    if (($changed -or $dropped) -and (Test-Path -LiteralPath $global:cfgPath) -and -not (Test-Path -LiteralPath $keep)) { try { Copy-Item -LiteralPath $global:cfgPath -Destination $keep -ErrorAction Stop } catch {} }
    Set-Prop $global:cfg 'layoutVersion' 3
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
function global:Get-ChipFallbackPic([string]$kind, [string]$hint = '') {
    if ($kind -ne 'website' -and $hint -match '(?i)jartrek') { return 'images/jartrek-security.png' }   # Jartrek chips get the key, not the register receipt; the type defaults stay
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
    return Get-PicSource ([pscustomobject]@{ image = (Get-ChipFallbackPic $kind (([string]$btn.label) + ' ' + ([string]$btn.target))) }) 32
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
        if ($d -match '\Abl-chip:([0-9]{1,9})\z') { Move-Chip ([int]$matches[1]) $index; $_.Handled = $true } }.GetNewClosure())
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
    try { $w.Add_DpiChanged({ Request-Relayout }) } catch {}   # WPF's own scale changed: re-size so window and content agree
    $w.Add_Closed({ Save-Config; $global:app.Shutdown() })
    foreach ($p in $groups) { Build-Panel $p }
    Build-Middle
    $w.Show()
}
# Pure sizing for the single window. $dpi must be the scale WPF draws at (Get-WpfDpi), so contentPx == wPx.
function global:Get-SingleSize([double]$waW, [double]$waH, [double]$pct, [double]$dpi) {
    $wDip = [Math]::Max(180, [Math]::Min(560, ($waW * $pct / 100.0) / $dpi)); $sc = $wDip / $global:BaseWidth
    @{ wDip = $wDip; sc = $sc; hDip = $waH / $dpi; wPx = [int][Math]::Round($global:BaseWidth * $sc * $dpi); contentPx = $global:BaseWidth * $sc * $dpi } }
# Dock: the panels' edge (left if the top panel was anchored left, else right), full work-area height of that monitor.
function global:Layout-Single {
    $s = $global:single; if (-not $s -or -not $s.hwnd -or $s.hwnd -eq [IntPtr]::Zero) { return }
    $pc = $global:panels[0].cfg
    $wa = Get-WorkArea (Get-Screen $pc)
    $dpi = Get-WorkAreaDpi $wa $global:panels[0]   # R12-L2: target monitor's scale, so the first layout / a monitor move isn't sized for the old one
    if ([Math]::Abs((Get-Dpi $global:panels[0]) - $dpi) -gt 0.001) {   # on another monitor's scale: move there first, then size (WPF rescales on the move)
        [void][BL.Native]::SetWindowPos($s.hwnd, [IntPtr]::Zero, [int]$wa.L, [int]$wa.T, 0, 0, 0x0015) }
    $wd = Get-WpfDpi $s.win   # size in the scale WPF draws at, so window px = content px (no left clip); DpiChanged relays out once WPF catches up
    if ($wd -gt 0 -and [Math]::Abs($wd - $dpi) -gt 0.001) { $dpi = $wd }
    $pct = if ($pc.size -is [string] -and $global:SizePct[[string]$pc.size]) { $global:SizePct[[string]$pc.size] } elseif ($pc.size) { [double]$pc.size } else { 14 }
    $sz = Get-SingleSize $wa.W $wa.H $pct $dpi
    $wDip = $sz.wDip; $sc = $sz.sc; $hDip = $sz.hDip
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
#   -viewonly    do not send keyboard or mouse events   (v1.4.9: -autoscaling is not sent)
#   -config file (unused since v1.4.2: View only and Interact always pass host::port and no password)
# The -password switch is never used: a password must never be on a command line.
$global:VncDefaultPort = 5900
$global:VncTimeoutMs   = 300
$global:VncParallel    = 16
$global:VncPaceMs      = 40
$global:VncCacheMaxAge = [TimeSpan]::FromDays(1)
$global:VncEntropy     = [Text.Encoding]::UTF8.GetBytes('ButtonLauncher.VNC.ViewOnly.v2')   # v1.4.4: new store (vnc-viewonly-v2.dat in %LOCALAPPDATA%\ButtonLauncher)
$global:VncDesKey      = [byte[]](0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0)   # vncauth.c fixedkey {23,82,107,6,35,78,88,7}, bit-reversed for standard DES. Obfuscation, not encryption.
$global:vncPicker      = $null

function global:Test-VncIPv4([string]$s) {
    if ($s -notmatch '\A([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\z') { return $false }   # CC L7: \A..\z, a trailing newline is refused
    foreach ($i in 1..4) { $o = $matches[$i]; if (($o.Length -gt 1 -and $o[0] -eq '0') -or [int]$o -gt 255) { return $false } }
    return $true
}
function global:Test-VncHost([string]$s) {   # untrusted: an IPv4 dotted quad, or a hostname of [A-Za-z0-9.-]
    if (-not $s -or $s.Length -gt 253) { return $false }
    if ($s -match '\A[0-9.]+\z') { return (Test-VncIPv4 $s) }
    if ($s -cnotmatch '\A[A-Za-z0-9.-]+\z') { return $false }   # CC L7
    foreach ($l in $s.TrimEnd('.').Split('.')) { if ($l.Length -lt 1 -or $l.Length -gt 63 -or $l.StartsWith('-') -or $l.EndsWith('-')) { return $false } }
    return $true
}
function global:Get-VncPort($p) {   # an integer 1-65535, else $null
    $s = ([string]$p).Trim()
    if ($s -notmatch '\A[0-9]{1,5}\z') { return $null }   # LJ M46-I2
    $n = [int]$s; if ($n -lt 1 -or $n -gt 65535) { return $null }
    return $n
}
function global:ConvertTo-VncEndpoint([string]$text, [int]$defaultPort = 5900) {   # 'host' or 'host:port' -> @{ host; port } or $null
    $t = ([string]$text).Trim(); $port = $defaultPort
    if ($t -match '\A([^:]+)::?([0-9]+)\z') { $t = $matches[1]; $port = Get-VncPort $matches[2]; if (-not $port -or $port -lt 100) { return $null } }   # LJ M44-I2: ports below 100 refused
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
    $p = 24; $s = ([string]$cfgPrefix).Trim(); if ($s -match '\A[0-9]{1,2}\z') { $p = [int]$s }   # CC N3
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
$global:VncAdapterDeny = '(?i)VPN|\bTAP\b|TAP-|\bTUN\d*\b|WireGuard|Wintun|AnyConnect|GlobalProtect|PANGP|Forti|OpenVPN|Zscaler|Tailscale|ZeroTier|Juniper|Pulse Secure|Hyper-V|vEthernet|\bWSL\b|VirtualBox|VMware|Npcap|Loopback|WAN Miniport|Teredo|isatap|Virtual|Tunnel|NordLynx|WARP|Cloudflare|Surfshark|Mullvad|Proton|Windscribe|Sophos|Check ?Point|SonicWall|NetExtender|Citrix|Ivanti|Bluetooth|Personal Area Network'
function global:Test-VncAdapter([string]$type, [string]$desc, [string]$name, [string]$ip, [int]$prefix, $gateways) {
    if ($type -notin 'Ethernet', 'GigabitEthernet', 'Wireless80211') { return $false }   # Ppp, Tunnel, Loopback, Unknown, ... never
    if (($desc -match $global:VncAdapterDeny) -or ($name -match $global:VncAdapterDeny)) { return $false }
    if (-not (Test-Rfc1918 $ip) -or $prefix -lt 1 -or $prefix -gt 30) { return $false }
    $size = [Math]::Pow(2, 32 - $prefix); $net = [Math]::Floor((ConvertTo-VncUInt $ip) / $size)
    $real = 0   # v1.4.0 (Charles): an isolated register LAN has no gateway at all; it is scanned too (ask once, its own key)
    foreach ($g in @($gateways)) { $gs = [string]$g; if ((Test-VncIPv4 $gs) -and $gs -ne '0.0.0.0') { $real++; if ([Math]::Floor((ConvertTo-VncUInt $gs) / $size) -eq $net) { return $true } } }
    return ($real -eq 0)   # gateways only outside the subnet (routed / odd setup): still not scanned
}
function global:ConvertTo-VncNicId($mac) {   # no-gateway network key: 'nic=<this adapter's MAC>', else ''
    $m = ([string]$mac).Trim().ToLowerInvariant() -replace '[:-]', ''
    if ($m -match '^[0-9a-f]{12}$' -and $m -ne '000000000000' -and $m -ne 'ffffffffffff') { return 'nic=' + (($m -split '(..)' | Where-Object { $_ }) -join '-') }
    return ''
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
            if ($gw) { $id = Get-VncGatewayId $gw $ix }
            else { $lbl += ', local only'; $id = ''; try { $id = ConvertTo-VncNicId ($nic.GetPhysicalAddress().ToString()) } catch {} }   # .NET only: no NetTCPIP cmdlets needed
            $res += @{ ip = $a; prefix = $pl; label = $lbl; gw = $gw; dns = [string]$props.DnsSuffix; gwId = $id } } }
    return $res
}
function global:Get-VncSubnetGateway([string]$ip, [int]$prefix, $gateways) {   # first IPv4 gateway inside the adapter's subnet, else ''
    $size = [Math]::Pow(2, 32 - $prefix); $net = [Math]::Floor((ConvertTo-VncUInt $ip) / $size)
    foreach ($g in @($gateways)) { $gs = [string]$g; if ((Test-VncIPv4 $gs) -and $gs -ne '0.0.0.0' -and [Math]::Floor((ConvertTo-VncUInt $gs) / $size) -eq $net) { return $gs } }
    return ''
}
function global:Get-VncRangeKey([string]$range, [string]$gw, [string]$dns, [string]$gwId) {   # R2-L1/R3-L1: same numbers on another network (home vs shop) ask again
    $d = ([string]$dns).Trim().ToLowerInvariant(); if ($d -notmatch '^[a-z0-9.-]{0,253}$') { $d = '?' }
    $i = ([string]$gwId).Trim().ToLowerInvariant(); if ($i -notmatch '^(mac=[0-9a-f-]{17}|nic=[0-9a-f-]{17}|net=[a-z0-9 ._-]{1,64})?$') { $i = '?' }
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
function global:Test-VncBannerText([string]$t) { $t -cmatch '\ARFB [0-9]{3}\.[0-9]{3}\z' }
function global:Get-VncDisplayName([string]$n, [int]$max = 40) {   # L5: shown with an ellipsis, never cut in config
    $t = Get-SafeText $n 1000; if ($t.Length -gt $max) { return ($t.Substring(0, $max - 1) + [char]0x2026) }; return $t
}
function global:Get-VncViewerArgs([string]$h, $port, [bool]$viewOnly, [string]$configFile) {   # an argument list; no shell
    $p = Get-VncPort $port
    if (-not (Test-VncHost $h) -or -not $p -or $p -lt 100) { throw 'bad host or port' }   # L6/M43-I2: one colon + a number below 100 is a display number, not a port
    $a = @(('{0}:{1}' -f $h, $p))   # v1.4.7 (Charles 8:22 AM Nov 4, Win+R): '"...\vncviewer.exe" 192.168.20.51:5900' connects and takes his password; with -connect first VNC Server was blank and auth failed. Bare host:port (one colon) comes FIRST, no -connect
    if ($configFile) {   # v1.4.4: View only with a saved view-only password: the .vnc also holds host and port ([connection]), so the host is set twice
        if ($configFile -notmatch '^[A-Za-z]:\\[^"]+\.vnc$') { throw 'bad config path' }
        $a += @('-config', ('"' + $configFile + '"'))
    }
    if ($viewOnly) { $a += '-viewonly' }
    # v1.4.9 (Charles 10:05 AM, log on 1.4.8): '<host>:<port> -autoscaling' still left VNC Server blank on his UltraVNC 1.5.0.0-dev, while Win+R '<host>:<port>' (no -autoscaling) works. -autoscaling is no longer sent.
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
        if (-not (Test-VncHost ([string]$f.host)) -or ($f.port -ne $null -and (-not (Get-VncPort $f.port) -or (Get-VncPort $f.port) -lt 100))) { [void]$bad.Add($f); continue }   # L5: kept as-is, not shown; LJ M44-I2: ports below 100 too
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
    return ('{0} saved computer(s) in buttons.json have an address that is not valid and are hidden: {1}' -f $n, $what)
}
function global:Set-VncFavorite($favs, [string]$h, [int]$port, $name, $pinned) {   # add or update; naming never pins (Squint 4); returns $false on bad input
    if (-not (Test-VncHost $h) -or -not (Get-VncPort $port) -or $port -lt 100) { return $false }   # LJ M44-I2
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
        [void]$rows.Add([pscustomobject]@{ host = $f.host; port = $f.port; name = $(if ($f.name) { $f.name } elseif ($h) { $h.name } else { '' }); dnsName = [bool](-not $f.name -and $h -and $h.name); banner = $(if ($h) { $h.banner } else { '' }); pinned = [bool]$f.pinned; fav = $true; seen = [bool]$h }) }
    foreach ($h in $hosts) { $isFav = $false; foreach ($x in $favs) { if ($x.host -eq $h.host -and $x.port -eq $h.port) { $isFav = $true } }; if (-not $isFav) {
        [void]$rows.Add([pscustomobject]@{ host = $h.host; port = $h.port; name = $h.name; dnsName = [bool]$h.name; banner = $h.banner; pinned = $false; fav = $false; seen = $true }) } }
    $sorted = @($rows | Sort-Object @{ e = { -not $_.pinned } }, @{ e = { if ($_.pinned) { $_.name } else { '' } } }, @{ e = { if (Test-VncIPv4 $_.host) { ConvertTo-VncUInt $_.host } else { [uint32]::MaxValue } } })
    return $sorted
}
function global:Get-VncFoundText([int]$n, [string]$At = '', [switch]$LookingUp) {   # Squint recheck wording
    $c = if ($n -eq 1) { '1 computer' } else { '{0} computers' -f $n }
    if ($LookingUp) { return ('Found {0} you can view. Looking up names...' -f $c) }
    return ('Found {0} on this network at {1}.' -f $c, $At) }   # N2: never claims "shop network"; range and adapter stay in the tooltip
function global:Get-VncShortName([string]$n) {   # Squint: a reverse-DNS name shows its first label; the full name goes in the tooltip (R5-L1: callers pass only DNS names)
    if ($n -match '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\.?$' -and $n -notmatch '^\d+(\.\d+){3}$') { return $n.Split('.')[0] }
    return $n }
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
        nameText = $(if ($named) { Get-VncDisplayName $(if ($r.dnsName) { Get-VncShortName ([string]$r.name) } else { [string]$r.name }) 40 } else { 'Unnamed (F2 to name)' })
        nameFull = $(if ($named) { Get-SafeText ([string]$r.name) 255 } else { $null })
        nameFg = $(if ($named -and -not $dim) { '#FFFFFF' } else { '#A0A0A0' }); addrFg = $(if ($dim) { '#A0A0A0' } else { '#FFFFFF' })
        addr = $addr; seen = $seen; tip = $tip; row = $r }
}
function global:Test-VncPickerButton($btn) {   # L2: the explicit flag, else only the stock View Register (label + stock askTitle or UltraVNC shortcut, no args)
    if ($btn.PSObject.Properties['vncPicker']) { return [bool]$btn.vncPicker }
    if ((Get-ButtonType $btn) -ne 'program' -or ([string]$btn.args).Trim()) { return $false }
    if ((([string]$btn.label) -replace '\s+', ' ').Trim() -ne 'VIEW REGISTER') { return $false }
    return (([string]$btn.askTitle) -eq 'Pick the UltraVNC Viewer (vncviewer.exe)' -or (@($btn.detect.lnkNames) -contains 'UltraVNC Viewer'))
}
function global:Test-VncUsePassword($row, [bool]$hasSecret) { $hasSecret -and [bool]$row.session -and (Test-VncBannerText ([string]$row.banner)) -and (Test-VncIPv4 ([string]$row.host)) }   # L4 + V2-I1: only to a host that greeted RFB in this session's scan; LJ M44-L1: only a literal IPv4 (a name could resolve elsewhere), names let the viewer ask

# ----- view-only password -----
# Legacy (v1.4.1): vnc-viewonly.dat beside buttons.json. Start-up deletes it unread (LJ M39-I1); that path is never the new store.
function global:Get-VncSecretPath { Join-Path (Split-Path -Parent $global:cfgPath) 'vnc-viewonly.dat' }
# v1.4.4 (Charles 3:49 PM): POS1 has a view-only password; his old button supplied it. One value per Windows user, DPAPI CurrentUser + app entropy,
# in %LOCALAPPDATA%\ButtonLauncher\vnc-viewonly-v2.dat (folder and file: owner + SYSTEM only). Never in buttons.json, the logs or a command line.
function global:Get-VncViewOnlyDir { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ButtonLauncher' }
function global:Get-VncViewOnlyPath { Join-Path (Get-VncViewOnlyDir) 'vnc-viewonly-v2.dat' }
function global:Test-VncSecret { $i = Get-Item -LiteralPath (Get-VncViewOnlyPath) -Force -ErrorAction SilentlyContinue; [bool]($i -and -not $i.PSIsContainer -and -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) }
function global:New-VncOwnerOnlySecurity([bool]$dir) {   # protected ACL: this user (owner) + SYSTEM, full control; nothing inherited
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User; $sys = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    if ($dir) { $s = New-Object System.Security.AccessControl.DirectorySecurity; $inh = 'ContainerInherit,ObjectInherit' } else { $s = New-Object System.Security.AccessControl.FileSecurity; $inh = 'None' }
    $s.SetAccessRuleProtection($true, $false); $s.SetOwner($me)
    foreach ($id in $me, $sys) { $s.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inh, 'None', 'Allow'))) }
    return $s
}
function global:Remove-VncViewOnlySecret { foreach ($p in @((Get-VncViewOnlyPath), ((Get-VncViewOnlyPath) + '.tmp'))) {   # Setup > No password: plain files only, never a folder or link
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($i -and -not $i.PSIsContainer -and -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $p -Force -Confirm:$false -ErrorAction SilentlyContinue } } }
function global:Save-VncSecret([System.Security.SecureString]$ss) {   # $false (nothing saved) if any character is above 0xFF (V13-I1)
    Add-Type -AssemblyName System.Security
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss); $raw = $null; $prot = $null
    try {
        for ($i = 0; $i -lt $ss.Length; $i++) { if (([Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2) -band 0xFFFF) -gt 0xFF) { return $false } }
        $len = [Math]::Min(8, $ss.Length); $raw = New-Object byte[] $len   # UltraVNC uses the first 8 characters
        for ($i = 0; $i -lt $len; $i++) { $c = [Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2); $raw[$i] = [byte]($c -band 0xFF) }
        $prot = [System.Security.Cryptography.ProtectedData]::Protect($raw, $global:VncEntropy, 'CurrentUser')
        $dir = Get-VncViewOnlyDir; $p = Get-VncViewOnlyPath; $tmp = $p + '.tmp'
        if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir, (New-VncOwnerOnlySecurity $true)) }
        $di = Get-Item -LiteralPath $dir -Force; if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'store folder is a link' }
        foreach ($x in $p, $tmp) { $xi = Get-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue; if ($xi -and ($xi.PSIsContainer -or ($xi.Attributes -band [IO.FileAttributes]::ReparsePoint))) { throw 'store file is a folder or link' } }
        if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) }
        $fs = New-Object IO.FileStream($tmp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-VncOwnerOnlySecurity $false))   # owner-only from creation
        try { $fs.Write($prot, 0, $prot.Length) } finally { $fs.Dispose() }
        if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
        [IO.File]::SetAccessControl($p, (New-VncOwnerOnlySecurity $false))   # Replace keeps the old file's ACL; set ours again
        return $true
    } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); if ($raw) { [Array]::Clear($raw, 0, $raw.Length) } }
}
function global:Clear-VncSecret { foreach ($p in @((Get-VncSecretPath), ((Get-VncSecretPath) + '.tmp'))) {   # LJ M40-I1 / CC A1: the .dat and the old save's .tmp; only a plain file, never a folder or link; never prompts
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($i -and -not $i.PSIsContainer -and -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $p -Force -Confirm:$false -ErrorAction SilentlyContinue } } }
function global:Get-VncSecretHex {   # obfuscated hex for the .vnc file, or $null; the plaintext bytes are zeroed
    if (-not (Test-VncSecret)) { return $null }; $p = Get-VncViewOnlyPath
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
function global:Show-VncPasswordDialog($owner) {   # v1.4.4: set, change or clear this Windows user's view-only password; $true when one is saved. v1.4.6 (Squint 5, Kern): Password label, 12 px note, #B4B4BC live status, Remove password only when saved
    $dlg = New-D2Dialog 'View-only password' $owner 380; $d = $dlg.win; $sp = $dlg.body
    $t = New-D2Label "Type the view-only password of the computers you view. It's saved for you on this PC only and used by View only. Interact always asks."
    $t.Margin = '0,0,0,16'; [void]$sp.Children.Add($t)
    $lb = New-D2Label 'Password' '#FFFFFF' 14; $lb.Margin = '0,0,0,8'; [void]$sp.Children.Add($lb)
    $pb = New-Object System.Windows.Controls.PasswordBox; $pb.MaxLength = 64; [System.Windows.Automation.AutomationProperties]::SetName($pb, 'View-only password')
    try { [System.Windows.Automation.AutomationProperties]::SetLabeledBy($pb, $lb) } catch {}
    $pf = New-D2Field $pb; $pf.Margin = '0,0,0,8'; [void]$sp.Children.Add($pf)
    $nt = New-D2Label 'Only used for computers listed by IP address. UltraVNC uses only the first 8 characters.' '#B4B4BC' 12; $nt.Margin = '0,0,0,8'; [void]$sp.Children.Add($nt)
    $st = New-D2Label '' '#B4B4BC' 12; $st.Margin = '0,0,0,16'
    try { [System.Windows.Automation.AutomationProperties]::SetLiveSetting($st, 'Assertive') } catch {}
    $say = { param([string]$msg, [string]$fg) $st.Text = $msg; $st.Foreground = Brush $fg
        try { $pe = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($st); if ($pe) { $pe.RaiseAutomationEvent('LiveRegionChanged') } } catch {} }.GetNewClosure()
    $has = [bool](Test-VncSecret)
    $st.Text = if ($has) { 'A view-only password is saved.' } else { 'No view-only password is saved: View only asks for one.' }
    [void]$sp.Children.Add($st)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'
    $res = @{ saved = $has }
    $bSave = New-D2Button 'Save' 'Green' $dlg; $bSave.IsDefault = $true
    $bNone = New-D2Button 'Remove password' 'Chip' $dlg
    $bNone.Visibility = Get-VncRemoveButtonVisibility $has
    $bCancel = New-D2Button 'Cancel' 'Chip' $dlg; $bCancel.IsCancel = $true
    $bSave.Add_Click({
        if ($pb.SecurePassword.Length -eq 0) { & $say 'Type the password, then Save. Or press Cancel.' '#F59E0B'; [void]$pb.Focus(); return }
        $ok = $false; try { $ok = Save-VncSecret $pb.SecurePassword } catch { $ok = $null }
        if ($null -eq $ok) { $pb.Clear(); & $say "Couldn't save it. Nothing was changed." '#F59E0B'; Write-LauncherLog 'view-only password: save failed'; return }
        if (-not $ok) { $pb.Clear(); & $say "That password has a character UltraVNC can't use. Use standard letters, numbers and symbols, then Save again." '#F59E0B'; [void]$pb.Focus(); return }
        $res.saved = $true; Write-LauncherLog 'view-only password: saved'; $pb.Clear(); $d.Close() }.GetNewClosure())
    $bNone.Add_Click({ try { Remove-VncViewOnlySecret } catch {}; $pb.Clear()
        $left = $true; try { $left = [bool](Test-VncSecret) } catch {}   # LJ M47-I1: recheck, don't assume it worked
        if ($left) { Write-LauncherLog 'view-only password: remove failed (still saved)'; & $say "Couldn't remove it. The password is still saved; try again." '#F59E0B'; return }   # CC N1
        Write-LauncherLog 'view-only password: none'; $res.saved = $false
        $bNone.Visibility = Get-VncRemoveButtonVisibility $false; & $say 'Saved password removed. View only will ask for one.' '#B4B4BC'; [void]$pb.Focus() }.GetNewClosure())
    $bCancel.Add_Click({ $pb.Clear(); $d.Close() }.GetNewClosure())
    foreach ($b in $bSave, $bNone, $bCancel) { [void]$row.Children.Add($b) }
    [void]$sp.Children.Add($row)
    $d.Add_ContentRendered({ [void]$pb.Focus() }.GetNewClosure())
    [void]$d.ShowDialog()
    return $res.saved
}
function global:Get-VncRemoveButtonVisibility([bool]$hasSecret) { if ($hasSecret) { 'Visible' } else { 'Collapsed' } }   # v1.4.6 (Squint 5): Remove password only when one is saved
function global:Get-VncPasswordFallbackText($row, [bool]$hasSecret) {   # v1.4.6 (Squint 1): why View only lets the viewer ask; '' when the saved password is sent. Never contains the password.
    if (Test-VncUsePassword $row $hasSecret) { return '' }
    $n = Get-SafeText ([string]$(if ($row.name) { $row.name } else { $row.host })) 60
    if (-not $hasSecret) { return 'No view-only password is saved, so the viewer will ask. To skip the prompt, set one in Setup > View-only password.' }
    if (-not (Test-VncIPv4 ([string]$row.host))) { return ("{0} is listed by name, so the saved view-only password isn't sent and the viewer will ask. To skip the prompt, list it by IP address in Allowed computers." -f $n) }
    return ("{0} didn't answer the quick check, so the saved view-only password isn't sent. Press F5, then try View only again." -f $n)
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
function global:New-D2Field($field) {   # wraps a TextBox or PasswordBox in the D2 field look
    $b = New-Object System.Windows.Controls.Border; $b.Height = 32; $b.CornerRadius = '6'; $b.Background = Brush '#0FFFFFFF'
    $b.BorderBrush = Brush '#1FFFFFFF'; $b.BorderThickness = '1'; $b.Margin = '0,0,0,16'
    $field.Background = [System.Windows.Media.Brushes]::Transparent; $field.BorderThickness = '0'; $field.Foreground = Brush '#FFFFFF'
    $field.CaretBrush = Brush '#FFFFFF'; $field.FontSize = 14; $field.VerticalContentAlignment = 'Center'; $field.Padding = '8,0'
    $line = New-Object System.Windows.Controls.Border; $line.Height = 2; $line.VerticalAlignment = 'Bottom'; $line.Background = Brush '#22C55E'; $line.Visibility = 'Hidden'
    $line.CornerRadius = '0,0,6,6'; $line.IsHitTestVisible = $false
    $g = New-Object System.Windows.Controls.Grid; [void]$g.Children.Add($field); [void]$g.Children.Add($line); $b.Child = $g
    $field.Add_GotKeyboardFocus({ $line.Visibility = 'Visible' }.GetNewClosure()); $field.Add_LostKeyboardFocus({ $line.Visibility = 'Hidden' }.GetNewClosure())
    return $b
}
function global:New-D2Button([string]$text, [string]$style, $dlg) {
    $b = New-Object System.Windows.Controls.Button; $b.Content = $text; $b.Margin = '8,0,0,0'; $b.MinWidth = 88
    $s = $null; try { $s = $dlg.win.TryFindResource($style) } catch {}
    if ($s) { $b.Style = $s } else { $b.Height = 32 }
    $b.Padding = '16,0'   # Kern: MinWidth 88, padding 16,0
    return $b
}
function global:Show-VncAddDialog($owner) {   # Squint 4 + Kern 6: one dialog, Address and Name (optional). Cancel adds nothing. Returns @{ addr; name } or $null.
    $dlg = New-D2Dialog 'Add a computer' $owner 380
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
        if (-not $tA.Text.Trim()) { $err.Text = "Type the computer's address first."; $err.Visibility = 'Visible'; [void]$tA.Focus(); return }
        $res.out = @{ addr = $tA.Text.Trim(); name = $tN.Text.Trim() }; $dlg.win.Close() }.GetNewClosure())
    $bNo.Add_Click({ $res.out = $null; $dlg.win.Close() }.GetNewClosure())
    [void]$row.Children.Add($bOk); [void]$row.Children.Add($bNo); [void]$dlg.body.Children.Add($row)
    $dlg.win.Add_ContentRendered({ [void]$tA.Focus() }.GetNewClosure())
    [void]$dlg.win.ShowDialog()
    return $res.out
}

# v1.4.3 (Charles 1:14 PM): look for vncviewer.exe in Program Files once per session (start-up), never a full crawl.
# Roots: ProgramW6432, ProgramFiles, ProgramFiles(x86) (a 32-bit PowerShell sees x86 as ProgramFiles, so ProgramW6432 finds 64-bit).
# A root counts only if it is X:\Program Files or X:\Program Files (x86) on a local fixed disk with no link in it (env vars are user-settable).
# Known folders first (uvnc bvba\UltraVNC, UltraVNC); only if none hold the viewer, folders named *uvnc* / *UltraVNC* at depth 1,
# and their *uvnc* / *UltraVNC* subfolders at depth 2. Links (reparse points) are never entered or accepted. Only a plain file
# named vncviewer.exe counts. Several: the newest file version wins, ties by path (ordinal); the others are logged.
$global:VncViewerRetrySec = 30   # LJ M47-I2 / CC N2: a not-found search (and its log line) at most once per 30 s
$global:VncViewerScan = $null   # @{ path; how = 'known'|'scan'|''; others = @(); ms } after the first look
$global:VncViewerProbe = @{
    Env  = { @{ ProgramW6432 = [string]$env:ProgramW6432; ProgramFiles = [Environment]::GetFolderPath('ProgramFiles'); ProgramFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86') } }
    Dirs = { param($d) @(Get-ChildItem -LiteralPath $d -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object { @{ name = $_.Name; path = $_.FullName; link = [bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } }) }
    File = { param($f) try { $i = Get-Item -LiteralPath $f -Force -ErrorAction Stop; if ($i.PSIsContainer) { return $null }; @{ link = [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint); version = [string]$i.VersionInfo.FileVersion } } catch { $null } }
    Local = { param($p) Test-LocalFixedPath $p }
}
function global:Get-VncProgramRoots($probe) {   # distinct trusted Program Files roots, 64-bit first
    if (-not $probe) { $probe = $global:VncViewerProbe }
    $e = & $probe.Env; $out = @()
    foreach ($r in @($e.ProgramW6432, $e.ProgramFiles, $e.ProgramFilesX86)) {
        $r = ([string]$r).Trim().TrimEnd('\')
        if ($r -notmatch '^(?i)[A-Z]:\\Program Files( \(x86\))?$') { continue }
        if ($out -contains $r) { continue }
        if (-not (& $probe.Local $r)) { continue }
        $out += $r }
    return $out
}
function global:Get-VncFileVersion([string]$v) {   # '1.5.0.0' / '1, 2, 4, 0' -> [version]; unknown = 0.0
    $m = [regex]::Match([string]$v, '^\s*([0-9]+)[.,]\s*([0-9]+)(?:[.,]\s*([0-9]+))?(?:[.,]\s*([0-9]+))?')
    if (-not $m.Success) { return [version]'0.0' }
    try { $p = @(foreach ($g in 1..4) { if ($m.Groups[$g].Success) { [int]$m.Groups[$g].Value } else { 0 } })   # CC I2: a part over int32 -> 0.0 (unknown), never an error that hides the viewer
          return New-Object version $p[0], $p[1], $p[2], $p[3] } catch { return [version]'0.0' }
}
function global:Test-VncViewerFile([string]$f, $probe) {   # file info when $f is a plain local vncviewer.exe, else $null
    if (-not $f -or ($f -replace '^.*[\\/]', '') -ne 'vncviewer.exe') { return $null }   # leaf name, no path parsing that could throw
    $i = & $probe.File $f; if (-not $i -or $i.link) { return $null }
    if (-not (& $probe.Local $f)) { return $null }
    return $i
}
function global:Find-VncViewerInProgramFiles($probe) {   # @{ path; how; others } ; path '' when none
    if (-not $probe) { $probe = $global:VncViewerProbe }
    $roots = @(Get-VncProgramRoots $probe); $hits = @(); $how = 'known'; $capped = $false
    foreach ($r in $roots) { foreach ($k in 'uvnc bvba\UltraVNC', 'UltraVNC') {
        $f = "$r\$k\vncviewer.exe"; $i = Test-VncViewerFile $f $probe; if ($i) { $hits += @{ path = $f; ver = (Get-VncFileVersion $i.version) } } } }
    if (-not $hits) {
        $how = 'scan'; $pat = '(?i)uvnc|ultravnc'
        # CC L2: hard caps (folders seen, time); hitting one stops the search and is logged
        $maxDirs = if ($probe.MaxDirs) { [int]$probe.MaxDirs } else { 5000 }; $maxMs = if ($probe.MaxMs) { [int]$probe.MaxMs } else { 2000 }
        $sw = [Diagnostics.Stopwatch]::StartNew(); $seen = 0
        foreach ($r in $roots) {
            if ($capped) { break }
            foreach ($d1 in @(& $probe.Dirs $r)) {
                $seen++; if ($seen -gt $maxDirs -or $sw.ElapsedMilliseconds -gt $maxMs) { $capped = $true; break }
                if ($d1.link -or $d1.name -notmatch $pat) { continue }
                $sub = @(& $probe.Dirs $d1.path); $seen += $sub.Count; if ($seen -gt $maxDirs) { $capped = $true }
                $dirs = @($d1.path) + @(foreach ($d2 in $sub) { if (-not $d2.link -and $d2.name -match $pat) { $d2.path } })
                foreach ($d in $dirs) { $f = "$d\vncviewer.exe"; $i = Test-VncViewerFile $f $probe
                    if ($i -and -not (@(foreach ($h in $hits) { $h.path }) -contains $f)) { $hits += @{ path = $f; ver = (Get-VncFileVersion $i.version) } } } } } }
    if (-not $hits) { return @{ path = ''; how = ''; others = @(); capped = $capped } }
    $sorted = @($hits | Sort-Object @{ Expression = { $_.ver }; Descending = $true }, @{ Expression = { $_.path }; Descending = $false })
    # Sort-Object is culture-aware for strings; settle exact version ties by ordinal path
    $tie = New-Object System.Collections.Generic.List[string]; foreach ($h in $sorted) { if ($h.ver -eq $sorted[0].ver) { $tie.Add($h.path) } }; $tie.Sort([StringComparer]::Ordinal)
    return @{ path = $tie[0]; how = $how; others = @(foreach ($h in $sorted) { if ($h.path -ne $tie[0]) { $h.path } }); capped = $capped }
}
function global:Get-VncViewerLogText([string]$path, [string]$how, $others, $vi) {   # one log line; never a password (there is none)
    if (-not $path) { return 'VNC viewer: not found in Program Files' }
    $t = 'VNC viewer: "{0}" found by {1} (viewer "{2}" {3})' -f (Get-SafeText $path 260), $how, $vi.product, $vi.version
    $o = @(foreach ($x in @($others)) { if ($x) { '"' + (Get-SafeText $x 260) + '"' } }); if ($o) { $t += '; also found: ' + ($o -join ', ') }
    return $t
}
function global:Get-VncScanAge($at) {   # CC D1: seconds since $at; clock moved back (negative) or missing = expired
    if (-not ($at -is [DateTime])) { return [double]::MaxValue }
    $s = ([DateTime]::UtcNow - $at).TotalSeconds; if ($s -lt 0) { return [double]::MaxValue }; return $s
}
function global:Initialize-VncViewerScan([switch]$Retry) {   # once per session (again with -Retry while not found); logs what it found
    if ($global:VncViewerScan -and ($global:VncViewerScan.path -or -not $Retry -or (Get-VncScanAge $global:VncViewerScan.at) -lt $global:VncViewerRetrySec)) { return $global:VncViewerScan }   # v1.4.6 (Squint 2): a cached 'not found' is searched again on Retry; LJ M47-I2/CC N2: at most every 30 s, so it logs at most once per window
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $r = Find-VncViewerInProgramFiles } catch { $r = @{ path = ''; how = ''; others = @() } }
    $r.ms = $sw.ElapsedMilliseconds; $r.at = [DateTime]::UtcNow; $global:VncViewerScan = $r
    $vi = if ($r.path) { Get-VncViewerInfo $r.path } else { $null }
    Write-LauncherLog ((Get-VncViewerLogText $r.path $r.how $r.others $vi) + (' [{0} ms]' -f $r.ms) + $(if ($r.capped) { ' (search stopped early: folder or time limit reached)' } else { '' }))
    return $r
}
function global:Find-VncViewer($btn) {   # local fixed path to vncviewer.exe, or $null. Order: valid saved path (override), Program Files, HKLM App Paths, ask.
    $t = Expand $btn.target; $how = $null; $f = $null; $others = @()
    if (-not (Is-Todo $t)) {   # LJ M41-L1: an override counts only as a plain local file named exactly vncviewer.exe; anything else (.lnk, odd path) is ignored and logged
        if (Test-VncViewerFile $t $global:VncViewerProbe) { $f = $t; $how = 'override' }
        elseif ($global:VncViewerBadOverride -ne $t) { $global:VncViewerBadOverride = $t; Write-LauncherLog ('VNC viewer: saved path "{0}" ignored (not a plain local vncviewer.exe); using the Program Files search' -f (Get-SafeText $t 260)) } }
    if (-not $f) { $s = Initialize-VncViewerScan -Retry; if ($s.path -and (Test-VncViewerFile $s.path $global:VncViewerProbe)) { $f = $s.path; $how = $s.how; $others = $s.others } }   # LJ M41-I1: recheck as a plain local vncviewer.exe
    if (-not $f) { try {   # HKLM only: HKCU is user-writable
        $v = [string](Get-ItemProperty -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\vncviewer.exe' -ErrorAction Stop).'(default)'
        $v = (Expand $v).Trim('"'); if ($v -and (Test-VncViewerFile $v $global:VncViewerProbe)) { $f = $v; $how = 'registry' } } catch {} }
    if (-not $f) {
        $ans = [System.Windows.MessageBox]::Show("UltraVNC Viewer isn't installed on this PC (looked in Program Files).`n`nDo you want to find vncviewer.exe yourself?`n`nChoose No to close. To install it, ask whoever looks after this PC.", 'View Register', 'YesNo', 'Information', 'No')
        if ($ans -ne 'Yes') { return $null }
        $f = Ask-ForPath $btn 'program'; $how = 'picked'
        if (-not $f) { return $null }
        if ($f -like '*.lnk') { try { $f = (New-Object -ComObject WScript.Shell).CreateShortcut($f).TargetPath } catch { $f = $null } }
        if (-not $f -or -not (Test-LocalFixedPath $f) -or -not (Test-Path -LiteralPath $f -PathType Leaf)) {
            [System.Windows.MessageBox]::Show("The viewer has to be on this PC's own drive (not a network share).", 'View Register') | Out-Null; return $null }
        Set-Prop $btn 'target' $f; Save-Config }   # only a user pick is saved; it is the override next time
    if ($global:VncViewerUsed -ne "$how|$f") { $global:VncViewerUsed = "$how|$f"; Write-LauncherLog (Get-VncViewerLogText $f $how $others (Get-VncViewerInfo $f)) }
    return $f
}
# ---------- v1.4.1 allowed computers (Charles 4:09 PM, option A) ----------
# One admin-only list: %ProgramData%\ButtonLauncher\vnc-allowed.json  { "version": 1, "computers": [ { "name", "host", "port" } ] }
# Untrusted input on read and on save: names 1-40 of [A-Za-z0-9 ._#()-], hosts IPv4 or RFC-1123, port 1-65535, at most 50, no duplicates, 64 KB cap.
# The picker shows only this list (no network scan). Missing, empty, unreadable or unprotected file = nobody allowed yet.
# Saving runs one elevated powershell.exe (UAC) whose script is a constant here (-EncodedCommand); the only data in it is base64 of the validated JSON.
$global:VncAllowedMax = 50
function global:Get-VncAllowedPath { Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ButtonLauncher\vnc-allowed.json' }
function global:Test-VncAllowedName([string]$n) { $n -cmatch '\A[A-Za-z0-9][A-Za-z0-9 ._#()-]{0,39}\z' }
function global:Test-VncAllowedHost([string]$h) {   # IPv4, or an RFC-1123 hostname (labels 1-63 of letters, digits, '-', not at either end); no trailing dot
    if (-not $h -or $h.EndsWith('.')) { return $false }
    return ((Test-VncHost $h) -and ($h -cmatch '^[A-Za-z0-9.-]+$'))
}
function global:ConvertTo-VncAllowedList($items) {   # @{ list = validated entries; bad = count skipped }
    $list = New-Object System.Collections.ArrayList; $bad = 0; $seen = @{}
    foreach ($e in @($items)) {
        if ($null -eq $e) { $bad++; continue }
        $n = ([string]$e.name).Trim(); $h = ([string]$e.host).Trim(); $p = if ($null -eq $e.port -or [string]$e.port -eq '') { 5900 } else { Get-VncPort $e.port }
        if (-not (Test-VncAllowedName $n) -or -not (Test-VncAllowedHost $h) -or -not $p -or $p -lt 100 -or $list.Count -ge $global:VncAllowedMax) { $bad++; continue }
        $k = ('{0}:{1}' -f $h.ToLowerInvariant(), $p); if ($seen[$k]) { $bad++; continue }; $seen[$k] = $true
        [void]$list.Add([pscustomobject]@{ name = $n; host = $h; port = [int]$p }) }
    return @{ list = @($list); bad = $bad }
}
function global:ConvertFrom-VncAllowedJson([string]$text) {   # @{ list; bad; error } ; never throws
    if ($null -eq $text -or $text.Length -gt 65536) { return @{ list = @(); bad = 0; error = 'too big' } }
    try { $o = $text | ConvertFrom-Json } catch { return @{ list = @(); bad = 0; error = 'not valid JSON' } }
    if (-not $o -or -not $o.PSObject.Properties['computers']) { return @{ list = @(); bad = 0; error = $(if ([string]::IsNullOrWhiteSpace($text)) { '' } else { 'no computers list' }) } }
    $r = ConvertTo-VncAllowedList @($o.computers); return @{ list = $r.list; bad = $r.bad; error = '' }
}
function global:ConvertTo-VncAllowedJson($list) {   # compact JSON of already validated entries
    $c = @(foreach ($e in @($list)) { [ordered]@{ name = [string]$e.name; host = [string]$e.host; port = [int]$e.port } })
    return (ConvertTo-Json -InputObject ([ordered]@{ version = 1; computers = $c }) -Depth 4 -Compress)
}
function global:ConvertFrom-VncAllowedText([string]$text) {   # editor: one 'Name, address[:port]' per line -> @{ list; error }
    $items = @(); $i = 0
    foreach ($line in ($text -split "`r?`n")) { $i++
        $t = $line.Trim(); if (-not $t) { continue }
        $parts = $t.Split(','); if ($parts.Count -ne 2) { return @{ list = @(); error = ('Line {0}: use Name, address (for example Register 1, 192.168.1.21).' -f $i) } }
        $n = $parts[0].Trim(); $ep = ConvertTo-VncEndpoint $parts[1].Trim() 5900
        if (-not (Test-VncAllowedName $n)) { return @{ list = @(); error = ('Line {0}: the name must be 1-40 letters, numbers, spaces or . _ # ( ) -' -f $i) } }
        if (-not $ep -and $parts[1].Trim() -match '\A[^:]+::?([0-9]{1,5})\z' -and [int]$matches[1] -lt 100) { return @{ list = @(); error = ('Line {0}: ports below 100 aren''t supported. Use the VNC port (usually 5900).' -f $i) } }   # CC N-L2
        if (-not $ep -or -not (Test-VncAllowedHost $ep.host)) { return @{ list = @(); error = ('Line {0}: that address isn''t valid. Use an IP like 192.168.1.21 or a name like REG1, optionally :port.' -f $i) } }
        $items += [pscustomobject]@{ name = $n; host = $ep.host; port = $ep.port } }
    if ($items.Count -gt $global:VncAllowedMax) { return @{ list = @(); error = ('At most {0} computers.' -f $global:VncAllowedMax) } }
    $r = ConvertTo-VncAllowedList $items
    if ($r.bad) { return @{ list = @(); error = 'The same computer is listed twice.' } }
    return @{ list = $r.list; error = '' }
}
function global:ConvertTo-VncAllowedText($list) { (@(foreach ($e in @($list)) { if ($e.port -eq 5900) { '{0}, {1}' -f $e.name, $e.host } else { '{0}, {1}:{2}' -f $e.name, $e.host, $e.port } }) -join "`r`n") }
function global:Test-VncAllowedAclSafe($acl) {   # owner is Administrators or SYSTEM, and only Administrators/SYSTEM/TrustedInstaller may write
    $okSids = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    try { $own = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { return $false }
    if ($okSids -notcontains $own) { return $false }
    # LJ M37-I1: delete-child, Delete, WRITE_DAC, WRITE_OWNER and GENERIC_WRITE / GENERIC_ALL (0x50000000) count as write; inherit-only ACEs don't apply here
    $write = [int64]([System.Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership, AppendData, CreateFiles, CreateDirectories, WriteData') -bor 0x50000000
    foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ([string]$r.AccessControlType -ne 'Allow') { continue }
        if (([int64]$r.PropagationFlags -band 2) -ne 0) { continue }   # InheritOnly
        if ((([int64]$r.FileSystemRights -band 0xFFFFFFFFL) -band $write) -and ($okSids -notcontains $r.IdentityReference.Value)) { return $false } }
    return $true
}
function global:Read-VncAllowed {   # @{ list; state = 'ok' | 'missing' | 'unsafe' | 'bad' ; bad }
    $p = Get-VncAllowedPath
    try {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ list = @(); state = 'missing'; bad = 0 } }
        $fi = Get-Item -LiteralPath $p; $di = $fi.Directory
        if (($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($di.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return @{ list = @(); state = 'unsafe'; bad = 0 } }
        if (-not (Test-VncAllowedAclSafe ([IO.File]::GetAccessControl($p))) -or -not (Test-VncAllowedAclSafe ([IO.Directory]::GetAccessControl($di.FullName)))) { return @{ list = @(); state = 'unsafe'; bad = 0 } }
        if ($fi.Length -gt 65536) { return @{ list = @(); state = 'bad'; bad = 0 } }
        $r = ConvertFrom-VncAllowedJson ([IO.File]::ReadAllText($p))
        return @{ list = $r.list; state = $(if ($r.error) { 'bad' } else { 'ok' }); bad = $r.bad }
    } catch { Write-LauncherLog ('allowed computers list unreadable: ' + $_.Exception.GetType().Name); return @{ list = @(); state = 'bad'; bad = 0 } }
}
# Elevated writer: constants only. __DATA__ is replaced by base64 (A-Z a-z 0-9 + / =) of the validated JSON; it re-checks every entry before writing.
$global:VncAllowedWriterScript = @'
$ErrorActionPreference = 'Stop'
$s = 0   # v1.4.4: which step failed -> exit 20+step (was a bare code 2)
try {
    $s = 1; $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__DATA__'))
    if ($json.Length -gt 65536) { exit 3 }
    $o = $json | ConvertFrom-Json
    $out = @(); $seen = @{}
    foreach ($e in @($o.computers)) {
        $n = [string]$e.name; $h = [string]$e.host; $p = [int]$e.port
        if ($n -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._#()-]{0,39}\z' -or $h.Length -gt 253 -or $p -lt 100 -or $p -gt 65535) { exit 3 }   # LJ M44-I2
        if ($h -cmatch '\A[0-9.]+\z') { if ($h -cnotmatch '\A((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\z') { exit 3 } }
        elseif ($h -cnotmatch '\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z') { exit 3 }
        $k = $h.ToLowerInvariant() + ':' + $p; if ($seen[$k]) { exit 3 }; $seen[$k] = 1
        $out += [ordered]@{ name = $n; host = $h; port = $p } }
    if ($out.Count -gt 50) { exit 3 }
    $text = ConvertTo-Json -InputObject ([ordered]@{ version = 1; computers = $out }) -Depth 4 -Compress
    # LJ M37-M1: never reuse a folder or file a non-admin could have made or still holds open
__ACLCHECK__
    $s = 2; $dir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ButtonLauncher'
    $adm = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'; $sys = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'; $usr = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    $ds = New-Object Security.AccessControl.DirectorySecurity
    $ds.SetOwner($adm); $ds.SetAccessRuleProtection($true, $false)
    foreach ($x in @(@($adm, 'FullControl'), @($sys, 'FullControl'), @($usr, 'ReadAndExecute'))) {
        $ds.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($x[0], $x[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow'))) }
    $s = 3; if (Test-Path -LiteralPath $dir) {   # untrusted (link, wrong owner, or anyone else may write): moved aside, never deleted
        $di = Get-Item -LiteralPath $dir -Force
        if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-VncAllowedAclSafe ([IO.Directory]::GetAccessControl($dir)))) {
            [IO.Directory]::Move($dir, ($dir + '.untrusted-' + [guid]::NewGuid().ToString('N'))) } }
    $s = 4; if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir, $ds) }   # ACL set at creation
    $di = Get-Item -LiteralPath $dir -Force
    if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-VncAllowedAclSafe ([IO.Directory]::GetAccessControl($dir)))) { exit 4 }   # re-check (a re-create race)
    $s = 5; $file = Join-Path $dir 'vnc-allowed.json'; $tmp = Join-Path $dir 'vnc-allowed.json.tmp'
    if ((Test-Path -LiteralPath $file -PathType Container) -or (Test-Path -LiteralPath $tmp -PathType Container)) { exit 6 }   # CC LOW-L: a folder where a file belongs
    foreach ($c in Get-ChildItem -LiteralPath $dir -Force) { if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 4 } }
    if (Test-Path -LiteralPath $file) { if (-not (Test-VncAllowedAclSafe ([IO.File]::GetAccessControl($file)))) { exit 4 } }
    if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) }   # only an admin could have made it in this folder
    $s = 6; $fs = New-Object Security.AccessControl.FileSecurity
    $fs.SetOwner($adm); $fs.SetAccessRuleProtection($true, $false)
    foreach ($x in @(@($adm, 'FullControl'), @($sys, 'FullControl'), @($usr, 'ReadAndExecute'))) { $fs.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($x[0], $x[1], 'Allow'))) }
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($text)
    $st = New-Object IO.FileStream($tmp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $fs)   # brand-new file, admin ACL from creation
    try { $st.Write($bytes, 0, $bytes.Length); $st.Flush() } finally { $st.Dispose() }
    $s = 7; if (Test-Path -LiteralPath $file) { [IO.File]::Replace($tmp, $file, [NullString]::Value) } else { [IO.File]::Move($tmp, $file) }   # v1.4.5: `$null` became '' and Replace threw (code 27 on every save after the first)
    $fi = Get-Item -LiteralPath $file -Force
    if (($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-VncAllowedAclSafe ([IO.File]::GetAccessControl($file)))) { exit 5 }
    exit 0
} catch { exit (20 + $s) }
'@
function global:Get-VncAllowedWriterText([string]$b64) {   # constant script + the reader's own ACL check (launcher code, not user data) + base64 data
    $chk = 'function Test-VncAllowedAclSafe {' + ${function:Test-VncAllowedAclSafe}.ToString() + '}'
    return $global:VncAllowedWriterScript.Replace('__ACLCHECK__', $chk).Replace('__DATA__', $b64)
}
function global:Get-VncAllowedWriterCommand($list) {   # the -EncodedCommand text for a validated list, or $null when too long for one command line
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-VncAllowedJson $list)))
    if ($b64 -cnotmatch '^[A-Za-z0-9+/=]*$') { return $null }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-VncAllowedWriterText $b64)))
    if ($enc.Length -gt 32000) { return $null }   # CreateProcess limit is 32767 characters for the whole command line
    return $enc
}
function global:Get-VncAllowedSaveError([int]$code) {   # CC LOW-L: plain words for the elevated writer's exit codes
    $d = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ButtonLauncher'
    switch ($code) {
        3 { return 'Not saved: the list was not valid.' }
        { $_ -in 4, 5, 6 } { return "Not saved: $d holds something unexpected (a link, a folder named like the list file, or a file someone else can change). Ask an administrator to check that folder, then save again." }
        { $_ -ge 21 -and $_ -le 27 } { $step = @('reading the list', 'preparing the folder permissions', 'checking the existing folder (it may be open in another program)', 'creating the folder', 'checking the folder contents', 'writing the new file', 'replacing the old file')[$code - 21]
            return "Not saved (code $code): Windows refused while $step. The saved list was not replaced; the old list (if any) is kept. Close any window showing $d and try again." }
        default { return "Not saved (code $code). Nothing was changed." } }
}
function global:Save-VncAllowedElevated($list) {   # $true when saved; Windows asks for an administrator (UAC)
    $enc = Get-VncAllowedWriterCommand $list
    if (-not $enc) { [System.Windows.MessageBox]::Show('That list is too long to save. Use fewer or shorter names.', 'Allowed computers') | Out-Null; return $false }
    $ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'   # LJ M37-I3: the real System32, not an environment variable
    try { $p = Start-Process -FilePath $ps -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) }
    catch { return $false }   # UAC cancelled
    if ($p.ExitCode -ne 0) { Write-LauncherLog ('allowed computers save failed, code ' + $p.ExitCode); [System.Windows.MessageBox]::Show((Get-VncAllowedSaveError ([int]$p.ExitCode)), 'Allowed computers') | Out-Null; return $false }
    return $true
}
function global:Show-VncAllowedDialog($owner) {   # Setup > Allowed computers (admin)...
    $cur = Read-VncAllowed
    $dlg = New-D2Dialog 'Allowed computers (admin)' $owner 440; $d = $dlg.win; $sp = $dlg.body
    [void]$sp.Children.Add((New-D2Label "View Register shows only these computers, for every Windows user on this PC. One per line: Name, address (an IP or computer name, optionally :port). Use IP addresses if you want View only to use the saved password. Saving asks Windows for an administrator."))
    $st = New-D2Label '' '#A0A0A0' 12
    $st.Text = switch ($cur.state) { 'unsafe' { 'The saved list is not protected, so it is ignored. Save again to fix it.' } 'bad' { 'The saved list could not be read. Save again to replace it.' } default { '{0} of {1} allowed.' -f @($cur.list).Count, $global:VncAllowedMax } }
    [void]$sp.Children.Add($st)
    $tb = New-Object System.Windows.Controls.TextBox; $tb.AcceptsReturn = $true; $tb.TextWrapping = 'NoWrap'; $tb.MaxLength = 6000; $tb.Text = ConvertTo-VncAllowedText $cur.list
    $tb.Height = 200; [System.Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($tb, 'Auto'); [System.Windows.Automation.AutomationProperties]::SetName($tb, 'Allowed computers, one per line')
    $f = New-D2Field $tb; $f.Height = 210; $tb.VerticalContentAlignment = 'Top'; $tb.Padding = '8,6'; [void]$sp.Children.Add($f)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'
    $bSave = New-D2Button 'Save as administrator...' 'Green' $dlg; $bCancel = New-D2Button 'Cancel' 'Chip' $dlg; $bCancel.IsCancel = $true
    $bSave.Add_Click({
        $r = ConvertFrom-VncAllowedText $tb.Text
        if ($r.error) { $st.Text = $r.error; $st.Foreground = Brush '#F59E0B'; [void]$tb.Focus(); return }
        if (Save-VncAllowedElevated $r.list) { $d.Close() } else { $st.Text = 'Not saved.'; $st.Foreground = Brush '#F59E0B' } }.GetNewClosure())
    $bCancel.Add_Click({ $d.Close() }.GetNewClosure())
    [void]$row.Children.Add($bSave); [void]$row.Children.Add($bCancel); [void]$sp.Children.Add($row)
    $d.Add_ContentRendered({ [void]$tb.Focus() }.GetNewClosure())
    [void]$d.ShowDialog()
}
# Quick online check of the allowed computers only: 300 ms connect, at most 12 bytes read, never replies.
$global:VncAllowedCheckScript = {
    param($items, [int]$timeoutMs, $sync)
    $batch = @()
    try {
        foreach ($it in $items) { $c = New-Object System.Net.Sockets.TcpClient; $b = @{ key = $it.key; c = $c; ar = $null }; $batch += $b
            try { $b.ar = $c.BeginConnect([string]$it.host, [int]$it.port, $null, $null) } catch {} }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
        foreach ($b in $batch) {
            if ($sync.cancel -or -not $b.ar) { continue }
            $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $ok = $false; try { $ok = $b.ar.AsyncWaitHandle.WaitOne($left) -and $b.c.Connected } catch {}
            if (-not $ok) { continue }
            $buf = New-Object byte[] 12; $got = 0
            try { $s = $b.c.GetStream(); $s.ReadTimeout = $timeoutMs
                  while ($got -lt 12) { $n = $s.Read($buf, $got, 12 - $got); if ($n -le 0) { break }; $got += $n } } catch {}
            $g = [Text.Encoding]::ASCII.GetString($buf, 0, $got)
            if ($got -eq 12 -and $g -cmatch '^RFB \d{3}\.\d{3}\n$') { $sync.found.Enqueue(@{ key = $b.key; banner = $g.TrimEnd([char]10) }) } }   # CC MED-1: the banner too
    } finally { foreach ($b in $batch) { try { $b.c.Close() } catch {} }; $sync.done = $true }
}
function global:Get-VncAllowedRows($list, $online, [bool]$checking) {   # picker rows for the allowed list, sorted by name
    $rows = foreach ($e in @($list)) { $k = '{0}:{1}' -f $e.host, $e.port
        $bn = [string]$online[$k]; if (-not (Test-VncBannerText $bn)) { $bn = '' }   # CC MED-1: the RFB greeting from this window's online check
        $r = [pscustomobject]@{ host = $e.host; port = $e.port; name = $e.name; dnsName = $false; banner = $bn; pinned = $false; fav = $false; seen = [bool]$bn; session = [bool]$bn }
        $v = Get-VncRowView $r $true $false
        $v.star = ''; $v.starTip = $null; $v.seen = $(if ($r.seen) { 'Online' } elseif ($checking) { 'Checking...' } else { 'Offline' })
        $v.nameFg = '#FFFFFF'; $v.addrFg = $(if ($r.seen -or $checking) { '#FFFFFF' } else { '#A0A0A0' })
        $v }
    return @($rows | Sort-Object { $_.row.name })
}
function global:Get-VncViewerInfo([string]$exe) {   # 'UltraVNC 1.5.0.0 (64-bit)' style text for the log; $null product = unknown
    try { $vi = (Get-Item -LiteralPath $exe).VersionInfo; $prod = [string]$vi.ProductName; $ver = [string]$vi.FileVersion } catch { $prod = ''; $ver = '' }
    return @{ product = (Get-SafeText $prod 60); version = (Get-SafeText $ver 30); ultra = ($prod -match 'Ultr@?VNC|UltraVNC') }
}
function global:Start-VncViewer($btn, $row, [bool]$viewOnly, $owner, [scriptblock]$OnEarlyExit) {
    $h = ([string](Get-VncRowHost $row)).Trim(); $p = Get-VncPort (Get-VncRowPort $row)   # v1.4.9: host/port read from the row whether it is a PSCustomObject, a hashtable or a picker view (.row)
    if (-not $h) { Write-LauncherLog 'VNC launch refused: empty host (nothing passed to the viewer)'; Show-VncNotice "This computer has no address, so the viewer wasn't started. Ask your administrator to check Setup > Allowed computers."; return $false }
    if (-not (Test-VncHost $h) -or -not $p) { Write-LauncherLog ('VNC launch refused: invalid host or port "{0}"' -f (Get-SafeText ('{0}:{1}' -f $h, (Get-SafeText ([string](Get-VncRowPort $row)) 10)) 80)); Show-VncNotice "That address isn't valid, so the viewer wasn't started."; return $false }
    if ($p -lt 100) { [System.Windows.MessageBox]::Show("Ports below 100 aren't supported. Use the computer's VNC port (usually 5900).", 'View Register') | Out-Null; return $false }   # L6/M43-I2
    $exe = Find-VncViewer $btn; if (-not $exe) { return $false }
    $file = $null; $hex = $null
    try {
        # v1.4.4: View only hands the saved view-only password to UltraVNC in a short-lived owner-only .vnc (-config), never on the command line.
        # Interact never sends one (the viewer asks). Only to a host that greeted RFB this session (L4 + V2-I1).
        $pw = 'none'
        if ($viewOnly -and (Test-VncUsePassword $row (Test-VncSecret))) { $hex = Get-VncSecretHex; if ($hex) { $file = New-VncTempConfig $h $p $hex; $pw = 'saved' } }
        $why = if ($viewOnly -and $pw -ne 'saved') { Get-VncPasswordFallbackText $row (Test-VncSecret) } else { '' }   # v1.4.6 (Squint 1)
        $vargs = @(Get-VncViewerArgs $h $p $viewOnly $file); $vi = Get-VncViewerInfo $exe
        $argLine = Get-VncArgLine $vargs   # v1.4.9: ONE string, built here and logged byte-for-byte as passed (no PS 5.1 array re-joining)
        if (-not $argLine.StartsWith($h + ':')) { throw 'the viewer arguments do not start with the host' }   # v1.4.9 guard: never start the viewer without host:port first
        Write-LauncherLog (Get-VncLaunchLogText $viewOnly $exe $vargs $file $pw $vi)   # never the password or the .vnc contents; the temp path is redacted

        if ($why) { Write-LauncherLog ('VNC view only: viewer will ask: ' + $why); if ($global:vncPicker) { $global:vncPicker.setStatus.Invoke($why) } }
        if (-not $vi.ultra -and $owner -and $global:vncPicker) { $global:vncPicker.setStatus.Invoke(('The picked viewer is "{0}", not UltraVNC. Pick UltraVNC''s vncviewer.exe if it can''t connect.' -f $vi.product)) }
        $psi = New-VncStartInfo $exe $argLine   # v1.4.9: like a Win+R / manual start: ShellExecute, the viewer's own folder, one exact argument string
        Write-LauncherLog (Get-VncStartInfoLogText $psi $file)   # read back from the ProcessStartInfo right before Start(); temp .vnc redacted, never a password
        $proc = Start-VncProcess $psi
        if ($file) { Remove-VncTempSoon $file $proc $OnEarlyExit; $file = $null }   # deleted 3 s after the viewer shows a window, or at 8 s
        return $true
    } catch {
        if ($file) { [void](Remove-VncTempDir (Split-Path -Parent $file)) }
        [System.Windows.MessageBox]::Show("Couldn't start the viewer.`n`n" + $_.Exception.Message, 'View Register') | Out-Null; return $false
    } finally { $hex = $null; if ($file) { [void](Remove-VncTempDir (Split-Path -Parent $file)) } }
}
function global:Show-VncNotice([string]$t) { [System.Windows.MessageBox]::Show($t, 'View Register') | Out-Null }
function global:Get-VncRowHost($row) {   # v1.4.9: the host of a picker row: PSCustomObject or hashtable, or a picker view whose .row holds it
    if ($null -eq $row) { return '' }
    if ($row -is [System.Collections.IDictionary]) { if ($row.Contains('host')) { return [string]$row['host'] }; if ($row.Contains('row')) { return (Get-VncRowHost $row['row']) }; return '' }
    if ($row.PSObject.Properties['host']) { return [string]$row.host }
    if ($row.PSObject.Properties['row']) { return (Get-VncRowHost $row.row) }
    return ''
}
function global:Get-VncRowPort($row) {
    if ($null -eq $row) { return $null }
    if ($row -is [System.Collections.IDictionary]) { if ($row.Contains('port')) { return $row['port'] }; if ($row.Contains('row')) { return (Get-VncRowPort $row['row']) }; return $null }
    if ($row.PSObject.Properties['port']) { return $row.port }
    if ($row.PSObject.Properties['row']) { return (Get-VncRowPort $row.row) }
    return $null
}
function global:Get-VncArgLine($vargs) { (@($vargs) | ForEach-Object { [string]$_ }) -join ' ' }   # the exact string handed to the viewer
function global:New-VncStartInfo([string]$exe, [string]$argLine) {   # never elevated (no runas), inherits the launcher user's context unchanged, nothing but the one argument string
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $argLine; $psi.UseShellExecute = $true
    $psi.WorkingDirectory = ($exe -replace '[\\/][^\\/]*$', '')   # the viewer's own folder (string form: same result on Windows, testable elsewhere)
    return $psi
}
function global:Start-VncProcess($psi) { [System.Diagnostics.Process]::Start($psi) }
function global:Get-VncStartInfoLogText($psi, [string]$file) {   # 'VNC viewer start: exe="..." args="..." dir="..." shell=True'
    $a = [string]$psi.Arguments; if ($file) { $a = $a.Replace($file, '<temp .vnc>') }
    return ('VNC viewer start: exe="{0}" args="{1}" dir="{2}" shell={3}' -f $psi.FileName, $a, $psi.WorkingDirectory, $psi.UseShellExecute)
}
function global:Get-VncArgLogText([string]$exe, [string]$argLine, [string]$file) {   # 'VNC viewer start: exe="<path>" args="<exact args>"'; a temp .vnc shows as <temp .vnc>; never a password (none is ever on the command line)
    $shown = if ($file) { $argLine.Replace($file, '<temp .vnc>') } else { $argLine }
    return ('VNC viewer start: exe="{0}" args="{1}"' -f $exe, $shown)
}
function global:Get-VncLaunchLogText([bool]$viewOnly, [string]$exe, $vargs, [string]$file, [string]$pw, $vi) {   # 'VNC view only: "<exe>" <args> (viewer ...) view-only password: saved|none'
    $shown = @(foreach ($x in @($vargs)) { if ($file -and ([string]$x).Contains($file)) { '"<temp .vnc>"' } else { [string]$x } }) -join ' '
    $pwText = if ($viewOnly) { '; view-only password: ' + $(if ($pw -eq 'saved') { 'saved' } else { 'none' }) } else { '' }
    return ('VNC {0}: "{1}" {2} (viewer "{3}" {4}){5}{6}' -f $(if ($viewOnly) { 'view only' } else { 'interact' }), $exe, $shown, $vi.product, $vi.version, $(if ($vi.ultra) { '' } else { ' NOT UltraVNC' }), $pwText)
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
            $a = [System.Windows.MessageBox]::Show(("Look for computers you can view on this network ({1})?`n`nThis quickly checks this network for computers you can view. You'll only be asked again if the network changes.`n`n(Range {0}, port {2})" -f $rg, $n.label, $ui.state.port), 'View Register', 'YesNo', 'Question', $(if ($Ask) { 'Yes' } else { 'No' }))
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
    if ($plan.none) { $ui.showEmpty.Invoke('nonet'); $ui.setStatus.Invoke('No local network found on this PC, so nothing was scanned.'); return }
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
    $ui.setStatus.Invoke(('Looking for computers on {0} (0 of {1})...' -f $ui.scan.range, $plan.targets.Count))
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
    if (-not $sc.sync.done) { $ui.setStatus.Invoke(('Looking for computers on {0} ({1} of {2})...' -f $sc.range, $sc.sync.scanned, $sc.sync.total)); return }
    if (-not $sc.nameps -and $sc.hits.Count -gt 0) {   # banners done: names, then save
        try { $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $ps = [powershell]::Create(); $ps.Runspace = $rs; $sc.namers = $rs; $sc.nameps = $ps
              [void]$ps.AddScript($global:VncNameScript).AddArgument([string[]]@($sc.hits | ForEach-Object { $_.host })).AddArgument($sc.sync); [void]$ps.BeginInvoke() }
        catch { $sc.sync.namesDone = $true } }
    if ($sc.hits.Count -gt 0 -and -not $sc.sync.namesDone) {
        if (Get-VncWorkerFault $sc.nameps $false) { $sc.sync.namesDone = $true }   # names are best effort: a failed lookup just ends it
        else { $ui.setStatus.Invoke((Get-VncFoundText $sc.hits.Count -LookingUp)); return } }
    $found = $sc.hits.Count; $range = $sc.range
    $ui.hosts = @($sc.hits)
    Stop-VncScan $ui
    try { Save-VncCache $ui.cachePath $ui.hosts ([datetime]::UtcNow) } catch {}
    $ui.refresh.Invoke()
    $ui.setStatus.Invoke((Get-VncFoundText $found -At (Get-Date -Format 't')))
    if ($ui.statusTip) { $ui.statusTip.Invoke(('Range {0}, port {1}. Press F5 to rescan.' -f $range, $ui.state.port)) }
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
        <Border x:Name="glow" CornerRadius="16" Margin="-6" Background="{TemplateBinding Tag}" Opacity="0" IsHitTestVisible="False"/>
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
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#9A9A9A"/><Setter TargetName="gt" Property="Foreground" Value="#9A9A9A"/></Trigger>
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
    <TextBlock Grid.Row="0" Text="Pick a computer. View only to watch, Interact to take control." FontSize="13" Foreground="#A0A0A0" Margin="0,0,0,12"/>
    <Border Grid.Row="1" CornerRadius="10" Background="#2E000000" BorderBrush="#1FFFFFFF" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Grid Margin="4,0" TextElement.FontSize="12" TextElement.FontWeight="SemiBold" TextElement.Foreground="#A0A0A0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/><ColumnDefinition Width="130"/></Grid.ColumnDefinitions>
          <TextBlock Grid.Column="1" Text="Name" VerticalAlignment="Center" Margin="4,0"/><TextBlock Grid.Column="2" Text="Address" VerticalAlignment="Center"/><TextBlock Grid.Column="3" Text="Seen" VerticalAlignment="Center"/>
        </Grid>
        <Rectangle Grid.Row="0" Height="1" VerticalAlignment="Bottom" Fill="#14FFFFFF"/>
        <ListBox x:Name="List" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" FontSize="14" Padding="0,4"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled" HorizontalContentAlignment="Stretch" AutomationProperties.Name="Computers">
          <ListBox.ItemTemplate><DataTemplate>
            <Grid ToolTip="{Binding tip}">
              <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/><ColumnDefinition Width="130"/></Grid.ColumnDefinitions>
              <Border Tag="star" Background="Transparent" Cursor="Hand" ToolTip="{Binding starTip}" AutomationProperties.Name="{Binding starName}">
                <TextBlock x:Name="star" Text="{Binding star}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="#F59E0B" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"/>
              </Border>
              <TextBlock Grid.Column="1" Text="{Binding nameText}" ToolTip="{Binding nameFull}" Foreground="{Binding nameFg}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="4,0,12,0"/>
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
      <Button x:Name="View" Grid.Column="0" Style="{StaticResource Green}" Content="View only" MinWidth="104" IsDefault="True" ToolTip="Watch this computer. Nothing you do reaches it. (Enter)"/>
      <Button x:Name="Interact" Grid.Column="1" Style="{StaticResource Blue}" Content="Interact" MinWidth="92" Margin="8,0,0,0" ToolTip="Take control of this computer's mouse and keyboard. Asks for the full password. (Ctrl+Enter)"/>
      <Button x:Name="Rescan" Grid.Column="3" Style="{StaticResource Chip}" Content="Rescan" MinWidth="84" ToolTip="Look for computers you can view on this network again (F5)"/>
      <Button x:Name="Add" Grid.Column="4" Style="{StaticResource Chip}" Content="Add..." MinWidth="72" Margin="8,0,0,0" ToolTip="Type a computer's address"/>
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
    if ($ui.allowedMode) { $m.Items.RemoveAt($m.Items.Count - 1) }   # v1.4.1: the admin's list can't be renamed, pinned or removed here
    else {
    $r = New-Object System.Windows.Controls.MenuItem; $r.Header = 'Rename...'; $r.InputGestureText = 'F2'; $r.IsEnabled = [bool]$s; $r.Add_Click({ $ui.rename.Invoke() }.GetNewClosure()); [void]$m.Items.Add($r)
    $p = New-Object System.Windows.Controls.MenuItem; $p.Header = $(if ($s -and $s.row.pinned) { 'Unpin' } else { 'Pin' }); $p.InputGestureText = 'Space'; $p.IsEnabled = [bool]$s; $p.Add_Click({ $ui.togglePin.Invoke() }.GetNewClosure()); [void]$m.Items.Add($p)
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    $d = New-Object System.Windows.Controls.MenuItem; $d.Header = 'Remove from favourites'; $d.InputGestureText = 'Del'
    $d.IsEnabled = [bool]($s -and $s.row.fav); if (-not $d.IsEnabled) { $d.ToolTip = 'Only saved computers can be removed'; [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($d, $true) }
    $d.Add_Click({ $ui.remove.Invoke() }.GetNewClosure()); [void]$m.Items.Add($d) }
    try { $m.Style = $ui.win.FindResource([System.Windows.Controls.ContextMenu]); $ms = $ui.win.FindResource([System.Windows.Controls.MenuItem])   # a code-built menu doesn't inherit the window's implicit styles
          foreach ($it in $m.Items) { if ($it -is [System.Windows.Controls.MenuItem]) { $it.Style = $ms } } } catch {}
    $m.Foreground = Brush '#FFFFFF'; $m.FontFamily = $global:UiFont; $m.FontSize = 14   # Kern Blocker: a popup doesn't inherit the window's text colour or font
    return $m
}
function global:Show-VncPicker($btn) {   # v1.4.1: only the admin's allowed computers; no network scan, no Add/Remove/Rescan
    if ($global:vncPicker -and $global:vncPicker.win.IsVisible) { $global:vncPicker.win.Activate() | Out-Null; return }
    Remove-VncTempLeftovers
    try { if ($global:VncViewerScan -and -not $global:VncViewerScan.path) { [void](Initialize-VncViewerScan -Retry) } } catch {}   # v1.4.6 (Squint 2): installed since the last look? search again on open
    $al = Read-VncAllowed
    $ui = @{ btn = $btn; allowedMode = $true; allowed = @($al.list); online = @{}; checking = $false; check = $null; timer = $null }
    try { $w = [Windows.Markup.XamlReader]::Parse($global:VncPickerXaml) }
    catch { Write-LauncherLog ('VNC picker window could not load: ' + $_.Exception.Message)
            [System.Windows.MessageBox]::Show("The computer finder couldn't open.`n`n" + $_.Exception.Message + "`n`nDetails are in launcher-error.log.", 'View Register', 'OK', 'Error') | Out-Null; return }
    $w.FontFamily = $global:UiFont
    $ui.win = $w
    $lv = $w.FindName('List'); $status = $w.FindName('Status'); $busyBar = $w.FindName('Busy'); $empty = $w.FindName('Empty'); $eT = $w.FindName('EmptyTitle'); $eB = $w.FindName('EmptyBody')
    $bView = $w.FindName('View'); $bInt = $w.FindName('Interact')
    foreach ($n in 'Rescan', 'Add', 'More') { $w.FindName($n).Visibility = 'Collapsed' }
    $ui.list = $lv
    try { [System.Windows.Automation.AutomationProperties]::SetLiveSetting($status, 'Polite') } catch {}
    $ui.setStatus = [Action[string]]{ param($s) $status.Text = $s
        try { $pe = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($status); if ($pe) { $pe.RaiseAutomationEvent('LiveRegionChanged') } } catch {} }.GetNewClosure()
    $ui.refresh = [Action]{
        $sel = $lv.SelectedItem; $lv.Items.Clear()
        foreach ($v in (Get-VncAllowedRows $ui.allowed $ui.online ([bool]$ui.checking))) { [void]$lv.Items.Add($v); if ($sel -and $sel.row.host -eq $v.row.host -and $sel.row.port -eq $v.row.port) { $lv.SelectedItem = $v } }
        if (-not $lv.SelectedItem -and $lv.Items.Count) { $lv.SelectedIndex = 0 }
        $has = [bool]$lv.SelectedItem; $bView.IsEnabled = $has; $bInt.IsEnabled = $has
        if ($lv.Items.Count -gt 0) { $empty.Visibility = 'Collapsed' }
        else { $eT.Text = 'No computers have been allowed yet. Ask your administrator.'
               $eB.Text = $(if ($al.state -eq 'unsafe') { "The allowed list on this PC isn't protected, so it is ignored. An administrator can save it again in Setup > Allowed computers (admin)..." } else { 'An administrator adds them in Setup > Allowed computers (admin)...' })
               $empty.Visibility = 'Visible' } }.GetNewClosure()
    $ui.startCheck = [Action]{   # F5 too: ~300 ms check of only the allowed computers
        if ($ui.checking -or @($ui.allowed).Count -eq 0) { return }
        $sync = [hashtable]::Synchronized(@{ cancel = $false; done = $false; found = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]) })
        $items = @(foreach ($e in $ui.allowed) { @{ key = ('{0}:{1}' -f $e.host, $e.port); host = $e.host; port = $e.port } })
        try { $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open(); $ps = [powershell]::Create(); $ps.Runspace = $rs
              [void]$ps.AddScript($global:VncAllowedCheckScript).AddArgument($items).AddArgument($global:VncTimeoutMs).AddArgument($sync)
              $ui.check = @{ sync = $sync; ps = $ps; rs = $rs; handle = $ps.BeginInvoke() } }
        catch { Write-LauncherLog ('VNC online check could not start: ' + $_.Exception.Message); return }
        $ui.online = @{}; $ui.checking = $true; $busyBar.IsIndeterminate = $true; $busyBar.Visibility = 'Visible'; $ui.refresh.Invoke(); $ui.timer.Start() }.GetNewClosure()
    $ui.stopCheck = [Action]{ $ui.timer.Stop(); $busyBar.IsIndeterminate = $false; $busyBar.Visibility = 'Hidden'; $ui.checking = $false
        if ($ui.check) { $ui.check.sync.cancel = $true; try { [void]$ui.check.ps.BeginStop($null, $null) } catch {}; [void]$global:VncDeadWorkers.Add(@{ ps = $ui.check.ps; rs = $ui.check.rs }); $ui.check = $null } }.GetNewClosure()
    $ui.timer = New-Object System.Windows.Threading.DispatcherTimer; $ui.timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $ui.timer.Add_Tick({ $c = $ui.check; if (-not $c) { $ui.timer.Stop(); return }
        $k = $null; while ($c.sync.found.TryDequeue([ref]$k)) { if (Test-VncBannerText ([string]$k.banner)) { $ui.online[[string]$k.key] = [string]$k.banner } }
        if ($c.sync.done -or (Get-VncWorkerFault $c.ps ([bool]$c.sync.done))) { $ui.stopCheck.Invoke(); Clear-VncDeadWorkers
            $n = @($ui.online.Keys).Count; $ui.refresh.Invoke(); $ui.setStatus.Invoke(('{0} of {1} online at {2}. Press F5 to check again.' -f $n, @($ui.allowed).Count, (Get-Date -Format 't'))) } }.GetNewClosure())
    $wrongPw = { $ui.setStatus.Invoke("Couldn't connect with the saved view-only password. Change it in Setup > View-only password (for viewing computers)...") }.GetNewClosure()
    $ui.go = [Action[bool]]{ param($vo) $s = $lv.SelectedItem; if (-not $s) { return }; [void](Start-VncViewer $ui.btn $s.row $vo $ui.win $wrongPw) }.GetNewClosure()
    $bView.Add_Click({ $ui.go.Invoke($true) }.GetNewClosure())
    $bInt.Add_Click({ $ui.go.Invoke($false) }.GetNewClosure())
    $lv.Add_SelectionChanged({ $has = [bool]$lv.SelectedItem; $bView.IsEnabled = $has; $bInt.IsEnabled = $has }.GetNewClosure())
    $lv.Add_MouseDoubleClick({ if ($lv.SelectedItem) { $ui.go.Invoke($true) } }.GetNewClosure())
    $lv.Add_PreviewMouseRightButtonUp({
        $o = $_.OriginalSource; while ($o -and -not ($o -is [System.Windows.Controls.ListBoxItem])) { if ($o -is [System.Windows.Media.Visual]) { $o = [System.Windows.Media.VisualTreeHelper]::GetParent($o) } else { $o = $null } }
        if ($o) { $o.IsSelected = $true; $m = New-VncRowMenu $ui $true; $m.PlacementTarget = $o; $m.IsOpen = $true; $_.Handled = $true } }.GetNewClosure())
    $w.Add_PreviewKeyDown({
        $k = $_.Key; $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        if ($k -eq 'Return' -and $ctrl) { $_.Handled = $true; $ui.go.Invoke($false) }
        elseif ($k -eq 'Return' -and $lv.IsKeyboardFocusWithin) { $_.Handled = $true; $ui.go.Invoke($true) }
        elseif ($k -eq 'F5') { $_.Handled = $true; $ui.startCheck.Invoke() }
        elseif ($k -eq 'Escape') { $_.Handled = $true; $w.Close() } }.GetNewClosure())
    $w.Add_Closed({ $ui.stopCheck.Invoke(); $global:vncPicker = $null
        $ct = New-Object System.Windows.Threading.DispatcherTimer; $ct.Interval = [TimeSpan]::FromSeconds(3)
        $ct.Add_Tick({ $ct.Stop(); if (-not $global:vncPicker) { Clear-VncDeadWorkers -All } }.GetNewClosure()); $ct.Start() }.GetNewClosure())
    $global:vncPicker = $ui
    $ui.refresh.Invoke()
    if ($al.bad -gt 0) { $ui.setStatus.Invoke(('{0} entries in the allowed list were not valid and are hidden.' -f $al.bad)) }
    $w.Show(); [void]$lv.Focus()
    $ui.startCheck.Invoke()
}

# ================= v1.4.0 unread email count on the Email tile (opt-in, per Windows user) =================
# Charles: off by default; Pulse (while unread > 0) by default once on; each Windows user signs in with their own @jartrek.net login; INBOX only.
# IMAP over implicit TLS to mail.jartrek.net:993. The only commands ever sent: AUTHENTICATE PLAIN (when the greeting lists AUTH=PLAIN) or LOGIN, STATUS INBOX (UNSEEN), LOGOUT.
# The certificate is checked by Windows itself (no custom validation callback; global .NET network settings untouched); a failure is an error.
# The password: a DPAPI CurrentUser blob (ConvertFrom-SecureString, no key) in %LOCALAPPDATA%\ButtonLauncher\email-count.dat,
# read back only as a SecureString; plaintext exists only as a char[]/byte[] inside the worker and is zeroed after the write.
# Squint: copy, flow, shared-PC warning, stop polling on a sign-in failure. Kern: badge, pulse, error ring, setup dialog.
$global:MailDomain   = '@jartrek.net'
$global:mail         = $null        # @{ set; state; ui }
$global:mailRun      = $null        # the one check in flight
$global:mailTimer    = $null        # the one poll timer
$global:mailFollow   = $null        # follow-up checks after the Email tile is clicked (60 s, 3 min)
$global:MailWorkerScript = $null
$global:MailDialogRes = $null
$global:MailDeadRuns  = New-Object System.Collections.ArrayList   # stopped checks waiting to end (BeginStop)
$global:MailLogDetails = @('address not allowed', 'server closed', 'no greeting', 'login has characters IMAP cannot send', 'sign-in refused', 'no continuation', 'server closed at sign-in', 'no sign-in reply',
                           'no STATUS reply', 'connect timed out', 'certificate or TLS check failed', 'TLS handshake failed', 'network error', 'timed out', 'no result', 'connection dropped', 'sign-in method not offered', 'internal error')   # the only words the log may carry
$global:MailLogSteps = @('connect', 'tls', 'greeting', 'login', 'status', 'logout', 'timeout', 'lost-result', 'worker-error')   # the failing step; fixed words only
$global:MailLogWords = @('OK', 'NO', 'BAD', 'BYE')   # the server reply's status word only, never the text after it
# CC L4: the worker gives up after 25 s; the UI cap in Start-MailRun is 45 s
$global:MailWorkerDeadlineSec = 25

# ---- IMAP protocol (pure; the worker runs these in a background runspace; tools/test-mail.ps1 drives them with a mock) ----
function global:ConvertTo-ImapQuotedBytes([char[]]$chars) {   # RFC 3501 quoted string as ASCII bytes ('\' and '"' escaped); $null = needs a literal; CR, LF, NUL throw
    $n = 0
    foreach ($ch in $chars) { $c = [int]$ch
        if ($c -eq 13 -or $c -eq 10 -or $c -eq 0) { throw 'CR, LF and NUL are not allowed.' }
        if ($c -lt 0x20 -or $c -gt 0x7E) { return $null }
        if ($c -eq 0x5C -or $c -eq 0x22) { $n += 2 } else { $n++ } }
    $b = New-Object byte[] ($n + 2); $i = 1; $b[0] = 0x22
    foreach ($ch in $chars) { $c = [int]$ch; if ($c -eq 0x5C -or $c -eq 0x22) { $b[$i] = 0x5C; $i++ }; $b[$i] = [byte]$c; $i++ }
    $b[$i] = 0x22
    return ,$b
}
function global:Get-ImapLoginBytes([string]$user, [char[]]$pass) {   # @{ cmd; literal }: the password is a quoted string, or a {n} literal (UTF-8) when it has non-ASCII characters
    $u = ConvertTo-ImapQuotedBytes $user.ToCharArray()
    if ($null -eq $u) { throw 'The email address must be plain ASCII.' }
    $q = ConvertTo-ImapQuotedBytes $pass
    $ms = New-Object IO.MemoryStream; $lit = $null
    try {
        $h = [Text.Encoding]::ASCII.GetBytes('a1 LOGIN '); $ms.Write($h, 0, $h.Length); $ms.Write($u, 0, $u.Length); $ms.WriteByte(0x20)
        if ($null -ne $q) { $ms.Write($q, 0, $q.Length); [Array]::Clear($q, 0, $q.Length) }
        else {
            $pb = [Text.Encoding]::UTF8.GetBytes($pass)
            $t = [Text.Encoding]::ASCII.GetBytes('{' + $pb.Length + '}'); $ms.Write($t, 0, $t.Length)
            $lit = New-Object byte[] ($pb.Length + 2); [Array]::Copy($pb, $lit, $pb.Length); $lit[$pb.Length] = 13; $lit[$pb.Length + 1] = 10
            [Array]::Clear($pb, 0, $pb.Length) }
        $ms.WriteByte(13); $ms.WriteByte(10)
        return @{ cmd = $ms.ToArray(); literal = $lit }
    } finally { $buf = $ms.GetBuffer(); [Array]::Clear($buf, 0, $buf.Length); $ms.Dispose() }
}
function global:Get-ImapPlainBytes([string]$user, [char[]]$pass, [string]$prefix) {   # SASL PLAIN (RFC 4616): ASCII prefix + base64(UTF-8 "\0user\0pass") + CRLF; NUL, CR, LF throw. Every buffer but the result is zeroed.
    for ($i = 0; $i -lt $user.Length; $i++) { $c = [int]$user[$i]; if ($c -eq 0 -or $c -eq 10 -or $c -eq 13) { throw 'CR, LF and NUL are not allowed.' } }   # LJ M28-I1: index loops, no extra copy of the password
    for ($i = 0; $i -lt $pass.Length; $i++) { $c = [int]$pass[$i]; if ($c -eq 0 -or $c -eq 10 -or $c -eq 13) { throw 'CR, LF and NUL are not allowed.' } }
    $ub = [Text.Encoding]::UTF8.GetBytes($user); $pb = $null; $raw = $null; $b64 = $null
    try {
        $pb = [Text.Encoding]::UTF8.GetBytes([char[]]$pass)
        $raw = New-Object byte[] (2 + $ub.Length + $pb.Length)
        [Array]::Copy($ub, 0, $raw, 1, $ub.Length); [Array]::Copy($pb, 0, $raw, 2 + $ub.Length, $pb.Length)
        $b64 = New-Object char[] (4 * [Math]::Ceiling($raw.Length / 3))
        [void][Convert]::ToBase64CharArray($raw, 0, $raw.Length, $b64, 0)
        $h = [Text.Encoding]::ASCII.GetBytes($prefix)
        $cmd = New-Object byte[] ($h.Length + $b64.Length + 2)
        [Array]::Copy($h, $cmd, $h.Length)
        for ($i = 0; $i -lt $b64.Length; $i++) { $cmd[$h.Length + $i] = [byte]$b64[$i] }
        $cmd[$cmd.Length - 2] = 13; $cmd[$cmd.Length - 1] = 10
        return ,$cmd
    } finally { foreach ($a in $pb, $raw) { if ($a) { [Array]::Clear($a, 0, $a.Length) } }; if ($b64) { [Array]::Clear($b64, 0, $b64.Length) } }
}
function global:Get-ImapCaps([string]$line) {   # '* OK [CAPABILITY ...] ...' or '* CAPABILITY ...' -> upper-case capability words; anything else -> empty
    if ($line -match '(?i)^\*\s+CAPABILITY\s+(.*)$') { $w = $Matches[1] } elseif ($line -match '(?i)^\*\s+(OK|PREAUTH)\s+\[CAPABILITY\s+([^\]]*)\]') { $w = $Matches[2] } else { return ,@() }
    return ,@(($w.Trim() -split '\s+') | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
}
function global:Read-ImapLine([scriptblock]$ReadLine) {   # one logical server line: a line ending in a {n} literal is joined with the next (a quoted or literal mailbox name in STATUS)
    $l = [string](& $ReadLine)
    for ($k = 0; $k -lt 4 -and $l -match '\{\d{1,6}\}$'; $k++) { $l = $l + ' ' + [string](& $ReadLine) }
    return $l
}
function global:Read-ImapStreamLine($stream, [IO.MemoryStream]$buf, $Deadline = $null, $Flags = $null) {   # bytes up to LF (CR trimmed), however the server split them across reads; CC L4: past the deadline -> throw (Flags.timedOut)
    $buf.SetLength(0)
    while ($true) { if ($null -ne $Deadline -and [DateTime]::UtcNow -ge $Deadline) { if ($Flags) { $Flags.timedOut = $true }; throw 'deadline' }
        $b = $stream.ReadByte(); if ($b -lt 0) { throw 'closed' }; if ($b -eq 10) { break }; if ($buf.Length -ge 16384) { throw 'line too long' }; $buf.WriteByte([byte]$b) }
    return ([Text.Encoding]::UTF8.GetString($buf.ToArray())).TrimEnd("`r")
}
function global:Get-ImapTagged([string]$line, [string]$tag) {   # 'OK' / 'NO' / 'BAD' for this tag's completion line, else $null
    if ($line -match ('(?i)^' + [regex]::Escape($tag) + ' (OK|NO|BAD)\b')) { return $Matches[1].ToUpperInvariant() }
    return $null
}
function global:Get-ImapStatusUnseen([string]$line) {   # '* STATUS INBOX (MESSAGES 9 UNSEEN 3)' -> 3; anything else -> -1
    if ($line -notmatch '(?i)^\*\s+STATUS\s+.*\(([^()]*)\)\s*$') { return -1 }
    if ($Matches[1] -notmatch '(?i)(?:^|\s)UNSEEN\s+([0-9]{1,9})(?:\s|$)') { return -1 }   # CC N3
    return [int]$Matches[1]
}
function global:Invoke-ImapSession([scriptblock]$ReadLine, [scriptblock]$Write, [string]$user, [char[]]$pass, $Flags = $null) {   # Flags.loginSent: M15-I1; Flags.step: the step a drop happened in
      # @{ kind = ok|auth|net|proto; unseen; detail; step; word }  (word = the server's status word only: OK/NO/BAD/BYE)
    $max = 200
    if ($Flags) { $Flags.step = 'greeting' }
    $g = Read-ImapLine $ReadLine
    if ($g -match '(?i)^\* BYE') { return @{ kind = 'net'; unseen = -1; detail = 'server closed'; step = 'greeting'; word = 'BYE' } }
    if ($g -notmatch '(?i)^\* (OK|PREAUTH)\b') { return @{ kind = 'proto'; unseen = -1; detail = 'no greeting'; step = 'greeting' } }
    if ($g -notmatch '(?i)^\* PREAUTH\b') {
        if ($Flags) { $Flags.step = 'login' }
        $caps = Get-ImapCaps $g   # from the greeting only: no extra command is ever sent
        if ($caps -contains 'LOGINDISABLED' -and -not ($caps -contains 'AUTH=PLAIN')) { return @{ kind = 'method'; stop = $true; unseen = -1; detail = 'sign-in method not offered'; step = 'login' } }   # LJ M28-I2: never send LOGIN the server refuses
        $lb = $null
        try {
            if ($caps -contains 'AUTH=PLAIN') {   # SASL PLAIN: the password is base64 of UTF-8, so quotes, backslashes, spaces, braces and non-ASCII all go through unchanged
                if ($caps -contains 'SASL-IR') { $lb = @{ cmd = (Get-ImapPlainBytes $user $pass 'a1 AUTHENTICATE PLAIN '); literal = $null } }
                else { $lb = @{ cmd = [Text.Encoding]::ASCII.GetBytes("a1 AUTHENTICATE PLAIN`r`n"); literal = (Get-ImapPlainBytes $user $pass '') } } }   # sent after the server's '+'
            else { $lb = Get-ImapLoginBytes $user $pass }
        } catch { return @{ kind = 'auth'; unseen = -1; detail = 'login has characters IMAP cannot send'; step = 'login' } }
        # M14-I4: once the sign-in is on the wire, anything but a definite 'a1 OK' (NO/BAD/BYE, no reply, a drop, a timeout) is a sign-in failure: polling stops, never a timer retry
        $t = $null
        try {
            try {
                if ($Flags) { $Flags.loginSent = $true }   # M15-I1: set before the sign-in goes out
                & $Write $lb.cmd
                if ($lb.literal) {   # CC N1: untagged lines may come first; wait for '+' or a tagged reply
                    $go = $false
                    for ($k = 0; $k -lt $max -and -not $go -and -not $t; $k++) { $cont = Read-ImapLine $ReadLine
                        if ($cont -match '^\+') { $go = $true } else { $t = Get-ImapTagged $cont 'a1'
                            if (-not $t -and $cont -match '(?i)^\* BYE') { return @{ kind = 'auth'; unclear = $true; unseen = -1; detail = 'server closed at sign-in'; step = 'login'; word = 'BYE' } } } }
                    if ($t) { return @{ kind = 'auth'; unseen = -1; detail = 'sign-in refused'; step = 'login'; word = $t } }
                    if (-not $go) { return @{ kind = 'auth'; unclear = $true; unseen = -1; detail = 'no continuation'; step = 'login' } }
                    & $Write $lb.literal }
            } finally { if ($lb) { [Array]::Clear($lb.cmd, 0, $lb.cmd.Length); if ($lb.literal) { [Array]::Clear($lb.literal, 0, $lb.literal.Length) }; $lb = $null } }
            for ($k = 0; $k -lt $max -and -not $t; $k++) { $l = Read-ImapLine $ReadLine
                $t = Get-ImapTagged $l 'a1'
                if (-not $t -and $l -match '(?i)^\* BYE') { return @{ kind = 'auth'; unclear = $true; unseen = -1; detail = 'server closed at sign-in'; step = 'login'; word = 'BYE' } } }
        } catch { return @{ kind = 'auth'; unclear = $true; unseen = -1; detail = 'no sign-in reply'; step = 'login' } }
        if ($t -ne 'OK') { if ($t) { return @{ kind = 'auth'; unseen = -1; detail = 'sign-in refused'; step = 'login'; word = $t } }; return @{ kind = 'auth'; unclear = $true; unseen = -1; detail = 'no sign-in reply'; step = 'login' } }
        if ($Flags) { $Flags.loginOk = $true }   # CC L1: sign-in confirmed; a later cap/loss is a network retry
    }
    if ($Flags) { $Flags.step = 'status' }
    & $Write ([Text.Encoding]::ASCII.GetBytes("a2 STATUS INBOX (UNSEEN)`r`n"))
    $n = -1; $t = $null
    for ($k = 0; $k -lt $max -and -not $t; $k++) { $l = Read-ImapLine $ReadLine   # untagged lines (CAPABILITY, OK, EXISTS, ...) in any order are skipped
        $t = Get-ImapTagged $l 'a2'
        if (-not $t) { $u = Get-ImapStatusUnseen $l; if ($u -ge 0) { $n = $u } elseif ($l -match '(?i)^\* BYE') { return @{ kind = 'net'; unseen = -1; detail = 'server closed'; step = 'status'; word = 'BYE' } } } }
    $res = if ($t -eq 'OK' -and $n -ge 0) { @{ kind = 'ok'; unseen = $n; detail = '' } } else { @{ kind = 'proto'; unseen = -1; detail = 'no STATUS reply'; step = 'status'; word = $t } }
    if ($Flags) { $Flags.step = 'logout' }
    try { & $Write ([Text.Encoding]::ASCII.GetBytes("a3 LOGOUT`r`n")); for ($k = 0; $k -lt 20; $k++) { if (Get-ImapTagged (Read-ImapLine $ReadLine) 'a3') { break } } } catch {}
    return $res
}
function global:Invoke-MailCheckWorker([string]$user, [System.Security.SecureString]$secure, $sync) {   # runs in the background runspace; one TLS connection, then closed
    $tcp = $null; $ssl = $null; $chars = $null; $bstr = [IntPtr]::Zero
    $deadline = [DateTime]::UtcNow.AddSeconds($global:MailWorkerDeadlineSec)   # CC L4: 25 s overall, checked before every byte read; under the UI's 45 s cap (Start-MailRun)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $sync.tcp = $tcp                                                            # lets the UI close it on exit or timeout
        $sync.step = 'connect'
        $ar = $tcp.BeginConnect('mail.jartrek.net', 993, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(10000)) { return @{ kind = 'net'; unseen = -1; detail = 'connect timed out'; step = 'connect' } }
        $tcp.EndConnect($ar)
        $sync.step = 'tls'
        $tcp.ReceiveTimeout = 10000; $tcp.SendTimeout = 10000
        $ns = $tcp.GetStream(); $ns.ReadTimeout = 10000; $ns.WriteTimeout = 10000
        $ssl = New-Object System.Net.Security.SslStream($ns, $false)                 # no validation callback: Windows checks the chain and the name
        $ssl.ReadTimeout = 10000; $ssl.WriteTimeout = 10000
        $proto = [System.Security.Authentication.SslProtocols]::Tls12
        try { if ([Environment]::OSVersion.Version.Build -ge 22000) { $proto = $proto -bor [System.Security.Authentication.SslProtocols]::Tls13 } } catch {}   # TLS 1.3 where Windows' client supports it
        try { $ssl.AuthenticateAsClient('mail.jartrek.net', $null, $proto, $true) }   # checkCertificateRevocation = true
        catch { $e = $_.Exception; while ($e -and -not ($e -is [System.Security.Authentication.AuthenticationException])) { $e = $e.InnerException }
                if ($e) { return @{ kind = 'cert'; unseen = -1; detail = 'certificate or TLS check failed'; step = 'tls' } }; return @{ kind = 'net'; unseen = -1; detail = 'TLS handshake failed'; step = 'tls' } }
        $buf = New-Object IO.MemoryStream
        $readLine = { Read-ImapStreamLine $ssl $buf $deadline $sync }.GetNewClosure()
        $write = { param([byte[]]$bytes) $ssl.Write($bytes, 0, $bytes.Length); $ssl.Flush() }.GetNewClosure()
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $chars = New-Object char[] $secure.Length
        [Runtime.InteropServices.Marshal]::Copy($bstr, $chars, 0, $chars.Length)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $bstr = [IntPtr]::Zero
        $res = Invoke-ImapSession $readLine $write $user $chars $sync
        if ($sync.timedOut) { $res.step = 'timeout'; $res.detail = 'timed out' }   # e.g. a sign-in cut off by the deadline stays an unclear sign-in failure
        return $res
    } catch {   # CC L1: connect/TLS failures are the network; a drop or EOF once TLS is up is the server (greeting or status)
        $st = [string]$sync.step; if ($st -cnotin $global:MailLogSteps) { $st = '' }
        $ex = $_.Exception; while ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
        $mine = $_.Exception.WasThrownFromThrowStatement -and ([string]$_.TargetObject -cin 'closed', 'deadline', 'line too long')
        $netx = ($ex -is [IO.IOException]) -or ($ex -is [System.Net.Sockets.SocketException]) -or ($ex -is [ObjectDisposedException]) -or ($ex -is [InvalidOperationException]) -or ($ex -is [TimeoutException]) -or ($ex -is [System.Security.Authentication.AuthenticationException]) -or ($ex -is [System.ComponentModel.Win32Exception])
        if (-not $sync.timedOut -and -not $mine -and -not $netx) {   # a Launcher bug, not the network: type and line only, never the message (it can hold user data)
            return @{ kind = 'internal'; unseen = -1; detail = 'internal error'; step = 'worker-error'; etype = $ex.GetType().FullName; eline = [int]$_.InvocationInfo.ScriptLineNumber; estep = $st } }
        if ($sync.timedOut) {   # CC L4: same split as the UI cap (Get-MailLostResult)
            if ($sync.loginSent -and -not $sync.loginOk) { return @{ kind = 'auth'; unclear = $true; unseen = -1; detail = 'timed out'; step = 'timeout' } }
            return @{ kind = 'net'; unseen = -1; detail = 'timed out'; step = 'timeout' } }
        if ($st -eq 'status' -or $st -eq 'greeting') { return @{ kind = 'proto'; unseen = -1; detail = 'connection dropped'; step = $st } }
        return @{ kind = 'net'; unseen = -1; detail = 'network error'; step = $st } }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($chars) { [Array]::Clear($chars, 0, $chars.Length) }
        try { if ($ssl) { $ssl.Dispose() } } catch {}
        try { if ($tcp) { $tcp.Close() } } catch {}
        $sync.tcp = $null }
}
# the worker's last line: anything that escapes Invoke-MailCheckWorker comes back as a worker-error result (type, line, step; never the message)
$global:MailWorkerTail = 'try { Invoke-MailCheckWorker $args[0] $args[1] $args[2] } catch { $e = $_.Exception; while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }; @{ kind = ''internal''; unseen = -1; detail = ''internal error''; step = ''worker-error''; etype = $e.GetType().FullName; eline = [int]$_.InvocationInfo.ScriptLineNumber; estep = [string]$args[2].step } }'
function global:Get-MailWorkerScript {   # the worker's functions, copied by name into the runspace (no file, no command line)
    if (-not $global:MailWorkerScript) {
        $parts = foreach ($n in 'ConvertTo-ImapQuotedBytes', 'Get-ImapLoginBytes', 'Get-ImapPlainBytes', 'Get-ImapCaps', 'Read-ImapLine', 'Read-ImapStreamLine', 'Get-ImapTagged', 'Get-ImapStatusUnseen', 'Invoke-ImapSession', 'Invoke-MailCheckWorker') {
            'function global:{0} {{ {1} }}' -f $n, (Get-Item -LiteralPath ('function:' + $n)).ScriptBlock.ToString() }
        $parts = @(("`$global:MailLogSteps = @('" + ($global:MailLogSteps -join "', '") + "')"), ("`$global:MailWorkerDeadlineSec = $([int]$global:MailWorkerDeadlineSec)")) + @($parts)   # parentheses: ',' binds tighter than '+'
        $global:MailWorkerScript = ($parts -join "`n") + "`n" + $global:MailWorkerTail }
    return $global:MailWorkerScript
}

# ---- state machine (pure) ----
function global:New-MailState([int]$epoch = 0) { @{ phase = 'checking'; count = -1; lastOk = $null; fails = 0; failSince = $null; failAt = $null; stopped = $false; epoch = $epoch } }
function global:Get-MailFreshState($old) { New-MailState ([int]$old.epoch + 1) }   # CC M1: Save / turn off: the epoch only goes up, so a check started earlier is always dropped
function global:Update-MailState($s, $r, [datetime]$now) {   # one check result -> state; @{ grew; ignored }. Squint: auth stops polling; offline after 2 tried polls; sleep never counts.
    $out = @{ grew = $false; ignored = $false }
    if ($null -ne $r.epoch -and [int]$r.epoch -ne [int]$s.epoch) { $out.ignored = $true; return $out }   # started before a sleep: not a tried poll
    $k = [string]$r.kind; if ($r.stop -and $k -ne 'ok' -and $k -ne 'method') { $k = 'auth' }   # an internal error after the sign-in may have gone out stops like a sign-in failure
    switch ($k) {
        'ok' {
            $prev = [Math]::Max(0, [int]$s.count); $n = [Math]::Max(0, [int]$r.unseen)
            $out.grew = $n -gt $prev
            $s.count = $n; $s.lastOk = $now; $s.fails = 0; $s.failSince = $null; $s.failAt = $null; $s.phase = 'ok'; $s.stopped = $false }
        'method' { $s.phase = 'methodfail'; $s.stopped = $true; $s.fails = 0; $s.failSince = $null }   # Squint/LJ M29-I1: the server offers no sign-in Launcher can use: stopped (no timer retry; Check email now tries again), not a sign-in failure
        'auth' { $s.phase = 'authfail'; $s.authUnclear = [bool]$r.unclear; $s.stopped = $true; $s.fails = 0; $s.failSince = $null }   # unclear: no definite NO/BAD from the server
        default {
            $s.fails++; $s.failAt = $now; if ($s.fails -eq 1) { $s.failSince = $now }
            $s.phase = if ($s.fails -ge 2) { 'offline' } else { 'retry' } }
    }
    return $out
}
function global:Get-MailLostResult($sync, [string]$why) {   # M15-I1: a check cut off by the 45 s cap (or lost) after LOGIN went out is an unclear sign-in failure: stop, never a timer retry
    if ($sync -and $sync.loginSent -and -not $sync.loginOk) {   # CC L1: not after a tagged OK
    return @{ kind = 'auth'; unclear = $true; unseen = -1; detail = $why; step = $(if ($why -eq 'no result') { 'lost-result' } else { 'timeout' }) } }
    if ($why -eq 'no result') { return @{ kind = 'proto'; unseen = -1; detail = $why; step = 'lost-result' } }   # Launcher lost its own result: not the network
    return @{ kind = 'net'; unseen = -1; detail = $why; step = 'timeout' }
}
function global:Step-MailResume($s) { $s.epoch = [int]$s.epoch + 1 }   # a check that started before sleep is ignored when it ends
function global:Get-MailNextDelaySec($s, $minutes = 3) {   # -1 = stopped (sign-in failed: never retried on a timer); the saved interval, network errors back off to 6 -> 12 -> 15 min (never sooner than the interval)
    if ($s.stopped) { return -1 }
    $base = 60 * (Get-MailInterval $minutes)
    switch ([int]$s.fails) { 0 { return $base } 1 { return $base } 2 { return [Math]::Max($base, 360) } 3 { return [Math]::Max($base, 720) } default { return [Math]::Max($base, 900) } }
}
function global:Get-MailBadgeText([int]$n) { if ($n -le 0) { '' } elseif ($n -ge 100) { '99+' } else { [string]$n } }
function global:Get-MailBadgeWidth([string]$t) { switch ($t.Length) { 0 { 18 } 1 { 18 } 2 { 24 } default { 30 } } }   # Kern: fixed width per bucket
function global:Get-MailBadgeLeft([double]$ipx, [double]$w, [double]$iconGap) {   # Windows capture fix: '99+' (30 px at icon right - 8) ran 12 px into the label. Keep icon right - 8 when it fits, else pin the right edge 4 px short of the label
    return [Math]::Min($ipx - 8, $ipx + $iconGap - 4 - $w)
}
function global:Get-MailBadgeTop([double]$w) { if ($w -gt 18) { -10 } else { -6 } }   # v1.4.9 (Kern r3 Minor 2): wider badges (42, 99+) sit 4 px higher so more of the envelope shows
function global:Test-MailShowBadge($s) { ($s.phase -eq 'ok' -or $s.phase -eq 'retry') -and [int]$s.count -gt 0 }
function global:Test-MailShowRing($s) { $s.phase -eq 'authfail' -or $s.phase -eq 'methodfail' -or $s.phase -eq 'offline' }   # the count is hidden whenever the ring shows
function global:Get-MailMotion([string]$style, [bool]$animOn) { if (-not $animOn) { return 'badge' }; if ($style -ceq 'badge') { return 'badge' }; return 'pulse' }   # Charles 1:58 PM: Pulse (default) or Just show the number
function global:Test-MailPulseOn($s, [string]$style, [bool]$animOn, [bool]$locked, [bool]$visible) {   # Charles: pulse the whole time unread > 0; never in edit mode, on a hidden panel, or with animations off
    (Test-MailShowBadge $s) -and (Get-MailMotion $style $animOn) -eq 'pulse' -and $locked -and $visible }
function global:Format-MailTime($t, [datetime]$now) {   # Squint: '9:41 AM' today, 'Oct 28, 4:10 PM' otherwise
    if ($null -eq $t) { return '' }
    $c = [Globalization.CultureInfo]::GetCultureInfo('en-US'); $d = [datetime]$t
    if ($d.Date -eq $now.Date) { return $d.ToString('h:mm tt', $c) }
    return $d.ToString('MMM d, h:mm tt', $c)
}
function global:Get-MailCountText([int]$n) { if ($n -le 0) { 'No unread email.' } elseif ($n -eq 1) { '1 unread email in Inbox.' } else { "$n unread emails in Inbox." } }
function global:Get-MailTipLine($s, [datetime]$now) {   # Squint's tooltip table (second line, under 'Open email')
    switch ($s.phase) {
        'authfail' { if ($s.authUnclear) { return 'Email count stopped: couldn''t confirm sign-in. Check the connection, then choose Check email now. If you changed your webmail password, update it in Setup > Unread email count...' }
                     return 'Email count stopped: can''t sign in. If you changed your webmail password, update it in Setup > Unread email count...' }
        'methodfail' { return 'Email count stopped: the mail server won''t accept Launcher''s sign-in. Tell your IT contact.' }
        'offline'  { return ('Can''t reach email since {0}. The count is hidden until it reconnects.' -f (Format-MailTime $s.failSince $now)) }
        'retry'    { if ([int]$s.count -ge 0) { return ('{0} Couldn''t check at {1}, trying again.' -f (Get-MailCountText $s.count), (Format-MailTime $s.failAt $now)) }
                     return ('Couldn''t check email at {0}, trying again.' -f (Format-MailTime $s.failAt $now)) }
        'ok'       { return ('{0} Checked {1}.' -f (Get-MailCountText $s.count), (Format-MailTime $s.lastOk $now)) }
        default    { return 'Checking email...' }
    }
}
function global:Get-MailMenuLine($s, [datetime]$now) {   # Squint: the first (disabled) line of the Email tile's right-click menu
    switch ($s.phase) {
        'authfail' { if ($s.authUnclear) { return 'Email count: couldn''t confirm sign-in' }; return 'Email count: can''t sign in' }
        'methodfail' { return 'Email count: stopped' }
        'offline'  { return ('Email count: offline since {0}' -f (Format-MailTime $s.failSince $now)) }
        'retry'    { if (-not $s.lastOk) { return ('Email count: couldn''t check at {0}, trying again' -f (Format-MailTime $s.failAt $now)) }
                     return ('Email count: {0}, checked {1}' -f $(if ([int]$s.count -le 0) { 'no unread' } else { "$([int]$s.count) unread" }), (Format-MailTime $s.lastOk $now)) }
        'ok'       { return ('Email count: {0}, checked {1}' -f $(if ([int]$s.count -le 0) { 'no unread' } else { "$([int]$s.count) unread" }), (Format-MailTime $s.lastOk $now)) }
        default    { return 'Email count: checking...' }
    }
}
function global:Get-MailAccessName([string]$base, $s) {   # Squint: 'Email, 3 unread'; error states in the name too
    switch ($s.phase) {
        'authfail' { if ($s.authUnclear) { return "$base, email count couldn't confirm sign-in" }; return "$base, email count can't sign in" }
        'methodfail' { return "$base, email count stopped" }
        'offline'  { return "$base, email count offline" }
        default { if ([int]$s.count -gt 0) { return "$base, $([int]$s.count) unread" }; if ([int]$s.count -eq 0) { return "$base, no unread email" }; return $base }
    }
}
function global:Get-MailTestText($r) {   # Squint's Test results: @{ kind = ok|auth|unclear|net|cert|proto|lost|internal|method; text }
    switch ([string]$r.kind) {
        'ok'   { $n = [int]$r.unseen; $t = if ($n -le 0) { 'Signed in. No unread email in Inbox.' } elseif ($n -eq 1) { 'Signed in. 1 unread email in Inbox.' } else { "Signed in. $n unread emails in Inbox." }; return @{ kind = 'ok'; text = $t } }
        'auth' { if ($r.unclear) { return @{ kind = 'unclear'; text = 'Couldn''t confirm sign-in. Check this PC is online, then press Test again.' } }
                 return @{ kind = 'auth'; text = 'Couldn''t sign in. Check the email address and password, the same ones you use for webmail.' } }
        'net'  { return @{ kind = 'net'; text = 'Can''t reach the mail server. Check this PC is online, then press Test again.' } }   # only real connect/network failures
        'cert' { return @{ kind = 'cert'; text = 'Launcher couldn''t confirm this is the real mail server, so it didn''t send your password. Check the PC''s date and time, then press Test again. If it keeps happening, tell your IT contact.' } }   # true: the worker fails the TLS check before the password is even decoded
        'internal' { return @{ kind = 'internal'; text = 'Something went wrong inside Launcher during the test. It isn''t your password or the mail server. Tell your IT contact.' } }
        'method'   { return @{ kind = 'method'; text = 'The mail server won''t accept Launcher''s way of signing in, so your password wasn''t checked. Tell your IT contact.' } }
        default { if ([string]$r.step -ceq 'lost-result') { return @{ kind = 'lost'; text = 'The test stopped before it finished. This is a Launcher problem, not your password. Press Test again; if it keeps happening, tell your IT contact.' } }   # Launcher lost its own result (polling still retries it as proto)
                  return @{ kind = 'proto'; text = 'The mail server answered in a way Launcher didn''t expect. Press Test again; if it keeps happening, tell your IT contact.' } }
    }
}
function global:Format-MailLogLine($r) {   # fixed words only: never the address, the password or server text
    $k = [string]$r.kind; if ($k -notin 'ok', 'auth', 'net', 'cert', 'proto', 'method') { $k = 'error' }
    $d = [string]$r.detail; if ($d -cnotin $global:MailLogDetails) { $d = '' }
    $st = [string]$r.step; if ($st -cnotin $global:MailLogSteps) { $st = '' }
    $w = [string]$r.word; if ($w -cnotin $global:MailLogWords) { $w = '' }
    $x = ''
    if ($st -ceq 'worker-error') {   # type: [A-Za-z0-9.] only; line: a number; at: a known step
        $ty = [string]$r.etype; if ($ty -cnotmatch '^[A-Za-z0-9.]{1,128}$') { $ty = 'unknown' }
        $ln = 0; try { $ln = [Math]::Max(0, [Math]::Min(999999, [int]$r.eline)) } catch {}
        $at = [string]$r.estep; if ($at -cnotin $global:MailLogSteps) { $at = '' }
        $x = " type=$ty line=$ln" + $(if ($at) { " at=$at" } else { '' }) }
    return ('email count: {0}{1}{2}{3}{4}' -f $k, $(if ($d) { " ($d)" } else { '' }), $(if ($st) { " step=$st" } else { '' }), $x, $(if ($w) { " reply=$w" } else { '' }))
}
function global:Write-MailLogLine($r, [string]$from = 'check') {   # background check and Test: the same fixed-word line, never the address, the password or server text
    if ([string]$r.kind -eq 'ok') { return }
    $f = if ($from -ceq 'test') { 'test' } else { 'check' }
    try { Add-Content -LiteralPath $global:logPath -Value ('{0}  {1} [{2}]' -f (Get-Date -Format s), (Format-MailLogLine $r), $f) -Encoding UTF8 } catch {}
}
function global:Get-MailAddress([string]$text) {   # v1.4.0 laptop test: Charles types the full address; only trimmed, never completed for him
    return ([string]$text).Trim()
}
function global:Test-MailAddress([string]$a) {   # untrusted: <= 254, one '@', no whitespace/control/quotes/backslash or IMAP specials ( ) { } % * ] ; plain ASCII
    if ([string]::IsNullOrEmpty($a) -or $a.Length -gt 254) { return $false }
    return ($a -cmatch '^[A-Za-z0-9._+-]{1,64}@[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})+\z' -and ($a.Split('@').Count -eq 2))
}
function global:Get-MailAddressProblem([string]$a) {   # $null = OK; Squint: an empty name before '@' gets its own words
    if (Test-MailAddress $a) { return $null }
    if (([string]$a).Trim().StartsWith('@')) { return 'Type your name before @jartrek.net.' }
    return 'Type your full email address, like name@jartrek.net.'
}
function global:ConvertTo-MailFullAddress([string]$a) {   # migration: a saved user part only ('cc') becomes 'cc@jartrek.net'
    $t = ([string]$a).Trim(); if ($t -cmatch '^[A-Za-z0-9._+-]{1,64}\z') { return $t + $global:MailDomain }; return $t
}
$global:MailIntervals = @(2, 3, 5, 10, 15, 30)   # minutes offered in Setup; the saved value is clamped by Get-MailInterval
function global:Get-MailInterval($v) {   # minutes: numeric 2..60 kept (hand-edited values too), above 60 -> 60, under 2 / missing / not a number -> 3
    $n = 0.0
    if ($null -eq $v -or $v -is [bool]) { return 3 }
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal] -or $v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte]) { $n = [double]$v }   # CC: numbers as they are (no string round-trip that overflows [double]::MaxValue)
    elseif (-not [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return 3 }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return 3 }
    $n = [Math]::Floor($n); if ($n -lt 2) { return 3 }; if ($n -gt 60) { return 60 }; return [int]$n
}
function global:Test-MailTile($btn) { (Get-ButtonType $btn) -eq 'website' -and ([string]$btn.target).Trim() -match '^(?i)mailto:' }   # the Email tile, by what it opens

# ---- per-Windows-user settings and login (never in buttons.json, the log, tooltips or a command line) ----
function global:Get-MailDir { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ButtonLauncher' }
function global:Get-MailSettingsPath { Join-Path (Get-MailDir) 'email-count.json' }
function global:Get-MailSecretPath { Join-Path (Get-MailDir) 'email-count.dat' }
function global:ConvertTo-MailSettings($o) {   # only these four keys survive, validated (never the password: that is only in the DPAPI file)
    $style = if ([string]$o.style -ceq 'badge') { 'badge' } else { 'pulse' }   # Charles: Pulse by default; old 'flash' and 'pulse' -> pulse, 'badge' -> Just show the number
    $addr = ConvertTo-MailFullAddress ([string]$o.address); if (-not (Test-MailAddress $addr)) { $addr = '' }
    return @{ enabled = ([bool]$o.enabled -and [bool]$addr); address = $addr; style = $style; interval = (Get-MailInterval $o.interval) }
}
function global:Get-MailSettingsJson($set) { $c = ConvertTo-MailSettings $set; return ([pscustomobject]@{ enabled = $c.enabled; address = $c.address; style = $c.style; interval = $c.interval } | ConvertTo-Json -Compress) }
function global:Read-MailSettings {
    $p = Get-MailSettingsPath
    try { if (Test-Path -LiteralPath $p) { return (ConvertTo-MailSettings (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)) } } catch {}
    return (ConvertTo-MailSettings @{ enabled = $false })
}
function global:Write-MailFile([string]$p, [string]$text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $p))
    $tmp = $p + '.tmp'; [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
}
function global:Save-MailSettings($set) { Write-MailFile (Get-MailSettingsPath) (Get-MailSettingsJson $set) }
function global:Save-MailSecret([System.Security.SecureString]$ss) { Write-MailFile (Get-MailSecretPath) (ConvertFrom-SecureString -SecureString $ss) }   # DPAPI CurrentUser (no -Key)
function global:Read-MailSecret {   # SecureString or $null
    $p = Get-MailSecretPath; if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertTo-SecureString -String ([IO.File]::ReadAllText($p).Trim())) } catch { return $null }
}
function global:Remove-MailLogin { foreach ($p in (Get-MailSecretPath), (Get-MailSettingsPath), ((Get-MailSecretPath) + '.tmp'), ((Get-MailSettingsPath) + '.tmp')) {   # M14-I3: crash leftovers too
    try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } } catch {} } }

# ---- one background check at a time (never on the UI thread) ----
function global:Start-MailRun([string]$user, [System.Security.SecureString]$secure, [scriptblock]$OnDone) {   # $false when a check is already running
    if ($global:mailRun) { return $false }
    if (-not (Test-MailAddress $user)) {   # LJ M21-I2: fail closed. Nothing is sent; the caller gets a sign-in failure (never a retry loop)
        if ($secure) { $secure.Dispose() }
        if ($OnDone) { & $OnDone @{ kind = 'auth'; unseen = -1; detail = 'address not allowed'; epoch = $(if ($global:mail) { $global:mail.state.epoch } else { 0 }) } }
        return $true }
    Clear-MailDeadRuns
    $sync = [hashtable]::Synchronized(@{ tcp = $null; loginSent = $false; loginOk = $false; step = 'connect'; timedOut = $false })
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript((Get-MailWorkerScript)).AddArgument($user).AddArgument($secure).AddArgument($sync)
    $epoch = if ($global:mail) { [int]$global:mail.state.epoch } else { 0 }
    $run = @{ ps = $ps; rs = $rs; sync = $sync; secure = $secure; start = [DateTime]::UtcNow; done = $OnDone; epoch = $epoch; timer = $null; handle = $null }
    $run.handle = $ps.BeginInvoke()
    $global:mailRun = $run
    $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(250)   # only while a check runs
    $t.Add_Tick({
        $r = $null
        if ($run.handle.IsCompleted) { $r = Get-MailRunResult $run }
        elseif (([DateTime]::UtcNow - $run.start).TotalSeconds -ge 45) { Stop-MailRunObjects $run; $r = Get-MailLostResult $run.sync 'timed out' }   # LJ M16-I1: close the socket first, then read the flags
        else { return }
        $t.Stop(); Stop-MailRunObjects $run
        if (-not ($r -is [hashtable])) { $r = Get-MailLostResult $run.sync 'no result' }
        if ([string]$r.kind -eq 'internal' -and $run.sync.loginSent -and -not $run.sync.loginOk) { $r.stop = $true }   # M15-I1: the sign-in may have gone out; never a timer retry
        $r.epoch = $run.epoch
        if ($run.done) { & $run.done $r } }.GetNewClosure())
    $run.timer = $t; $t.Start()
    return $true
}
function global:Get-MailWorkerError($err, $sync) {   # an ErrorRecord or exception from the worker -> worker-error result: type (allowlisted characters) and line only, never the message
    $ex = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { $err }
    while ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }
    $line = 0
    if ($ex -is [System.Management.Automation.ParseException] -and $ex.Errors -and $ex.Errors.Count -gt 0) { $line = [int]$ex.Errors[0].Extent.StartLineNumber }
    elseif ($err -is [System.Management.Automation.ErrorRecord] -and $err.InvocationInfo) { $line = [int]$err.InvocationInfo.ScriptLineNumber }
    elseif ($ex -is [System.Management.Automation.IContainsErrorRecord] -and $ex.ErrorRecord.InvocationInfo) { $line = [int]$ex.ErrorRecord.InvocationInfo.ScriptLineNumber }
    $st = if ($sync) { [string]$sync.step } else { '' }
    return @{ kind = 'internal'; unseen = -1; detail = 'internal error'; step = 'worker-error'; etype = $(if ($ex) { $ex.GetType().FullName } else { '' }); eline = $line; estep = $st }
}
function global:Get-MailRunResult($run) {   # a finished worker -> its result hashtable; a worker that threw -> worker-error; a worker that gave nothing -> $null (lost)
    $o = $null
    try { $o = $run.ps.EndInvoke($run.handle) } catch { return (Get-MailWorkerError $_ $run.sync) }
    if ($o -and $o.Count -gt 0) { $x = $o[$o.Count - 1]; if ($x -is [hashtable]) { return [hashtable]$x } }   # -is sees through the PSObject wrapper; never .BaseObject (on a hashtable it reads the key 'BaseObject' = $null)
    try { if ($run.ps.Streams.Error.Count -gt 0) { return (Get-MailWorkerError $run.ps.Streams.Error[$run.ps.Streams.Error.Count - 1] $run.sync) } } catch {}
    return $null
}
function global:Stop-MailRunObjects($run) {   # closes the socket first so a stuck read ends at once, then frees the runspace
    if (-not $run) { return }
    try { if ($run.timer) { $run.timer.Stop() } } catch {}
    try { if ($run.sync.tcp) { $run.sync.tcp.Close() } } catch {}
    if ($global:mailRun -eq $run) { $global:mailRun = $null }
    if (-not $run.handle.IsCompleted) { try { [void]$run.ps.BeginStop($null, $null) } catch {}; [void]$global:MailDeadRuns.Add($run); return }   # CC L1: never block the UI thread
    try { $run.ps.Dispose() } catch {}; try { $run.rs.Dispose() } catch {}
    try { if ($run.secure) { $run.secure.Dispose() } } catch {}
}
function global:Clear-MailDeadRuns {   # frees stopped checks once they have really ended (at the next check, or on exit)
    foreach ($r in @($global:MailDeadRuns)) { if ($r.handle.IsCompleted) { try { $r.ps.Dispose() } catch {}; try { $r.rs.Dispose() } catch {}; try { if ($r.secure) { $r.secure.Dispose() } } catch {}; $global:MailDeadRuns.Remove($r) } }
}

# ---- controller ----
function global:Initialize-Mail { $global:mail = @{ set = (Read-MailSettings); state = (New-MailState); ui = (New-Object System.Collections.ArrayList) } }
function global:Set-MailTimer([double]$sec) {   # (re)arms the one poll timer; -1 stops it
    if (-not $global:mailTimer) { $global:mailTimer = New-Object System.Windows.Threading.DispatcherTimer
        $global:mailTimer.Add_Tick({ $global:mailTimer.Stop(); Invoke-MailPoll $false }) }
    $global:mailTimer.Stop()
    if ($sec -lt 0) { return }
    $global:mailTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $sec)); $global:mailTimer.Start()
}
function global:Stop-MailFollow { if ($global:mailFollow) { foreach ($t in @($global:mailFollow)) { try { $t.Stop() } catch {} } }; $global:mailFollow = $null }
function global:Start-MailPolling([int]$firstSec = 5) {   # startup, and after Setup saves; nothing at all while off
    Stop-MailFollow; Set-MailTimer -1
    if ($global:mail -and $global:mail.set.enabled -and -not $global:mail.state.stopped) { Set-MailTimer $firstSec }
    Update-MailUi $false
}
function global:Invoke-MailPoll([bool]$byUser) {   # timer, follow-ups and wake: skipped after a sign-in failure. Check email now: always one try.
    $m = $global:mail; if (-not $m -or -not $m.set.enabled) { return }
    if ($m.state.stopped -and -not $byUser) { return }
    if ($global:mailRun) { if (-not $byUser) { Set-MailTimer 15 }; return }
    $ss = Read-MailSecret
    if (-not $ss) { [void](Update-MailState $m.state @{ kind = 'auth'; epoch = $m.state.epoch } (Get-Date)); Update-MailUi $false; return }
    if (-not (Start-MailRun $m.set.address $ss { param($r) Complete-MailPoll $r })) { $ss.Dispose() }
}
function global:Complete-MailPoll($r) {
    $m = $global:mail; if (-not $m -or -not $m.set.enabled) { return }
    $out = Update-MailState $m.state $r (Get-Date)
    if ($out.ignored) { if (-not $m.state.stopped) { Set-MailTimer 10 }; return }
    Write-MailLogLine $r 'check'
    Update-MailUi $out.grew
    Set-MailTimer (Get-MailNextDelaySec $m.state $m.set.interval)
}
function global:Start-MailFollowUp {   # Squint: check again 60 s and 3 min after the Email tile opens email
    $m = $global:mail; if (-not $m -or -not $m.set.enabled -or $m.state.stopped) { return }
    Stop-MailFollow; $list = @()
    foreach ($sec in 60, 180) { $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds($sec)
        $t.Add_Tick({ $t.Stop(); Invoke-MailPoll $false }.GetNewClosure()); $t.Start(); $list += $t }
    $global:mailFollow = $list
}
function global:Resume-Mail {   # wake from sleep: the check in flight (if any) doesn't count; check once ~10 s after wake
    $m = $global:mail; if (-not $m) { return }
    Step-MailResume $m.state
    if ($m.set.enabled -and -not $m.state.stopped) { Set-MailTimer 10 }
}
function global:Stop-Mail { Stop-MailFollow; try { Set-MailTimer -1 } catch {}; Stop-MailRunObjects $global:mailRun }   # app exit / turn off
function global:Disable-Mail {   # Turn off: forget the login on this PC and clear the badge at once
    Stop-Mail; Remove-MailLogin
    $global:mail.set = ConvertTo-MailSettings @{ enabled = $false }; $global:mail.state = Get-MailFreshState $global:mail.state   # CC M1
    Update-MailUi $false
}

# ---- tile visuals (Kern D2): badge, error ring, pulse glow overlay; opacity only ----
function global:Test-MailAnimOn { try { return [bool][System.Windows.SystemParameters]::ClientAreaAnimation } catch { return $true } }   # re-read on every update
function global:New-MailKeyAnim([double[]]$ms, [double[]]$val, [bool]$sine) {
    $k = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    for ($i = 0; $i -lt $ms.Count; $i++) {
        $kt = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($ms[$i]))
        if ($sine) { $f = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame $val[$i], $kt; $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $f.EasingFunction = $e }
        else { $f = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame $val[$i], $kt }
        [void]$k.KeyFrames.Add($f) }
    return $k
}
function global:Get-HexLuminance([string]$hex) {   # WCAG relative luminance of a tile colour: '#RGB', '#ARGB', '#RRGGBB', '#AARRGGBB' or a named colour ('White'), as WPF reads it; alpha ignored; unreadable -> 0 (dark-label look)
    $t = ([string]$hex).Trim(); $h = $null
    if ($t -match '^#([0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') {
        $h = $Matches[1]; if ($h.Length -le 4) { $h = -join ($h.ToCharArray() | ForEach-Object { "$_$_" }) }; if ($h.Length -eq 8) { $h = $h.Substring(2) } }
    elseif ($t -match '^[A-Za-z]{3,30}$') {   # CC LOW-D: named colours, resolved like the tile does (WPF ColorConverter; System.Drawing's known colours have the same names and values)
        try { $c = [System.Windows.Media.ColorConverter]::ConvertFromString($t); $h = '{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B } catch {
            try { $c = [System.Drawing.Color]::FromName($t); if ($c.IsKnownColor) { $h = '{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B } } catch {} } }
    if (-not $h) { return 0.0 }
    $l = foreach ($i in 0, 2, 4) { $v = [Convert]::ToInt32($h.Substring($i, 2), 16) / 255.0; if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow(($v + 0.055) / 1.055, 2.4) } }
    return 0.2126 * $l[0] + 0.7152 * $l[1] + 0.0722 * $l[2]
}
function global:Get-MailPulseHint([bool]$animOn) { if ($animOn) { 'The pulse stops once every email is read.' } else { 'Windows animations are off, so Launcher just shows the number.' } }   # Squint: the hint under Pulse
function global:Get-MailPulseLook([string]$labelHex) {   # Charles 2:17 PM 'Red pulse at 3.5 seconds': the tile fades to red and back. Dark label (default Email #111111): coral #F87A6F -> #E5675E (>= 4.5:1 every frame).
    # Kern: a light label (luminance > 0.5, a user-recoloured dark tile) gets a deep red #B3261E -> #A1221B instead, so the white label stays >= 4.5:1 (7.1+:1 at the peak)
    if ((Get-HexLuminance $labelHex) -gt 0.5) { return @{ top = '#B3261E'; bottom = '#A1221B'; peak = 1.0 } }
    return @{ top = '#F87A6F'; bottom = '#E5675E'; peak = 1.0 }
}
function global:Add-MailOverlay($tile, $wrap, $g, $c, [string]$ir, $btn) {   # Email tile only: built collapsed; nothing runs until the count is on
    if (-not $global:mail) { return }
    $ov = New-Object System.Windows.Controls.Border; $ov.IsHitTestVisible = $false; $ov.Opacity = 0; $ov.CornerRadius = $ir
    $look = Get-MailPulseLook ([string](Get-TileColors $btn).fg)
    $ov.Background = New-VGrad $look.top $look.bottom   # frozen red gradient under the icon and label; only its Opacity animates (0 = the tile's own colour, 1 = red)
    $g.Children.Insert([Math]::Max(0, $g.Children.IndexOf($c.el)), $ov)          # under the icon and label
    $cv = New-Object System.Windows.Controls.Canvas; $cv.IsHitTestVisible = $false; $cv.ClipToBounds = $false
    [System.Windows.Controls.Panel]::SetZIndex($cv, 2)
    $ipx = 24.0
    if ($c.icon) {   # the badge is a sibling of the icon (rides the tile's lift and press, not the icon's 1.06 hover scale)
        if (-not [double]::IsNaN([double]$c.icon.Width)) { $ipx = [double]$c.icon.Width }
        $sp = $c.el; $i = $sp.Children.IndexOf($c.icon)
        $ib = New-Object System.Windows.Controls.Grid; $ib.HorizontalAlignment = $c.icon.HorizontalAlignment; $ib.VerticalAlignment = $c.icon.VerticalAlignment
        $ib.Margin = $c.icon.Margin; $c.icon.Margin = '0'
        $sp.Children.RemoveAt($i); [void]$ib.Children.Add($c.icon); [void]$ib.Children.Add($cv); $sp.Children.Insert($i, $ib)
    } else { $cv.HorizontalAlignment = 'Left'; $cv.VerticalAlignment = 'Top'; $cv.Margin = '12,14,0,0'; [void]$g.Children.Add($cv) }
    $bd = New-Object System.Windows.Controls.Border; $bd.Height = 18; $bd.Width = 18; $bd.CornerRadius = '9'
    $bd.Background = Brush '#111111'; $bd.BorderBrush = Brush '#B3FFFFFF'; $bd.BorderThickness = '1.5'   # 70% white ring
    $bd.UseLayoutRounding = $true; $bd.SnapsToDevicePixels = $true; $bd.Visibility = 'Collapsed'; $bd.Opacity = 0
    $sc = New-Object System.Windows.Media.ScaleTransform 1, 1; $bd.RenderTransform = $sc; $bd.RenderTransformOrigin = '0.5,0.5'
    $tx = New-Object System.Windows.Controls.TextBlock; $tx.Foreground = Brush '#FACC15'; $tx.FontSize = 11; $tx.FontWeight = [System.Windows.FontWeights]::Bold
    $tx.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text, Segoe UI Semibold, Segoe UI'   # 11 px numeral badge: Kern's accepted exception to the 12 floor
    $tx.HorizontalAlignment = 'Center'; $tx.VerticalAlignment = 'Center'; $tx.TextAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($tx, [System.Windows.FontNumeralAlignment]::Tabular)
    $bd.Child = $tx
    $iconGap = 10.0; if ($c.icon -and $sp.Orientation -ne 'Horizontal') { $iconGap = [double]::PositiveInfinity }   # label beside the icon (10 px gap) or below it (no side overlap)
    [System.Windows.Controls.Canvas]::SetLeft($bd, (Get-MailBadgeLeft $ipx 18 $iconGap)); [System.Windows.Controls.Canvas]::SetTop($bd, -6)   # Kern Minor 2: icon right - 8, icon top - 6, pulled left so it never reaches the label
    $rg = New-Object System.Windows.Shapes.Ellipse; $rg.Width = 8; $rg.Height = 8; $rg.Stroke = Brush '#4A4A4A'; $rg.StrokeThickness = 1.5; $rg.Visibility = 'Collapsed'
    $rg.SnapsToDevicePixels = $true
    [System.Windows.Controls.Canvas]::SetLeft($rg, $ipx - 3); [System.Windows.Controls.Canvas]::SetTop($rg, -1)   # centred where the badge centre is
    [void]$cv.Children.Add($rg); [void]$cv.Children.Add($bd)
    $lab = Get-DisplayLabel $btn; $base = ([string]$lab.main -replace "`n", ' ').Trim(); if (-not $base) { $base = 'Email' }
    $e = @{ ipx = $ipx; iconGap = $iconGap; tile = $tile; wrap = $wrap; badge = $bd; text = $tx; scale = $sc; ring = $rg; glow = $ov; pulse = $null; peak = [double]$look.peak; tip0 = $tile.ToolTip; name = $base; born = [DateTime]::UtcNow }
    $tile.Add_IsVisibleChanged({ Update-MailPulse $e }.GetNewClosure())                # a hidden panel stops its pulse; shown again, it restarts
    $tile.Add_Unloaded({ Set-MailPulse $e $false }.GetNewClosure())
    $tile.Add_Loaded({ [void](Add-MailStateHookOnce ([System.Windows.Window]::GetWindow($e.tile)) { param($w) $w.Add_StateChanged({ foreach ($x in @($global:mail.ui)) { Update-MailPulse $x } }) }) }.GetNewClosure())   # CC: minimised stops the pulse, restore resumes; LJ M34-I1: one handler per window, however often tiles rebuild                    # a rebuilt panel (edit mode, layout) drops the old tile's pulse
    $tile.Add_PreviewMouseLeftButtonUp({ Start-MailFollowUp })                      # the click itself still does exactly what it did
    $tile.Add_PreviewKeyDown({ if (($_.Key -eq 'Enter' -or $_.Key -eq 'Space') -and -not $_.IsRepeat) { Start-MailFollowUp } })
    [void]$global:mail.ui.Add($e)
    if (-not $global:MailAnimHooked) {   # Squint: Windows animations turned off or on while running -> redraw at once (one static handler, no polling)
        $global:MailAnimHooked = $true
        try { [System.Windows.SystemParameters]::add_StaticPropertyChanged({ param($src0, $chg) if ($chg.PropertyName -eq 'ClientAreaAnimation') { Update-MailUi $false } }) } catch {} }
    Set-MailEntry $e $false
}
function global:Add-MailMenu($menu) {   # Squint: status line first, then Check email now, then Email count settings... (only while the count is on)
    $st = New-Object System.Windows.Controls.MenuItem; $st.IsEnabled = $false; $st.Header = 'Email count: checking...'
    $ck = New-Object System.Windows.Controls.MenuItem; $ck.Header = 'Check email now'; $ck.Add_Click({ Invoke-MailPoll $true })
    $se = New-Object System.Windows.Controls.MenuItem; $se.Header = 'Unread email count...'; $se.Add_Click({ [void](Show-MailSetupDialog $null) })
    $sep = New-Object System.Windows.Controls.Separator
    $menu.Items.Insert(0, $st); $menu.Items.Insert(1, $ck); $menu.Items.Insert(2, $se); $menu.Items.Insert(3, $sep)
    $menu.Add_Opened({
        $on = [bool]($global:mail -and $global:mail.set.enabled); $v = if ($on) { 'Visible' } else { 'Collapsed' }
        foreach ($x in @($st, $ck, $se, $sep)) { $x.Visibility = $v }
        if ($on) { $st.Header = Get-MailMenuLine $global:mail.state (Get-Date); $ck.IsEnabled = -not $global:mailRun } }.GetNewClosure())
}
$global:MailPulseCycleMs = 3500   # Charles 2:11 PM: one full pulse (in and out) every 3.5 s, about 0.29 Hz (he picks 3.5 or 5 s)
function global:Set-MailPulse($e, [bool]$on, [double]$peak = 1.0) {   # one Storyboard per tile on the red overlay: 0 -> $peak -> 0 every $global:MailPulseCycleMs ms, sine ease, 20 fps; started once, removed when off
    if ($on) {
        if ($e.pulse) { return }   # already running: a count change never restarts it
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation 0.0, $peak, ([System.Windows.Duration][TimeSpan]::FromMilliseconds($global:MailPulseCycleMs / 2))
        $ez = New-Object System.Windows.Media.Animation.SineEase; $ez.EasingMode = 'EaseInOut'; $a.EasingFunction = $ez; $a.AutoReverse = $true
        [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a, (New-Object System.Windows.PropertyPath 'Opacity'))
        $sb = New-Object System.Windows.Media.Animation.Storyboard; [void]$sb.Children.Add($a)
        $sb.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($sb, 20)
        $e.pulse = $sb; $sb.Begin($e.glow, $true)
    } elseif ($e.pulse) { try { $e.pulse.Remove($e.glow) } catch {}; $e.pulse = $null; $e.glow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $e.glow.Opacity = 0 }
}
$global:MailStateHooked = New-Object 'System.Collections.Generic.HashSet[object]'   # LJ M34-I1: windows that already have the StateChanged handler
function global:Add-MailStateHookOnce($w, [scriptblock]$add) {   # LJ M34-I1: once per window; LJ M35-I1 / CC LOW-H: a closed window leaves the set
    if (-not $w -or $global:MailStateHooked.Contains($w)) { return $false }
    [void]$global:MailStateHooked.Add($w); & $add $w
    $w.Add_Closed({ [void]$global:MailStateHooked.Remove($w) }.GetNewClosure())
    return $true }
function global:Test-MailWinMinimized($el) { try { $w = [System.Windows.Window]::GetWindow($el); return [bool]($w -and $w.WindowState -eq 'Minimized') } catch { return $false } }
function global:Update-MailPulse($e) {
    $m = $global:mail; if (-not $m) { return }
    $on = [bool]$m.set.enabled -and (Test-MailPulseOn $m.state ([string]$m.set.style) (Test-MailAnimOn) ([bool]$global:cfg.locked) ([bool]$e.tile.IsVisible -and -not (Test-MailWinMinimized $e.tile)))
    Set-MailPulse $e $on ([double]$e.peak)
}
function global:Stop-MailPulse { if ($global:mail) { foreach ($e in @($global:mail.ui)) { Set-MailPulse $e $false } } }
function global:Set-MailEntry($e, [bool]$grew) {
    $m = $global:mail; $s = $m.state; $op = [System.Windows.UIElement]::OpacityProperty
    $bd = $e.badge
    if (-not $m.set.enabled) {
        Set-MailPulse $e $false; $bd.BeginAnimation($op, $null); $bd.Opacity = 0; $bd.Visibility = 'Collapsed'; $e.ring.Visibility = 'Collapsed'
        $e.tile.ToolTip = $e.tip0; $e.tile.ClearValue([System.Windows.Automation.AutomationProperties]::NameProperty); return }
    $now = Get-Date
    $e.tile.ToolTip = "Open email`n" + (Get-MailTipLine $s $now)
    [System.Windows.Automation.AutomationProperties]::SetName($e.tile, (Get-MailAccessName $e.name $s))
    $e.ring.Visibility = if (Test-MailShowRing $s) { 'Visible' } else { 'Collapsed' }
    $motion = Get-MailMotion ([string]$m.set.style) (Test-MailAnimOn)
    if (Test-MailShowBadge $s) {
        $txt = Get-MailBadgeText ([int]$s.count); $e.text.Text = $txt; $bd.Width = Get-MailBadgeWidth $txt; [System.Windows.Controls.Canvas]::SetLeft($bd, (Get-MailBadgeLeft $e.ipx $bd.Width $e.iconGap)); [System.Windows.Controls.Canvas]::SetTop($bd, (Get-MailBadgeTop $bd.Width))   # wider '99+' grows left, over the icon, not onto the label
        $appear = $bd.Visibility -ne 'Visible'
        $bd.Visibility = 'Visible'
        $sx = [System.Windows.Media.ScaleTransform]::ScaleXProperty; $sy = [System.Windows.Media.ScaleTransform]::ScaleYProperty
        $e.scale.BeginAnimation($sx, $null); $e.scale.BeginAnimation($sy, $null); $e.scale.ScaleX = 1; $e.scale.ScaleY = 1   # the badge never bounces; the tile pulses (Update-MailPulse)
        if ($appear) { $fade = if ($motion -eq 'badge') { 120 } else { 150 }
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation 0.0, 1.0, ([System.Windows.Duration][TimeSpan]::FromMilliseconds($fade)); $bd.BeginAnimation($op, $a) }
        elseif ($bd.Opacity -lt 1) { $bd.BeginAnimation($op, $null); $bd.Opacity = 1 }
        if ($grew) { try { $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($e.tile); if ($peer) { $peer.RaiseAutomationEvent([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged) } } catch {} }   # polite, only when it goes up
    } else {
        $e.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null); $e.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
        if ($bd.Visibility -eq 'Visible') {   # Kern 3: 150 ms fade, then collapsed (120 ms with motion off)
            $fade = if ($motion -eq 'badge') { 120 } else { 150 }
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation 0.0, ([System.Windows.Duration][TimeSpan]::FromMilliseconds($fade))
            $a.Add_Completed({ if ($bd.Opacity -lt 0.01) { $bd.Visibility = 'Collapsed' } }.GetNewClosure())
            $bd.BeginAnimation($op, $a) }
    }
    Update-MailPulse $e   # Charles: on the whole time unread > 0, off at 0, on a stop or an error
}
function global:Update-MailUi([bool]$grew) {   # drops tiles from old panel builds, then redraws each Email tile
    $m = $global:mail; if (-not $m) { return }
    $keep = New-Object System.Collections.ArrayList
    foreach ($e in @($m.ui)) { if ($e.wrap.Parent -or ([DateTime]::UtcNow - $e.born).TotalSeconds -lt 5) { [void]$keep.Add($e) } }
    foreach ($e in @($m.ui)) { if (-not $keep.Contains($e)) { Set-MailPulse $e $false } }
    $m.ui = $keep
    foreach ($e in @($m.ui)) { try { Set-MailEntry $e $grew } catch { Add-Content -LiteralPath $global:logPath -Value ('{0}  email count display: {1}' -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue } }
}

# ---- Setup > Unread email count... (Kern D2 dialog, Squint copy) ----
$global:MailDialogXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="D2Check" TargetType="CheckBox">
    <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="FontSize" Value="14"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <Grid Background="Transparent" MinHeight="24"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid Width="26" Height="26" VerticalAlignment="Center">
          <Border x:Name="Ring" CornerRadius="8" BorderBrush="#FFFFFF" BorderThickness="2" Visibility="Hidden"/>
          <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" BorderBrush="#8CFFFFFF" BorderThickness="1.5" Background="Transparent"/>
          <Path x:Name="Mark" Data="M 6,11.5 L 9.5,15 L 16,7.5" Stroke="#111111" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
        </Grid>
        <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#14FFFFFF"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="#22C55E"/><Setter TargetName="Box" Property="BorderThickness" Value="0"/><Setter TargetName="Mark" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Ring" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="D2Radio" TargetType="RadioButton">
    <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="FontSize" Value="14"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
      <Grid Background="Transparent" Height="28"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid Width="26" Height="26" VerticalAlignment="Center">
          <Ellipse x:Name="Ring" Stroke="#FFFFFF" StrokeThickness="2" Visibility="Hidden"/>
          <Ellipse x:Name="Outer" Width="18" Height="18" Stroke="#8CFFFFFF" StrokeThickness="1.5" Fill="Transparent"/>
          <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#22C55E" Visibility="Collapsed"/>
        </Grid>
        <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Outer" Property="Fill" Value="#14FFFFFF"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Outer" Property="Stroke" Value="#22C55E"/><Setter TargetName="Dot" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Ring" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="D2ComboItem" TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="FontSize" Value="14"/><Setter Property="Height" Value="32"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
      <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="10,0">
        <Grid><Border x:Name="Pill" Width="3" Height="16" CornerRadius="1.5" Background="#22C55E" HorizontalAlignment="Left" Margin="-8,0,0,0" Visibility="Hidden"/>
          <ContentPresenter VerticalAlignment="Center"/></Grid>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsSelected" Value="True"><Setter TargetName="Pill" Property="Visibility" Value="Visible"/><Setter TargetName="Bd" Property="Background" Value="#0FFFFFFF"/></Trigger>
        <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#17FFFFFF"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="D2Combo" TargetType="ComboBox">
    <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="FontSize" Value="14"/><Setter Property="Height" Value="32"/><Setter Property="Width" Value="140"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="ItemContainerStyle" Value="{StaticResource D2ComboItem}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
      <Grid>
        <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
          <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Box" Background="#0FFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" CornerRadius="6">
              <Grid>
                <Border x:Name="Rest" Height="1" VerticalAlignment="Bottom" Background="#66FFFFFF"/>
                <TextBlock x:Name="Chev" Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" Foreground="#B4B4BC" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#17FFFFFF"/><Setter TargetName="Chev" Property="Foreground" Value="#FFFFFF"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="Chev" Property="Foreground" Value="#FFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate></ToggleButton.Template>
        </ToggleButton>
        <Border x:Name="Focus" Height="2" VerticalAlignment="Bottom" Background="#22C55E" CornerRadius="0,0,6,6" Visibility="Hidden" IsHitTestVisible="False"/>
        <ContentPresenter IsHitTestVisible="False" Margin="10,0,28,0" VerticalAlignment="Center" HorizontalAlignment="Left" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
        <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" VerticalOffset="2" AllowsTransparency="True" Focusable="False" PopupAnimation="None">
          <Grid Margin="1"><Border Margin="-1" CornerRadius="9" BorderBrush="#40000000" BorderThickness="1" IsHitTestVisible="False"/><!-- Kern: 1 px dark hairline ring (no bitmap effects) -->
            <Border MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" Background="#2B2B30" BorderBrush="#59FFFFFF" BorderThickness="1" CornerRadius="8" Padding="4">
            <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}" VerticalScrollBarVisibility="Auto"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
          </Border></Grid>
        </Popup>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Focus" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsDropDownOpen" Value="True"><Setter TargetName="Focus" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
</ResourceDictionary>
'@
function global:Show-MailConfirmOff($owner) {   # Squint: 'Turn off the email count and forget this login on this PC?' Default No.
    $dlg = New-D2Dialog 'Unread email count' $owner 348
    [void]$dlg.body.Children.Add((New-D2Label 'Turn off the email count and forget this login on this PC?'))
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,16,0,0'
    $res = @{ yes = $false }
    $bNo = New-D2Button 'No' 'Green' $dlg; $bNo.IsDefault = $true; $bNo.IsCancel = $true
    $bYes = New-D2Button 'Yes, turn off' 'Chip' $dlg
    $bNo.Add_Click({ $dlg.win.Close() }.GetNewClosure()); $bYes.Add_Click({ $res.yes = $true; $dlg.win.Close() }.GetNewClosure())
    [void]$row.Children.Add($bNo); [void]$row.Children.Add($bYes); [void]$dlg.body.Children.Add($row)
    $dlg.win.Add_ContentRendered({ [void]$bNo.Focus() }.GetNewClosure())
    [void]$dlg.win.ShowDialog()
    return $res.yes
}
function global:Show-MailSetupDialog($owner) {   # opt-in; Save only after a good Test; the password lives only in the PasswordBox and the DPAPI file
    if (-not $global:mail) { Initialize-Mail }
    $was = $global:mail.set
    $dlg = New-D2Dialog 'Unread email count' $owner 408; $d = $dlg.win; $sp = $dlg.body
    if (-not $global:MailDialogRes) { try { $global:MailDialogRes = [Windows.Markup.XamlReader]::Parse($global:MailDialogXaml) } catch { Add-Content -LiteralPath $global:logPath -Value ('{0}  email dialog styles: {1}' -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue } }
    if ($global:MailDialogRes) { foreach ($k in @($global:MailDialogRes.Keys)) { $d.Resources[$k] = $global:MailDialogRes[$k] } }
    $hd = New-D2Label 'Unread email count' '#FFFFFF' 18; $hd.FontWeight = [System.Windows.FontWeights]::SemiBold; $hd.Margin = '0,0,0,16'; [void]$sp.Children.Add($hd)
    $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = 'Show unread email count on the Email button'; $cb.Margin = '0,0,0,16'
    $s1 = $d.TryFindResource('D2Check'); if ($s1) { $cb.Style = $s1 } else { $cb.Foreground = Brush '#FFFFFF'; $cb.FontSize = 14 }
    $cb.IsChecked = [bool]$was.enabled; [void]$sp.Children.Add($cb)
    $acct = New-Object System.Windows.Controls.StackPanel; [void]$sp.Children.Add($acct)
    $intro = New-D2Label 'Uses your Jartrek email, the same login as webmail.' '#B4B4BC' 13; $intro.Margin = '0,0,0,16'; [void]$acct.Children.Add($intro)
    [void]$acct.Children.Add((New-D2Label 'Email address'))
    $ta = New-Object System.Windows.Controls.TextBox; $ta.MaxLength = 254
    $ta.Text = if ($was.address) { [string]$was.address } else { $global:MailDomain }   # Charles types the whole address; '@jartrek.net' is only an editable start
    [System.Windows.Automation.AutomationProperties]::SetName($ta, 'Email address')
    [System.Windows.Automation.AutomationProperties]::SetHelpText($ta, 'Type your name before @jartrek.net')   # Squint: Narrator hears where the name goes
    $fa = New-D2Field $ta; $fa.Margin = '0,0,0,4'; [void]$acct.Children.Add($fa)
    $hint = New-Object System.Windows.Controls.TextBlock; $hint.Text = 'Type your name before @jartrek.net'; $hint.FontSize = 12; $hint.Foreground = Brush '#B4B4BC'; $hint.Margin = '0,0,0,16'   # Kern caption: 12 px #B4B4BC
    [void]$acct.Children.Add($hint)
    $ta.Add_GotKeyboardFocus({   # Squint: click or Tab into a field that still says only '@jartrek.net' -> caret before the @ (after WPF places it)
        $t = $ta; if ($t.Text -ceq $global:MailDomain) { [void]$t.Dispatcher.BeginInvoke([Action]{ $t.CaretIndex = 0 }.GetNewClosure(), [System.Windows.Threading.DispatcherPriority]::Input) } }.GetNewClosure())
    $ph = New-Object System.Windows.Controls.TextBlock; $ph.Text = 'name@jartrek.net'; $ph.FontSize = 14; $ph.Foreground = Brush '#9A9AA4'; $ph.VerticalAlignment = 'Center'; $ph.Margin = '10,0,0,0'; $ph.IsHitTestVisible = $false
    [void]$fa.Child.Children.Add($ph)
    [void]$acct.Children.Add((New-D2Label 'Password'))
    $pb = New-Object System.Windows.Controls.PasswordBox; $pb.MaxLength = 256
    $fp = New-D2Field $pb; [void]$acct.Children.Add($fp)
    $pph = New-Object System.Windows.Controls.TextBlock; $pph.FontSize = 14; $pph.Foreground = Brush '#9A9AA4'; $pph.VerticalAlignment = 'Center'; $pph.Margin = '10,0,0,0'; $pph.IsHitTestVisible = $false
    $pph.Text = if ($was.enabled -and (Test-Path -LiteralPath (Get-MailSecretPath))) { 'Saved. Type it again only to change it.' } else { '' }
    [void]$fp.Child.Children.Add($pph)
    $pErr = New-Object System.Windows.Controls.Border; $pErr.Height = 2; $pErr.VerticalAlignment = 'Bottom'; $pErr.Background = Brush '#F87171'; $pErr.CornerRadius = '0,0,6,6'; $pErr.IsHitTestVisible = $false; $pErr.Visibility = 'Hidden'
    [void]$fp.Child.Children.Add($pErr)
    foreach ($f in @($fa, $fp)) { $rl = New-Object System.Windows.Controls.Border; $rl.Height = 1; $rl.VerticalAlignment = 'Bottom'; $rl.Background = Brush '#66FFFFFF'; $rl.IsHitTestVisible = $false; $f.Child.Children.Insert(0, $rl) }   # Kern: 40% rest line (3:1 edge)
    $warn = New-Object System.Windows.Controls.Border; $warn.CornerRadius = '8'; $warn.Background = Brush '#1FF59E0B'; $warn.BorderBrush = Brush '#59F59E0B'; $warn.BorderThickness = '1'; $warn.Padding = '10,8'; $warn.Margin = '0,8,0,24'
    $wd = New-Object System.Windows.Controls.DockPanel
    $wi = New-Object System.Windows.Controls.TextBlock; $wi.Text = [string][char]0xE7BA; $wi.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'; $wi.FontSize = 16; $wi.Foreground = Brush '#FBBF24'; $wi.Margin = '0,0,8,0'; $wi.VerticalAlignment = 'Top'
    [System.Windows.Automation.AutomationProperties]::SetName($wi, 'Warning')
    $wt = New-Object System.Windows.Controls.TextBlock; $wt.Text = 'Everyone who uses this Windows login on this PC will see how many unread emails this account has.'; $wt.FontSize = 13; $wt.Foreground = Brush '#FBBF24'; $wt.TextWrapping = 'Wrap'
    [void]$wd.Children.Add($wi); [void]$wd.Children.Add($wt); $warn.Child = $wd; [void]$acct.Children.Add($warn)
    $h2 = New-D2Label 'While there are unread emails:' '#FFFFFF' 14; $h2.FontWeight = [System.Windows.FontWeights]::SemiBold; [void]$acct.Children.Add($h2)
    $s2 = $d.TryFindResource('D2Radio'); $radios = @{}
    foreach ($o in @(@('pulse', 'Pulse the Email button'), @('badge', 'Just show the number'))) {
        $rb = New-Object System.Windows.Controls.RadioButton; $rb.GroupName = 'mailStyle'; $rb.Content = $o[1]; if ($s2) { $rb.Style = $s2 } else { $rb.Foreground = Brush '#FFFFFF'; $rb.FontSize = 14; $rb.Margin = '0,4' }
        $rb.IsChecked = ([string]$was.style -eq $o[0]); $radios[$o[0]] = $rb; [void]$acct.Children.Add($rb)
        if ($o[0] -eq 'pulse') {   # Squint: hint under the option, the dialog's caption style (12 px #B4B4BC), aligned with the label
            $pulsePh = New-Object System.Windows.Controls.TextBlock; $pulsePh.FontSize = 12; $pulsePh.Foreground = Brush '#B4B4BC'; $pulsePh.Margin = '28,0,0,4'; $pulsePh.TextWrapping = 'Wrap'; [void]$acct.Children.Add($pulsePh) } }   # v1.4.2: own name; reusing $ph hid the pulse hint instead of the address placeholder
    $pulseHint = { $t = Get-MailPulseHint (Test-MailAnimOn); $pulsePh.Text = $t; [System.Windows.Automation.AutomationProperties]::SetHelpText($radios['pulse'], $t) }.GetNewClosure()   # Squint: one hint spot, also the radio's HelpText; the saved choice stays as it is
    & $pulseHint
    $animH = [System.ComponentModel.PropertyChangedEventHandler]{ param($src0, $chg) if ($chg.PropertyName -eq 'ClientAreaAnimation') { & $pulseHint } }.GetNewClosure()
    $d.Add_Loaded({ try { [System.Windows.SystemParameters]::add_StaticPropertyChanged($animH) } catch {} }.GetNewClosure())   # CC LOW-F: hooked only once the dialog is up (a build failure never leaves it hooked)
    $d.Add_Closed({ try { [System.Windows.SystemParameters]::remove_StaticPropertyChanged($animH) } catch {} }.GetNewClosure())   # live while the dialog is open, unhooked when it closes
    if (-not ($radios.Values | Where-Object { $_.IsChecked })) { $radios['pulse'].IsChecked = $true }   # Charles: Pulse by default
    $h3 = New-D2Label 'Check for new email every:' '#FFFFFF' 14; $h3.FontWeight = [System.Windows.FontWeights]::SemiBold; $h3.Margin = '0,16,0,6'; [void]$acct.Children.Add($h3)
    $cbI = New-Object System.Windows.Controls.ComboBox; $cbI.Width = 140; $cbI.Height = 32; $cbI.HorizontalAlignment = 'Left'; $cbI.FontSize = 14; $cbI.Margin = '0'   # Kern: 16 to the buttons comes from the row
    $s3 = $d.TryFindResource('D2Combo'); if ($s3) { $cbI.Style = $s3 }
    [System.Windows.Automation.AutomationProperties]::SetName($cbI, 'Check for new email every')
    $curI = Get-MailInterval $was.interval; $ivals = @($global:MailIntervals); if ($ivals -notcontains $curI) { $ivals = @($ivals + $curI | Sort-Object) }   # a hand-edited value (e.g. 7) still shows
    foreach ($mi in $ivals) { [void]$cbI.Items.Add(('{0} minutes' -f $mi)) }
    $cbI.SelectedIndex = [array]::IndexOf($ivals, $curI); [void]$acct.Children.Add($cbI)
    $rline = New-Object System.Windows.Controls.DockPanel; $rline.Margin = '0,16,0,8'; $rline.MinHeight = 20; $rline.Visibility = 'Collapsed'
    $ri = New-Object System.Windows.Controls.TextBlock; $ri.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'; $ri.FontSize = 16; $ri.Margin = '0,0,8,0'; $ri.VerticalAlignment = 'Top'
    $rt = New-Object System.Windows.Controls.TextBlock; $rt.FontSize = 13; $rt.TextWrapping = 'Wrap'
    try { [System.Windows.Automation.AutomationProperties]::SetLiveSetting($rt, [System.Windows.Automation.AutomationLiveSetting]::Polite) } catch {}
    [void]$rline.Children.Add($ri); [void]$rline.Children.Add($rt); [void]$sp.Children.Add($rline)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,16,0,0'   # Kern: 8 under the result line (set when it shows)
    $bTest = New-D2Button 'Test' 'Chip' $dlg
    $bSave = New-D2Button 'Save' 'Green' $dlg
    $bCancel = New-D2Button 'Cancel' 'Chip' $dlg; $bCancel.IsCancel = $true
    foreach ($b in @($bTest, $bSave, $bCancel)) { [void]$row.Children.Add($b) }
    [void]$sp.Children.Add($row)
    $ds = @{ tested = $false; addr = ''; result = $null; busy = $false; closed = $false; wait = $null; ivals = $ivals }
    $origAddr = [string]$was.address
    $refresh = {
        $on = [bool]$cb.IsChecked; $acct.IsEnabled = $on; $acct.Opacity = $(if ($on) { 1.0 } else { 0.45 }); $bTest.IsEnabled = $on -and -not $ds.busy
        $ph.Visibility = if ($ta.Text) { 'Collapsed' } else { 'Visible' }
        $pph.Visibility = if ($pb.SecurePassword.Length -gt 0) { 'Collapsed' } else { 'Visible' }
        $addr = Get-MailAddress $ta.Text
        $styleOnly = [bool]$was.enabled -and $addr -eq $origAddr -and $pb.SecurePassword.Length -eq 0   # style or interval only: no new Test needed
        $ok = if ($on) { ($ds.tested -and $ds.addr -eq $addr) -or $styleOnly } else { [bool]$was.enabled }
        $bSave.IsEnabled = $ok -and -not $ds.busy; $bSave.Opacity = $(if ($bSave.IsEnabled) { 1.0 } else { 0.45 })
        $bSave.IsDefault = $ok; $bTest.IsDefault = -not $ok }.GetNewClosure()   # Squint: Enter = Test until a Test passes, then Save
    $showResult = { param($kind, $text)
        $rline.Visibility = 'Visible'; $rt.Text = $text; $row.Margin = '0'
        $pErr.Visibility = if ($kind -eq 'auth') { 'Visible' } else { 'Hidden' }   # Kern: #F87171 line on the password after a failed sign-in
        switch ($kind) { 'ok' { $ri.Text = [string][char]0xE930; $ri.Foreground = Brush '#22C55E'; $rt.Foreground = Brush '#4ADE80' }
                         'auth' { $ri.Text = [string][char]0xEA39; $ri.Foreground = Brush '#F87171'; $rt.Foreground = Brush '#F87171' }
                         { $_ -eq 'net' -or $_ -eq 'unclear' -or $_ -eq 'cert' -or $_ -eq 'proto' -or $_ -eq 'lost' -or $_ -eq 'internal' -or $_ -eq 'method' } { $ri.Text = [string][char]0xE7BA; $ri.Foreground = Brush '#FBBF24'; $rt.Foreground = Brush '#FBBF24' }
                         default { $ri.Text = ''; $rt.Foreground = Brush '#B4B4BC' } } }.GetNewClosure()
    $cb.Add_Click({ $ds.tested = $false; & $refresh }.GetNewClosure())
    $ta.Add_TextChanged({ $ds.tested = $false; & $refresh }.GetNewClosure())
    $pb.Add_PasswordChanged({ $ds.tested = $false; $pErr.Visibility = 'Hidden'; & $refresh }.GetNewClosure())
    $bTest.Add_Click({
        # 4:38 PM laptop bug: GetNewClosure copies only LOCAL variables, so $onDone and the wait timer below (closures made in here)
        # never saw $ds/$showResult/$refresh and hit "$null.busy = ...". Re-bind them as locals of this handler first.
        $ds = $ds; $showResult = $showResult; $refresh = $refresh
        $addr = Get-MailAddress $ta.Text
        $why = Get-MailAddressProblem $addr; if ($why) { & $showResult 'auth' $why; [void]$ta.Focus(); return }
        $sec = $null
        if ($pb.SecurePassword.Length -gt 0) { $sec = $pb.SecurePassword }                       # a copy; disposed when the check ends
        elseif ([bool]$was.enabled -and $addr -eq $origAddr) { $sec = Read-MailSecret }
        if (-not $sec) { & $showResult 'auth' 'Type your password first.'; [void]$pb.Focus(); return }
        $ds.busy = $true; $ds.tested = $false; & $showResult 'busy' 'Testing...'; & $refresh
        $onDone = { param($r)
            $ds.busy = $false
            if ($ds.closed) { return }
            Write-MailLogLine $r 'test'   # the same fixed-word line as the background check, with the failing step
            $tr = Get-MailTestText $r; & $showResult $tr.kind $tr.text
            if ($tr.kind -eq 'ok') { $ds.tested = $true; $ds.addr = $addr; $ds.result = $r }
            & $refresh }.GetNewClosure()
        if (-not (Start-MailRun $addr $sec $onDone)) {   # a background check is running: start as soon as it ends
            $w = New-Object System.Windows.Threading.DispatcherTimer; $w.Interval = [TimeSpan]::FromMilliseconds(300); $ds.wait = $w
            $w.Add_Tick({ if ($ds.closed) { $w.Stop(); $sec.Dispose(); return }; if (Start-MailRun $addr $sec $onDone) { $w.Stop() } }.GetNewClosure()); $w.Start() } }.GetNewClosure())
    $bSave.Add_Click({
        if (-not [bool]$cb.IsChecked) {
            if ([bool]$was.enabled -and (Show-MailConfirmOff $d)) { Disable-Mail; $pb.Clear(); $d.Close() }
            return }
        $addr = Get-MailAddress $ta.Text
        $why = Get-MailAddressProblem $addr; if ($why) { & $showResult 'auth' $why; [void]$ta.Focus(); return }   # Squint: Save says it too
        $style = 'pulse'; foreach ($k in @($radios.Keys)) { if ($radios[$k].IsChecked) { $style = $k } }
        if ($pb.SecurePassword.Length -gt 0) { $ss = $pb.SecurePassword; try { Save-MailSecret $ss } finally { $ss.Dispose() } }
        $iv = Get-MailInterval $(if ($cbI.SelectedIndex -ge 0) { $ds.ivals[$cbI.SelectedIndex] } else { 3 })
        $set = ConvertTo-MailSettings @{ enabled = $true; address = $addr; style = $style; interval = $iv }
        Save-MailSettings $set
        $global:mail.set = $set
        if ($ds.tested -and $ds.result) {   # the good Test is this poll: no second sign-in right away; a stopped count starts again
            Stop-MailRunObjects $global:mailRun; $global:mail.state = Get-MailFreshState $global:mail.state; $ds.result.epoch = $global:mail.state.epoch   # CC M1
            [void](Update-MailState $global:mail.state $ds.result (Get-Date)); Start-MailPolling -firstSec (60 * $set.interval) }
        else { Update-MailUi $false   # the new interval applies now, without a restart
            if (-not $global:mail.state.stopped) { if (-not $global:mailTimer -or -not $global:mailTimer.IsEnabled) { Start-MailPolling } elseif ([int]$was.interval -ne [int]$set.interval) { Set-MailTimer (Get-MailNextDelaySec $global:mail.state $set.interval) } } }
        $pb.Clear(); $d.Close() }.GetNewClosure())
    $bCancel.Add_Click({ $pb.Clear(); $d.Close() }.GetNewClosure())
    $d.Add_Closed({ $ds.closed = $true; if ($ds.wait) { $ds.wait.Stop() }; $pb.Clear() }.GetNewClosure())
    $d.Add_ContentRendered({ if ($cb.IsChecked) { [void]$ta.Focus(); $ta.CaretIndex = 0 } else { [void]$cb.Focus() } }.GetNewClosure())   # caret before '@jartrek.net' so typing the name just works
    & $refresh
    [void]$d.ShowDialog()
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
    Write-LauncherLog ('Launcher {0} started' -f $global:AppVersion)   # v1.4.3: which copy ran
    try { [void](Initialize-VncViewerScan) } catch {}   # v1.4.3: find vncviewer.exe once (bounded, a few folder reads)
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
    try { Clear-VncSecret } catch {}   # LJ M39-I1: delete a leftover v1.4.1 vnc-viewonly.dat (beside buttons.json) unread; the v1.4.4 store is a different file in another folder
    try { Remove-VncTempLeftovers 0 } catch {}   # v1.4.4: no viewer of ours is running yet, so any bl-vnc-* .vnc left by a crash goes now
    try { Write-LauncherLog ('view-only password: ' + $(if (Test-VncSecret) { 'saved' } else { 'none' })) } catch {}
    try { Initialize-Mail } catch { $global:mail = $null; Add-Content -LiteralPath $global:logPath -Value ('{0}  email count settings unreadable: {1}' -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue }   # v1.4.0: reads a per-user file only; no network
    if ((Get-LayoutMode $global:cfg) -eq 'single' -and @($global:cfg.panels).Count -ge 1) { Open-Single }
    else { foreach ($pc in @($global:cfg.panels)) { [void](Open-Panel $pc) } }
    Apply-Lock                                          # builds every panel (menus know every panel) + tool-window style + placement
    if ($global:panels.Count -eq 0) { throw 'No panels could be opened.' }
    try { Start-MailPolling } catch { Write-LauncherError 'starting the email count' $_ }   # v1.4.0: nothing at all unless this Windows user turned it on
    Start-TrayAndHotkey                                 # Squint Major 1: tray icon + Ctrl+Alt+L bring the launcher forward (both layouts)
    $global:app.Add_Exit({ Stop-TrayAndHotkey; try { Clear-VncDeadWorkers -All } catch {}; try { Stop-Mail } catch {}; try { Clear-MailDeadRuns } catch {} })   # N1
    # Idle CPU: wait for the "show" signal on a thread-pool wait instead of polling every 400 ms; it posts to the UI thread.
    # R11-M1: its own Add-Type (WPF is loaded by now; BL.Native stays exactly as before). On failure: log, 1 s poll.
    $showWatch = $false
    try {
        if (-not ('BL.Waits' -as [type])) { Add-Type -ReferencedAssemblies WindowsBase, System -TypeDefinition $global:WaitsSource }
        [BL.Waits]::WatchHandle($global:showEvent, $global:app.Dispatcher, [Action]{ Show-AllPanels }); $showWatch = $true
    } catch { Add-Content -LiteralPath $global:logPath -Value ("{0}  event waits unavailable ({1}); polling for the show signal instead" -f (Get-Date -Format s), $_.Exception.Message) -ErrorAction SilentlyContinue }
    try { if ('BL.Waits' -as [type]) { [BL.Waits]::WatchResume($global:app.Dispatcher, [Action]{ $global:forceRelayout = $true; Request-Relayout; try { Resume-Mail } catch {} }) } }   # R12-N1: own try; R10-L1 re-dock after sleep
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
