# VNC picker checks that run without Windows: validation, argument building, subnet math, banner parsing,
# the .vnc file and its password obfuscation, favourites and cache persistence, and source checks for the scan.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Launcher.ps1'), [ref]$null, [ref]$null)
$src = $ast.Extent.Text
$fns = 'Set-Prop', 'Get-ButtonType', 'Test-VncIPv4', 'Test-VncHost', 'Get-VncPort', 'ConvertTo-VncEndpoint', 'Test-Rfc1918', 'ConvertTo-VncUInt', 'ConvertFrom-VncUInt',
       'Get-VncPrefix', 'Get-VncScanTargets', 'Get-SafeText', 'Get-RfbBanner', 'Get-VncViewerArgs', 'ConvertTo-VncObfuscated', 'New-VncConfigText', 'Get-VncState',
       'Save-VncFavorites', 'Set-VncFavorite', 'Read-VncCache', 'Save-VncCache', 'Test-VncCacheStale', 'Merge-VncRows', 'Test-VncPickerButton'
foreach ($n in $fns) {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(VncDesKey|VncCacheMaxAge)\s*=') { Invoke-Expression $l.Extent.Text } }

# --- host / port validation (untrusted input) ---
foreach ($h in '192.168.1.20', '10.0.0.1', '0.0.0.0', '255.255.255.255', 'REG1', 'reg-1.shop.local', 'a', ('a' * 63), 'reg1.') { Check "host ok: $($h.Substring(0, [Math]::Min(20, $h.Length)))" (Test-VncHost $h) }
foreach ($h in '', '256.1.1.1', '1.2.3', '1.2.3.4.5', '01.2.3.4', '-reg', 'reg-', 'a..b', ('a' * 64), (((('a' * 60) + '.') * 5)), 'reg 1', 'reg;calc', 'reg&x', 'reg"x', "reg`nx", 'reg_1', '-config', 'h:1', '[::1]', 'réг', 'reg/x', 'C:\x') {
    Check ("host rejected: " + ($h -replace '[^\x20-\x7E]', '?')) (-not (Test-VncHost $h)) }
Check 'hostname max 253 chars ok' (Test-VncHost (((('a' * 63) + '.') * 3) + ('a' * 61)))
Check 'port 1 and 65535 ok' ((Get-VncPort 1) -eq 1 -and (Get-VncPort '65535') -eq 65535)
foreach ($p in 0, 65536, -1, '5900x', '', $null, '1e3', ' ', '5900.0', '99999999') { Check "port rejected: '$p'" ($null -eq (Get-VncPort $p)) }
$e = ConvertTo-VncEndpoint 'reg1:5901'; Check 'endpoint host:port' ($e.host -eq 'reg1' -and $e.port -eq 5901)
$e = ConvertTo-VncEndpoint 'reg1::5902'; Check 'endpoint host::port' ($e.host -eq 'reg1' -and $e.port -eq 5902)
$e = ConvertTo-VncEndpoint ' 192.168.1.9 ' 5900; Check 'endpoint default port, trimmed' ($e.host -eq '192.168.1.9' -and $e.port -eq 5900)
foreach ($t in 'reg1:0', 'reg1:70000', 'reg1:a', 'a:b:c', 'reg 1', '') { Check "endpoint rejected: '$t'" ($null -eq (ConvertTo-VncEndpoint $t)) }

# --- viewer arguments (verified switches: host::port, -autoscaling, -viewonly, -config) ---
$a = Get-VncViewerArgs '192.168.1.20' 5900 $false $null
Check 'interact: host::port -autoscaling, no -viewonly' (($a -join ' ') -eq '192.168.1.20::5900 -autoscaling')
$a = Get-VncViewerArgs 'reg1' 5901 $true $null
Check 'view only: host::port -autoscaling -viewonly' (($a -join ' ') -eq 'reg1::5901 -autoscaling -viewonly')
$a = Get-VncViewerArgs 'reg1' 5901 $true 'C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc'
Check 'view only + saved password: -config "<file>" -autoscaling -viewonly, no host, no password' (($a -join ' ') -eq '-config "C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc" -autoscaling -viewonly')
$threw = $false; try { [void](Get-VncViewerArgs 'reg1 -password x' 5900 $true $null) } catch { $threw = $true }; Check 'args: bad host throws' $threw
$threw = $false; try { [void](Get-VncViewerArgs 'reg1' 0 $true $null) } catch { $threw = $true }; Check 'args: bad port throws' $threw
$threw = $false; try { [void](Get-VncViewerArgs 'reg1' 5900 $true 'C:\a"b\c.vnc') } catch { $threw = $true }; Check 'args: quote in config path throws' $threw
Check '254-char hostname rejected' (-not (Test-VncHost (((('a' * 63) + '.') * 3) + ('a' * 62))))
$threw = $false; try { [void](Get-VncViewerArgs 'reg1' 5900 $true 'c.vnc') } catch { $threw = $true }; Check 'args: relative config path throws' $threw

# --- subnet math: own subnet only, /24 default, /22 hard cap, RFC1918 only ---
Check 'RFC1918 10/8, 172.16/12, 192.168/16' ((Test-Rfc1918 '10.1.2.3') -and (Test-Rfc1918 '172.16.0.1') -and (Test-Rfc1918 '172.31.255.1') -and (Test-Rfc1918 '192.168.0.5'))
foreach ($ip in '172.15.0.1', '172.32.0.1', '8.8.8.8', '100.64.0.1', '169.254.1.1', '127.0.0.1', '192.169.0.1', '11.0.0.1') { Check "not private: $ip" (-not (Test-Rfc1918 $ip)) }
$t = Get-VncScanTargets '192.168.1.37' 24 24
Check '/24: 253 targets (no network, broadcast or self)' ($t.Count -eq 253 -and $t -notcontains '192.168.1.0' -and $t -notcontains '192.168.1.255' -and $t -notcontains '192.168.1.37' -and $t[0] -eq '192.168.1.1' -and $t[-1] -eq '192.168.1.254')
Check 'adapter /16 still scans only the /24 by default' ((Get-VncScanTargets '10.5.6.7' 16 $null).Count -eq 253)
Check 'setting /22 -> 1021 targets' ((Get-VncScanTargets '10.5.6.7' 16 22).Count -eq 1021)
Check 'setting /16 is capped at /22' ((Get-VncScanTargets '10.5.6.7' 8 16).Count -eq 1021)
Check 'setting /8 or garbage is capped/defaulted' ((Get-VncScanTargets '10.5.6.7' 8 8).Count -eq 1021 -and (Get-VncScanTargets '10.5.6.7' 8 'x').Count -eq 253)
Check 'adapter /26 narrower than setting wins' ((Get-VncScanTargets '192.168.1.70' 26 24).Count -eq 61)
Check 'public IP: nothing scanned' ((Get-VncScanTargets '8.8.8.8' 24 24).Count -eq 0)
Check 'CGNAT 100.64/10: nothing scanned' ((Get-VncScanTargets '100.64.3.4' 24 24).Count -eq 0)
Check 'APIPA: nothing scanned' ((Get-VncScanTargets '169.254.10.10' 16 24).Count -eq 0)
$t22 = Get-VncScanTargets '172.16.2.9' 22 22
Check '/22 stays inside 172.16.0.0-172.16.3.255 and private' ($t22[0] -eq '172.16.0.1' -and $t22[-1] -eq '172.16.3.254' -and -not ($t22 | Where-Object { -not (Test-Rfc1918 $_) }))
Check '/31 or /32 adapter: nothing' ((Get-VncScanTargets '10.0.0.1' 31 24).Count -eq 0)

# --- banner parsing ---
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("RFB 003.008`n")); Check 'banner RFB 003.008' ($b.text -eq 'RFB 003.008' -and $b.rfb)
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("RFB 003.889`n")); Check 'banner UltraVNC 3.889 accepted' ($b.rfb)
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("SSH-2.0-OpenSSH_9.6`r`n")); Check 'non-RFB: shown as text, not RFB, max 12' (-not $b.rfb -and $b.text.Length -le 12)
$b = Get-RfbBanner ([byte[]](0x1B, 0x5B, 0x32, 0x4A, 0x07, 0x00, 0x52, 0x46, 0x42)); Check 'control chars stripped' ($b.text -notmatch '[\x00-\x1F\x7F]')
$b = Get-RfbBanner ([byte[]]@()); Check 'empty banner' ($b.text -eq '' -and -not $b.rfb)
$b = Get-RfbBanner ([byte[]](1..200 | ForEach-Object { 65 })); Check 'only the first 12 bytes are used' ($b.text.Length -eq 12)
Check 'SafeText strips C1 and caps length' ((Get-SafeText ("ab" + [char]0x9B + "c" + ('x' * 100)) 10) -eq 'abcxxxxxxx')

# --- .vnc file + password obfuscation (fixed VNC DES key; obfuscation, not encryption) ---
Check "obfuscation matches the classic VNC vector for 'password'" ((ConvertTo-VncObfuscated ([Text.Encoding]::ASCII.GetBytes('password'))) -eq 'dbd83cfd727a1458')
$dummy = [Text.Encoding]::ASCII.GetBytes('0000'); $hx = ConvertTo-VncObfuscated $dummy
Check 'dummy: 16 lowercase hex' ($hx -match '^[0-9a-f]{16}$')
Check 'longer than 8 chars: only first 8 used (like UltraVNC)' ((ConvertTo-VncObfuscated ([Text.Encoding]::ASCII.GetBytes('password123'))) -eq 'dbd83cfd727a1458')
function Undo-Vnc([string]$hex) { $k = $global:VncDesKey; $d = [System.Security.Cryptography.DES]::Create(); $d.Mode = 'ECB'; $d.Padding = 'None'
    $in = [byte[]](0..7 | ForEach-Object { [Convert]::ToByte($hex.Substring($_ * 2, 2), 16) }); $d.CreateDecryptor($k, (New-Object byte[] 8)).TransformFinalBlock($in, 0, 8) }
Check 'dummy round-trips' (([Text.Encoding]::ASCII.GetString((Undo-Vnc $hx))).TrimEnd([char]0) -eq '0000')
$priv = '/home/box/shared/button-launcher/private/vnc-viewonly.txt'   # box-only real value: round-trip only, never printed
if (Test-Path -LiteralPath $priv) {
    $pb = [IO.File]::ReadAllBytes($priv); $len = $pb.Length; while ($len -gt 0 -and $pb[$len - 1] -in 10, 13, 32) { $len-- }
    $pw = New-Object byte[] ([Math]::Min(8, $len)); [Array]::Copy($pb, $pw, $pw.Length)
    $rt = Undo-Vnc (ConvertTo-VncObfuscated $pw); $same = $true; for ($i = 0; $i -lt 8; $i++) { $exp = if ($i -lt $pw.Length) { $pw[$i] } else { 0 }; if ($rt[$i] -ne $exp) { $same = $false } }
    Check 'real view-only value round-trips (value not shown)' $same
    [Array]::Clear($pb, 0, $pb.Length); [Array]::Clear($pw, 0, $pw.Length); [Array]::Clear($rt, 0, $rt.Length) }
$txt = New-VncConfigText '192.168.1.20' 5900 $hx $true
Check '.vnc: [connection] host/port/password + [options] viewonly=1 AutoScaling=1' ($txt -match '(?m)^\[connection\]\r?$' -and $txt -match '(?m)^host=192\.168\.1\.20\r?$' -and $txt -match '(?m)^port=5900\r?$' -and $txt -match "(?m)^password=$hx\r?$" -and $txt -match '(?m)^viewonly=1\r?$' -and $txt -match '(?m)^AutoScaling=1\r?$')
$threw = $false; try { [void](New-VncConfigText "reg`r`nport=1" 5900 $hx $true) } catch { $threw = $true }; Check '.vnc: newline injection in host throws' $threw
$threw = $false; try { [void](New-VncConfigText 'reg1' 5900 'zz' $true) } catch { $threw = $true }; Check '.vnc: bad hex throws' $threw

# --- favourites + cache persistence ---
$cfg = [pscustomobject]@{ vnc = [pscustomobject]@{ port = '5901'; prefix = 16; favorites = @(
    [pscustomobject]@{ host = 'REG1'; port = 5900; name = "Register 1`u{0007}"; pinned = $true },
    [pscustomobject]@{ host = 'bad host;x'; port = 5900; name = 'evil' },
    [pscustomobject]@{ host = '192.168.1.30'; port = 'abc'; name = 'P' }) } }
$st = Get-VncState $cfg
Check 'state: port from config, prefix capped at 22' ($st.port -eq 5901 -and $st.prefix -eq 22)
Check 'state: invalid favourite dropped, names cleaned, bad port -> default' ($st.favorites.Count -eq 2 -and $st.favorites[0].name -eq 'Register 1' -and $st.favorites[1].port -eq 5901)
Check 'favourite: bad host refused' (-not (Set-VncFavorite $st.favorites 'x y' 5900 'n' $true))
Check 'favourite: add by hand' ((Set-VncFavorite $st.favorites '192.168.1.44' 5900 'Register 2' $true) -and $st.favorites.Count -eq 3)
[void](Set-VncFavorite $st.favorites 'REG1' 5900 'Front Register' $null); Check 'favourite: rename keeps pin' ($st.favorites[0].name -eq 'Front Register' -and $st.favorites[0].pinned)
Save-VncFavorites $cfg $st.favorites
$back = Get-VncState (($cfg | ConvertTo-Json -Depth 6) | ConvertFrom-Json)
Check 'favourites survive a JSON round trip' ($back.favorites.Count -eq 3 -and $back.favorites[2].host -eq '192.168.1.44' -and $back.favorites[2].name -eq 'Register 2')
Check 'favourites JSON has no password field' (($cfg | ConvertTo-Json -Depth 6) -notmatch '(?i)passw')
$cfg0 = [pscustomobject]@{}; $s0 = Get-VncState $cfg0; Check 'missing vnc block created with defaults' ($cfg0.vnc -and $s0.port -eq 5900 -and $s0.prefix -eq 24 -and $s0.favorites.Count -eq 0)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vnctest-' + [guid]::NewGuid().ToString('N') + '.json')
$now = [datetime]::UtcNow
Save-VncCache $tmp @([pscustomobject]@{ host = '192.168.1.20'; port = 5900; name = 'reg1'; banner = 'RFB 003.008' }) $now
$c = Read-VncCache $tmp
Check 'cache round trip' (@($c.hosts).Count -eq 1 -and $c.hosts[0].banner -eq 'RFB 003.008' -and [Math]::Abs(($c.time - $now).TotalSeconds) -lt 1)
Check 'cache fresh now, stale after a day' (-not (Test-VncCacheStale $c $now) -and (Test-VncCacheStale $c $now.AddHours(25)))
Check 'cache with a future time counts as stale' (Test-VncCacheStale $c $now.AddHours(-1))
Set-Content -LiteralPath $tmp -Value '{"time":"x","hosts":[{"host":"8.8.8.8;x","port":5900},{"host":"192.168.1.5","port":5900,"name":"bad name!","banner":"RFB\u0007 003"}]}'
$c = Read-VncCache $tmp
Check 'cache re-validates hosts, names and banners' (@($c.hosts).Count -eq 1 -and $c.hosts[0].name -eq '' -and $c.hosts[0].banner -notmatch '[\x00-\x1F]' -and (Test-VncCacheStale $c $now))
Remove-Item -LiteralPath $tmp -Force
Check 'missing cache: empty and stale' ((Test-VncCacheStale (Read-VncCache '/nonexistent/x.json') $now))
$rows = Merge-VncRows $back.favorites @([pscustomobject]@{ host = '192.168.1.9'; port = 5901; name = 'r9'; banner = 'RFB 003.008' }, [pscustomobject]@{ host = '192.168.1.44'; port = 5900; name = 'dns44'; banner = 'RFB 003.889' })
Check 'rows: pinned favourites first, by name; then the rest by address' ($rows.Count -eq 4 -and $rows[0].name -eq 'Front Register' -and $rows[1].name -eq 'Register 2' -and $rows[1].banner -eq 'RFB 003.889' -and $rows[2].host -eq '192.168.1.9' -and -not $rows[2].fav -and $rows[3].host -eq '192.168.1.30' -and -not $rows[3].pinned)

# --- backward compatibility: which buttons open the picker ---
Check 'new default: vncPicker true' (Test-VncPickerButton ([pscustomobject]@{ type = 'program'; vncPicker = $true }))
Check 'vncPicker false keeps the old launch' (-not (Test-VncPickerButton ([pscustomobject]@{ type = 'program'; vncPicker = $false; detect = [pscustomobject]@{ lnkNames = @('UltraVNC Viewer') } })))
Check 'old stock View Register (no flag, no args) gets the picker' (Test-VncPickerButton ([pscustomobject]@{ type = 'program'; target = ''; args = ''; detect = [pscustomobject]@{ lnkNames = @('UltraVNC Viewer') } }))
Check 'old button with a host in args keeps working as before' (-not (Test-VncPickerButton ([pscustomobject]@{ type = 'program'; target = 'C:\x\vncviewer.exe'; args = '192.168.1.5' })))
Check 'other programs are untouched' (-not (Test-VncPickerButton ([pscustomobject]@{ type = 'program'; target = 'C:\x\notepad.exe'; args = '' })))
$def = Get-Content (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
$vr = @($def.panels | ForEach-Object { $_.buttons }) | Where-Object { $_.label -eq 'VIEW REGISTER' }
Check 'buttons.default.json: View Register has vncPicker, vnc block defaults' ($vr.vncPicker -eq $true -and $def.vnc.port -eq 5900 -and $def.vnc.prefix -eq 24)

# --- source checks: scan behaviour, launch, secrets ---
$fn = { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text }
$scan = [regex]::Match($src, '(?s)\$global:VncScanScript = \{.*?\n\}').Value
Check 'scan: reads at most 12 bytes, never writes to the socket' ($scan -match 'New-Object byte\[\] 12' -and $scan -match '12 - \$got' -and $scan -notmatch '\.Write\(' -and $scan -notmatch 'BeginSend|\.Send\(')
Check 'scan: connect timeout, batch of $parallel, paced, cancellable' ($scan -match 'BeginConnect' -and $scan -match 'WaitOne\(\$left\)' -and $scan -match 'Start-Sleep -Milliseconds \$paceMs' -and $scan -match '\$sync\.cancel')
Check 'scan: 300 ms, 16 at a time' ($src -match '\$global:VncTimeoutMs\s+= 300' -and $src -match '\$global:VncParallel\s+= 16')
Check 'scan only from the picker (open when stale, or Rescan)' (([regex]::Matches($src, 'Start-VncScan \$ui')).Count -ge 3 -and ([regex]::Match($src, '(?s)# =+ MAIN.*').Value -notmatch 'VncScan|Show-VncPicker'))
Check 'picker: closing cancels the scan' ((& $fn 'Show-VncPicker') -match 'Add_Closed\(\{ Stop-VncScan')
Check 'picker: Enter = View only' ((& $fn 'Show-VncPicker') -match "Key -eq 'Enter'[^\n]*& \`$go \`$true")
$vncSrc = [regex]::Match($src, '(?s)# ---------- VNC register picker.*?# =+ MAIN').Value
Check 'VNC code: no -password switch, no Invoke-Expression, no cmd /c' ($vncSrc -notmatch "'-password'" -and $vncSrc -notmatch 'Invoke-Expression|iex ' -and $vncSrc -notmatch 'cmd(\.exe)?\s*/c')
Check 'launch: Start-Process with an argument list from Get-VncViewerArgs' ((& $fn 'Start-VncViewer') -match 'Start-Process -FilePath \$exe -ArgumentList \(Get-VncViewerArgs')
Check 'viewer path must be a local fixed path' ((& $fn 'Find-VncViewer') -match 'Test-LocalFixedPath \$f' -and (& $fn 'Find-VncViewer') -match 'App Paths\\vncviewer\.exe')
Check 'secret: DPAPI CurrentUser + entropy, plaintext zeroed' ((& $fn 'Save-VncSecret') -match "ProtectedData\]::Protect\(\`$raw, \`$global:VncEntropy, 'CurrentUser'\)" -and (& $fn 'Save-VncSecret') -match 'ZeroFreeBSTR' -and (& $fn 'Get-VncSecretHex') -match 'Array\]::Clear')
Check 'secret: separate file, not buttons.json' ((& $fn 'Get-VncSecretPath') -match "'vnc-viewonly\.dat'")
Check 'interact never uses the saved password' ((& $fn 'Start-VncViewer') -match 'if \(\$viewOnly\) \{' -and ([regex]::Matches((& $fn 'Start-VncViewer'), 'Get-VncSecretHex')).Count -eq 1 -and (& $fn 'Start-VncViewer') -match '(?s)if \(\$viewOnly\) \{.*Get-VncSecretHex.*\}\s*try')
Check 'temp .vnc: random folder, protected ACL for this user, CreateNew, deleted soon + leftovers' ((& $fn 'New-VncTempConfig') -match "bl-vnc-' \+ \[guid\]" -and (& $fn 'New-VncTempConfig') -match 'SetAccessRuleProtection\(\$true, \$false\)' -and (& $fn 'New-VncTempConfig') -match 'CreateNew' -and (& $fn 'Start-VncViewer') -match 'Remove-VncTempSoon' -and (& $fn 'Show-VncPicker') -match 'Remove-VncTempLeftovers')
Check 'password box is a PasswordBox, read as SecurePassword' ((& $fn 'Show-VncPasswordDialog') -match 'Controls\.PasswordBox' -and (& $fn 'Show-VncPasswordDialog') -match 'SecurePassword' -and (& $fn 'Show-VncPasswordDialog') -notmatch '\.Password\b')
Check 'Setup menu has the view-only password item' ($src -match "Add-MenuItem \`$setup 'View-only register password\.\.\.'")
Check 'ScreenConnect elevation and force-restart confirm unchanged' ($src -match "Start-Process powershell\.exe -Verb RunAs -WindowStyle Hidden -PassThru" -and $src -match 'CC-M4/LJ-L3: force restart ALWAYS asks')
Check 'no PS7-only syntax in the VNC code' ($vncSrc -notmatch '\?\?|\?\.|\s\?\s[^:]+\s:\s|ForEach-Object -Parallel|&&|\|\|')

if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
