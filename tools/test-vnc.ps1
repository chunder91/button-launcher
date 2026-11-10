# VNC picker checks that run without Windows: validation, argument building, subnet math, banner parsing,
# the .vnc file and its password obfuscation, favourites and cache persistence, and source checks for the scan.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Launcher.ps1'), [ref]$null, [ref]$null)
$src = $ast.Extent.Text
$fns = 'Set-Prop', 'Get-VncLaunchLogText', 'Get-ButtonType', 'Test-VncIPv4', 'Test-VncHost', 'Get-VncPort', 'ConvertTo-VncEndpoint', 'Test-Rfc1918', 'ConvertTo-VncUInt', 'ConvertFrom-VncUInt',
       'Get-VncPrefix', 'Get-VncScanTargets', 'Get-SafeText', 'Get-RfbBanner', 'Get-VncViewerArgs', 'ConvertTo-VncObfuscated', 'New-VncConfigText', 'Get-VncState',
       'Save-VncFavorites', 'Set-VncFavorite', 'Read-VncCache', 'Save-VncCache', 'Test-VncCacheStale', 'Merge-VncRows', 'Test-VncPickerButton',
       'Test-VncAdapter', 'Get-VncRangeText', 'Get-VncNewRanges', 'Test-VncAutoScan', 'Test-VncBannerText', 'Get-VncDisplayName', 'Get-VncInvalidText',
       'Get-VncRowView', 'Get-VncShortName', 'Get-VncFoundText', 'Test-VncUsePassword', 'Get-VncPasswordFallbackText', 'Get-VncRemoveButtonVisibility', 'Get-VncWorkerFault', 'Get-VncTempAction', 'Remove-VncTempDir',
       'Get-VncSubnetGateway', 'Get-VncRangeKey', 'Get-VncRangeState', 'Get-VncAgeText', 'Test-VncRangeKeyCurrent', 'ConvertTo-VncGatewayId', 'Select-VncGatewayMac', 'ConvertTo-VncNicId'
foreach ($n in $fns) {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(VncDesKey|VncCacheMaxAge|VncAdapterDeny)\s*=') { Invoke-Expression $l.Extent.Text } }

# --- host / port validation (untrusted input) ---
foreach ($h in '192.168.1.20', '10.0.0.1', '0.0.0.0', '255.255.255.255', 'REG1', 'reg-1.shop.local', 'a', ('a' * 63), 'reg1.') { Check "host ok: $($h.Substring(0, [Math]::Min(20, $h.Length)))" (Test-VncHost $h) }
foreach ($h in '', '256.1.1.1', '1.2.3', '1.2.3.4.5', '01.2.3.4', '-reg', 'reg-', 'a..b', ('a' * 64), (((('a' * 60) + '.') * 5)), 'reg 1', 'reg;calc', 'reg&x', 'reg"x', "reg`nx", 'reg_1', '-config', 'h:1', '[::1]', ('r' + [char]0xE9 + [char]0x433), 'reg/x', 'C:\x') {
    Check ("host rejected: " + ($h -replace '[^\x20-\x7E]', '?')) (-not (Test-VncHost $h)) }
Check 'hostname max 253 chars ok' (Test-VncHost (((('a' * 63) + '.') * 3) + ('a' * 61)))
Check 'port 1 and 65535 ok' ((Get-VncPort 1) -eq 1 -and (Get-VncPort '65535') -eq 65535)
foreach ($p in 0, 65536, -1, '5900x', '', $null, '1e3', ' ', '5900.0', '99999999') { Check "port rejected: '$p'" ($null -eq (Get-VncPort $p)) }
$e = ConvertTo-VncEndpoint 'reg1:5901'; Check 'endpoint host:port' ($e.host -eq 'reg1' -and $e.port -eq 5901)
$e = ConvertTo-VncEndpoint 'reg1::5902'; Check 'endpoint host::port' ($e.host -eq 'reg1' -and $e.port -eq 5902)
$e = ConvertTo-VncEndpoint ' 192.168.1.9 ' 5900; Check 'endpoint default port, trimmed' ($e.host -eq '192.168.1.9' -and $e.port -eq 5900)
foreach ($t in 'reg1:0', 'reg1:70000', 'reg1:a', 'a:b:c', 'reg 1', '') { Check "endpoint rejected: '$t'" ($null -eq (ConvertTo-VncEndpoint $t)) }

# --- viewer arguments (verified switches: host::port,, -viewonly, -config) ---
$a = Get-VncViewerArgs '192.168.1.20' 5900 $false $null
Check 'interact: host:port, no -viewonly' (($a -join ' ') -eq '192.168.1.20:5900 -autoscaling')
$a = Get-VncViewerArgs 'reg1' 5901 $true $null
Check 'view only: host:port -viewonly' (($a -join ' ') -eq 'reg1:5901 -viewonly -autoscaling')
$a = Get-VncViewerArgs 'reg1' 5901 $true 'C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc'
Check 'v1.4.4: view only + saved password: host:port -config "<file>" -viewonly, no password in argv' (($a -join ' ') -ceq 'reg1:5901 -config "C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc" -viewonly -autoscaling')
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
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("RFB 003.008`n")); Check 'banner RFB 003.008\n' ($b.text -eq 'RFB 003.008' -and $b.rfb)
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("RFB 003.889`n")); Check 'banner UltraVNC 3.889 accepted' ($b.rfb)
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("RFB 003.008 ")); Check 'L4: no trailing \n -> not RFB' (-not $b.rfb)
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("RFB 3.8`n")); Check 'L4: short version -> not RFB' (-not $b.rfb)
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("rfb 003.008`n")); Check 'L4: lower-case -> not RFB' (-not $b.rfb)
$b = Get-RfbBanner ([Text.Encoding]::ASCII.GetBytes("SSH-2.0-OpenSSH_9.6`r`n")); Check 'non-RFB: not RFB, text max 12' (-not $b.rfb -and $b.text.Length -le 12)
$b = Get-RfbBanner ([byte[]](0x1B, 0x5B, 0x32, 0x4A, 0x07, 0x00, 0x52, 0x46, 0x42)); Check 'control chars stripped' ($b.text -notmatch '[\x00-\x1F\x7F]' -and -not $b.rfb)
$b = Get-RfbBanner ([byte[]]@()); Check 'empty banner' ($b.text -eq '' -and -not $b.rfb)
$b = Get-RfbBanner ([byte[]](1..200 | ForEach-Object { 65 })); Check 'only the first 12 bytes are used' ($b.text.Length -eq 12 -and -not $b.rfb)
Check 'banner text check' ((Test-VncBannerText 'RFB 003.008') -and -not (Test-VncBannerText 'RFB 003.008x') -and -not (Test-VncBannerText ''))
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
$long = 'Register at the very back of the shop by the loading door'   # 57 chars
$cfg = [pscustomobject]@{ vnc = [pscustomobject]@{ port = '5901'; prefix = 16; favorites = @(
    [pscustomobject]@{ host = 'REG1'; port = 5900; name = 'Register 1'; pinned = $true },
    [pscustomobject]@{ host = 'bad host;x'; port = 5900; name = 'evil'; extra = 'kept' },
    [pscustomobject]@{ host = '192.168.1.30'; name = $long },
    [pscustomobject]@{ host = '192.168.1.31'; port = 'abc'; name = 'P' }) } }
$st = Get-VncState $cfg
Check 'state: port from config, prefix capped at 22' ($st.port -eq 5901 -and $st.prefix -eq 22)
Check 'L5: invalid favourites kept aside, not dropped' ($st.favorites.Count -eq 2 -and $st.invalid.Count -eq 2 -and $st.invalid[0].extra -eq 'kept')
Check 'L5: long name kept whole in state, missing port -> default' ($st.favorites[1].name -eq $long -and $st.favorites[1].port -eq 5901)
Check 'L5: long name shown with an ellipsis' ((Get-VncDisplayName $long 40).Length -eq 40 -and (Get-VncDisplayName $long 40).EndsWith([string][char]0x2026) -and (Get-VncDisplayName 'Register 1' 40) -eq 'Register 1')
Check 'L5: warning names the hidden entries' ((Get-VncInvalidText $st.invalid) -match '^2 saved computer\(s\).*bad host;x' -and (Get-VncInvalidText @()) -eq '')
Check 'favourite: bad host refused' (-not (Set-VncFavorite $st.favorites 'x y' 5900 'n' $true))
Check 'favourite: add by hand is not pinned' ((Set-VncFavorite $st.favorites '192.168.1.44' 5900 'Register 2' $null) -and $st.favorites.Count -eq 3 -and -not $st.favorites[2].pinned)
[void](Set-VncFavorite $st.favorites 'REG1' 5900 'Front Register' $null); Check 'rename keeps the pin state' ($st.favorites[0].name -eq 'Front Register' -and $st.favorites[0].pinned)
[void](Set-VncFavorite $st.favorites '192.168.1.44' 5900 'Reg 2' $null); Check 'Squint 4: naming never pins' (-not $st.favorites[2].pinned)
[void](Set-VncFavorite $st.favorites '192.168.1.44' 5900 $null $true); Check 'star toggles pin without renaming' ($st.favorites[2].pinned -and $st.favorites[2].name -eq 'Reg 2')
[void](Set-VncFavorite $st.favorites '192.168.1.44' 5900 $null $false); [void](Set-VncFavorite $st.favorites '192.168.1.44' 5900 'Register 2' $null)
Save-VncFavorites $cfg $st.favorites $st.invalid
$json = $cfg | ConvertTo-Json -Depth 6
$back = Get-VncState ($json | ConvertFrom-Json)
Check 'favourites survive a JSON round trip' ($back.favorites.Count -eq 3 -and $back.favorites[2].host -eq '192.168.1.44' -and $back.favorites[2].name -eq 'Register 2')
Check 'L5: invalid entries written back untouched, long name not cut' ($back.invalid.Count -eq 2 -and $json -match 'bad host;x' -and $json -match '"extra":\s*"kept"' -and $json -match [regex]::Escape($long))
Check 'favourites JSON has no password field' ($json -notmatch '(?i)passw')
$cfg0 = [pscustomobject]@{}; $s0 = Get-VncState $cfg0; Check 'missing vnc block created with defaults' ($cfg0.vnc -and $s0.port -eq 5900 -and $s0.prefix -eq 24 -and $s0.favorites.Count -eq 0 -and @($s0.confirmed).Count -eq 0)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vnctest-' + [guid]::NewGuid().ToString('N') + '.json')
$now = [datetime]::UtcNow
Save-VncCache $tmp @([pscustomobject]@{ host = '192.168.1.20'; port = 5900; name = 'reg1'; banner = 'RFB 003.008' }) $now
$c = Read-VncCache $tmp
Check 'cache round trip' (@($c.hosts).Count -eq 1 -and $c.hosts[0].banner -eq 'RFB 003.008' -and [Math]::Abs(($c.time - $now).TotalSeconds) -lt 1)
Check 'cache fresh now, stale after a day' (-not (Test-VncCacheStale $c $now) -and (Test-VncCacheStale $c $now.AddHours(25)))
Check 'cache with a future time counts as stale' (Test-VncCacheStale $c $now.AddHours(-1))
Save-VncCache $tmp @() $now; $c0 = Read-VncCache $tmp
Check 'L3: an empty result from an hour ago is not stale' (@($c0.hosts).Count -eq 0 -and -not (Test-VncCacheStale $c0 $now.AddHours(1)) -and (Test-VncCacheStale $c0 $now.AddDays(2)))
Set-Content -LiteralPath $tmp -Value ('{"time":"x","hosts":[{"host":"8.8.8.8;x","port":5900},{"host":"192.168.1.5","port":5900,"name":"bad name!","banner":"RFB 003.008"},' +
    '{"host":"192.168.1.6","port":5900,"banner":"SSH-2.0"},{"host":"192.168.1.7","port":5900,"banner":"RFB\u0007 003"}]}')
$c = Read-VncCache $tmp
Check 'cache re-validates hosts and names; L4 drops non-RFB rows' (@($c.hosts).Count -eq 1 -and $c.hosts[0].host -eq '192.168.1.5' -and $c.hosts[0].name -eq '' -and (Test-VncCacheStale $c $now))
Remove-Item -LiteralPath $tmp -Force
Check 'missing cache: stale' ((Test-VncCacheStale (Read-VncCache '/nonexistent/x.json') $now))
$rows = Merge-VncRows $back.favorites @([pscustomobject]@{ host = '192.168.1.9'; port = 5901; name = 'r9'; banner = 'RFB 003.008' }, [pscustomobject]@{ host = '192.168.1.44'; port = 5900; name = 'dns44'; banner = 'RFB 003.889' })
Check 'rows: pinned first, then the rest by address' ($rows.Count -eq 4 -and $rows[0].name -eq 'Front Register' -and $rows[1].host -eq '192.168.1.9' -and $rows[2].host -eq '192.168.1.30' -and $rows[3].name -eq 'Register 2' -and $rows[3].banner -eq 'RFB 003.889')
Check 'rows: seen = in the latest scan' ($rows[0].seen -eq $false -and $rows[1].seen -and $rows[3].seen -and -not $rows[2].seen)
$v = Get-VncRowView ([pscustomobject]@{ host = '192.168.1.77'; port = 5900; name = ''; banner = 'RFB 003.008'; pinned = $false; fav = $false; seen = $true }) $true $false
Check "Squint 1: unnamed row reads 'Unnamed (F2 to name)' in grey" ($v.nameText -eq 'Unnamed (F2 to name)' -and $v.nameFg -eq '#A0A0A0' -and $v.seen -eq 'Now' -and $v.tip -match 'RFB 003\.008' -and $v.addr -eq '192.168.1.77')
$v = Get-VncRowView $rows[0] $true $false
Check 'Squint 3: not-found row greyed, Seen = Not found last scan; pinned = E735' ($v.seen -eq 'Not found last scan' -and $v.addrFg -eq '#A0A0A0' -and $v.star -eq [string][char]0xE735 -and $v.starOn -and $v.starName -eq 'Pinned')
$v = Get-VncRowView $rows[0] $true $true; Check "while scanning an unseen row says 'Looking...'" ($v.seen -eq 'Looking...' -and $v.addrFg -eq '#FFFFFF')
$v = Get-VncRowView $rows[1] $false $false; Check "cached row says 'Earlier'; port shown when not 5900" ($v.seen -eq 'Earlier' -and $v.addr -eq '192.168.1.9:5901' -and -not $v.starOn -and $v.star -eq [string][char]0xE734)
Check 'Kern 6/L5: long name in the row has an ellipsis' ((Get-VncRowView $rows[2] $true $false).nameText.EndsWith([string][char]0x2026))

# --- L4: password file only to an RFB host ---
Check 'a row with no host never gets a password file' (-not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889' }) $false))

# --- H1: adapters, ranges, confirmation, favourites-first ---
Check 'H1: Ethernet with gateway in its subnet' (Test-VncAdapter 'Ethernet' 'Intel(R) Ethernet Connection I219-LM' 'Ethernet' '192.168.1.37' 24 @('192.168.1.1'))
Check 'H1: Wi-Fi with gateway in its subnet' (Test-VncAdapter 'Wireless80211' 'Intel(R) Wi-Fi 6 AX201' 'Wi-Fi' '10.0.5.20' 16 @('10.0.0.1'))
foreach ($ty in 'Ppp', 'Tunnel', 'Loopback', 'Unknown', 'Wwanpp', 'Ethernet3Megabit') { Check "H1: type $ty never scanned" (-not (Test-VncAdapter $ty 'x' 'x' '192.168.1.37' 24 @('192.168.1.1'))) }
foreach ($d in 'Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter', 'PANGP Virtual Ethernet Adapter', 'Fortinet SSL VPN Virtual Ethernet Adapter', 'TAP-Windows Adapter V9',
               'WireGuard Tunnel', 'Wintun Userspace Tunnel', 'Hyper-V Virtual Ethernet Adapter', 'VirtualBox Host-Only Ethernet Adapter', 'VMware Virtual Ethernet Adapter for VMnet8',
               'Npcap Loopback Adapter', 'Zscaler Network Adapter', 'OpenVPN Data Channel Offload', 'Tailscale Tunnel', 'ZeroTier Virtual Port', 'WAN Miniport (IKEv2)') {
    Check "H1: '$d' never scanned" (-not (Test-VncAdapter 'Ethernet' $d 'Ethernet 2' '192.168.1.37' 24 @('192.168.1.1'))) }
foreach ($n in 'vEthernet (WSL)', 'vEthernet (Default Switch)', 'VPN - Office', 'tun0', 'WSL') { Check "H1: adapter named '$n' never scanned" (-not (Test-VncAdapter 'Ethernet' 'Generic adapter' $n '172.20.1.5' 20 @('172.20.0.1'))) }
Check 'v1.4.0: physical Ethernet with no gateway (isolated register LAN) -> scanned' ((Test-VncAdapter 'Ethernet' 'Realtek PCIe GbE' 'Ethernet' '192.168.1.37' 24 @()))
Check 'H1: gateway outside the subnet -> not scanned' (-not (Test-VncAdapter 'Ethernet' 'Realtek PCIe GbE' 'Ethernet' '192.168.1.37' 24 @('192.168.2.1')))
Check 'v1.4.0: 0.0.0.0 gateway counts as no gateway -> scanned' (Test-VncAdapter 'Ethernet' 'Realtek PCIe GbE' 'Ethernet' '192.168.1.37' 24 @('0.0.0.0'))
Check 'H1: public address -> not scanned' (-not (Test-VncAdapter 'Ethernet' 'Realtek PCIe GbE' 'Ethernet' '8.8.4.4' 24 @('8.8.4.1')))
Check 'range text /24 default' ((Get-VncRangeText '192.168.1.37' 24 $null) -eq '192.168.1.0/24' -and (Get-VncRangeText '10.5.6.7' 16 $null) -eq '10.5.6.0/24')
Check 'range text /22 setting, /26 adapter' ((Get-VncRangeText '10.5.6.7' 16 22) -eq '10.5.4.0/22' -and (Get-VncRangeText '192.168.1.70' 26 24) -eq '192.168.1.64/26')
Check 'new ranges: only unconfirmed' ((@(Get-VncNewRanges @('192.168.1.0/24', '10.0.0.0/24') @('192.168.1.0/24')) -join ',') -eq '10.0.0.0/24' -and @(Get-VncNewRanges @('192.168.1.0/24') @('192.168.1.0/24')).Count -eq 0)
Check 'new ranges: a changed range asks again' (@(Get-VncNewRanges @('192.168.2.0/24') @('192.168.1.0/24')).Count -eq 1)
$fresh = @{ time = $now; hosts = @() }; $old = @{ time = $now.AddDays(-3); hosts = @() }
Check 'favourites-first: favourites + old cache + no new range -> no scan on open' (-not (Test-VncAutoScan $true $old $now $false))
Check 'favourites-first: favourites + new range -> scan (after the confirm)' (Test-VncAutoScan $true $fresh $now $true)
Check 'no favourites: stale cache scans, fresh does not' ((Test-VncAutoScan $false $old $now $false) -and -not (Test-VncAutoScan $false $fresh $now $false))
$scanSrc = (& { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text } 'Get-VncScanPlan')
Check 'H1/Squint 2: plain confirm text, Yes from Rescan / No on open, remembered in vnc.confirmedRanges' ($scanSrc -match "Look for computers you can view on this network \(\{1\}\)\?" -and $scanSrc -match "This quickly checks this network for computers you can view" -and $scanSrc -match "'YesNo', 'Question', \`$\(if \(\`$Ask\) \{ 'Yes' \} else \{ 'No' \}\)" -and $scanSrc -match "Set-Prop \`$global:cfg\.vnc 'confirmedRanges'")

# --- M1: worker state ---
function FakePs($state, $msg) { [pscustomobject]@{ InvocationStateInfo = [pscustomobject]@{ State = $state; Reason = $(if ($msg) { New-Object Exception $msg } else { $null }) } } }
Check 'M1: running worker is fine' ((Get-VncWorkerFault (FakePs 'Running' $null) $false) -eq '')
Check 'M1: failed worker gives its reason' ((Get-VncWorkerFault (FakePs 'Failed' 'runspace broke') $false) -eq 'runspace broke')
Check 'M1: completed without done = ended early' ((Get-VncWorkerFault (FakePs 'Completed' $null) $false) -ne '' -and (Get-VncWorkerFault (FakePs 'Completed' $null) $true) -eq '')
Check 'M1: stopped without done = fault' ((Get-VncWorkerFault (FakePs 'Stopped' $null) $false) -ne '')
$step = (& { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text } 'Step-VncScan')
Check 'M1: Step checks the worker each tick, shows the reason, stops the timer' ($step -match 'Get-VncWorkerFault \$sc\.ps' -and $step -match "Scan failed: " -and $step -match 'Stop-VncScan \$ui' -and $step -match 'Get-VncWorkerFault \$sc\.nameps')
$stop = (& { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text } 'Stop-VncScan')
Check 'M1: Stop always stops the timer (no idle timer)' ($stop -match '^\S.*\{\s*\r?\n\s*if \(\$ui\.timer\) \{ \$ui\.timer\.Stop\(\) \}')
$startSrc = (& { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text } 'Start-VncScan')
Check 'L1: Rescan first stops and disposes the old workers (names too)' ($startSrc -match '^\S.*\{\s*\r?\n\s*Stop-VncScan \$ui' -and $stop -match 'nameps' -and $stop -match 'namers' -and $stop -match 'Dispose')

# --- M2 + V13-L1: temp file deletion ---
Check 'M2: wait while the viewer starts' ((Get-VncTempAction 1 $false $false -1) -eq 'wait' -and (Get-VncTempAction 4 $false $true 2) -eq 'wait')
Check 'M2: delete 3 s after its window shows' ((Get-VncTempAction 5 $false $true 2) -eq 'delete')
Check 'M2: delete at 8 s regardless' ((Get-VncTempAction 8 $false $false -1) -eq 'delete')
Check 'M2: quit within 6 s = early (wrong password), still deleted' ((Get-VncTempAction 3 $true $false -1) -eq 'early' -and (Get-VncTempAction 7 $true $true 2) -eq 'delete')
$soon = (& { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text } 'Remove-VncTempSoon')
Check 'M2: no WaitForInputIdle anywhere; polled' ($src -notmatch 'WaitForInputIdle' -and $src -match 'function global:Get-VncProcState[^\n]*\n[^\n]*\n[^\n]*MainWindowHandle' -and $soon -match 'Get-VncProcState' -and $soon -match 'Get-VncTempAction')
$base = Join-Path ([IO.Path]::GetTempPath()) ('vnct-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory $base)
$d1 = Join-Path $base ('bl-vnc-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory $d1); Set-Content (Join-Path $d1 'c.vnc') 'x'
Check 'V13-L1: folder with only c.vnc is removed' ((Remove-VncTempDir $d1) -and -not (Test-Path $d1))
$d2 = Join-Path $base ('bl-vnc-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory $d2); Set-Content (Join-Path $d2 'c.vnc') 'x'; Set-Content (Join-Path $d2 'other.txt') 'keep'
Check 'V13-L1: folder holding anything else is left alone' (-not (Remove-VncTempDir $d2) -and (Test-Path (Join-Path $d2 'other.txt')) -and (Test-Path (Join-Path $d2 'c.vnc')))
$d3 = Join-Path $base 'not-ours'; [void](New-Item -ItemType Directory $d3); Set-Content (Join-Path $d3 'c.vnc') 'x'
Check 'V13-L1: a folder not named bl-vnc-<guid> is never touched' (-not (Remove-VncTempDir $d3) -and (Test-Path (Join-Path $d3 'c.vnc')))
$d4 = Join-Path $base ('bl-vnc-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory $d4); [void](New-Item -ItemType Directory (Join-Path $d4 'c.vnc'))
Check 'V13-L1: a c.vnc folder is not deleted' (-not (Remove-VncTempDir $d4) -and (Test-Path (Join-Path $d4 'c.vnc')))
Remove-Item -LiteralPath $base -Recurse -Force
$vncSrc0 = [regex]::Match($src, '(?s)# ---------- VNC register picker.*?# =+ MAIN').Value
Check 'V13-L1: no Remove-Item -Recurse in the VNC code' ($vncSrc0 -notmatch 'Remove-Item[^\n]*-Recurse')
$tcfg = (& { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text } 'New-VncTempConfig')
Check 'nit: temp config creation in try/finally, cleaned on failure' ($tcfg -match '(?s)try \{.*CreateDirectory.*\} finally \{ if \(-not \$ok\) \{ \[void\]\(Remove-VncTempDir \$dir\) \} \}')

# --- V13-I1: Latin-1 only ---
$sv = (& { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text } 'Save-VncSecret')
Check 'V13-I1: characters above 0xFF are refused before anything is saved' ($sv -match '(?s)-gt 0xFF\) \{ return \$false \}.*ProtectedData')

# --- backward compatibility: which buttons open the picker (L2) ---
$stock = { [pscustomobject]@{ label = 'VIEW REGISTER'; type = 'program'; target = ''; args = ''; askTitle = 'Pick the UltraVNC Viewer (vncviewer.exe)'; detect = [pscustomobject]@{ lnkNames = @('UltraVNC Viewer') } } }
Check 'new default: vncPicker true' (Test-VncPickerButton ([pscustomobject]@{ type = 'program'; vncPicker = $true }))
Check 'vncPicker false keeps the old launch' (-not (Test-VncPickerButton ([pscustomobject]@{ label = 'VIEW REGISTER'; type = 'program'; vncPicker = $false; detect = [pscustomobject]@{ lnkNames = @('UltraVNC Viewer') } })))
Check 'old stock View Register (no flag, no args) gets the picker' (Test-VncPickerButton (& $stock))
$sb = & $stock; $sb.label = "VIEW`nREGISTER"; Check 'stock label split over lines still matches' (Test-VncPickerButton $sb)
$sb = & $stock; $sb.args = '192.168.1.5'; Check 'old button with a host in args keeps working as before' (-not (Test-VncPickerButton $sb))
Check 'L2: another vncviewer button (other label) is not taken over' (-not (Test-VncPickerButton ([pscustomobject]@{ label = 'OFFICE VNC'; type = 'program'; target = 'C:\x\vncviewer.exe'; args = ''; detect = [pscustomobject]@{ lnkNames = @('UltraVNC Viewer') } })))
Check 'L2: a View Register label pointing at something else is not taken over' (-not (Test-VncPickerButton ([pscustomobject]@{ label = 'VIEW REGISTER'; type = 'program'; target = 'C:\x\other.exe'; args = '' })))
Check 'other programs are untouched' (-not (Test-VncPickerButton ([pscustomobject]@{ type = 'program'; target = 'C:\x\notepad.exe'; args = '' })))
$def = Get-Content (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
$vr = @($def.panels | ForEach-Object { $_.buttons }) | Where-Object { $_.label -eq 'VIEW REGISTER' }
Check 'buttons.default.json: View Register has vncPicker, vnc block defaults' ($vr.vncPicker -eq $true -and $def.vnc.port -eq 5900 -and $def.vnc.prefix -eq 24)

# --- source checks: scan behaviour, launch, secrets, picker UI ---
$fn = { param($n) $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true).Extent.Text }
$scan = [regex]::Match($src, '(?s)\$global:VncScanScript = \{.*?\n\}').Value
Check 'scan: reads at most 12 bytes, never writes to the socket' ($scan -match 'New-Object byte\[\] 12' -and $scan -match '12 - \$got' -and $scan -notmatch '\.Write\(' -and $scan -notmatch 'BeginSend|\.Send\(')
Check 'scan: connect timeout, batch of $parallel, paced, cancellable' ($scan -match 'BeginConnect' -and $scan -match 'WaitOne\(\$left\)' -and $scan -match 'Start-Sleep -Milliseconds \$paceMs' -and $scan -match '\$sync\.cancel')
Check 'L4: scan reports only exact RFB greetings' ($scan -match [regex]::Escape("-cmatch '^RFB \d{3}\.\d{3}\n$'") -and $scan -match '\$got -eq 12')
Check 'nit: sockets closed in finally (also on cancel)' ($scan -match '(?s)finally \{ foreach \(\$b in \$batch\) \{ try \{ \$b\.c\.Close\(\) \}')
Check 'scan: 300 ms, 16 at a time' ($src -match '\$global:VncTimeoutMs\s+= 300' -and $src -match '\$global:VncParallel\s+= 16')
$pk = & $fn 'Show-VncPicker'
$xaml = [regex]::Match($src, "(?s)\`$global:VncPickerXaml = @'.*?'@").Value
Check 'XAML parses as XML' ($(try { [void]([xml]($xaml -replace "^\`$global:VncPickerXaml = @'\r?\n", '' -replace "\r?\n'@$", '')); $true } catch { $false }))
Check 'Kern 1: one button row: View only, Interact | Rescan, Add..., More; 32 px; no WrapPanel; window still 620' ($xaml -notmatch 'WrapPanel' -and $xaml -match '(?s)x:Name="View".*x:Name="Interact".*x:Name="Rescan".*x:Name="Add".*x:Name="More"' -and $xaml -match 'Property="Height" Value="32"' -and $xaml -match 'Width="620"' -and $xaml -match 'Margin="8,0,0,0"' -and $xaml -match '&#xE712;' -and $xaml -match 'AutomationProperties.Name="More actions"')
Check 'Kern 2: Win11 selection: white 9%, 3x18 (v1.4.10) #22C55E pill, radius 6, hover 5%' ($xaml -match 'Value="#17FFFFFF"' -and $xaml -match 'Width="3" Height="18"[^>]*Fill="#22C55E"' -and $xaml -match 'x:Name="bg" CornerRadius="6"' -and $xaml -match 'Value="#0DFFFFFF"' -and $xaml -notmatch '#0B6E99"/>\s*</Trigger>')
Check 'Squint 7: title once (chrome), hint line, no H1' ($xaml -match 'Title="View Register"' -and $xaml -match 'Pick a computer\. View only to watch, Interact to take control\.' -and $xaml -notmatch 'FontSize="20"')
Check 'Squint 5: Interact tooltip' ($xaml -match [regex]::Escape("Take control of this computer's mouse and keyboard. Asks for the full password."))
$menu = & $fn 'New-VncRowMenu'
Check 'D2: gradient client area, radius 10 chips, stroke 28%->6%, sheen, list radius 10' ($xaml -match '#26262C' -and $xaml -match '#16161A' -and $xaml -match 'CornerRadius="10" Background="\{TemplateBinding Background\}"' -and $xaml -match '#47FFFFFF' -and $xaml -match '#0FFFFFFF' -and $xaml -match '#24FFFFFF' -and $xaml -match 'CornerRadius="10" Background="#2E000000"')
Check 'D2: primary gradients + hover/pressed per kern.md' ($xaml -match '#0E7A4B" Offset="0"/><GradientStop Color="#0A5A38"' -and $xaml -match '#187F52' -and $xaml -match '#0A5333' -and $xaml -match '#0B6E99" Offset="0"/><GradientStop Color="#085171"' -and $xaml -match '#15749D' -and $xaml -match '#074B68')
Check 'D2: hover lift 1 px, press 0.97, focus ring, disabled #2A2A2A/#8A8A8A, 2 px busy bar' ($xaml -match 'TranslateTransform Y="-1"' -and $xaml -match 'ScaleX="0.97"' -and $xaml -match 'x:Name="ring" CornerRadius="12"' -and $xaml -match 'Value="#2A2A2A"' -and $xaml -match 'Value="#8A8A8A"' -and $xaml -match 'ProgressBar x:Name="Busy"[^>]*Height="2"[^>]*Foreground="#0E7A4B"')
Check 'status line announced politely' ($pk -match "SetLiveSetting\(\`$status, 'Polite'\)")
$vncSrc = [regex]::Match($src, '(?s)# ---------- VNC register picker.*?# =+ MAIN').Value
Check 'VNC code: no -password switch, no Invoke-Expression, no cmd /c' ($vncSrc -notmatch "'-password'" -and $vncSrc -notmatch 'Invoke-Expression|iex ' -and $vncSrc -notmatch 'cmd(\.exe)?\s*/c')
Check 'launch: Start-Process with an argument list from Get-VncViewerArgs' ((& $fn 'Start-VncViewer').Contains('$vargs = @(Get-VncViewerArgs $h $p $viewOnly $file)') -and (& $fn 'Start-VncViewer').Contains('$psi = New-VncStartInfo $exe $argLine') -and (& $fn 'Start-VncViewer') -notmatch 'Start-Process')
Check 'viewer path must be a local fixed path' ((& $fn 'Find-VncViewer') -match 'Test-VncViewerFile \$f \$global:VncViewerProbe\)\) \{   # LJ M42-I1' -and (& $fn 'Find-VncViewer') -match 'App Paths\\vncviewer\.exe')
Check 'secret: DPAPI CurrentUser + entropy, plaintext zeroed' ($sv -match "ProtectedData\]::Protect\(\`$raw, \`$global:VncEntropy, 'CurrentUser'\)" -and $sv -match 'ZeroFreeBSTR' -and (& $fn 'Get-VncSecretHex') -match 'Array\]::Clear')
Check 'secret: separate file, not buttons.json' ((& $fn 'Get-VncSecretPath') -match "'vnc-viewonly\.dat'")
$sv2 = & $fn 'Start-VncViewer'
Check 'v1.4.12: View only writes the temp .vnc only inside the view-only branch' ($sv2.Contains('if ($viewOnly)') -and $sv2.Contains('if ($launch.use) { $hex = [string]$launch.hex; $file = New-VncTempConfig $h $p $hex') -and $sv2.Contains('Remove-VncTempSoon $file $proc $OnEarlyExit') -and $sv2 -notmatch 'Show-VncPasswordDialog')
Check 'temp .vnc: random folder, protected ACL for this user, CreateNew, deleted soon + leftovers' ($tcfg -match "bl-vnc-' \+ \[guid\]" -and $tcfg -match 'SetAccessRuleProtection\(\$true, \$false\)' -and $tcfg -match 'CreateNew' -and $sv2 -match 'Remove-VncTempSoon' -and $pk -match 'Remove-VncTempLeftovers')
Check 'v1.4.4: legacy start-up delete targets only the v1.4.1 file; the new store is another name in another folder' ($src.Contains('try { Clear-VncSecret } catch {}') -and ([regex]::Matches($src, 'Clear-VncSecret')).Count -eq 2 -and (& $fn 'Clear-VncSecret') -notmatch 'Get-Content|ReadAll|Unprotect|Get-VncSecretHex|ViewOnly' -and (& $fn 'Get-VncSecretPath') -match "'vnc-viewonly\.dat'" -and (& $fn 'Get-VncViewOnlyPath') -match "'vnc-viewonly-v2\.dat'" -and (& $fn 'Get-VncViewOnlyDir') -match "LocalApplicationData'\)\) 'ButtonLauncher'")
$cvs = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Clear-VncSecret' }, $true).Extent.Text; Invoke-Expression $cvs
$cvd = Join-Path ([IO.Path]::GetTempPath()) ('bl-cvs-' + [guid]::NewGuid()); [void](New-Item -ItemType Directory -Path $cvd)
function global:Get-VncSecretPath { Join-Path $cvd 'vnc-viewonly.dat' }
Set-Content -LiteralPath (Get-VncSecretPath) -Value 'x'; Set-Content -LiteralPath ((Get-VncSecretPath) + '.tmp') -Value 'x'; Clear-VncSecret; $gone = -not (Test-Path -LiteralPath (Get-VncSecretPath)) -and -not (Test-Path -LiteralPath ((Get-VncSecretPath) + '.tmp'))
[void](New-Item -ItemType Directory -Path (Get-VncSecretPath)); Set-Content -LiteralPath (Join-Path (Get-VncSecretPath) 'keep.txt') -Value 'k'; Clear-VncSecret; $dirKept = Test-Path -LiteralPath (Join-Path (Get-VncSecretPath) 'keep.txt'); Remove-Item -LiteralPath (Get-VncSecretPath) -Recurse -Force
Set-Content -LiteralPath (Join-Path $cvd 'target.txt') -Value 't'; $lnk = $false; try { [void](New-Item -ItemType SymbolicLink -Path (Get-VncSecretPath) -Target (Join-Path $cvd 'target.txt') -ErrorAction Stop); $lnk = $true } catch {}
if ($lnk) { Clear-VncSecret; $linkKept = (Test-Path -LiteralPath (Get-VncSecretPath)) -and (Test-Path -LiteralPath (Join-Path $cvd 'target.txt')) } else { $linkKept = $true }
$noneOk = $true; Remove-Item -LiteralPath (Get-VncSecretPath) -Force -ErrorAction SilentlyContinue; try { Clear-VncSecret } catch { $noneOk = $false }
Remove-Item -LiteralPath $cvd -Recurse -Force
Check 'LJ M40-I1 / CC A1: Clear-VncSecret deletes the plain .dat and .tmp, skips a folder and a link quietly, nothing there is fine, never prompts' ($gone -and $dirKept -and $linkKept -and $noneOk -and $cvs.Contains('-Confirm:$false -ErrorAction SilentlyContinue') -and $cvs.Contains('[IO.FileAttributes]::ReparsePoint') -and $cvs -notmatch 'Get-Content|ReadAll|Unprotect')
Check 'ScreenConnect elevation and force-restart confirm unchanged' ($src -match "Start-Process powershell\.exe -Verb RunAs -WindowStyle Hidden -PassThru" -and $src -match 'CC-M4/LJ-L3: force restart ALWAYS asks')
Check 'no PS7-only syntax in the VNC code' ($vncSrc -notmatch '\?\?|\?\.|\s\?\s[^:]+\s:\s|ForEach-Object -Parallel|&&|\|\||::new\(')
Check 'nit: this test file is plain ASCII with no BOM' ($(($b = [IO.File]::ReadAllBytes($PSCommandPath)); -not ($b | Where-Object { $_ -gt 127 })))

# --- round 2 (ClaudeCode R2, Lockjaw V2-I1) ---
Check 'R2-L1: gateway inside the subnet is found' ((Get-VncSubnetGateway '192.168.1.37' 24 @('10.0.0.1', '192.168.1.1')) -eq '192.168.1.1' -and (Get-VncSubnetGateway '192.168.1.37' 24 @('192.168.2.1')) -eq '')
$kShop = Get-VncRangeKey '192.168.1.0/24' '192.168.1.1' 'Shop.LAN' 'mac=AA-BB-CC-00-11-22'; $kHome = Get-VncRangeKey '192.168.1.0/24' '192.168.1.254' 'home' ''
Check 'R2-L1/R3-L1: key = range + gateway + gateway id + DNS suffix (lower-case)' ($kShop -eq '192.168.1.0/24|gw=192.168.1.1|id=mac=aa-bb-cc-00-11-22|dns=shop.lan')
$kA = Get-VncRangeKey '192.168.1.0/24' '192.168.1.1' '' (ConvertTo-VncGatewayId 'aa:bb:cc:00:11:22' 'Home'); $kB = Get-VncRangeKey '192.168.1.0/24' '192.168.1.1' '' (ConvertTo-VncGatewayId '11-22-33-44-55-66' 'Home')
Check 'R3-L1: same 192.168.1.1 and no DNS suffix, different router MAC -> different keys' ($kA -ne $kB -and $kA -match '\|id=mac=aa-bb-cc-00-11-22\|')
Check 'R3-L1: no usable MAC -> network profile name; neither -> empty id' ((ConvertTo-VncGatewayId '00-00-00-00-00-00' 'Shop Net 2') -eq 'net=shop net 2' -and (ConvertTo-VncGatewayId '' 'Bad|Name') -eq 'net=bad_name' -and (ConvertTo-VncGatewayId '' '') -eq '')
Check 'R3-L1: hostile id neutralised' ((Get-VncRangeKey '10.0.0.0/24' '10.0.0.1' '' "x|dns=1") -eq '10.0.0.0/24|gw=10.0.0.1|id=?|dns=')
Check 'R3-L1 migration: keys saved before the gateway id count as unconfirmed' (-not (Test-VncRangeKeyCurrent '192.168.1.0/24|gw=192.168.1.1|dns=') -and (Test-VncRangeKeyCurrent $kA) -and ($src -match 'Where-Object \{ Test-VncRangeKeyCurrent'))
Check 'R2-L1: same range on another network is a different key' ($kShop -ne $kHome -and (Get-VncRangeKey '192.168.1.0/24' '192.168.1.1' 'other') -ne $kShop)
Check 'R2-L1: odd DNS suffix is neutralised' ((Get-VncRangeKey '10.0.0.0/24' '10.0.0.1' "x|gw=1`n" '') -eq '10.0.0.0/24|gw=10.0.0.1|id=|dns=?')
Check 'R2-L2: range state ok / declined / new' ((Get-VncRangeState $kShop @($kShop) @()) -eq 'ok' -and (Get-VncRangeState $kHome @($kShop) @($kHome)) -eq 'declined' -and (Get-VncRangeState 'x' @($kShop) @($kHome)) -eq 'new')
$plan = & $fn 'Get-VncScanPlan'
Check 'R2-L2: declines remembered in vnc.declinedRanges, skipped unless Rescan asks' ($plan -match "Set-Prop \`$global:cfg\.vnc 'declinedRanges'" -and $plan -match "\`$st -eq 'declined' -and -not \`$Ask" -and $plan -match 'Get-VncRangeKey')
foreach ($d in 'NordLynx Tunnel', 'Cloudflare WARP Interface Tunnel', 'Surfshark WireGuard', 'Mullvad Tunnel', 'ProtonVPN TUN', 'Windscribe VPN', 'Tailscale Tunnel', 'ZeroTier One Virtual Port', 'Sophos SSL VPN Adapter', 'SonicWall NetExtender') {
    Check "R2-L3: '$d' never scanned" (-not (Test-VncAdapter 'Ethernet' $d 'Ethernet 3' '192.168.1.37' 24 @('192.168.1.1'))) }
Check 'nit: GigabitEthernet type allowed' (Test-VncAdapter 'GigabitEthernet' 'Realtek PCIe GbE' 'Ethernet' '192.168.1.37' 24 @('192.168.1.1'))
$xaml2 = [regex]::Match($src, "(?s)\`$global:VncPickerXaml = @'.*?'@").Value
Check 'R2-L4: no Tag binding inside triggers, no blur effect in the picker' ($xaml2 -notmatch '\{Binding Tag' -and $xaml2 -notmatch 'DropShadowEffect')
Check 'R2-L4: glow layer = TemplateBinding Tag brush, shown on hover/press, hidden when disabled' ($xaml2 -match 'x:Name="glow"[^>]*Background="\{TemplateBinding Tag\}"' -and $xaml2 -match 'TargetName="glow" Property="Opacity" Value="0.35"' -and $xaml2 -match 'TargetName="glow" Property="Opacity" Value="0.15"' -and $xaml2 -match '<SolidColorBrush Color="#22C55E"/>' -and $xaml2 -match '<SolidColorBrush Color="#38BDF8"/>')
$stop2 = & $fn 'Stop-VncScan'
Check 'nit: Stop is async (BeginStop, dispose later), no blocking Stop()' ($stop2 -match 'BeginStop' -and $stop2 -notmatch '\.Stop\(\);' -and $stop2 -notmatch '\$x\.Stop\(\)' -and (& $fn 'Clear-VncDeadWorkers') -match 'Dispose')
Check 'nit: XAML load in try with a clear message' ($pk -match "(?s)try \{ \`$w = \[Windows\.Markup\.XamlReader\]::Parse.*The computer finder couldn't open")
Check 'nit: no unused $total in Step-VncScan' ((& $fn 'Step-VncScan') -notmatch '\$total')
Check 'nit: age text' ((Get-VncAgeText ([datetime]::MinValue) $now) -eq '' -and (Get-VncAgeText $now.AddMinutes(-5) $now) -eq '5 min ago' -and (Get-VncAgeText $now.AddHours(-3) $now) -eq '3 h ago' -and (Get-VncAgeText $now.AddDays(-1.2) $now) -eq '1 day ago' -and (Get-VncAgeText $now.AddDays(-3) $now) -eq '3 days ago')
$rv = Get-VncRowView ([pscustomobject]@{ host = '192.168.1.21'; port = 5900; name = 'Register 1'; banner = 'RFB 003.889'; pinned = $true; fav = $true; seen = $true }) $false $false '3 days ago' $true
Check 'Squint 5: stale cached row says Earlier (age only in the status line) and is greyed' ($rv.seen -eq 'Earlier' -and $rv.addrFg -eq '#A0A0A0' -and $rv.nameFg -eq '#A0A0A0')

# ---- v1.3.0 round 3 (Squint / Kern / ClaudeCode) ----
Check 'Kern 6: Add and password dialogs use the D2 dialog' ($src -match "New-D2Dialog 'Add a computer'" -and $src -match "Background = Brush '#0FFFFFFF'" -and $src -match "Background = Brush '#22C55E'")
Check 'Picker Blocker: menu text white 14 px UI font, disabled #9A9A9A' ($xaml2 -match '<Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="FontSize" Value="14"/>' -and $xaml2 -match 'Property="Foreground" Value="#9A9A9A"' -and $src -match "\`$m\.Foreground = Brush '#FFFFFF'; \`$m\.FontFamily = \`$global:UiFont; \`$m\.FontSize = 14")
Check 'Picker Minor: shortcut text #B4B4B4' ($xaml2 -match 'Text="\{TemplateBinding InputGestureText\}" Foreground="#B4B4B4"')
Check 'Picker Minor: list border 12% white' ($xaml2 -match 'Background="#2E000000" BorderBrush="#1FFFFFFF"')
Check 'N1: -All cleanup after picker close and on exit' ($src -match 'Clear-VncDeadWorkers -All \} \}\.GetNewClosure\(\)\); \$ct\.Start\(\)' -and $src -match 'Add_Exit\(\{ Stop-TrayAndHotkey; try \{ Clear-VncDeadWorkers -All \}')
$xmlOk = $true; try { $px = [regex]::Match($xaml2, "(?s)@'\r?\n(.*)\r?\n'@").Groups[1].Value; if (-not $px) { throw 'empty' }; [void][xml]$px } catch { $xmlOk = $false }
Check 'picker XAML still well-formed XML' $xmlOk
# ---- R4-L1 (ClaudeCode): gateway MAC pick ----
function NB($mac, $state = 'Reachable', $ix = 7) { [pscustomobject]@{ LinkLayerAddress = $mac; State = $state; InterfaceIndex = $ix } }
Check 'R4-L1: half-resolved entry ahead of the good one is skipped' ((Select-VncGatewayMac @((NB '' 'Incomplete'), (NB '00-00-00-00-00-00' 'Stale'), (NB 'AA-AA-AA-AA-AA-AA')) 7) -eq 'AA-AA-AA-AA-AA-AA')
Check 'R4-L1: other adapters are ignored' ((Select-VncGatewayMac @((NB '11-11-11-11-11-11' 'Reachable' 3), (NB '22-22-22-22-22-22' 'Reachable' 7)) 7) -eq '22-22-22-22-22-22')
Check 'R4-L1: unreachable / invalid only -> empty' ((Select-VncGatewayMac @((NB 'AA-AA-AA-AA-AA-AA' 'Unreachable'), (NB 'zz-bb-cc-dd-ee-ff'), (NB 'aabbccddeeff')) 7) -eq '' -and (Select-VncGatewayMac @() 7) -eq '')
Check 'R4-L1: Get-NetNeighbor filtered by -InterfaceIndex; empty id never cached' ($src -match 'Get-NetNeighbor -IPAddress \$gw -AddressFamily IPv4 -InterfaceIndex \$ifIndex' -and $src -match 'if \(\$id\) \{ \$global:VncGwIdCache\[\$ck\] = \$id \}')
$rm = [regex]::Match($xaml2, '(?s)<Window\.Resources>(.*?)</Window\.Resources>')
$rdOk = $rm.Success; try { [void][xml]('<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' + $rm.Groups[1].Value + '</ResourceDictionary>') } catch { $rdOk = $false }
Check 'N2: dialog styles come from the resources block alone (well-formed)' ($rdOk -and $src.Contains('[regex]::Match($global:VncPickerXaml, ''(?s)<Window\.Resources>(.*?)</Window\.Resources>'')'))

# Squint Windows recheck: wording, short reverse-DNS names, status line
Check "Squint recheck: 'Found N computers you can view' while names load" ((Get-VncFoundText 3 -LookingUp) -eq 'Found 3 computers you can view. Looking up names...' -and (Get-VncFoundText 1 -LookingUp) -eq 'Found 1 computer you can view. Looking up names...')
Check "N1/N2: status 'Found 3 computers on this network at 1:05 PM.'" ((Get-VncFoundText 3 -At '1:05 PM') -eq 'Found 3 computers on this network at 1:05 PM.' -and (Get-VncFoundText 1 -At '1:05 PM') -eq 'Found 1 computer on this network at 1:05 PM.')
Check 'N2: no "shop network" claim in the status or scan prompt' ($src -notmatch "Found \{0\} on the shop network" -and $src -notmatch 'checks the shop network')
$rs = @(Merge-VncRows @([pscustomobject]@{ host = '192.168.1.20'; port = 5900; name = 'Front.Till'; pinned = $true }, [pscustomobject]@{ host = '192.168.1.21'; port = 5900; name = 'Till.1'; pinned = $false }, [pscustomobject]@{ host = '192.168.1.22'; port = 5900; name = 'Till.2'; pinned = $false }, [pscustomobject]@{ host = '192.168.1.23'; port = 5900; name = ''; pinned = $false }) @([pscustomobject]@{ host = '192.168.1.23'; port = 5900; name = 'pos-04.shop.lan'; banner = 'RFB 003.008' }, [pscustomobject]@{ host = '192.168.1.24'; port = 5900; name = 'pos-05.shop.lan'; banner = 'RFB 003.008' }))
$nt = @{}; foreach ($x in $rs) { $nt[$x.host] = (Get-VncRowView $x $true $false).nameText }
Check "R5-L1: typed name 'Front.Till' shown in full" ($nt['192.168.1.20'] -eq 'Front.Till')
Check "R5-L1: typed 'Till.1' and 'Till.2' stay distinct" ($nt['192.168.1.21'] -eq 'Till.1' -and $nt['192.168.1.22'] -eq 'Till.2')
Check 'R5-L1: reverse-DNS names (saved without a name, or scanned) are shortened' ($nt['192.168.1.23'] -eq 'pos-04' -and $nt['192.168.1.24'] -eq 'pos-05')
Check 'Squint recheck: range and port only in the status tooltip' ($src -match "statusTip\.Invoke\(\('Range \{0\}, port \{1\}\. Press F5 to rescan\.'" -and $src -notmatch "register\(s\) on \{1\}")
Check "Squint recheck: no 'register(s)' wording left" ($src -notmatch 'register\(s\)')
Check 'Squint recheck: reverse-DNS name shows the first label, full name in tooltip' ((Get-VncShortName 'pos-03.shop.example.lan') -eq 'pos-03' -and (Get-VncShortName 'Till 2') -eq 'Till 2' -and (Get-VncShortName '192.168.1.5') -eq '192.168.1.5' -and (Get-VncRowView ([pscustomobject]@{ name = 'pos-03.shop.example.lan'; host = '192.168.1.5'; port = 5900; seen = $true }) $true $false).nameFull -eq 'pos-03.shop.example.lan')
Check 'Squint recheck: name column tooltip + 12 px gap before Address' ($src -match 'Text="\{Binding nameText\}" ToolTip="\{Binding nameFull\}"[^>]*Margin="4,0,12,0"')
$d7Lines = @(($src -split "`n") | ForEach-Object { ($_ -replace '(^|\s)#\s.*$', '') } | ForEach-Object { $_ -creplace 'View Register|VIEW REGISTER|Register \d|register\.png|REGISTER`nUSER GUIDE', '' } | Where-Object { $_ -match 'shop network|\bregisters?\b' })
Check 'delta 7: View Register tile/window name unchanged' ($src -match "'View Register'")
Check 'delta 7: no picker UI string says "shop network", "register" or "registers" (comments, View Register, the "Register 1" name example register.png and the old REGISTER guide-art label allowed); title, Rescan tooltip and no-network copy updated' ($d7Lines.Count -eq 0 -and $src -match [regex]::Escape('ToolTip="Look for computers you can view on this network again (F5)"') -and $src -match [regex]::Escape("'No local network found on this PC, so nothing was scanned.'"))
# --- v1.4.0 (Charles): isolated register LANs with no default gateway are scanned too ---
Check 'no-gateway Wi-Fi -> scanned' (Test-VncAdapter 'Wireless80211' 'Intel(R) Wi-Fi 6 AX201' 'Wi-Fi' '192.168.50.20' 24 @())
foreach ($d in 'Hyper-V Virtual Ethernet Adapter', 'TAP-Windows Adapter V9', 'WireGuard Tunnel', 'Microsoft KM-TEST Loopback Adapter', 'VirtualBox Host-Only Ethernet Adapter', 'Cisco AnyConnect Virtual Miniport Adapter') {
    Check "no gateway still excludes '$d'" (-not (Test-VncAdapter 'Ethernet' $d 'Ethernet 9' '192.168.56.1' 24 @())) }
foreach ($ty in 'Loopback', 'Tunnel', 'Ppp') { Check "no gateway still excludes type $ty" (-not (Test-VncAdapter $ty 'x' 'x' '192.168.50.20' 24 @())) }
Check 'no gateway: APIPA 169.254 excluded' (-not (Test-VncAdapter 'Ethernet' 'Realtek PCIe GbE' 'Ethernet' '169.254.10.20' 16 @()))
Check 'no gateway: public address excluded' (-not (Test-VncAdapter 'Ethernet' 'Realtek PCIe GbE' 'Ethernet' '8.8.4.4' 24 @()))
Check 'no gateway: /31-/32 still excluded' (-not (Test-VncAdapter 'Ethernet' 'Realtek PCIe GbE' 'Ethernet' '192.168.50.20' 31 @()))
Check 'no gateway /16 adapter still scans only its /24' ((Get-VncRangeText '10.20.30.40' 16 24) -eq '10.20.30.0/24' -and @(Get-VncScanTargets '10.20.30.40' 16 24).Count -eq 253)
Check 'nic id: MAC -> nic=aa-bb-..; bad/zero MAC -> empty' ((ConvertTo-VncNicId '00155D0A0B0C') -eq 'nic=00-15-5d-0a-0b-0c' -and (ConvertTo-VncNicId 'AA:BB:CC:DD:EE:FF') -eq 'nic=aa-bb-cc-dd-ee-ff' -and (ConvertTo-VncNicId '000000000000') -eq '' -and (ConvertTo-VncNicId 'zz') -eq '')
$kIso = Get-VncRangeKey '192.168.50.0/24' '' '' (ConvertTo-VncNicId '00155D0A0B0C')
Check 'no-gateway key is stable and keeps the nic id' ($kIso -eq '192.168.50.0/24|gw=|id=nic=00-15-5d-0a-0b-0c|dns=' -and $kIso -eq (Get-VncRangeKey '192.168.50.0/24' '' '' 'nic=00-15-5d-0a-0b-0c') -and (Test-VncRangeKeyCurrent $kIso))
Check 'no-gateway key differs from a gateway network with the same numbers' ($kIso -ne (Get-VncRangeKey '192.168.50.0/24' '192.168.50.1' '' 'mac=aa-bb-cc-00-11-22'))
$ls = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Get-VncLocalSubnets' }, $true).Extent.Text
Check 'local subnets: no-gateway id from .NET (GetPhysicalAddress), no NetTCPIP cmdlet, label says local only' ($ls.Contains('ConvertTo-VncNicId ($nic.GetPhysicalAddress().ToString())') -and $ls -notmatch 'Get-Net' -and $ls.Contains("', local only'"))
# Get-VncScanPlan with 3 adapters (gateway LAN, isolated register LAN, a duplicate address on the isolated LAN): each network asked once
if (-not ('System.Windows.MessageBox' -as [type])) { Add-Type -TypeDefinition 'namespace System.Windows { public static class MessageBox { public static int Calls; public static string Answer = "Yes"; public static System.Collections.Generic.List<string> Texts = new System.Collections.Generic.List<string>(); public static string Show(string t, string c, string b, string i, string d) { Calls++; Texts.Add(t); return Answer; } } }' }
if ([System.Windows.MessageBox].GetField('Calls')) {
    $global:cfg = [pscustomobject]@{ vnc = [pscustomobject]@{} }; function global:Save-Config {}
    $sp = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Get-VncScanPlan' }, $true).Extent.Text; Invoke-Expression $sp
    function global:Get-VncLocalSubnets { @(@{ ip = '192.168.1.37'; prefix = 24; label = 'Ethernet'; gw = '192.168.1.1'; dns = ''; gwId = 'mac=aa-bb-cc-00-11-22' },
                                            @{ ip = '192.168.50.20'; prefix = 24; label = 'Ethernet, local only'; gw = ''; dns = ''; gwId = 'nic=00-15-5d-0a-0b-0c' },
                                            @{ ip = '192.168.50.21'; prefix = 24; label = 'Ethernet, local only'; gw = ''; dns = ''; gwId = 'nic=00-15-5d-0a-0b-0c' }) }
    $ui = @{ state = @{ prefix = 24; port = 5900; confirmed = @(); declined = @() } }
    [System.Windows.MessageBox]::Calls = 0; $pl = Get-VncScanPlan $ui $false
    Check 'two real adapters: both /24s scanned, labelled by network' ($pl.ranges.Count -eq 2 -and ($pl.labels -join ';') -eq '192.168.1.0/24 (Ethernet);192.168.50.0/24 (Ethernet, local only)' -and $pl.targets -contains '192.168.1.10' -and $pl.targets -contains '192.168.50.10')
    Check 'each network asked once (2 prompts, the duplicate on the same network not asked again)' ([System.Windows.MessageBox]::Calls -eq 2 -and $ui.state.confirmed.Count -eq 2)
    [System.Windows.MessageBox]::Calls = 0; $pl = Get-VncScanPlan $ui $false
    Check 'next open: no prompts, both still scanned' ([System.Windows.MessageBox]::Calls -eq 0 -and $pl.ranges.Count -eq 2)
    Check 'scan targets stay inside each /24 (no .0, .255, no other range)' (-not @($pl.targets | Where-Object { $_ -notmatch '^192\.168\.(1|50)\.([1-9]|[1-9]\d|1\d\d|2[0-4]\d|25[0-4])$' }).Count)
    $ui.state.confirmed = @(); [System.Windows.MessageBox]::Answer = 'No'; [System.Windows.MessageBox]::Calls = 0; $pl = Get-VncScanPlan $ui $false
    Check 'declined: nothing scanned, each network remembered as declined' ($pl.targets.Count -eq 0 -and $ui.state.declined.Count -eq 2 -and [System.Windows.MessageBox]::Calls -eq 2)
    [System.Windows.MessageBox]::Answer = 'Yes'
} else { 'SKIP  scan plan with a stub MessageBox (real WPF loaded)' }
foreach ($d in 'Bluetooth Device (Personal Area Network)', 'Bluetooth Device (Personal Area Network) #2') { Check "LJ M18-I4: '$d' never scanned (with or without a gateway)" (-not (Test-VncAdapter 'Ethernet' $d 'Bluetooth Network Connection' '192.168.44.5' 24 @()) -and -not (Test-VncAdapter 'Ethernet' $d 'Ethernet 5' '192.168.44.5' 24 @('192.168.44.1'))) }
Check 'LJ M18-I4: an adapter named Bluetooth Network Connection never scanned' (-not (Test-VncAdapter 'Ethernet' 'Generic adapter' 'Bluetooth Network Connection' '192.168.44.5' 24 @()))

# ================= v1.4.1 (Charles 4:09 PM / 4:11 PM): allowed computers, View only never asks, Interact keeps UltraVNC's own box =================
foreach ($n in 'Test-VncAllowedName', 'Test-VncAllowedHost', 'ConvertTo-VncAllowedList', 'ConvertFrom-VncAllowedJson', 'ConvertTo-VncAllowedJson', 'ConvertFrom-VncAllowedText',
               'ConvertTo-VncAllowedText', 'Get-VncReachWord', 'Get-VncReachTip', 'Test-VncReachStale', 'ConvertTo-VncReachBanner', 'Get-VncReachOutcome', 'Get-VncReachView', 'Get-VncReachShort', 'ConvertTo-VncReachEntry', 'Get-VncAllowedRows', 'Get-VncAllowedSaveError', 'Get-VncAllowedWriterText', 'Get-VncAllowedWriterCommand', 'Test-VncAllowedAclSafe') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "v1.4.1 defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(VncAllowedMax|VncAllowedWriterScript|VncReachFresh)\s*=') { Invoke-Expression $l.Extent.Text } }
# names, hosts, ports
foreach ($n in 'Register 1', 'REG-2', 'Front (till) #3', 'a', ('a' * 40)) { Check "allowed name ok: $n" (Test-VncAllowedName $n) }
foreach ($n in '', ' lead', ('a' * 41), 'x;calc', 'x"y', "x`ny", 'x$(y)', 'x<y>', [string][char]0xE9) { Check ("allowed name rejected: " + ($n -replace '[^\x20-\x7E]', '?')) (-not (Test-VncAllowedName $n)) }
foreach ($h in '192.168.1.21', 'REG1', 'reg-1.shop.local') { Check "allowed host ok: $h" (Test-VncAllowedHost $h) }
foreach ($h in 'reg1.', '-reg', 'reg_1', '256.1.1.1', '01.2.3.4', 'reg 1', '..', '', 'a..b', '-config') { Check "allowed host rejected: '$h'" (-not (Test-VncAllowedHost $h)) }
$j = '{"version":1,"computers":[{"name":"Register 1","host":"192.168.1.21"},{"name":"Register 2","host":"REG2","port":5901},{"name":"bad;","host":"x"},{"name":"Port","host":"1.2.3.4","port":70000},{"name":"Dup","host":"192.168.1.21","port":5900},{"name":"Evil","host":"-viewonly"}]}'
$r = ConvertFrom-VncAllowedJson $j
Check 'allowlist: 2 good entries kept, 4 bad skipped' (@($r.list).Count -eq 2 -and $r.bad -eq 4 -and -not $r.error)
Check 'allowlist: default port 5900, explicit port kept' ($r.list[0].port -eq 5900 -and $r.list[1].port -eq 5901 -and $r.list[1].host -eq 'REG2')
Check 'allowlist: empty list -> no entries, no error' (@((ConvertFrom-VncAllowedJson '{"version":1,"computers":[]}').list).Count -eq 0 -and -not (ConvertFrom-VncAllowedJson '{"version":1,"computers":[]}').error)
Check 'allowlist: not JSON -> nothing, error' (@((ConvertFrom-VncAllowedJson 'nope{').list).Count -eq 0 -and (ConvertFrom-VncAllowedJson 'nope{').error)
Check 'allowlist: over 64 KB -> nothing' (@((ConvertFrom-VncAllowedJson ('{"computers":[]}' + (' ' * 70000))).list).Count -eq 0)
$many = '{"computers":[' + ((1..60 | ForEach-Object { '{{"name":"R{0}","host":"10.0.0.{0}"}}' -f $_ }) -join ',') + ']}'
Check 'allowlist: capped at 50 entries' (@((ConvertFrom-VncAllowedJson $many).list).Count -eq 50)
$rt = ConvertFrom-VncAllowedJson (ConvertTo-VncAllowedJson $r.list); Check 'allowlist: JSON round trip' (@($rt.list).Count -eq 2 -and $rt.list[1].port -eq 5901 -and -not $rt.error)
# editor text
$t = ConvertFrom-VncAllowedText "Register 1, 192.168.1.21`r`n`r`nRegister 2, REG2:5901"
Check 'editor: two lines parsed, blank lines skipped' (-not $t.error -and @($t.list).Count -eq 2 -and $t.list[1].port -eq 5901)
Check 'editor: text round trip' ((ConvertTo-VncAllowedText $t.list) -eq "Register 1, 192.168.1.21`r`nRegister 2, REG2:5901")
foreach ($bad in 'no comma here', 'A, B, C', 'x;y, 1.2.3.4', 'Good, 999.1.1.1', 'Good, reg1:0', "A, 1.2.3.4`r`nB, 1.2.3.4") { Check "editor rejects: $($bad -replace "`r`n", ' / ')" ([bool](ConvertFrom-VncAllowedText $bad).error) }
Check 'editor: at most 50' ([bool](ConvertFrom-VncAllowedText ((1..51 | ForEach-Object { "R$_, 10.0.0.$_" }) -join "`n")).error)
# rows
$rows = Get-VncAllowedRows $t.list @{ '192.168.1.21:5900' = 'RFB 003.008' } $false
Check 'picker rows: fresh RFB is Online; a row with no result is Not checked, not Offline; no star' ($rows.Count -eq 2 -and $rows[0].seen -eq 'Online' -and $rows[0].statusKind -eq 'online' -and $rows[1].seen -eq 'Not checked' -and $rows[1].statusKind -eq 'unchecked' -and $rows[0].star -eq '' -and $rows[0].nameText -eq 'Register 1')
Check "picker rows: in-flight with no result stays Not checked" ((Get-VncAllowedRows $t.list @{} $true)[0].seen -eq 'Not checked' -and (Get-VncAllowedRows $t.list @{} $true)[0].statusTip -match 'in progress')
Check 'empty list: rows empty' (@(Get-VncAllowedRows @() @{} $false).Count -eq 0)
$pk = & $fn 'Show-VncPicker'
Check "empty-state copy: 'No computers have been allowed yet.'" ($pk -match [regex]::Escape("'No computers have been allowed yet.'") -and $pk -notmatch 'Ask your administrator' -and $pk -match 'Setup > Allowed computers \(admin\)')
Check 'picker: allowed list only (Read-VncAllowed), no scan, no favourites' ($pk -match 'Read-VncAllowed' -and $pk -notmatch 'Start-VncScan|Merge-VncRows|favorites|Read-VncCache')
Check 'picker: Rescan, Add and More hidden' ($pk -match "foreach \(\`$n in 'Rescan', 'Add', 'More'\) \{ \`$w.FindName\(\`$n\).Visibility = 'Collapsed' \}")
Check 'picker: Enter = View only, Ctrl+Enter = Interact, double-click = View only, F5 = online check, Esc closes' ($pk -match "'Return' -and \`$ctrl\) \{ \`$_.Handled = \`$true; \`$ui.go.Invoke\(\`$false\)" -and $pk -match 'MouseDoubleClick\(\{ if \(\$lv.SelectedItem\) \{ \$ui.go.Invoke\(\$true\)' -and $pk -match "'F5'\) \{ \`$_.Handled = \`$true; \`$ui.startCheck.Invoke\(\)" -and $pk -match "'Escape'")
Check 'picker: online check uses 300 ms (VncTimeoutMs) and only the allowed entries' ($pk -match 'VncAllowedCheckScript\).AddArgument\(\$items\).AddArgument\(\$global:VncTimeoutMs\)')
Check 'picker: closing stops the check and the prompt timer' ($pk -match 'Add_Closed\(\{ Stop-VncPromptWatch \$global:VncPromptWatch; \[void\]\(Close-VncReachCheck \$ui.reach\); \$ui.stopCheck.Invoke\(\)')
$rm = & $fn 'New-VncRowMenu'; Check 'row menu: allowed mode has only View only + Interact' ($rm -match 'if \(\$ui.allowedMode\) \{ \$m.Items.RemoveAt')
# View only never asks; password for any allowed row when saved
$sv = & $fn 'Start-VncViewer'
Check 'View only: no password prompt from the launcher (ask-once removed)' ($sv -notmatch 'Show-VncPasswordDialog' -and $sv -notmatch 'viewOnlyAsked')
Check 'L4: saved password used for a host that greeted RFB in this session' (Test-VncUsePassword ([pscustomobject]@{ host = '192.168.1.21'; banner = 'RFB 003.889'; session = $true }) $true)
Check 'V2-I1: cached RFB banner alone is not enough (not seen this session)' (-not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889'; session = $false }) $true) -and -not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889' }) $true))
Check 'L4: no password file for a host with no or a non-RFB greeting' (-not (Test-VncUsePassword ([pscustomobject]@{ banner = '' }) $true) -and -not (Test-VncUsePassword ([pscustomobject]@{ banner = 'SSH-2.0-Open' }) $true))
Check 'View only, nothing saved: -viewonly, no -config, no password (no-password registers)' (((Get-VncViewerArgs 'REG1' 5900 $true $null) -join ' ') -eq 'REG1:5900 -viewonly -autoscaling' -and -not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889'; session = $true }) $false))
Check 'v1.4.4: Start-VncViewer always passes host:port first (also with -config)' ($sv.Contains('$vargs = @(Get-VncViewerArgs $h $p $viewOnly $file)') -and (& $fn 'Get-VncViewerArgs').Contains("`$a = @(('{0}:{1}' -f `$h, `$p))") -and (& $fn 'Get-VncViewerArgs').Contains("`$a += @('-config'"))
# Interact: no config, no password, no -viewonly (UltraVNC asks for the password itself)
$a = Get-VncViewerArgs 'REG1' 5900 $false $null
Check 'Interact never -password, -config, -viewonly or -dsmplugin' (-not ((Get-VncViewerArgs 'REG1' 5900 $false $null) -match '^-password$|^-config$|^-viewonly$|^-dsmplugin$'))
Check 'Interact: same args for an IP or a name, host:port' (((Get-VncViewerArgs '192.168.1.21' 5900 $false $null) -join ' ') -eq '192.168.1.21:5900 -autoscaling')
Check 'DSM change reverted: no plugin code left' ($src -notmatch '(?i)dsmplugin|Get-VncHostDsm|Get-VncDsmFromLines')
Check 'Interact: host:port only (UltraVNC asks for the password)' (((Get-VncViewerArgs 'REG1' 5900 $false $null) -join ' ') -eq 'REG1:5900 -autoscaling')
$vi9 = @{ product = 'UltraVNC Viewer'; version = '1.5.0.0'; ultra = $true }; $f9 = 'C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc'
$lt9 = Get-VncLaunchLogText $true 'C:\v\vncviewer.exe' @(Get-VncViewerArgs '192.168.20.51' 5900 $true $f9) $f9 'saved' $vi9
Check 'v1.4.4: launch log: temp path redacted, says saved/none, never a password or hex' ($lt9 -ceq 'VNC view only: "C:\v\vncviewer.exe" 192.168.20.51:5900 -config "<temp .vnc>" -viewonly -autoscaling (viewer "UltraVNC Viewer" 1.5.0.0); view-only password: saved' -and (Get-VncLaunchLogText $false 'C:\v\vncviewer.exe' @(Get-VncViewerArgs 'POS1' 5900 $false $null) $null 'none' $vi9) -ceq 'VNC interact: "C:\v\vncviewer.exe" POS1:5900 -autoscaling (viewer "UltraVNC Viewer" 1.5.0.0)' -and (Get-VncLaunchLogText $true 'x' @('a:5900') $null 'none' $vi9) -like '*view-only password: none' -and $sv -notmatch 'Write-LauncherLog[^\n]*(\$hex|Get-VncSecretHex)' -and (& $fn 'Get-VncLaunchLogText') -notmatch 'hex|Secret')
# elevated writer
$enc = Get-VncAllowedWriterCommand $t.list
$dec = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc))
Check 'writer: encoded command is the constant script + reader ACL check + only base64 data' ($dec -eq (Get-VncAllowedWriterText ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-VncAllowedJson $t.list))))) -and $dec -notmatch '__DATA__|__ACLCHECK__')
$pe = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($dec, [ref]$null, [ref]$pe); Check 'writer script parses' ($pe.Count -eq 0)
Check 'writer: ACL Administrators + SYSTEM full, Users read, inheritance off, owner Administrators' ($global:VncAllowedWriterScript -match "S-1-5-32-544" -and $global:VncAllowedWriterScript -match "@\(\`$usr, 'ReadAndExecute'\)" -and $global:VncAllowedWriterScript -match 'SetAccessRuleProtection\(\$true, \$false\)' -and $global:VncAllowedWriterScript -match 'SetOwner\(\$adm\)')
Check 'writer: refuses reparse points, re-validates every entry, writes only vnc-allowed.json' ($global:VncAllowedWriterScript -match 'ReparsePoint\) \{ exit 4 \}' -and $global:VncAllowedWriterScript -match 'exit 3' -and @([regex]::Matches($global:VncAllowedWriterScript, "Join-Path \`$dir '")).Count -eq 2)
Check 'writer: no file or script from a user folder is run' ($global:VncAllowedWriterScript -notmatch 'LOCALAPPDATA|TEMP|APPDATA|Invoke-Expression|iex |& \$|\. \$|Start-Process')
$se = & $fn 'Save-VncAllowedElevated'; Check 'save: System folder powershell.exe, RunAs, -EncodedCommand' ($se.Contains("Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'") -and $se.Contains('-Verb RunAs') -and $se.Contains("'-EncodedCommand', `$enc"))
Check 'writer: 50 long entries still fit one command line' ([bool](Get-VncAllowedWriterCommand (1..50 | ForEach-Object { [pscustomobject]@{ name = ('Register number {0:00} front till' -f $_); host = ('register-{0:00}.shop.example.local' -f $_); port = 5900 } })))
# writer re-validation on a hand-made (hostile) payload: decode + run its checks in a sandbox copy with exit trapped
Check 'v1.4.4: Setup menu has Allowed computers and View-only password; masked PasswordBox with show/hide; set/change/reset; logs only saved/none' ($src -match "'Allowed computers \(admin\)\.\.\.'" -and $src -match "'View-only password \(for viewing computers\)\.\.\.'" -and (& $fn 'Show-VncPasswordDialog').Contains('System.Windows.Controls.PasswordBox') -and (& $fn 'Show-VncPasswordDialog').Contains('System.Windows.Controls.TextBox') -and (& $fn 'Show-VncPasswordDialog').Contains('Remove-VncViewOnlySecret') -and -not ((& $fn 'Show-VncPasswordDialog') -match 'Write-LauncherLog\s*[(]?[^;''\n]*\$pb') -and ([regex]::Matches((& $fn 'Show-VncPasswordDialog'), "Write-LauncherLog '").Count -eq 4))
# --- LJ M37 (FIX-FIRST on c202b8b) ---
$ws = $global:VncAllowedWriterScript
Check 'M37-M1: untrusted existing folder (link or failed ACL check) is moved aside to .untrusted-<guid>, never deleted' ($ws -match "Test-VncAllowedAclSafe \(\[IO.Directory\]::GetAccessControl\(\`$dir\)\)\)\) \{\s*\[IO.Directory\]::Move\(\`$dir, \(\`$dir \+ '.untrusted-'" -and $ws -notmatch 'Remove-Item|Directory\]::Delete')
Check 'M37-M1: folder created with its DirectorySecurity, then owner/ACL re-checked (exit 4)' ($ws -match '\[IO.Directory\]::CreateDirectory\(\$dir, \$ds\)' -and $ws -match "(?s)CreateDirectory\(\`$dir, \`$ds\).*?Test-VncAllowedAclSafe \(\[IO.Directory\]::GetAccessControl\(\`$dir\)\)\)\) \{ exit 4 \}")
Check 'M37-M1: temp file is FileMode CreateNew with FileSecurity, FileShare None; no WriteAllText/SetAccessControl reuse' ($ws -match 'New-Object IO.FileStream\(\$tmp, \[IO.FileMode\]::CreateNew, \[Security.AccessControl.FileSystemRights\]::Write, \[IO.FileShare\]::None, 4096, \[IO.FileOptions\]::None, \$fs\)' -and $ws -notmatch 'WriteAllText|SetAccessControl')
Check 'M37-M1: existing unsafe vnc-allowed.json refused; final file re-verified (exit 5)' ($ws -match "Test-VncAllowedAclSafe \(\[IO.File\]::GetAccessControl\(\`$file\)\)\)\) \{ exit 4 \}" -and $ws -match "GetAccessControl\(\`$file\)\)\)\) \{ exit 5 \}")
$full = Get-VncAllowedWriterText 'AA=='; $pe = $null; $wa = [System.Management.Automation.Language.Parser]::ParseInput($full, [ref]$null, [ref]$pe)
Check 'M37-M1: full elevated script parses and defines the same ACL check as the reader' ($pe.Count -eq 0 -and [bool]$wa.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Test-VncAllowedAclSafe' }, $true) -and $full.Contains(${function:Test-VncAllowedAclSafe}.ToString()))
Check 'M37-M1: data appears only inside the FromBase64String literal' (([regex]::Matches($full, "FromBase64String\('AA=='\)")).Count -eq 1 -and ([regex]::Matches($full, 'AA==')).Count -eq 1)
$se = & $fn 'Save-VncAllowedElevated'
Check 'M37-I3: powershell.exe from [Environment]::GetFolderPath(System), not $env:SystemRoot' ($se -match "Join-Path \(\[Environment\]::GetFolderPath\('System'\)\) 'WindowsPowerShell\\v1.0\\powershell.exe'" -and $se -notmatch '\$env:SystemRoot')
# reader ACL check against stand-in ACL objects
function New-FakeAcl([string]$owner, $rules) {
    $o = [pscustomobject]@{ owner = $owner; rules = $rules }
    $o | Add-Member ScriptMethod GetOwner { param($t) [pscustomobject]@{ Value = $this.owner } }
    $o | Add-Member ScriptMethod GetAccessRules { param($a, $b, $c) $this.rules }
    return $o }
function New-FakeAce([string]$sid, [int64]$rights, [int]$prop = 0, [string]$type = 'Allow') { [pscustomobject]@{ IdentityReference = [pscustomobject]@{ Value = $sid }; FileSystemRights = $rights; PropagationFlags = $prop; AccessControlType = $type } }
$A = 'S-1-5-32-544'; $S = 'S-1-5-18'; $U = 'S-1-5-32-545'
$good = @((New-FakeAce $A 0x1F01FF), (New-FakeAce $S 0x1F01FF), (New-FakeAce $U 0x1200A9))
Check 'reader: admin-owned, admins/SYSTEM full, Users read -> safe' (Test-VncAllowedAclSafe (New-FakeAcl $A $good))
Check 'reader: user-owned -> unsafe' (-not (Test-VncAllowedAclSafe (New-FakeAcl $U $good)))
Check 'M37-I1: Users delete-child (0x40) -> unsafe' (-not (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce $U 0x40)))))
Check 'M37-I1: Users GENERIC_WRITE (0x40000000) -> unsafe' (-not (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce $U 0x40000000)))))
Check 'M37-I1: Users GENERIC_ALL (0x10000000) -> unsafe' (-not (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce $U 0x10000000)))))
Check 'M37-I1: Users Delete / WRITE_DAC / WRITE_OWNER -> unsafe' (-not (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce $U 0x10000)))) -and -not (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce $U 0x40000)))) -and -not (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce $U 0x80000)))))
Check 'M37-I1: inherit-only write ACE ignored (CREATOR OWNER style)' (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce 'S-1-3-0' 0x10000000 2))))
Check 'M37-I1: Deny ACE ignored' (Test-VncAllowedAclSafe (New-FakeAcl $A ($good + (New-FakeAce $U 0x1F01FF 0 'Deny'))))
Check 'v1.4.2: exact final args, View only and Interact, address and name' ((((Get-VncViewerArgs '192.168.20.51' 5900 $true $null) -join ' ') -ceq '192.168.20.51:5900 -viewonly -autoscaling') -and (((Get-VncViewerArgs '192.168.20.51' 5900 $false $null) -join ' ') -ceq '192.168.20.51:5900 -autoscaling') -and (((Get-VncViewerArgs 'POS1' 5901 $true $null) -join ' ') -ceq 'POS1:5901 -viewonly -autoscaling') -and (((Get-VncViewerArgs 'POS1' 5901 $false $null) -join ' ') -ceq 'POS1:5901 -autoscaling'))
# --- ClaudeCode FIX-FIRST on c202b8b ---
$on = Get-VncAllowedRows $t.list @{ '192.168.1.21:5900' = 'RFB 003.008'; 'REG2:5901' = 'SSH-2.0-x' } $false
Check 'CC MED-1: online allowed row carries the RFB banner + session -> saved password used (usePassword True)' ($on[0].row.banner -eq 'RFB 003.008' -and $on[0].row.session -and (Test-VncUsePassword $on[0].row $true))
Check 'CC MED-1: a non-RFB answer is Offline, and View only still may use the password file' ($on[1].seen -eq 'Offline' -and $on[1].statusKind -eq 'offline' -and -not $on[1].row.session -and (Test-VncUsePassword $on[1].row $true))
Check 'CC MED-1: nothing saved still passes the password gate, and the launcher has no password prompt of its own' ((Test-VncUsePassword $on[0].row $false) -and (& $fn 'Start-VncViewer') -notmatch 'Show-VncPasswordDialog')
Check 'CC MED-1: reachability check queues key, kind and banner; only an RFB greeting is Online' ($src -match 'Enqueue\(@\{ key = \$b.key; kind = \$kind; banner = \$banner \}\)' -and (& $fn 'Get-VncReachOutcome') -match 'Test-VncBannerText')
Check 'CC LOW-L: a folder named vnc-allowed.json(.tmp) -> exit 6' ($global:VncAllowedWriterScript -match "Test-Path -LiteralPath \`$file -PathType Container\) -or \(Test-Path -LiteralPath \`$tmp -PathType Container\)\) \{ exit 6 \}")
Check 'CC LOW-L: planted .tmp in an untrusted folder goes aside with the folder; CreateNew never opens an old .tmp' ($global:VncAllowedWriterScript -match 'CreateNew' -and $global:VncAllowedWriterScript -match '\.untrusted-')
Check "CC LOW-L: clear 'Not saved' messages for codes 3, 4, 5, 6 and others" ((Get-VncAllowedSaveError 3) -like 'Not saved*' -and (Get-VncAllowedSaveError 6) -like 'Not saved: *unexpected*' -and (Get-VncAllowedSaveError 4) -eq (Get-VncAllowedSaveError 5) -and (Get-VncAllowedSaveError 2) -like 'Not saved (code 2)*' -and (Get-VncAllowedSaveError 23) -like 'Not saved (code 23): *checking the existing folder*' -and (Get-VncAllowedSaveError 27) -like '*replacing the old file*')
Check 'v1.4.4: the elevated writer reports the failing step (20+step), never a bare code 2' ($global:VncAllowedWriterScript.Contains('catch { exit (20 + $s) }') -and -not $global:VncAllowedWriterScript.Contains('exit 2 }'))
Check 'L6/M43-I2: ports below 100 refused (a single colon would mean a display number)' ($(try { [void](Get-VncViewerArgs 'REG1' 99 $true $null); $false } catch { $true }) -and ((Get-VncViewerArgs 'REG1' 100 $false $null) -join ' ') -ceq 'REG1:100 -autoscaling' -and (& $fn 'Start-VncViewer').Contains('if ($p -lt 100)'))
Check 'M43-I1: step messages say the old list is kept' ((Get-VncAllowedSaveError 24) -like '*old list (if any) is kept*' -and (Get-VncAllowedSaveError 24) -notlike '*Nothing else*')
$rIp = [pscustomobject]@{ host = '192.168.20.51'; port = 5900; session = $true; banner = 'RFB 003.008' }; $rNm = [pscustomobject]@{ host = 'POS1'; port = 5900; session = $true; banner = 'RFB 003.008' }
Check 'v1.4.12: a name on a usable host still passes the password gate (the allowlist is separate)' ((Test-VncUsePassword $rIp $true) -and (Test-VncUsePassword $rNm $true) -and (Test-VncUsePassword $rIp $false) -and (Test-VncUsePassword ([pscustomobject]@{ host = 'pos1.local'; session = $true; banner = 'RFB 003.008' }) $true))
Check 'LJ M44-I2: ports below 100 refused in endpoints, allowed list, writer and favorites' ($null -eq (ConvertTo-VncEndpoint 'REG1:99') -and $null -eq (ConvertTo-VncEndpoint 'REG1::1') -and (ConvertTo-VncEndpoint 'REG1:100').port -eq 100 -and (ConvertTo-VncAllowedList @([pscustomobject]@{ name = 'A'; host = '10.0.0.1'; port = 99 })).bad -eq 1 -and @((ConvertTo-VncAllowedList @([pscustomobject]@{ name = 'A'; host = '10.0.0.1'; port = 100 })).list).Count -eq 1 -and $global:VncAllowedWriterScript.Contains('$p -lt 100 -or $p -gt 65535) { exit 3 }') -and (& $fn 'Get-VncState').Contains('(Get-VncPort $f.port) -lt 100') -and (& $fn 'Set-VncFavorite').Contains('$port -lt 100'))
Check 'CC L7: host and IPv4 checks refuse a trailing newline' (-not (Test-VncHost "reg1`n") -and -not (Test-VncIPv4 "1.2.3.4`n") -and -not (Test-VncHost "1.2.3.4`n") -and (Test-VncHost 'reg1') -and (Test-VncIPv4 '1.2.3.4'))
$qa = @(Get-VncViewerArgs '192.168.20.51' 5900 $true 'C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc')
Check 'v1.4.4: -config path with a space is its own quoted element (Start-Process joins with spaces, no quoting)' ($qa[2] -ceq '"C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc"' -and ($qa -join ' ') -ceq '192.168.20.51:5900 -config "C:\Users\O Brien\AppData\Local\Temp\bl-vnc-1\c.vnc" -viewonly -autoscaling' -and $(try { [void](Get-VncViewerArgs 'a' 5900 $true 'C:\x"y\c.vnc'); $false } catch { $true }))
$repBad = @(foreach ($f9 in Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1) { $t9 = [System.Management.Automation.Language.Parser]::ParseFile($f9.FullName, [ref]$null, [ref]$null)
    $t9.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Static -and [string]$x.Member -eq 'Replace' -and [string]$x.Expression -match '^\[(System\.)?IO\.File\]$' }, $true) | Where-Object { @($_.Arguments).Count -ge 3 -and [string]$_.Arguments[2] -eq '$null' -and $_.Extent.StartScriptPosition.Line -notmatch 'nullThrows' } | ForEach-Object { '{0}:{1}' -f $f9.Name, $_.Extent.StartLineNumber } })
$repBad += @(foreach ($f9 in Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1) { $i9 = 0; foreach ($l9 in [IO.File]::ReadAllLines($f9.FullName)) { $i9++; if ($l9 -match '\[(System\.)?IO\.File\]::Replace\([^)]*,\s*\$null\s*\)' -and $l9 -notmatch 'nullThrows|-match ') { '{0}:{1} (text)' -f $f9.Name, $i9 } } })   # also inside here-strings (the elevated writer)
Check ('v1.4.5: no [IO.File]::Replace gets $null as the backup path (use [NullString]::Value) ' + ($repBad -join ' ')) ($repBad.Count -eq 0 -and $global:VncAllowedWriterScript.Contains('[IO.File]::Replace($tmp, $file, [NullString]::Value)'))
$rd9 = Join-Path ([IO.Path]::GetTempPath()) ('bl-rep-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $rd9); $ra = Join-Path $rd9 'a'; $rb = Join-Path $rd9 'b'
Set-Content -LiteralPath $ra -Value 'new'; Set-Content -LiteralPath $rb -Value 'old'; $nullThrows = $false; try { [IO.File]::Replace($ra, $rb, $null) } catch { $nullThrows = $true }
$nsOk = $false; try { [IO.File]::Replace($ra, $rb, [NullString]::Value); $nsOk = ((Get-Content -LiteralPath $rb) -eq 'new') -and -not (Test-Path -LiteralPath $ra) } catch {}
Remove-Item -LiteralPath $rd9 -Recurse -Force
Check 'v1.4.5: pwsh behaviour: Replace(tmp, existing, $null) throws, [NullString]::Value works' ($nullThrows -and $nsOk)
Check 'v1.4.5: N-L1/M45-I1 anchors and [0-9]' (-not (Test-VncBannerText "RFB 003.008`n") -and (Test-VncBannerText 'RFB 003.008') -and -not (Test-VncAllowedName "A`n") -and (Test-VncAllowedName 'Register 1') -and -not (Test-VncIPv4 ([string][char]0x0661 + '.1.1.1')) -and $global:VncAllowedWriterScript -notmatch "'\^")
Check 'v1.4.5: N-L2 the editor says when a port is below 100' ((ConvertFrom-VncAllowedText 'Reg, 10.0.0.1:99').error -like 'Line 1: ports below 100*' -and (ConvertFrom-VncAllowedText 'Reg, 10.0.0.1:5900').error -eq '' -and (ConvertFrom-VncAllowedText 'Reg, 10.0.0.1:x').error -like "*isn't valid*")
Check 'v1.4.4: exact argv POS1 View only / Interact' ((((Get-VncViewerArgs '192.168.20.51' 5900 $true $null) -join '|') -ceq '192.168.20.51:5900|-viewonly|-autoscaling') -and (((Get-VncViewerArgs '192.168.20.51' 5900 $false $null) -join '|') -ceq '192.168.20.51:5900|-autoscaling'))
# --- v1.4.3: find vncviewer.exe in Program Files (override, known, bounded scan, none, links) ---
foreach ($n in 'Get-VncProgramRoots', 'Get-VncFileVersion', 'Get-VncScanAge', 'Test-VncViewerFile', 'Find-VncViewerInProgramFiles', 'Get-VncViewerLogText') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
function New-FakeFs($files, $dirs, $envv) {   # files: path -> @{ version; link }; dirs: path -> @( @{ name; link } )
    $calls = New-Object System.Collections.ArrayList
    $fs = @{ files = $files; dirs = $dirs; calls = $calls }
    @{ calls = $calls
       Env = { $envv }.GetNewClosure()
       Dirs = { param($d) [void]$calls.Add($d); @(@($dirs[$d]) | Where-Object { $_ } | ForEach-Object { @{ name = $_.name; path = "$d\$($_.name)"; link = [bool]$_.link } }) }.GetNewClosure()
       File = { param($f) $files[$f] }.GetNewClosure()
       Local = { param($p) $p -match '^[A-Za-z]:\\' }.GetNewClosure() }
}
$e64 = @{ ProgramW6432 = 'C:\Program Files'; ProgramFiles = 'C:\Program Files (x86)'; ProgramFilesX86 = 'C:\Program Files (x86)' }   # 32-bit PowerShell view
$pr = New-FakeFs @{} @{} $e64
Check 'v1.4.3: roots from ProgramW6432 + ProgramFiles(x86), 64-bit first, deduped (32-bit PowerShell)' ((@(Get-VncProgramRoots $pr) -join '|') -eq 'C:\Program Files|C:\Program Files (x86)')
$pr = New-FakeFs @{} @{} @{ ProgramW6432 = 'C:\Users\x\AppData\Local\Temp\Program Files'; ProgramFiles = 'C:\Program Files\'; ProgramFilesX86 = '\\srv\Program Files (x86)' }
Check 'v1.4.3: user-writable / odd / UNC roots refused; trailing slash trimmed' ((@(Get-VncProgramRoots $pr) -join '|') -eq 'C:\Program Files')
$pr = New-FakeFs @{} @{} @{ ProgramW6432 = ''; ProgramFiles = 'D:\Program Files'; ProgramFilesX86 = $null }
Check 'v1.4.3: other system drive ok; empty roots skipped' ((@(Get-VncProgramRoots $pr) -join '|') -eq 'D:\Program Files')
Check 'v1.4.3: file versions' ((Get-VncFileVersion '1.5.0.0') -eq [version]'1.5.0.0' -and (Get-VncFileVersion '1, 2, 4, 0') -eq [version]'1.2.4.0' -and (Get-VncFileVersion '') -eq [version]'0.0' -and (Get-VncFileVersion '1.10') -gt (Get-VncFileVersion '1.9.9'))
# known path found: no scan of folders at all
$pr = New-FakeFs @{ 'C:\Program Files (x86)\uvnc bvba\UltraVNC\vncviewer.exe' = @{ version = '1.2.4.0' } } @{ 'C:\Program Files' = @(@{ name = 'UltraVNC2' }) } $e64
$r = Find-VncViewerInProgramFiles $pr
Check 'v1.4.3: known path (x86, uvnc bvba\UltraVNC) found, how=known, no folder listing' ($r.path -eq 'C:\Program Files (x86)\uvnc bvba\UltraVNC\vncviewer.exe' -and $r.how -eq 'known' -and $pr.calls.Count -eq 0 -and @($r.others).Count -eq 0)
$pr = New-FakeFs @{ 'C:\Program Files (x86)\uvnc bvba\UltraVNC\vncviewer.exe' = @{ version = '1.2.4.0' }; 'C:\Program Files\UltraVNC\vncviewer.exe' = @{ version = '1.5.0.0' } } @{} $e64
$r = Find-VncViewerInProgramFiles $pr
Check 'v1.4.3: two known -> newest version wins, the other is listed' ($r.path -eq 'C:\Program Files\UltraVNC\vncviewer.exe' -and (@($r.others) -join '|') -eq 'C:\Program Files (x86)\uvnc bvba\UltraVNC\vncviewer.exe')
$pr = New-FakeFs @{ 'C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe' = @{ version = '1.5.0.0' }; 'C:\Program Files\UltraVNC\vncviewer.exe' = @{ version = '1.5.0.0' } } @{} $e64
$r = Find-VncViewerInProgramFiles $pr
Check 'v1.4.3: equal versions -> ordinal path order decides (UltraVNC < uvnc)' ($r.path -eq 'C:\Program Files\UltraVNC\vncviewer.exe' -and @($r.others).Count -eq 1)
# bounded scan
$dirs = @{ 'C:\Program Files' = @(@{ name = 'Common Files' }, @{ name = 'uvnc' }, @{ name = 'UltraVNC-old'; link = $true }, @{ name = 'Tools' })
           'C:\Program Files\uvnc' = @(@{ name = 'UltraVNC 1.6' }, @{ name = 'bin' })
           'C:\Program Files (x86)' = @(@{ name = 'MyUltraVNC' }) }
$files = @{ 'C:\Program Files\uvnc\UltraVNC 1.6\vncviewer.exe' = @{ version = '1.6.1.0' }; 'C:\Program Files\uvnc\bin\vncviewer.exe' = @{ version = '9.0' }
            'C:\Program Files\UltraVNC-old\vncviewer.exe' = @{ version = '9.0' }; 'C:\Program Files\Tools\vncviewer.exe' = @{ version = '9.0' }
            'C:\Program Files (x86)\MyUltraVNC\vncviewer.exe' = @{ version = '1.6.1.0'; link = $true } }
$pr = New-FakeFs $files $dirs $e64
$r = Find-VncViewerInProgramFiles $pr
Check 'v1.4.3: scan picks depth-2 *UltraVNC* folder under *uvnc*, how=scan' ($r.path -eq 'C:\Program Files\uvnc\UltraVNC 1.6\vncviewer.exe' -and $r.how -eq 'scan' -and @($r.others).Count -eq 0)
Check 'v1.4.3: scan skips non-matching folders (Tools, bin), a linked folder and a linked file' (-not ((@($r.others) + $r.path) -match 'Tools|\\bin\\|old|MyUltraVNC'))
Check 'v1.4.3: scan is bounded (lists only the roots and matching depth-1 folders, never Common Files / Tools / links)' ((@($pr.calls) -join '|') -eq 'C:\Program Files|C:\Program Files\uvnc|C:\Program Files (x86)|C:\Program Files (x86)\MyUltraVNC')
$pr = New-FakeFs @{ 'C:\Program Files\UltraVNC\VNCViewer.exe.lnk' = @{ version = '1.0' }; 'C:\Program Files\UltraVNC\vncviewer.exe' = $null } @{ 'C:\Program Files' = @(@{ name = 'UltraVNC' }) } $e64
$r = Find-VncViewerInProgramFiles $pr
Check 'v1.4.3: none found -> empty path, no crash' ($r.path -eq '' -and $r.how -eq '' -and @($r.others).Count -eq 0)
$pr = New-FakeFs @{ 'C:\Program Files\UltraVNC\vncviewer.exe' = @{ version = '1.5'; link = $true } } @{} $e64
Check 'v1.4.3: a known-path vncviewer.exe that is a link is refused' ((Find-VncViewerInProgramFiles $pr).path -eq '')
Check 'v1.4.3: only a file named vncviewer.exe counts' ($null -eq (Test-VncViewerFile 'C:\Program Files\UltraVNC\winvnc.exe' (New-FakeFs @{ 'C:\Program Files\UltraVNC\winvnc.exe' = @{ version = '1' } } @{} $e64)))
# log lines
$vi = @{ product = 'UltraVNC'; version = '1.5.0.0' }
Check 'v1.4.3: log line (found)' ((Get-VncViewerLogText 'C:\Program Files\UltraVNC\vncviewer.exe' 'scan' @('C:\x\vncviewer.exe') $vi) -ceq 'VNC viewer: "C:\Program Files\UltraVNC\vncviewer.exe" found by scan (viewer "UltraVNC" 1.5.0.0); also found: "C:\x\vncviewer.exe"')
Check 'v1.4.3: log line (none)' ((Get-VncViewerLogText '' '' @() $null) -ceq 'VNC viewer: not found in Program Files')
Check 'v1.4.3: log line strips control characters' ((Get-VncViewerLogText ("C:\a`r`nb\vncviewer.exe") 'override' @() $vi) -notmatch "[`r`n]")
$fv = (& $fn 'Find-VncViewer')
Check 'v1.4.3: Find-VncViewer order: valid saved path (override) > Program Files scan > HKLM App Paths > plain message + optional pick' ($fv.IndexOf("`$how = 'override'") -lt $fv.IndexOf('Initialize-VncViewerScan') -and $fv.IndexOf('Initialize-VncViewerScan') -lt $fv.IndexOf('HKLM:\Software') -and $fv.IndexOf('HKLM:\Software') -lt $fv.IndexOf("isn't installed on this PC") -and $fv -notmatch 'HKCU:' -and $fv -notmatch 'Find-Detected')
Check 'v1.4.3: start-up logs the version and runs the scan once (cached)' ($src.Contains("Get-LauncherStartLogText `$args[0] `$args[1]") -and $src.Contains("AddArgument(`$global:AppVersion)") -and $src.Contains('try { [void](Initialize-VncViewerScan) } catch {}') -and (& $fn 'Initialize-VncViewerScan').Contains('if ($global:VncViewerScan -and ($global:VncViewerScan.path -or -not $Retry -or'))
Check 'v1.4.4: no -password switch anywhere; store owner-only ACL from creation; DPAPI CurrentUser v2 entropy' ($src -notmatch "'-password'" -and (& $fn 'Save-VncSecret').Contains('New-VncOwnerOnlySecurity $false') -and (& $fn 'Save-VncSecret').Contains('[IO.Directory]::CreateDirectory($dir, (New-VncOwnerOnlySecurity $true))') -and (& $fn 'Save-VncSecret').Contains('[IO.File]::SetAccessControl($p, (New-VncOwnerOnlySecurity $false))') -and (& $fn 'New-VncOwnerOnlySecurity').Contains('SetAccessRuleProtection($true, $false)') -and (& $fn 'New-VncOwnerOnlySecurity').Contains("'S-1-5-18'") -and $src.Contains("GetBytes('ButtonLauncher.VNC.ViewOnly.v2')") -and (& $fn 'Save-VncSecret').Contains("'CurrentUser'"))
$td9 = Join-Path ([IO.Path]::GetTempPath()) ('bl-vnc-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $td9); Set-Content -LiteralPath (Join-Path $td9 'c.vnc') -Value '[connection]'
$td8 = Join-Path ([IO.Path]::GetTempPath()) ('bl-vnc-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $td8); Set-Content -LiteralPath (Join-Path $td8 'other.txt') -Value 'k'
Check 'v1.4.4: temp .vnc folder is deleted; a folder with anything else is left alone; start-up sweeps leftovers' ((Remove-VncTempDir $td9) -and -not (Test-Path -LiteralPath $td9) -and -not (Remove-VncTempDir $td8) -and (Test-Path -LiteralPath (Join-Path $td8 'other.txt')) -and $src.Contains('try { Remove-VncTempLeftovers 0 } catch {}') -and (& $fn 'Start-VncViewer').Contains('if ($file) { [void](Remove-VncTempDir (Split-Path -Parent $file)) }'))
Remove-Item -LiteralPath $td8 -Recurse -Force
# --- LJ M41-L1 / M41-I1 ---
$pr = New-FakeFs @{ 'C:\Program Files\UltraVNC\vncviewer.exe' = @{ version = '1.5' }; 'C:\Users\x\Desktop\UltraVNC Viewer.lnk' = @{ version = '' }; 'C:\Tools\vncviewer.exe.bak' = @{ version = '' } } @{} $e64
Check 'M41-L1: override must be a plain local file named exactly vncviewer.exe (.lnk, other names, empty, UNC refused)' ((Test-VncViewerFile 'C:\Program Files\UltraVNC\vncviewer.exe' $pr) -and -not (Test-VncViewerFile 'C:\Users\x\Desktop\UltraVNC Viewer.lnk' $pr) -and -not (Test-VncViewerFile 'C:\Tools\vncviewer.exe.bak' $pr) -and -not (Test-VncViewerFile '' $pr) -and -not (Test-VncViewerFile '\\srv\s\vncviewer.exe' (New-FakeFs @{ '\\srv\s\vncviewer.exe' = @{ version = '1' } } @{} $e64)))
Check 'M41-L1: odd text never throws in the leaf check' ($null -eq (Test-VncViewerFile 'C:\a<>|?*\x' $pr))
$fv = (& $fn 'Find-VncViewer')
Check 'M41-L1: Find-VncViewer uses Test-VncViewerFile for the override and logs + ignores a bad saved path, then searches' ($fv.Contains("if (Test-VncViewerFile `$t `$global:VncViewerProbe) { `$f = `$t; `$how = 'override' }") -and $fv.Contains('ignored (not a plain local vncviewer.exe); using the Program Files search') -and $fv -notmatch 'Test-Path -LiteralPath \$t')
Check 'M41-I1: the cached search result is rechecked with Test-VncViewerFile, not just Test-Path' ($fv.Contains('if ($s.path -and (Test-VncViewerFile $s.path $global:VncViewerProbe))'))
$tr = (& $fn 'Test-ButtonReady')
Check 'M41-L1: Set up this PC never runs Find-Detected for the View Register button' ($tr.IndexOf('if (Test-VncPickerButton $btn) { return $true }') -ge 0 -and $tr.IndexOf('if (Test-VncPickerButton $btn) { return $true }') -lt $tr.IndexOf('Find-Detected'))
$dj = Get-Content -LiteralPath (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
$vb = @(foreach ($pn in @($dj.panels)) { foreach ($b in @($pn.buttons)) { if ($b.vncPicker) { $b } } })
Check 'M41-L1: shipped View Register button has no detect paths/lnkNames and is still recognised as the picker' ($vb.Count -eq 1 -and $null -eq $vb[0].detect -and (Test-VncPickerButton $vb[0]))
# --- CC L2: search caps ---
$many = @{ 'C:\Program Files' = @(1..50 | ForEach-Object { @{ name = "App$_" } }) + @(@{ name = 'UltraVNC2' }) }
$pr = New-FakeFs @{ 'C:\Program Files\UltraVNC2\vncviewer.exe' = @{ version = '1.5' } } $many $e64; $pr.MaxDirs = 10
$r = Find-VncViewerInProgramFiles $pr
Check 'CC L2: folder cap stops the search and reports capped (no crash, nothing past the cap)' ($r.capped -and $r.path -eq '')
$pr = New-FakeFs @{ 'C:\Program Files\UltraVNC2\vncviewer.exe' = @{ version = '1.5' } } $many $e64
$r = Find-VncViewerInProgramFiles $pr
Check 'CC L2: under the default caps the same tree is searched fully' (-not $r.capped -and $r.path -eq 'C:\Program Files\UltraVNC2\vncviewer.exe')
$slow = New-FakeFs @{ 'C:\Program Files\UltraVNC2\vncviewer.exe' = @{ version = '1.5' } } $many $e64; $slow.MaxMs = 1; $d0 = $slow.Dirs
$slow.Dirs = { param($d) Start-Sleep -Milliseconds 20; & $d0 $d }.GetNewClosure()
Check 'CC L2: time cap stops the search' ((Find-VncViewerInProgramFiles $slow).capped)
Check 'CC L2: default caps 5000 folders / 2000 ms and the cap is logged' ((& $fn 'Find-VncViewerInProgramFiles').Contains('else { 5000 }') -and (& $fn 'Find-VncViewerInProgramFiles').Contains('else { 2000 }') -and (& $fn 'Initialize-VncViewerScan').Contains('search stopped early'))
# --- v1.4.6 ---
$ipRow = [pscustomobject]@{ name = 'POS1'; host = '192.168.20.51'; port = 5900; banner = 'RFB 003.008'; session = $true }
$nmRow = [pscustomobject]@{ name = 'POS1'; host = 'POS1'; port = 5900; banner = 'RFB 003.008'; session = $true }
$offRow = [pscustomobject]@{ name = 'POS2'; host = '192.168.20.52'; port = 5900; banner = ''; session = $false }
Check 'v1.4.6 Squint 1: saved password + IP row that answered -> no fallback message' ((Get-VncPasswordFallbackText $ipRow $true) -eq '')
Check 'v1.4.12: nothing saved, a hostname, and an unchecked row do not make View only ask' ((Get-VncPasswordFallbackText $ipRow $false) -eq '' -and (Get-VncPasswordFallbackText $nmRow $true) -eq '' -and (Get-VncPasswordFallbackText $offRow $true) -eq '')
$sv6 = & $fn 'Start-VncViewer'
Check 'v1.4.6 Squint 1: Start-VncViewer logs the ask reason only when no password file is sent; never $hex/$pb in it' ($sv6.Contains("`$why = if (`$viewOnly -and `$pw -eq 'none')") -and $sv6.Contains("Write-LauncherLog ('VNC view only: viewer will ask: ' + `$why)") -and $sv6.Contains('$global:vncPicker.setStatus.Invoke($why)') -and (& $fn 'Get-VncPasswordFallbackText') -notmatch '\$hex|Get-VncSecretHex|SecurePassword')
Check 'v1.4.6 Squint 2: Find-VncViewer and picker open re-search while not found' ((& $fn 'Find-VncViewer').Contains('Initialize-VncViewerScan -Retry') -and (& $fn 'Show-VncPicker').Contains('if ($global:VncViewerScan -and -not $global:VncViewerScan.path) { [void](Initialize-VncViewerScan -Retry) }'))
$global:VncViewerScan = $null; $global:scanCalls = 0; $global:VncViewerRetrySec = 0
function global:Find-VncViewerInProgramFiles { $global:scanCalls++; if ($global:scanCalls -ge 2) { @{ path = 'C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe'; how = 'known'; others = @() } } else { @{ path = ''; how = ''; others = @() } } }
function global:Get-VncViewerInfo { $null }; function global:Get-VncViewerLogText { 'x' }; function global:Write-LauncherLog { }
Invoke-Expression (& $fn 'Initialize-VncViewerScan')
$a1 = Initialize-VncViewerScan; $a2 = Initialize-VncViewerScan; $a3 = Initialize-VncViewerScan -Retry; $a4 = Initialize-VncViewerScan -Retry
Check 'v1.4.6 Squint 2: cached not-found is reused without -Retry, searched again with -Retry, and a found result is cached' (-not $a1.path -and -not $a2.path -and $a3.path -like '*vncviewer.exe' -and $a4.path -like '*vncviewer.exe' -and $global:scanCalls -eq 2)
Check 'v1.4.6 Kern: Remove password visible only when saved' ((Get-VncRemoveButtonVisibility $true) -eq 'Visible' -and (Get-VncRemoveButtonVisibility $false) -eq 'Collapsed')
$pd = & $fn 'Show-VncPasswordDialog'
Check 'v1.4.6 Kern: dialog has Password label 14 px #FFFFFF (0,0,0,8), field 0,0,0,8, 12 px #B4B4BC note, #B4B4BC Assertive status 0,0,0,16, reset hidden unless an override is saved' ($pd.Contains("New-D2Label 'Password' '#FFFFFF' 14; `$lb.Margin = '0,0,0,8'") -and $pd.Contains("`$pf.Margin = '0,0,0,8'") -and $pd.Contains("Used for View only on allowed computers. UltraVNC uses only the first 8 characters.' '#B4B4BC' 12") -and $pd.Contains("`$st = New-D2Label '' '#B4B4BC' 12; `$st.Margin = '0,0,0,16'") -and $pd.Contains("SetLiveSetting(`$st, 'Assertive')") -and $pd.Contains("New-D2Button 'Reset to default password' 'Chip'") -and $pd.Contains("New-D2Button 'Show password' 'Chip'") -and (& $fn 'Test-VncResetConfirm').Contains('Remove the saved override? View only will use the built-in default again.') -and $pd.Contains('$bNone.Visibility = Get-VncRemoveButtonVisibility $has') -and $pd -notmatch "'No password'|#A0A0A0|1234" -and $pd.Contains('Override reset. View only uses the built-in default.'))
Check 'LJ M46-I2: Get-VncPort/ConvertTo-VncEndpoint use [0-9] and \A..\z' ((& $fn 'Get-VncPort').Contains("'\A[0-9]{1,5}\z'") -and (& $fn 'ConvertTo-VncEndpoint').Contains("'\A([^:]+)::?([0-9]+)\z'") -and -not (Get-VncPort ([string][char]0x0661 + '5900')) -and (Get-VncPort '5900') -eq 5900)
$global:AppVersion = '1.4.12'; Invoke-Expression (& $fn 'Get-LauncherVersionText')
$mv = $src.IndexOf('$ver.IsEnabled = $false; [void]$setup.Items.Add($ver)'); $ms = $src.IndexOf("Add-MenuItem `$setup 'Set up this PC...'")
Check 'v1.4.6: Setup menu first item is a disabled "Button Launcher <AppVersion>" (no click handler)' ((Get-LauncherVersionText) -eq 'Button Launcher 1.4.12' -and $src.Contains("`$global:AppVersion   = '1.4.12'") -and $src.Contains('$ver.Header = Get-LauncherVersionText; $ver.IsEnabled = $false') -and $mv -gt 0 -and $mv -lt $ms -and $src.IndexOf('$setup.Items.Add') -eq $mv + '$ver.IsEnabled = $false; [void]'.Length -and $src -notmatch '\$ver\.Add_Click')
$global:VncViewerScan = $null; $global:scanCalls = 0; $global:VncViewerRetrySec = 30; $global:scanLogs = 0
function global:Get-VncViewerLogText { $global:scanLogs++; 'x' }
$b1 = Initialize-VncViewerScan; $b2 = Initialize-VncViewerScan -Retry; $c1 = $global:scanCalls
$global:VncViewerScan.at = [DateTime]::UtcNow.AddSeconds(-20); $b2b = Initialize-VncViewerScan -Retry; $c2 = $global:scanCalls
$global:VncViewerScan.at = [DateTime]::UtcNow.AddSeconds(-31); $b3 = Initialize-VncViewerScan -Retry
Check 'LJ M47-I2/CC N2: a not-found re-search (and its log line) is skipped under 30 s, runs after; default 30 s' ($c1 -eq 1 -and $c2 -eq 1 -and -not $b2b.path -and $global:scanLogs -eq 2 -and -not $b2.path -and $global:scanCalls -eq 2 -and $b3.path -like '*vncviewer.exe' -and $src.Contains('$global:VncViewerRetrySec = 30'))
$global:secretLeft = $true; $global:logs = @(); $global:said = $null
function global:Remove-VncViewOnlySecret { }; function global:Test-VncSecret { $global:secretLeft }; function global:Write-LauncherLog($m) { $global:logs += $m }
$rmSrc = [regex]::Match($pd, '\$bNone\.Add_Click\(\{(.*?)\}\.GetNewClosure\(\)\)', 'Singleline').Groups[1].Value
$rmRun = { param($left) $global:secretLeft = $left; $global:logs = @(); $global:said = $null
    $pb = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod Clear { } | Add-Member -PassThru ScriptMethod Focus { }
    $tb = [pscustomobject]@{ Text = 'x' } | Add-Member -PassThru ScriptMethod Focus { }; $reveal = @{ on = $false }
    $focusPw = { if ($reveal.on) { [void]$tb.Focus() } else { [void]$pb.Focus() } }
    $d = $null; function global:Test-VncResetConfirm { $true }
    $bNone = [pscustomobject]@{ Visibility = 'Visible' }; $res = @{ saved = $true }; $say = { param($m, $c) $global:said = $m }
    & ([scriptblock]::Create($rmSrc)); @{ vis = $bNone.Visibility; saved = $res.saved } }
$rf = & $rmRun $true; $rfSaid = $global:said; $rfLog = $global:logs
$ro = & $rmRun $false; $roSaid = $global:said; $roLog = $global:logs
Check 'LJ M47-I1: Reset rechecks; still saved -> failure message, button stays, log "reset failed"' ($rfSaid -like "Couldn't reset it.*still saved*" -and $rf.vis -eq 'Visible' -and $rf.saved -and $rfLog -contains 'view-only password: reset failed (still saved)' -and ($rfLog -join ' ') -notmatch 'hex|Secure|1234')
Check 'v1.4.12: Reset -> success message, button hidden, log "default"' ($roSaid -eq 'Override reset. View only uses the built-in default.' -and $ro.vis -eq 'Collapsed' -and -not $ro.saved -and $roLog -contains 'view-only password: default' -and ($roLog -join ' ') -notmatch '1234')
Check 'CC N3: Get-VncPrefix / Get-VncFileVersion use [0-9] (non-ASCII digits refused)' ((& $fn 'Get-VncPrefix') -notmatch '\\d' -and (& $fn 'Get-VncFileVersion') -notmatch '\\d' -and (Get-VncPrefix ([string][char]0x0662 + '4')) -eq 24 -and (Get-VncPrefix '23') -eq 23 -and (Get-VncFileVersion ([string][char]0x0661 + '.2')) -eq [version]'0.0' -and (Get-VncFileVersion '1.4.4.0') -eq [version]'1.4.4.0')
# --- v1.4.7 ---
$allA = New-Object object[] 4; $allA[0] = @(Get-VncViewerArgs '192.168.20.51' 5900 $false $null); $allA[1] = @(Get-VncViewerArgs '192.168.20.51' 5900 $true $null); $allA[2] = @(Get-VncViewerArgs '192.168.20.51' 5900 $true 'C:\T\bl-vnc-1\c.vnc'); $allA[3] = @(Get-VncViewerArgs 'REG1' 5901 $true $null)   # v1.4.9: kept as arrays (Interact is now one element)
Check 'v1.4.7 (Charles 8:22 AM): no -connect anywhere; bare host:port is argv[0] in every mode' ((@($allA | Where-Object { $_ -contains '-connect' }).Count -eq 0) -and $allA[0][0] -ceq '192.168.20.51:5900' -and $allA[1][0] -ceq '192.168.20.51:5900' -and $allA[2][0] -ceq '192.168.20.51:5900' -and $allA[3][0] -ceq 'REG1:5901' -and $src -notmatch "'-connect'")
Check 'v1.4.7: exact argv Interact / View only / View only + saved' ((($allA[0]) -join '|') -ceq '192.168.20.51:5900|-autoscaling' -and (($allA[1]) -join '|') -ceq '192.168.20.51:5900|-viewonly|-autoscaling' -and (($allA[2]) -join '|') -ceq '192.168.20.51:5900|-config|"C:\T\bl-vnc-1\c.vnc"|-viewonly|-autoscaling')
Check 'v1.4.7: single colon, ports below 100 still refused' (($allA[0][0] -notmatch '::') -and $(try { [void](Get-VncViewerArgs '192.168.20.51' 99 $false $null); $false } catch { $true }))
$lt7 = Get-VncLaunchLogText $true 'C:\v\vncviewer.exe' $allA[2] 'C:\T\bl-vnc-1\c.vnc' 'saved' @{ product = 'UltraVNC'; version = '1.5'; ultra = $true }
Check 'v1.4.7: launch log still redacts the temp .vnc path' ($lt7 -ceq 'VNC view only: "C:\v\vncviewer.exe" 192.168.20.51:5900 -config "<temp .vnc>" -viewonly -autoscaling (viewer "UltraVNC" 1.5); view-only password: saved' -and $lt7 -notmatch 'bl-vnc-1')
Check 'CC D1: scan age: clock moved back or missing = expired; recent = small' ((Get-VncScanAge ([DateTime]::UtcNow.AddSeconds(60))) -eq [double]::MaxValue -and (Get-VncScanAge $null) -eq [double]::MaxValue -and (Get-VncScanAge ([DateTime]::UtcNow.AddSeconds(-5))) -lt 10)
Check 'CC I1: chip drop handler uses [0-9] with \A..\z' ($src.Contains("'\Abl-chip:([0-9]{1,9})\z'") -and $src -notmatch "bl-chip:\(\\d")
Check 'CC I2: viewer version part over int32 -> 0.0, no throw' ((Get-VncFileVersion '99999999999.1') -eq [version]'0.0' -and (Get-VncFileVersion '1.5.0.0') -eq [version]'1.5.0.0')
# --- v1.4.9: the real View Register handler path (allowed list -> picker rows -> SelectedItem.row -> Start-VncViewer -> Start-Process) ---
foreach ($n in 'Test-VncAllowedName', 'Test-VncAllowedHost', 'ConvertTo-VncAllowedList', 'ConvertFrom-VncAllowedJson', 'Read-VncAllowed', 'Test-VncAllowedTarget', 'Get-VncViewOnlyLaunch', 'Get-VncViewOnlyDefaultBytes', 'Get-VncViewOnlyMaterial', 'Get-VncAllowedRows', 'Get-VncExeLeaf', 'Test-VncPasswordPrompt', 'Select-VncPasswordPrompt', 'Select-VncStartedPid', 'Get-VncViewerProcessList', 'Resolve-VncViewerPid', 'Get-VncVisibleWindowRows', 'Enable-VncViewerForeground', 'Show-VncPasswordPrompt', 'Update-VncPromptWatch', 'Start-VncPromptWatch', 'Start-VncViewer', 'Get-VncRowHost', 'Get-VncRowPort', 'Get-VncArgLine', 'Show-VncNotice', 'Get-VncViewerDir', 'Get-VncProcState', 'Get-VncElevatedWarning', 'Get-LauncherStartLogText', 'Test-LauncherElevated', 'Get-LauncherParentChain', 'New-VncStartInfo', 'Get-VncStartInfoLogText') { Invoke-Expression (& $fn $n) }
$global:VncAllowedMax = 50
$global:t9 = @{ sp = @(); log = @(); box = @() }
function global:Find-VncViewer($b) { 'C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe' }
function global:Get-VncViewerInfo($e) { @{ product = 'UltraVNC'; version = '1.5.0.0'; ultra = $true } }
function global:Write-LauncherLog($t) { $global:t9.log += [string]$t }
function global:Test-VncSecret { $false }
$defHex = ConvertTo-VncObfuscated (Get-VncViewOnlyDefaultBytes)
$plain = [Text.Encoding]::ASCII.GetString((Get-VncViewOnlyDefaultBytes))
Check 'default view-only password is the built-in value' ($plain -eq '1234' -and $defHex -match '^[0-9a-f]{16}$')
$matD = Get-VncViewOnlyMaterial
Check 'no override: View only material is the default' ($matD.kind -eq 'default' -and $matD.hex -eq $defHex)
function global:Test-VncSecret { $true }
function global:Get-VncSecretHex { '0123456789abcdef' }
$matS = Get-VncViewOnlyMaterial
Check 'override: View only material is the saved value' ($matS.kind -eq 'saved' -and $matS.hex -eq '0123456789abcdef' -and $matS.hex -ne $defHex)
function global:Test-VncSecret { $false }
$matC = Get-VncViewOnlyMaterial
Check 'clear: View only material is the default again' ($matC.kind -eq 'default' -and $matC.hex -eq $defHex)
$allowedPw = @([pscustomobject]@{ name = 'POS1'; host = '192.168.20.51'; port = 5900 }, [pscustomobject]@{ name = 'Name'; host = 'POS1'; port = 5900 })
$lvDef = Get-VncViewOnlyLaunch $true '192.168.20.51' 5900 $allowedPw $matC
$lvName = Get-VncViewOnlyLaunch $true 'POS1' 5900 $allowedPw $matC
$lvSav = Get-VncViewOnlyLaunch $true '192.168.20.51' 5900 $allowedPw $matS
$lvInt = Get-VncViewOnlyLaunch $false '192.168.20.51' 5900 $allowedPw $matS
$lvOut = Get-VncViewOnlyLaunch $true '10.0.0.9' 5900 $allowedPw $matC
Check 'allowed View only uses the default, including a name and a stale-shaped row' ($lvDef.use -and $lvDef.kind -eq 'default' -and $lvDef.hex -eq $defHex -and $lvName.use)
Check 'allowed View only uses the override when one is saved' ($lvSav.use -and $lvSav.kind -eq 'saved' -and $lvSav.hex -eq '0123456789abcdef')
Check 'Interact still gets no password file' (-not $lvInt.use -and $lvInt.kind -eq 'none' -and ((Get-VncViewerArgs '192.168.20.51' 5900 $false $null) -join ' ') -ceq '192.168.20.51:5900 -autoscaling')
Check 'a computer that is not allowed gets no password file' (-not $lvOut.use)
$cfgPw = New-VncConfigText '192.168.20.51' 5900 $defHex $true
$logPw = Get-VncLaunchLogText $true 'C:\v\vncviewer.exe' @('192.168.20.51:5900', '-config', '"C:\T\c.vnc"', '-viewonly', '-autoscaling') 'C:\T\c.vnc' 'default' @{ product = 'UltraVNC'; version = '1.5'; ultra = $true }
$favJson = '{"favorites":[{"host":"192.168.20.51","port":5900,"name":"POS1","pinned":false}]}'
Check 'nothing leaks the default password into the log, the dialog, the launch, or JSON' ($logPw -like '*view-only password: default*' -and $logPw -notmatch '1234' -and $logPw -notmatch $defHex -and $cfgPw -notmatch '1234' -and $favJson -notmatch '1234|password' -and (& $fn 'Show-VncPasswordDialog') -notmatch '1234' -and (& $fn 'Start-VncViewer') -notmatch '1234' -and (& $fn 'Get-VncLaunchLogText') -notmatch '1234')
function global:Test-VncSecret { $false }
function global:Read-VncAllowed { @{ list = @(); state = 'missing'; bad = 0 } }   # the integration launch must not read a real list or a password file
function global:Start-VncProcess($psi) { $global:t9.sp += ,@($psi.FileName, $psi.Arguments, $psi.WorkingDirectory, $psi.UseShellExecute, $psi.Verb); 1 }
function global:Show-VncNotice([string]$t) { $global:t9.box += $t }
$goSrc = [regex]::Match($src, '\$ui\.go = \[Action\[bool\]\]\{[^\n]*').Value
Check 'v1.4.9: Interact/View only click handlers call $ui.go, which passes SelectedItem.row to Start-VncViewer' ($goSrc.Contains('$s = $lv.SelectedItem') -and $goSrc.Contains('Start-VncViewer $ui.btn $s.row $vo') -and $src.Contains('$bInt.Add_Click({ $ui.go.Invoke($false) }') -and $src.Contains('$bView.Add_Click({ $ui.go.Invoke($true) }'))
$al9 = ConvertFrom-VncAllowedJson '{"version":1,"computers":[{"name":"POS1","host":"192.168.20.51","port":5900}]}'
$rows9 = @(Get-VncAllowedRows $al9.list @{ '192.168.20.51:5900' = 'RFB 003.008' } $false)
$lv9 = [pscustomobject]@{ SelectedItem = $rows9[0] }
# the closure body of $ui.go, run with the same names it captures
$ui9 = @{ btn = @{ label = 'View Register' }; win = $null }
$go9 = { param($vo) $s = $lv9.SelectedItem; if (-not $s) { return }; [void](Start-VncViewer $ui9.btn $s.row $vo $ui9.win $null) }
$env:USERPROFILE = 'C:\Users\Charles'; $global:LauncherElevated = $false; $global:t9.sp = @(); & $go9 $false
$a9 = [string]$global:t9.sp[0][1]
Check 'v1.4.9: View Register > POS1 > Interact: one argument string starting "192.168.20.51:5900"' ($global:t9.sp.Count -eq 1 -and $global:t9.sp[0][1] -is [string] -and $a9.StartsWith('192.168.20.51:5900') -and $a9 -ceq '192.168.20.51:5900 -autoscaling')
Check 'v1.4.9: Interact log line shows the exact exe and argument string' (@($global:t9.log) -contains 'VNC viewer start: exe="C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe" args="192.168.20.51:5900 -autoscaling" dir="C:\Program Files\uvnc bvba\UltraVNC" shell=True elevated=False' -and $global:t9.sp[0][3] -eq $true -and [string]$global:t9.sp[0][4] -eq '' -and $global:t9.sp[0][2] -eq 'C:\Program Files\uvnc bvba\UltraVNC')
$global:t9.sp = @(); & $go9 $true
Check 'v1.4.9: View Register > POS1 > View only: "192.168.20.51:5900 -viewonly -autoscaling"' ($global:t9.sp.Count -eq 1 -and [string]$global:t9.sp[0][1] -ceq '192.168.20.51:5900 -viewonly -autoscaling')
foreach ($rw in @(@{ host = '192.168.20.51'; port = 5900 }, ([pscustomobject]@{ host = '192.168.20.51'; port = 5900 }), $rows9[0], @{ row = @{ host = '192.168.20.51'; port = '5900' } })) {
    $global:t9.sp = @(); [void](Start-VncViewer @{} $rw $false $null $null)
    Check ('v1.4.9: row shape ' + $rw.GetType().Name + ' -> 192.168.20.51:5900') ($global:t9.sp.Count -eq 1 -and ([string]$global:t9.sp[0][1]) -ceq '192.168.20.51:5900 -autoscaling') }
foreach ($rw in @(@{ host = ''; port = 5900 }, ([pscustomobject]@{ name = 'POS1'; port = 5900 }), @{ Host = $null; port = 5900 }, ([pscustomobject]@{ host = '  '; port = 5900 }), $null)) {
    $global:t9.sp = @(); $global:t9.log = @(); $global:t9.box = @(); $ok9 = Start-VncViewer @{} $rw $false $null $null
    Check 'v1.4.9 guard: empty host refuses to launch, with a message and a log line' ($ok9 -eq $false -and $global:t9.sp.Count -eq 0 -and (@($global:t9.box) -join '|') -like '*no address*' -and (@($global:t9.log) -join '|') -like '*refused: empty host*') }
foreach ($rw in @(@{ host = 'reg1 -password x'; port = 5900 }, @{ host = '[::1]'; port = 5900 }, @{ host = 'fe80::1'; port = 5900 }, @{ host = '192.168.20.51'; port = 0 })) {
    $global:t9.sp = @(); $ok9 = Start-VncViewer @{} $rw $false $null $null
    Check ('v1.4.9 guard: invalid host/port refused: ' + $rw.host) ($ok9 -eq $false -and $global:t9.sp.Count -eq 0) }
Check 'v1.4.9: no assignment to the automatic $host anywhere' (-not $ast.Find({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -match '^\[?[^\]]*\]?\$host$' }, $true) -and $src -notmatch '(?i)foreach\s*\(\s*\$host\s+in|param\([^)]*\$host\b')
Check 'v1.4.10: -autoscaling is back, last (Interact = host:port -autoscaling, View only = host:port -viewonly -autoscaling, saved = host:port -config "<file>" -viewonly -autoscaling); host:port first' (((Get-VncViewerArgs '192.168.20.51' 5900 $false $null) -join ' ') -ceq '192.168.20.51:5900 -autoscaling' -and ((Get-VncViewerArgs '192.168.20.51' 5900 $true $null) -join ' ') -ceq '192.168.20.51:5900 -viewonly -autoscaling' -and ((Get-VncViewerArgs '192.168.20.51' 5900 $true 'C:\T\bl-vnc-1\c.vnc') -join ' ') -ceq '192.168.20.51:5900 -config "C:\T\bl-vnc-1\c.vnc" -viewonly -autoscaling')
$psi9 = New-VncStartInfo 'C:\v\vncviewer.exe' '192.168.20.51:5900 -config "C:\T\bl-vnc-1\c.vnc" -viewonly'
Check 'v1.4.9: ProcessStartInfo log reads the object, redacts the temp .vnc; no Verb, no env changes in the VNC launch' ((Get-VncStartInfoLogText $psi9 'C:\T\bl-vnc-1\c.vnc') -ceq 'VNC viewer start: exe="C:\v\vncviewer.exe" args="192.168.20.51:5900 -config "<temp .vnc>" -viewonly" dir="C:\v" shell=True elevated=False' -and (& $fn 'New-VncStartInfo') -notmatch 'Verb|Environment' -and (& $fn 'Start-VncViewer') -notmatch 'RunAs|Verb|EnvironmentVariables')
# --- v1.4.9 review follow-ups (CC Low/Minors, LJ M42-I1) ---
$ps9 = Get-VncProcState $null
$acts9 = @(foreach ($t in 0..12) { Get-VncTempAction $t $ps9.exited $ps9.window -1 })
Check 'CC Low: no process object -> not exited, no window; never "early", deleted at the fixed 8 s' ($ps9.exited -eq $false -and $ps9.window -eq $false -and $acts9 -notcontains 'early' -and $acts9[7] -eq 'wait' -and $acts9[8] -eq 'delete' -and (& $fn 'Remove-VncTempSoon').Contains('$ps = Get-VncProcState $proc'))
$global:t9.sp = @(); $global:t9.log = @(); function global:Start-VncProcess($psi) { $global:t9.sp += ,@($psi.FileName, $psi.Arguments); $null }
$global:t9.box = @(); $ok9 = Start-VncViewer @{} $rows9[0] $false $null $null
Check 'CC Low: Start returns no process -> logged, no "viewer closed" message, launch still reported' ($ok9 -eq $true -and (@($global:t9.log) -join '|') -like '*no process object returned*' -and @($global:t9.box).Count -eq 0)
Check 'CC Minor: viewer in a drive root -> working folder "C:\", in a folder -> that folder' ((Get-VncViewerDir 'C:\vncviewer.exe') -ceq 'C:\' -and (Get-VncViewerDir 'D:\vncviewer.exe') -ceq 'D:\' -and (Get-VncViewerDir 'C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe') -ceq 'C:\Program Files\uvnc bvba\UltraVNC' -and (New-VncStartInfo 'C:\vncviewer.exe' 'a:5900').WorkingDirectory -ceq 'C:\')
Check 'CC Minor: Get-VncArgLogText removed; stale host::port / "-config unused" header gone' ($src -notmatch 'Get-VncArgLogText' -and $src -notmatch "so we always use '::'" -and $src -notmatch '-config file \(unused' -and $src.Contains("('host:port -config ""<file>"" -viewonly')"))
$fp9 = @{ File = { param($f) if ($f -like '*link*') { @{ link = $true; version = '1.5' } } elseif ($f -like '*missing*') { $null } else { @{ link = $false; version = '1.5' } } }; Local = { param($p) $p -match '^[A-Za-z]:\\' -and $p -notlike 'Z:*' } }
Check 'LJ M42-I1: Test-VncViewerFile: only exactly vncviewer.exe, a plain file, absolute, local fixed disk' ([bool](Test-VncViewerFile 'C:\Tools\vncviewer.exe' $fp9) -and -not (Test-VncViewerFile 'C:\Tools\vncviewer.exe.lnk' $fp9) -and -not (Test-VncViewerFile 'C:\Tools\calc.exe' $fp9) -and -not (Test-VncViewerFile 'C:\link\vncviewer.exe' $fp9) -and -not (Test-VncViewerFile 'C:\missing\vncviewer.exe' $fp9) -and -not (Test-VncViewerFile 'vncviewer.exe' $fp9) -and -not (Test-VncViewerFile 'Tools\vncviewer.exe' $fp9) -and -not (Test-VncViewerFile '\\server\share\vncviewer.exe' $fp9) -and -not (Test-VncViewerFile 'Z:\vncviewer.exe' $fp9))
Invoke-Expression (& $fn 'Find-VncViewer')
$global:VncViewerProbe = $fp9; $global:t9.saved = 0
function global:Expand($x) { [string]$x }; function global:Is-Todo($x) { -not $x -or $x -eq 'TODO' }; function global:Initialize-VncViewerScan { @{ path = ''; how = ''; others = @() } }
function global:Get-ItemProperty { throw 'no registry' }; function global:Set-Prop($b, $k, $v) { $b[$k] = $v }; function global:Save-Config { $global:t9.saved++ }
function global:Get-VncViewerLogText { 'x' }; function global:Get-VncViewerInfo($e) { @{ product = 'UltraVNC'; version = '1.5'; ultra = $true } }
if ([System.Windows.MessageBox].GetField('Answer')) {
    [System.Windows.MessageBox]::Answer = 'Yes'
    foreach ($bad in 'C:\Tools\calc.exe', '\\server\share\vncviewer.exe', 'C:\link\vncviewer.exe', 'Tools\vncviewer.exe') {
        function global:Ask-ForPath($b, $k) { $script:pick9 }; $script:pick9 = $bad; $global:t9.box = @(); $global:t9.log = @(); $b9 = @{ target = 'TODO' }
        $r9 = Find-VncViewer $b9
        Check ('LJ M42-I1: hand-picked viewer refused with a message, not saved: ' + $bad) ($null -eq $r9 -and $b9.target -eq 'TODO' -and (@($global:t9.box) -join '|') -like "*can't be used*vncviewer.exe*") }
    $script:pick9 = 'C:\Tools\vncviewer.exe'; $b9 = @{ target = 'TODO' }; $r9 = Find-VncViewer $b9
    Check 'LJ M42-I1: a good hand-picked vncviewer.exe is used and saved' ($r9 -eq 'C:\Tools\vncviewer.exe' -and $b9.target -eq 'C:\Tools\vncviewer.exe')
} else { 'SKIP  hand-picked viewer (real WPF MessageBox loaded)' }
# --- v1.4.9 start-up diagnostics, elevation, Win+R-like start (Charles 10:35/10:37 AM) ---
Check 'diag: start-up line has version, elevated, 64-bit, cwd and the parent chain (names only)' ((Get-LauncherStartLogText '1.4.9' $true $false 'C:\Users\Charles\AppData\Local\Button Launcher' 'powershell.exe < ButtonLauncher.exe < explorer.exe') -ceq 'Launcher 1.4.9 started (elevated=True, 64-bit=False, cwd="C:\Users\Charles\AppData\Local\Button Launcher", parents="powershell.exe < ButtonLauncher.exe < explorer.exe")' -and (& $fn 'Get-LauncherParentChain') -match '\.Name\) 60' -and (& $fn 'Get-LauncherParentChain') -notmatch 'CommandLine|ExecutablePath')
Check 'diag: elevation read with WindowsPrincipal IsInRole Administrator, never throws; no behaviour depends on it except the warning' ((& $fn 'Test-LauncherElevated') -match 'IsInRole\(\[Security\.Principal\.WindowsBuiltInRole\]::Administrator\)' -and ($src -split 'LauncherElevated').Count -le 7)
$global:LauncherElevated = $true; $global:t9.sp = @(); $global:t9.log = @(); $wst9 = @(); $global:vncPicker = @{ setStatus = [Action[string]]{ param($x) $script:wst9 += $x } }
function global:Start-VncProcess($psi) { $global:t9.sp += ,@($psi.FileName, $psi.Arguments, $psi.WorkingDirectory); 1 }
$ok9 = Start-VncViewer @{} $rows9[0] $false $null $null
Check 'elevated launcher: one-line warning on the status line, launch log says elevated=True, viewer still started with the same arguments' ($ok9 -and $global:t9.sp.Count -eq 1 -and [string]$global:t9.sp[0][1] -ceq '192.168.20.51:5900 -autoscaling' -and @($script:wst9) -contains 'Button Launcher is running as administrator; restart it normally for VNC.' -and (@($global:t9.log) -join '|') -like '*elevated=True*')
$global:LauncherElevated = $false; $script:wst9 = @(); $global:t9.sp = @(); [void](Start-VncViewer @{} $rows9[0] $false $null $null)
Check 'not elevated: no warning' (@($script:wst9).Count -eq 0 -and (Get-VncElevatedWarning $false) -eq '')
$global:vncPicker = $null
Invoke-Expression (& $fn 'Start-VncProcess'); Invoke-Expression (& $fn 'Get-LauncherEnvText')
$sh9 = @{ calls = @() }; function global:New-ShellApplication { $o = [pscustomobject]@{}; $o | Add-Member ScriptMethod ShellExecute { param($f, $a, $d, $v, $n) $script:sh9.calls += ,@($f, $a, $d, $v, $n) }; $o }
$global:t9.log = @(); $psiA = New-VncStartInfo 'C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe' '192.168.20.51:5900'; $rA = Start-VncProcess $psiA
Check 'Explorer start: Shell.Application.ShellExecute(viewer, exact args, viewer folder, open, 1 = normal window); no process object (fixed 8 s temp delete); method logged' ($null -eq $rA -and $sh9.calls.Count -eq 1 -and $sh9.calls[0][0] -ceq 'C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe' -and $sh9.calls[0][1] -ceq '192.168.20.51:5900' -and $sh9.calls[0][2] -ceq 'C:\Program Files\uvnc bvba\UltraVNC' -and $sh9.calls[0][3] -eq 'open' -and $sh9.calls[0][4] -eq 1 -and $global:VncStartMethod -eq 'Shell.Application' -and (& $fn 'Start-VncViewer').Contains("Write-LauncherLog ('VNC viewer start: method={0}' -f `$global:VncStartMethod)"))
function global:New-ShellApplication { throw [System.Runtime.InteropServices.COMException]::new('no shell') }
$fb9 = $null; try { $fb9 = Start-VncProcess (New-VncStartInfo '/bin/true' '') } catch {}
Check 'fallback: Shell.Application throws -> logged, ProcessStartInfo ShellExecute, WindowStyle Normal, viewer folder' ($global:VncStartMethod -eq 'ProcessStartInfo' -and (@($global:t9.log) -join '|') -like '*Shell.Application failed (COMException); using ProcessStartInfo*' -and [string]$psiA.WindowStyle -eq 'Normal' -and $psiA.UseShellExecute -and $psiA.WorkingDirectory -ceq 'C:\Program Files\uvnc bvba\UltraVNC')
$env9 = Get-LauncherEnvText
Check 'diag: env line lists TEMP, APPDATA, USERPROFILE, PATH entry count, __COMPAT_LAYER, session; logged at start-up' ($env9 -match '^env: TEMP="[^"]*" APPDATA="[^"]*" USERPROFILE="[^"]*" PATH entries=\d+ __COMPAT_LAYER="[^"]*" session=\d+$' -and $src.Contains('(Get-LauncherParentChain); Get-LauncherEnvText } catch {}'))
Invoke-Expression (& $fn 'Step-LauncherLog'); $lt = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'bl-roll-test.log'); Remove-Item -LiteralPath ($lt + '.old') -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($lt, 'x' * 2000); $r1 = Step-LauncherLog $lt 1000; Check 'M56-I1: log past the limit rolls to .old' ($r1 -and -not (Test-Path -LiteralPath $lt) -and (Test-Path -LiteralPath ($lt + '.old')))
[IO.File]::WriteAllText($lt, 'x' * 10); $r2 = Step-LauncherLog $lt 1000; Check 'M56-I1: small log is left alone' (-not $r2 -and (Test-Path -LiteralPath $lt))
Check 'M56-I1: missing log is fine' (-not (Step-LauncherLog ($lt + '.none') 1000)); Remove-Item -LiteralPath $lt, ($lt + '.old') -ErrorAction SilentlyContinue
Check 'M56-I1 + v1.4.10 CC Low: parent chain = ONE CIM query for Name, ProcessId, ParentProcessId (1 s timeout), walked in memory' ($src.Contains('[void](Step-LauncherLog $global:logPath)') -and ([regex]::Matches($src, 'Get-CimInstance Win32_Process')).Count -eq 1 -and $src.Contains('Get-CimInstance Win32_Process -Property Name, ProcessId, ParentProcessId -OperationTimeoutSec 1 -ErrorAction Stop'))
Check 'v1.4.11 CC Low: start-up diagnostics in a background runspace whose script only builds the 2 lines (no log write, no UI), started after the start-up cwd is read' ($src.Contains('    [void](Start-LauncherDiagnostics)   #') -and (& $fn 'Start-LauncherDiagnostics').Contains('[PowerShell]::Create()') -and ([regex]::Match((& $fn 'Start-LauncherDiagnostics'), "\$body = '[^\n]*").Value -notmatch 'Write-LauncherLog|Add-Content|Dispatcher|MessageBox|vncPicker|FindName') -and $src.IndexOf('$global:LauncherStartCwd = ') -lt $src.IndexOf('    [void](Start-LauncherDiagnostics)   #'))
Check 'Shell.Application COM object released in finally; CC Low 1 trade-off documented' ($src.Contains('finally { if ($sh -and [Runtime.InteropServices.Marshal]::IsComObject($sh)) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)') -and $src.Contains('saved view-only password failure hint (OnEarlyExit) no longer shows'))
function global:Get-CimInstance { @([pscustomobject]@{ Name = 'powershell.exe'; ProcessId = $PID; ParentProcessId = 900 }, [pscustomobject]@{ Name = 'ButtonLauncher.exe'; ProcessId = 900; ParentProcessId = 800 }, [pscustomobject]@{ Name = 'explorer.exe'; ProcessId = 800; ParentProcessId = 800 }) }
Invoke-Expression (& $fn 'Get-LauncherParentChain'); $pc10 = Get-LauncherParentChain; Remove-Item function:Get-CimInstance
Check ('v1.4.10: in-memory parent walk -> ' + $pc10) ($pc10 -ceq 'ButtonLauncher.exe < explorer.exe')
# --- v1.4.11: Interact closes View Register once the viewer started (Charles 12:06 PM) ---
Invoke-Expression (& $fn 'Close-VncPickerAfterStart')
$global:cw = [pscustomobject]@{ closed = 0; log = @() }
function global:Write-LauncherLog([string]$m) { $global:cw.log += $m }
function New-FakeWin { $d = [pscustomobject]@{}; $d | Add-Member ScriptMethod BeginInvoke { param($pr, $a) $a.Invoke(); $null }; $w = [pscustomobject]@{ Dispatcher = $d }; $w | Add-Member ScriptMethod Close { $global:cw.closed++ }; $w }
$fw = New-FakeWin; $c1 = Close-VncPickerAfterStart $fw $false $true
Check 'v1.4.11: Interact + successful start -> View Register closes, log line written' ($c1 -eq $true -and $global:cw.closed -eq 1 -and (@($global:cw.log) -contains 'View Register closed after Interact start'))
$global:cw.closed = 0; $global:cw.log = @(); $c2 = Close-VncPickerAfterStart $fw $true $true
Check 'v1.4.11: View only + successful start -> stays open' ($c2 -eq $false -and $global:cw.closed -eq 0 -and @($global:cw.log).Count -eq 0)
$c3 = Close-VncPickerAfterStart $fw $false $false; $c4 = Close-VncPickerAfterStart $fw $false $null; $c5 = Close-VncPickerAfterStart $null $false $true
Check 'v1.4.11: Interact + failed start (guard, bad viewer, both starts threw -> $false) -> stays open; no window -> no-op' ($c3 -eq $false -and $c4 -eq $false -and $c5 -eq $false -and $global:cw.closed -eq 0)
# the real handler: Start-VncViewer stubbed to succeed / fail, then the go closure body as written in Launcher.ps1
$goBody = [regex]::Match($src, '\$ui\.go = \[Action\[bool\]\]\{ (param\(\$vo\)[^\n]*?) \}\.GetNewClosure\(\)').Groups[1].Value
$lv = [pscustomobject]@{ SelectedItem = [pscustomobject]@{ row = @{ host = '192.168.20.51'; port = 5900 } } }; $ui = @{ btn = @{}; win = (New-FakeWin) }; $wrongPw = $null
Invoke-Expression (& $fn 'Set-VncTilesBusy'); Invoke-Expression (& $fn 'Restore-VncTiles'); $bView = [pscustomobject]@{ IsEnabled = $true }; $bInt = [pscustomobject]@{ IsEnabled = $true }
foreach ($case in @(@($true, $false, 1), @($false, $false, 0), @($true, $true, 0))) {
    $global:svOk = $case[0]; function global:Start-VncViewer { $global:svOk }; $global:cw.closed = 0; $bView.IsEnabled = $true; $bInt.IsEnabled = $true
    & ([scriptblock]::Create($goBody)) $case[1]
    Check ('v1.4.11 handler: start ok=' + $case[0] + ', view only=' + $case[1] + ' -> closes ' + $case[2] + '; tiles re-enabled when it stays open') ($global:cw.closed -eq $case[2] -and ($case[2] -eq 1 -or ($bView.IsEnabled -and $bInt.IsEnabled))) }
function global:Start-VncViewer { $global:seenTiles = @($bView.IsEnabled, $bInt.IsEnabled); $global:svOk }; $global:svOk = $false; $bInt.IsEnabled = $false; & ([scriptblock]::Create($goBody)) $false
Check 'v1.4.11 Info: both tiles disabled during the start; afterwards back to their earlier state (Interact stays off if it was off)' (($global:seenTiles -join ',') -eq 'False,False' -and $bView.IsEnabled -and -not $bInt.IsEnabled)
function global:Start-VncViewer { throw 'boom' }; $bInt.IsEnabled = $true; try { & ([scriptblock]::Create($goBody)) $false } catch {}
Check 'v1.4.11 Info: a throwing start still re-enables the tiles (finally)' ($bView.IsEnabled -and $bInt.IsEnabled)
$fw2 = New-FakeWin; $global:cw.closed = 0
Check 'v1.4.11 Info: strict success check: only [bool] $true closes (not 1, ''True'', @($true))' (-not (Close-VncPickerAfterStart $fw2 $false 1) -and -not (Close-VncPickerAfterStart $fw2 $false 'True') -and -not (Close-VncPickerAfterStart $fw2 $false @($true)) -and $global:cw.closed -eq 0)
# CC L1/L2, LJ M61-I1: the runspace returns lines; the UI thread writes and disposes
foreach ($n in 'Get-LauncherStartLogText', 'Get-LauncherEnvText', 'Get-SafeText', 'Start-LauncherDiagnostics', 'Complete-LauncherDiagnostics', 'Stop-LauncherDiagnostics') { Invoke-Expression (& $fn $n) }
Invoke-Expression (& $fn 'Get-LauncherParentChain'); $global:cw.log = @(); $global:AppVersion = '1.4.11'; $global:LauncherElevated = $false; $global:LauncherStartCwd = 'C:\x'
$sd = Start-LauncherDiagnostics; $dps = $global:LauncherDiag.ps; [void]$global:LauncherDiag.h.AsyncWaitHandle.WaitOne(20000); $nw = Complete-LauncherDiagnostics
Check 'CC L1: runspace returns 2 lines; written by Write-LauncherLog on the calling thread; runspace never writes the log' ($sd -eq $true -and $nw -eq 2 -and @($global:cw.log)[0] -like 'Launcher 1.4.11 started (elevated=False*' -and @($global:cw.log)[1] -like 'env: TEMP=*' -and (& $fn 'Start-LauncherDiagnostics') -notmatch "'Write-LauncherLog'|Add-Content")
Check 'CC L2 / LJ M61-I1: EndInvoke + Dispose after completion; handle cleared' ($null -eq $global:LauncherDiag -and $dps.InvocationStateInfo.State -eq 'Completed' -and $(try { [void]$dps.AddScript('1'); $false } catch { $true }))
$hang = [PowerShell]::Create(); [void]$hang.AddScript('Start-Sleep -Seconds 60'); $global:LauncherDiag = @{ ps = $hang; h = $hang.BeginInvoke(); born = [DateTime]::UtcNow }; $sw = [Diagnostics.Stopwatch]::StartNew(); Stop-LauncherDiagnostics
Check ('LJ M61-I1: exit with a hung runspace returns at once (BeginStop + Dispose): ' + $sw.ElapsedMilliseconds + ' ms') ($sw.ElapsedMilliseconds -lt 3000 -and $null -eq $global:LauncherDiag -and $src.Contains('try { Clear-VncDeadWorkers -All } catch {}; try { Stop-LauncherDiagnostics } catch {};'))
Check 'CC Info: start-up call discards its result; README mentions the close' ($src.Contains('    [void](Start-LauncherDiagnostics)   #') -and (Get-Content -Raw (Join-Path $root 'README.txt')).Contains('Interact closes View Register once the viewer starts.'))
Check 'v1.4.11: close goes through Closed (watcher + worker cleanup); temp .vnc timer is not owned by the window; args and start method unchanged' ((& $fn 'Close-VncPickerAfterStart').Contains('$win.Close()') -and $src.Contains('Remove-VncTileWatch $bView; Remove-VncTileWatch $bInt') -and (& $fn 'Remove-VncTempSoon') -notmatch '\$win|vncPicker|Owner' -and ((Get-VncViewerArgs '192.168.20.51' 5900 $false $null) -join ' ') -ceq '192.168.20.51:5900 -autoscaling' -and (& $fn 'Start-VncProcess').Contains('ShellExecute($psi.FileName, $psi.Arguments, $psi.WorkingDirectory, ''open'', 1)'))
$closeSrc = & $fn 'Close-VncPickerAfterStart'
Check 'prompt focus runs after View Register closes' ($closeSrc.IndexOf('$win.Close()') -ge 0 -and $closeSrc.IndexOf('$win.Close()') -lt $closeSrc.IndexOf('Show-VncPasswordPrompt'))
foreach ($n in 'Get-VncExeLeaf', 'Test-VncPasswordPrompt', 'Select-VncPasswordPrompt', 'Select-VncStartedPid') { Invoke-Expression (& $fn $n) }
$auth = [pscustomobject]@{ pid = 40; class = '#32770'; title = 'VNC Authentication'; hwnd = 7 }
$otherPid = [pscustomobject]@{ pid = 9; class = '#32770'; title = 'VNC Authentication'; hwnd = 8 }
$main = [pscustomobject]@{ pid = 40; class = 'VNCViewer'; title = 'UltraVNC Viewer'; hwnd = 3 }
$save = [pscustomobject]@{ pid = 40; class = '#32770'; title = 'Save As'; hwnd = 4 }
Check 'password window: this PID, dialog class, and an auth title' ((Test-VncPasswordPrompt 40 '#32770' 'VNC Authentication' 40) -and (Test-VncPasswordPrompt 40 '#32770' 'UltraVNC Authentication' 40) -and -not (Test-VncPasswordPrompt 9 '#32770' 'VNC Authentication' 40) -and -not (Test-VncPasswordPrompt 40 'VNCViewer' 'UltraVNC Viewer' 40) -and -not (Test-VncPasswordPrompt 40 '#32770' 'Save As' 40) -and -not (Test-VncPasswordPrompt 40 '#32770' 'VNC Authentication' 0))
$nowF = [datetime]::UtcNow
$hitF = Select-VncPasswordPrompt @($main, $otherPid, $save, $auth) 40 $nowF $nowF.AddSeconds(1)
Check 'password window: the match is that dialog, not another window' ($hitF.hwnd -eq 7 -and $hitF.pid -eq 40)
Check 'password window: past the deadline returns nothing' ($null -eq (Select-VncPasswordPrompt @($auth) 40 $nowF.AddSeconds(2) $nowF))
$ran = @([pscustomobject]@{ Id = 10; Name = 'vncviewer.exe'; Path = 'C:\v\vncviewer.exe'; Started = $nowF.AddSeconds(-30) }, [pscustomobject]@{ Id = 42; Name = 'vncviewer.exe'; Path = 'C:\v\vncviewer.exe'; Started = $nowF }, [pscustomobject]@{ Id = 7; Name = 'notepad.exe'; Path = 'C:\n\notepad.exe'; Started = $nowF })
Check 'started PID: ProcessStartInfo id wins; otherwise the new viewer, not an older one or another program' ((Select-VncStartedPid 15 @(10) $ran 'C:\v\vncviewer.exe') -eq 15 -and (Select-VncStartedPid 0 @(10) $ran 'C:\v\vncviewer.exe') -eq 42 -and (Select-VncStartedPid 0 @(10, 42) $ran 'C:\v\vncviewer.exe') -eq 0)
$tie = @($ran[1], [pscustomobject]@{ Id = 43; Name = 'vncviewer.exe'; Path = 'C:\v\vncviewer.exe'; Started = $nowF })
Check 'started PID: two new viewers with the same start time are refused, and a path that does not match is ignored' ((Select-VncStartedPid 0 @(10) $tie 'C:\v\vncviewer.exe') -eq 0 -and (Select-VncStartedPid 0 @() @([pscustomobject]@{ Id = 8; Name = 'vncviewer.exe'; Path = 'C:\other\vncviewer.exe'; Started = $nowF }) 'C:\v\vncviewer.exe') -eq 0)
$ws = [regex]::Match($src, "(?s)\`$global:WaitsSource = @'.*?'@").Value
Check 'GetWindowLongW is the Unicode export and BL.Waits still has no key injection' ($ws -match 'EntryPoint = "GetWindowLongW"' -and $ws -match 'static extern int GetWindowLongW' -and $ws -notmatch 'EntryPoint = "GetWindowLong"' -and $ws -notmatch 'SendKeys|keybd_event|SendInput|SetWindowText')
Check 'prompt wait is a dispatcher timer, not a sleep on the UI thread' ((& $fn 'Start-VncViewer') -notmatch 'Start-Sleep' -and (& $fn 'Start-VncViewer') -match 'Start-VncPromptWatch' -and (& $fn 'Start-VncPromptWatch') -match 'DispatcherTimer' -and (& $fn 'Start-VncPromptWatch') -notmatch 'Start-Sleep' -and (& $fn 'Update-VncPromptWatch') -match 'Resolve-VncViewerPid')
$global:pidSnap = @([pscustomobject]@{ Id = 10; Name = 'vncviewer.exe'; Path = 'C:\v\vncviewer.exe'; Started = $nowF.AddMinutes(-5) })
function global:Get-VncViewerProcessList { $global:pidSnap }
function global:Get-VncVisibleWindowRows { @() }
$st = @{ proc = $null; exe = 'C:\v\vncviewer.exe'; before = @(10); born = [datetime]::UtcNow; pid = 0; granted = $false; hit = $null }
Check 'prompt watch: the first look does not adopt a viewer that was already running' ((Update-VncPromptWatch $st ([datetime]::UtcNow)) -eq 'wait' -and $st.pid -eq 0)
$global:pidSnap = @($global:pidSnap) + @([pscustomobject]@{ Id = 42; Name = 'vncviewer.exe'; Path = 'C:\v\vncviewer.exe'; Started = [datetime]::UtcNow })
function global:Get-VncVisibleWindowRows { @([pscustomobject]@{ pid = 42; class = '#32770'; title = 'VNC Authentication'; hwnd = 5 }) }
Check 'prompt watch: a later snapshot adopts only the new viewer and can see its dialog' ((Update-VncPromptWatch $st ([datetime]::UtcNow)) -eq 'found' -and $st.pid -eq 42 -and $st.hit.hwnd -eq 5)
Invoke-Expression (& $fn 'Get-VncViewerProcessList'); Invoke-Expression (& $fn 'Get-VncVisibleWindowRows')
Invoke-Expression (& $fn 'Stop-VncPromptWatch'); Invoke-Expression (& $fn 'Complete-VncPromptWatch'); Invoke-Expression (& $fn 'Enable-VncPickerTiles')
$stopped = $false
$fakeTimer = [pscustomobject]@{ }
$fakeTimer | Add-Member ScriptMethod Stop { $script:stopped = $true }
$oldWatch = @{ id = 'old'; done = $false; timer = $fakeTimer }
$global:VncPromptWatch = $oldWatch
Stop-VncPromptWatch $oldWatch
Check 'prompt watch: Stop releases the timer and drops that watch' ($stopped -and $oldWatch.done -and $null -eq $global:VncPromptWatch)
$global:tieLog = @(); function global:Write-LauncherLog($m) { $global:tieLog += [string]$m }
$global:VncPromptTie = $true
$tieWatch = @{ id = 'tie'; done = $false; timer = $null; pid = 0; viewOnly = $true; win = $null; hit = $null }
$global:VncPromptWatch = $tieWatch
Complete-VncPromptWatch $tieWatch 'timeout'
Check 'prompt watch: a same-start tie is logged without a path or a password' (($global:tieLog -join '|') -eq 'VNC password prompt: refused, two viewers started together' -and ($global:tieLog -join '|') -notmatch '1234|:\\')
$sw = & $fn 'Start-VncPromptWatch'
Check 'prompt watch: a new launch stops the previous timer, and a failed tick stops it and re-enables the tiles' ($sw.IndexOf('Stop-VncPromptWatch $global:VncPromptWatch') -ge 0 -and $sw.IndexOf('Stop-VncPromptWatch $global:VncPromptWatch') -lt $sw.IndexOf('$global:VncPromptWatch = $state') -and $sw.Contains("Write-LauncherLog 'VNC password prompt: watch failed'") -and $sw.Contains('finally { if ($failed) { Stop-VncPromptWatch $state; Enable-VncPickerTiles $state.win } }') -and $src.Contains('Add_Closed({ Stop-VncPromptWatch $global:VncPromptWatch'))
$global:tileProbe = @{ list = [pscustomobject]@{ SelectedItem = 'x' }; view = [pscustomobject]@{ IsEnabled = $false }; interact = [pscustomobject]@{ IsEnabled = $false } }
$tileWin = [pscustomobject]@{}; $tileWin | Add-Member ScriptMethod FindName { param($n) $global:tileProbe[$n.ToLower()] }
Enable-VncPickerTiles $tileWin
Check 'prompt watch: re-enable follows the selection' ($global:tileProbe.view.IsEnabled -and $global:tileProbe.interact.IsEnabled)
$ws = [regex]::Match($src, "(?s)\`$global:WaitsSource = @'.*?'@").Value
$focusSrc = (& $fn 'Start-VncViewer') + (& $fn 'Show-VncPasswordPrompt') + $ws
Check 'prompt focus: Interact or a View only fallback only; no typing into the field' ($focusSrc -match '\$expectPrompt = \(-not \$viewOnly\) -or \(\$pw -eq ''none''\)' -and $focusSrc -match 'AllowSetForegroundWindow' -and $focusSrc -match '0x0028' -and $focusSrc -notmatch 'SendKeys|keybd_event|SendInput|SetWindowText|WM_SETTEXT|WM_CHAR')
# --- v1.4.12 review: truthful reachability. No sockets are opened here. ---
foreach ($n in 'Get-VncReachKind', 'Test-VncReachTarget', 'ConvertTo-VncReachBanner', 'New-VncReachState', 'Start-VncReachCheck', 'Add-VncReachObservation', 'Complete-VncReachCheck', 'Close-VncReachCheck', 'Get-VncReachCounts', 'Get-VncReachExpiryMs', 'Get-VncReachStatusText', 'Get-VncChromeDelta', 'Get-VncPickerRows', 'Get-VncReachShort', 'Test-VncReachAllExpired', 'Get-VncReachFooter', 'Get-VncStatusWrite', 'Get-VncPickerReason') { Invoke-Expression (& $fn $n) }
$nowR = [datetime]::UtcNow
Check 'reach: valid allowed target vs bad host, low port, empty' ((Test-VncReachTarget '192.168.20.51' 5900) -and (Test-VncReachTarget 'POS1' 5900) -and -not (Test-VncReachTarget 'not a host' 5900) -and -not (Test-VncReachTarget '192.168.20.51' 99) -and -not (Test-VncReachTarget '192.168.20.51' 0) -and -not (Test-VncReachTarget '' 5900))
Check 'reach kind: invalid wins even if a connect looks successful; cancel wins over a finished connect' ((Get-VncReachKind $false $false $true $true $true $false 12) -eq 'invalid' -and (Get-VncReachKind $true $true $true $true $true $false 12) -eq 'cancelled')
Check 'reach kind: begin-failed, timeout, refused, read-timeout, banner, closed' ((Get-VncReachKind $true $false $false $false $false $false 0) -eq 'begin-failed' -and (Get-VncReachKind $true $false $true $false $false $false 0) -eq 'timeout' -and (Get-VncReachKind $true $false $true $true $false $false 0) -eq 'refused' -and (Get-VncReachKind $true $false $true $true $true $true 4) -eq 'read-timeout' -and (Get-VncReachKind $true $false $true $true $true $false 12) -eq 'banner' -and (Get-VncReachKind $true $false $true $true $true $false 5) -eq 'closed')
foreach ($pair in @(@('banner','RFB 003.008','online'), @('banner','SSH-2.0-Open','offline'), @('banner','','offline'), @('refused','','offline'), @('closed','','offline'), @('timeout','','unchecked'), @('read-timeout','','unchecked'), @('invalid','','unchecked'), @('cancelled','','unchecked'), @('begin-failed','','unchecked'), @('worker-fault','','unchecked'), @('missing','','unchecked'))) {
    Check ('reach outcome ' + $pair[0] + ' -> ' + $pair[2]) ((Get-VncReachOutcome @{ kind = $pair[0]; banner = $pair[1] }) -eq $pair[2]) }
Check 'fresh through 60 s, stale at 61 s, stale if missing or more than 5 min ahead' (-not (Test-VncReachStale $nowR.AddSeconds(-60) $nowR) -and (Test-VncReachStale $nowR.AddSeconds(-61) $nowR) -and (Test-VncReachStale ([datetime]::MinValue) $nowR) -and (Test-VncReachStale $nowR.AddMinutes(6) $nowR) -and -not (Test-VncReachStale $nowR.AddMinutes(4) $nowR))
$one = @([pscustomobject]@{ name = 'POS1'; host = '192.168.20.51'; port = 5900; seen = $true })
$disc = Get-VncAllowedRows $one @{} $false $nowR
Check 'discovery is not Online: a seen flag with no check is Not checked' ($disc[0].statusText -eq 'Not checked' -and $disc[0].statusKind -eq 'unchecked' -and -not $disc[0].row.session -and $disc[0].statusTip -match 'not Online' -and $disc[0].seen -ne 'Online')
$fly = Get-VncAllowedRows $one @{} $true $nowR
Check 'in-flight: Not checked, not Offline, tip says a check is in progress' ($fly[0].statusText -eq 'Not checked' -and $fly[0].statusTip -match 'in progress' -and $fly[0].statusTip -match 'not Offline' -and -not $fly[0].row.session)
$okR = Get-VncAllowedRows $one @{ '192.168.20.51:5900' = @{ kind = 'banner'; banner = 'RFB 003.008'; at = $nowR } } $true $nowR
Check 'success: fresh RFB is Online while other rows could still be in flight; tip does not claim sign-in or a session' ($okR[0].statusKind -eq 'online' -and $okR[0].statusText -eq 'Online' -and $okR[0].row.session -and $okR[0].row.banner -eq 'RFB 003.008' -and (Test-VncUsePassword $okR[0].row $true) -and $okR[0].statusTip -match 'Nothing was signed in' -and $okR[0].statusTip -match 'no remote session' -and $okR[0].statusTip -notmatch 'password')
$ref = Get-VncAllowedRows $one @{ '192.168.20.51:5900' = @{ kind = 'refused'; banner = ''; at = $nowR } } $false $nowR
Check 'refusal: check finished and the port refused -> Offline, and the password gate stays open' ($ref[0].statusText -eq 'Offline' -and $ref[0].statusKind -eq 'offline' -and $ref[0].statusTip -match 'refused' -and -not $ref[0].row.session -and (Test-VncUsePassword $ref[0].row $true))
$to = Get-VncAllowedRows $one @{ '192.168.20.51:5900' = @{ kind = 'timeout'; banner = ''; at = $nowR } } $false $nowR
Check 'timeout is Not checked, not Offline' ($to[0].statusText -eq 'Not checked' -and $to[0].statusKind -eq 'unchecked' -and $to[0].statusTip -match 'timed out' -and $to[0].statusTip -match 'not Offline' -and -not $to[0].row.session)
$rt = Get-VncAllowedRows $one @{ '192.168.20.51:5900' = @{ kind = 'read-timeout'; banner = ''; at = $nowR } } $false $nowR
Check 'read timeout is Not checked, not Offline' ($rt[0].statusText -eq 'Not checked' -and $rt[0].statusTip -match 'did not finish a VNC greeting' -and -not $rt[0].row.session)
$badR = Get-VncAllowedRows $one @{ '192.168.20.51:5900' = @{ kind = 'invalid'; banner = ''; at = $nowR } } $false $nowR
Check 'invalid target: Not checked, nothing contacted' ($badR[0].statusText -eq 'Not checked' -and $badR[0].statusTip -match 'nothing was contacted')
$staleR = Get-VncAllowedRows $one @{ '192.168.20.51:5900' = @{ kind = 'banner'; banner = 'RFB 003.008'; outcome = 'online'; at = $nowR.AddSeconds(-61) } } $false $nowR
Check 'stale Online expires to Not checked, and View only may still use the password file' ($staleR[0].statusText -eq 'Not checked' -and $staleR[0].statusTip -match 'expired' -and $staleR[0].statusTip -match 'was Online' -and -not $staleR[0].row.session -and (Test-VncUsePassword $staleR[0].row $true) -and $staleR[0].tip -match 'Last check')
$staleOff = Get-VncAllowedRows $one @{ '192.168.20.51:5900' = @{ kind = 'refused'; outcome = 'offline'; at = $nowR.AddMinutes(-3) } } $false $nowR
Check 'stale Offline expires to Not checked (expired is not still Offline)' ($staleOff[0].statusText -eq 'Not checked' -and $staleOff[0].statusTip -match 'was Offline' -and $staleOff[0].statusTip -match 'not still Offline')
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:VncTileSize\s*=') { Invoke-Expression $l.Extent.Text } }
Check 'no selection: tiles stay disabled and the status reason is unchanged' ((Get-VncPickerReason $false) -ceq 'Pick a computer to view or control it.' -and (Get-VncPickerReason $true) -eq '' -and (& $fn 'Show-VncPicker') -match '\$bView.IsEnabled = \$has; \$bInt.IsEnabled = \$has')
$rs = New-VncReachState; $g1 = Start-VncReachCheck $rs
[void](Add-VncReachObservation $rs $g1 '192.168.20.51:5900' 'refused' '' $nowR)
$g2 = Start-VncReachCheck $rs
$late = Add-VncReachObservation $rs $g1 '192.168.20.51:5900' 'refused' '' $nowR
$keep = Add-VncReachObservation $rs $g2 '192.168.20.51:5900' 'banner' 'RFB 003.008' $nowR
$oldDone = Complete-VncReachCheck $rs $g1 $true $nowR
$done2 = Complete-VncReachCheck $rs $g2 $false $nowR
$after = Add-VncReachObservation $rs $g2 '192.168.20.51:5900' 'timeout' '' $nowR
Check 'repeated refresh: old generation cannot overwrite; late result after complete is ignored' ($g1 -eq 1 -and $g2 -eq 2 -and -not $late -and $keep -and $rs.results['192.168.20.51:5900'].outcome -eq 'online' -and -not $oldDone -and $done2 -and -not $rs.checking -and -not $after)
[void](Close-VncReachCheck $rs)
Check 'window close: further checks and results are refused' ($rs.closed -and (Start-VncReachCheck $rs) -eq 0 -and $rs.gen -eq 2 -and -not (Add-VncReachObservation $rs 3 '192.168.20.51:5900' 'refused' '' $nowR) -and $rs.results['192.168.20.51:5900'].outcome -eq 'online')
$two = @([pscustomobject]@{ name = 'A'; host = '192.168.20.51'; port = 5900 }, [pscustomobject]@{ name = 'B'; host = '10.0.0.8'; port = 5900 })
$mix = @{ '192.168.20.51:5900' = @{ kind = 'banner'; banner = 'RFB 003.008'; at = $nowR }; '10.0.0.8:5900' = @{ kind = 'timeout'; at = $nowR } }
$cnt = Get-VncReachCounts $two $mix $nowR
Check 'counts: one Online and one timeout is 1 online, 0 offline, 1 not checked' ($cnt.online -eq 1 -and $cnt.offline -eq 0 -and $cnt.unchecked -eq 1)
$checkingLine = Get-VncReachStatusText 1 0 1 $true $false $false ''
Check 'status line while checking keeps the counts and does not say a row is Offline' ($checkingLine -eq 'Checking. 1 online, 0 offline, 1 not checked.' -and $checkingLine -notmatch 'are Offline|is Offline')
Check 'status line: a failed check is Not checked, not N of M online' ((Get-VncReachStatusText 0 0 2 $false $true $false '3:00 PM') -match 'Not Offline' -and (Get-VncReachStatusText 1 0 1 $false $false $false '3:00 PM') -eq '1 online, 0 offline, 1 not checked. Press F5 to check again.')
Check 'status line: expiry is not Offline' ((Get-VncReachStatusText 0 0 2 $false $false $true '') -match 'not Offline' -and (Get-VncReachStatusText 0 0 2 $false $false $true '') -match 'Not checked')
$exp = @{ '192.168.20.51:5900' = @{ outcome = 'online'; kind = 'banner'; banner = 'RFB 003.008'; at = $nowR.AddSeconds(-30) } }
$msExp = Get-VncReachExpiryMs $exp $nowR
Check ('expiry timer is the remaining freshness, capped at 60 s, and -1 when nothing is still Online or Offline: ' + $msExp) ($msExp -ge 29000 -and $msExp -le 31000 -and (Get-VncReachExpiryMs @{ 'x:1' = @{ outcome = 'unchecked'; kind = 'timeout'; at = $nowR } } $nowR) -eq -1 -and (Get-VncReachExpiryMs @{ 'x:1' = @{ outcome = 'online'; at = $nowR.AddSeconds(-61) } } $nowR) -eq -1)
$chk = [regex]::Match($src, '(?s)\$global:VncAllowedCheckScript = \{.*?\n\}').Value
$iCancel = $chk.IndexOf('if ($sync.cancel)'); $iProbe = $chk.IndexOf('if (-not $probe)'); $iTcp = $chk.IndexOf('New-Object System.Net.Sockets.TcpClient')
Check 'check script: cancel and non-probe return before any socket' ($iCancel -ge 0 -and $iProbe -gt $iCancel -and $iTcp -gt $iProbe -and $chk -match 'Get-VncReachKind' -and $chk -notmatch '\.Write\(|BeginSend|\.Send\(' -and $chk -match 'finally \{ foreach \(\$b in \$batch\) \{ try \{ \$b\.c\.Close\(\) \}' -and $chk -notmatch 'Get-VncScanTargets|VncScanScript|confirmedRanges|vnc-viewonly|email-count|SecureString')
if ($iTcp -gt $iProbe -and $iProbe -gt $iCancel) {
    Invoke-Expression $chk
    $syncR = [hashtable]::Synchronized(@{ cancel = $false; done = $false; found = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]) })
    & $global:VncAllowedCheckScript @(@{ key = 'bad host:5900'; host = 'bad host'; port = 5900; probe = $false }, @{ key = '192.168.20.51:99'; host = '192.168.20.51'; port = 99; probe = $false }) 300 $syncR
    $gotR = @(); $oneR = $null; while ($syncR.found.TryDequeue([ref]$oneR)) { $gotR += $oneR }
    Check 'simulated invalid rows: both Not-checked kinds, done, no connect' ($syncR.done -and $gotR.Count -eq 2 -and @($gotR | Where-Object { $_.kind -eq 'invalid' }).Count -eq 2)
} else { Check 'refused to execute the check script (it might connect)' $false }
$pkR = & $fn 'Show-VncPicker'
Check 'picker check list is only the allowed computers, with an explicit probe flag' ($pkR -match 'foreach \(\$e in \$ui.allowed\)' -and $pkR -match 'probe = \(Test-VncReachTarget' -and $pkR -notmatch 'Get-VncScanTargets|Start-VncScan|Get-VncLocalSubnets')
Check 'F5 while a check is in flight stops it with BeginStop before the next generation' ($pkR -match 'if \(\$ui.check\) \{ \$ui.stopCheck.Invoke\(\) \}' -and $pkR.IndexOf('if ($ui.check) { $ui.stopCheck.Invoke() }') -lt $pkR.IndexOf('$gen = Start-VncReachCheck') -and $pkR -match 'BeginStop\(\$null, \$null\)' -and $pkR -notmatch '\$ui\.check\.ps\.Stop\(|\.EndInvoke\(')
$ft = [regex]::Match($pkR, '(?s)\$ui\.freshTimer\.Add_Tick\(\{.*?\}\.GetNewClosure\(\)').Value
Check 'expiry timer only repaints (no socket, no scan, no check script)' ($ft -and $ft -notmatch 'TcpClient|BeginConnect|VncAllowedCheckScript|VncScanScript|\.Write\(')
$xamlR = [regex]::Match($src, "(?s)\`$global:VncPickerXaml = @'.*?'@").Value
Check 'approved marks: green filled circle, red square, gray hollow circle; 16 SemiBold; selection pill stays separate' ($xamlR -match 'x:Name="markOn"[^>]*Fill="#22C55E"' -and $xamlR -match 'x:Name="markOff"[^>]*Fill="#F87171"' -and $xamlR -match 'x:Name="markNo"[^>]*Stroke="#B4B4BC"[^>]*StrokeThickness="1.5"' -and $xamlR -match 'Text="Status"' -and $xamlR -notmatch 'Text="Seen"' -and $xamlR -match 'Width="620" Height="522" MinWidth="616" MinHeight="410"' -and $xamlR -match 'Height="38"' -and $xamlR -match 'x:Name="pill"[^>]*Fill="#22C55E"' -and $xamlR -match 'FontSize="16" FontWeight="SemiBold"' -and $xamlR -match 'Value="#4ADE80"' -and $xamlR -match 'Value="#FECACA"' -and $xamlR -match 'Foreground="#B4B4BC"')
Check 'column widths unchanged: 28 / * / 180 / 160 twice' (([regex]::Matches($xamlR, '<ColumnDefinition Width="28"/><ColumnDefinition Width="\*"/><ColumnDefinition Width="180"/><ColumnDefinition Width="160"/>')).Count -eq 2)
Check 'intro stays one line; the VNC caveat is its own 16 px footer line' ($xamlR -match 'Text="Pick a computer\. View only to watch, Interact to take control\." FontSize="13" LineHeight="16"' -and $xamlR -match 'Margin="0,0,0,4"' -and $xamlR -match 'Text="Online: VNC answered, not signed in or the screen\. Offline: the VNC port, not the PC\."' -and $xamlR -notmatch 'MaxHeight="48"' -and $xamlR -match 'MaxHeight="32"' -and $xamlR -match 'x:Name="Status" Grid.Column="0" MaxWidth="360"' -and $xamlR -match 'x:Name="StatusDetail" Grid.Column="1" MinWidth="180"' -and $xamlR -match 'AutomationProperties.Name="Online: VNC answered, not signed in or the screen. Offline: the VNC port, not the PC."')
Check 'chrome delta is 0: one intro line (margin 4) and two 16 px footer lines (margin 2) vs the old one-line pair' ((Get-VncChromeDelta 1 4 2 2 16) -eq 0 -and (Get-VncPickerRows 410) -ge 4 -and (Get-VncPickerRows 522) -eq 7 -and $xamlR -match 'Width="620" Height="522" MinWidth="616" MinHeight="410"' -and $xamlR -match 'Height="38"')
Check 'status owner: a selection event during rebuild does not write; an unchanged line is not announced' (($null -eq (Get-VncStatusWrite 'Checking. 1 online, 0 offline, 1 not checked.' 'Pick a computer to view or control it.' $true $true)) -and ($null -eq (Get-VncStatusWrite 'same' 'same' $false $false)) -and ((Get-VncStatusWrite 'old' '1 online, 0 offline, 1 not checked. Press F5 to check again.' $false $false) -eq '1 online, 0 offline, 1 not checked. Press F5 to check again.'))
$kept = Get-VncReachFooter 1 0 2 $false $false $false '3:00 PM' 'POS1: VNC answered just now.'
Check 'footer keeps the counts when the selected row adds its check detail' ($kept -eq '1 online, 0 offline, 2 not checked. Press F5 to check again. POS1: VNC answered just now.' -and $kept -notmatch 'RFB')
$lf = ConvertTo-VncReachBanner ("RFB 003.008" + [char]10)
$cr = ConvertTo-VncReachBanner ("RFB 003.008" + [char]13)
Check 'greeting: LF is the RFB banner; CR is Offline, and both hosts still pass the password gate' ($lf -eq 'RFB 003.008' -and (Get-VncReachOutcome @{ kind = 'banner'; banner = $lf }) -eq 'online' -and $cr -eq '' -and (Get-VncReachOutcome @{ kind = 'banner'; banner = $cr }) -eq 'offline' -and (Test-VncUsePassword ([pscustomobject]@{ host = '192.168.20.51'; banner = $cr; session = $true }) $true) -and (Test-VncUsePassword ([pscustomobject]@{ host = '192.168.20.51'; banner = $lf; session = $true }) $true))
$whyRow = { param($why) [pscustomobject]@{ name = 'POS2'; host = '192.168.20.52'; port = 5900; banner = ''; session = $false; reachWhy = $why } }
Check 'fallback: stale, in flight, cancelled, timeout, and refused do not make View only ask' (((Get-VncPasswordFallbackText (& $whyRow 'stale') $true) -eq '') -and ((Get-VncPasswordFallbackText (& $whyRow 'running') $true) -eq '') -and ((Get-VncPasswordFallbackText (& $whyRow 'cancelled') $true) -eq '') -and ((Get-VncPasswordFallbackText (& $whyRow 'timeout') $true) -eq '') -and ((Get-VncPasswordFallbackText (& $whyRow 'refused') $true) -eq ''))
$stag = @(
  [pscustomobject]@{ name = 'Old'; host = '192.168.20.51'; port = 5900 }
  [pscustomobject]@{ name = 'Fresh'; host = '192.168.20.52'; port = 5900 }
  [pscustomobject]@{ name = 'Wait'; host = '192.168.20.53'; port = 5900 })
$stagRes = @{
  '192.168.20.51:5900' = @{ kind = 'banner'; banner = 'RFB 003.008'; outcome = 'online'; at = $nowR.AddSeconds(-70) }
  '192.168.20.52:5900' = @{ kind = 'banner'; banner = 'RFB 003.008'; outcome = 'online'; at = $nowR.AddSeconds(-5) } }
$stagRows = Get-VncAllowedRows $stag $stagRes $true $nowR
$stagBy = @{}; foreach ($sr in $stagRows) { $stagBy[$sr.row.name] = $sr }
$stagCounts = Get-VncReachCounts $stag $stagRes $nowR
$stagFoot = Get-VncReachFooter $stagCounts.online $stagCounts.offline $stagCounts.unchecked $true $false $false '' ''
Check 'staggered expiry while a check is still running: old Online is Not checked, fresh Online stays, footer keeps both counts' ($stagBy['Old'].statusText -eq 'Not checked' -and $stagBy['Fresh'].statusText -eq 'Online' -and $stagBy['Wait'].statusText -eq 'Not checked' -and $stagBy['Wait'].statusTip -match 'in progress' -and $stagCounts.online -eq 1 -and $stagCounts.unchecked -eq 2 -and $stagFoot -match 'Checking\. 1 online, 0 offline, 2 not checked' -and -not (Test-VncReachAllExpired $stagRes $nowR))
Check 'picker writes the summary after rebuild and ignores selection noise while rebuilding' ($pkR -match '\$ui\.rebuilding = \$true' -and $pkR.IndexOf('$ui.rebuilding = $true') -lt $pkR.IndexOf('$lv.Items.Clear()') -and $pkR -match 'if \(\$ui\.rebuilding\) \{ return \}' -and $pkR -match 'elseif \(\$ui\.ownStatus\) \{ \$ui\.noteStatus\.Invoke\(\$false\) \}' -and $pkR -match 'if \(\$ui\.line -eq \$combined\) \{ return \}')
Check 'empty allowed list says none are allowed, not Pick a computer, and tiles still follow selection' ($pkR -match 'if \(\$lv\.Items\.Count -eq 0\) \{ \$ui\.setStatus\.Invoke\(''No computers have been allowed yet\.''\) \}' -and $pkR -notmatch 'Ask your administrator' -and $pkR -match '\$bView\.IsEnabled = \$has; \$bInt\.IsEnabled = \$has')
Check 'polite live region announces the combined counts and detail, and the caveat and detail names stay the full text' ($pkR.IndexOf('SetName($status, $combined)') -ge 0 -and $pkR.IndexOf('SetName($status, $combined)') -lt $pkR.IndexOf("RaiseAutomationEvent('LiveRegionChanged')") -and $pkR -match 'SetName\(\$statusDetail, \[string\]\$detail\)' -and $pkR -match 'SetName\(\$caveat, \[string\]\$caveat\.Text\)' -and $pkR -match '\$status\.ToolTip = \$counts' -and $pkR -match '\$statusDetail\.ToolTip = \[string\]\$detail')
Check 'read gives up on cancel inside a short slice and still closes the socket' ($chk -match '\$s\.ReadTimeout = 50' -and $chk -match 'while \(\$got -lt 12 -and -not \$sync\.cancel\)' -and $chk -match 'ConvertTo-VncReachBanner')
# Loopback only: 127.0.0.1 ephemeral port. No other address is contacted.
function Wait-Loopback($ln, [int]$ms) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not $ln.Pending -and $sw.ElapsedMilliseconds -lt $ms) { Start-Sleep -Milliseconds 15 }
  if (-not $ln.Pending) { throw 'loopback client did not connect' }
  return $ln.AcceptTcpClient()
}
$lbOk = $false
try {
  $ln = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
  $ln.Start(); $lbPort = ([System.Net.IPEndPoint]$ln.LocalEndpoint).Port
  $lbSync = [hashtable]::Synchronized(@{ cancel = $false; done = $false; found = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]) })
  $lbIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  foreach ($bn in 'Get-VncReachKind', 'ConvertTo-VncReachBanner') { $lbIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry $bn, (Get-Item "function:$bn").ScriptBlock.ToString())) }
  $lbRs = [runspacefactory]::CreateRunspace($lbIss); $lbRs.Open(); $lbPs = [powershell]::Create(); $lbPs.Runspace = $lbRs
  [void]$lbPs.AddScript($global:VncAllowedCheckScript).AddArgument(@(@{ key = "127.0.0.1:$lbPort"; host = '127.0.0.1'; port = $lbPort; probe = $true })).AddArgument(2000).AddArgument($lbSync)
  $lbH = $lbPs.BeginInvoke()
  $lbClient = Wait-Loopback $ln 2000; $lbStream = $lbClient.GetStream()
  $lbBytes = [Text.Encoding]::ASCII.GetBytes("RFB 003.008`n"); [void]$lbStream.Write($lbBytes, 0, $lbBytes.Length)
  $lbSw = [Diagnostics.Stopwatch]::StartNew(); while (-not $lbSync.done -and $lbSw.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 20 }
  $lbHit = $null; [void]$lbSync.found.TryDequeue([ref]$lbHit)
  $lbOk = ($lbSync.done -and $lbHit.kind -eq 'banner' -and $lbHit.banner -eq 'RFB 003.008' -and (Get-VncReachOutcome $lbHit) -eq 'online')
  $lbClient.Close(); $ln.Stop(); $lbPs.Dispose(); $lbRs.Dispose()
} catch { $lbOk = $false }
Check 'loopback LF greeting is Online' $lbOk
$crOk = $false
try {
  $ln2 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
  $ln2.Start(); $crPort = ([System.Net.IPEndPoint]$ln2.LocalEndpoint).Port
  $crSync = [hashtable]::Synchronized(@{ cancel = $false; done = $false; found = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]) })
  $crIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  foreach ($bn in 'Get-VncReachKind', 'ConvertTo-VncReachBanner') { $crIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry $bn, (Get-Item "function:$bn").ScriptBlock.ToString())) }
  $crRs = [runspacefactory]::CreateRunspace($crIss); $crRs.Open(); $crPs = [powershell]::Create(); $crPs.Runspace = $crRs
  [void]$crPs.AddScript($global:VncAllowedCheckScript).AddArgument(@(@{ key = "127.0.0.1:$crPort"; host = '127.0.0.1'; port = $crPort; probe = $true })).AddArgument(2000).AddArgument($crSync)
  $crH = $crPs.BeginInvoke()
  $crClient = Wait-Loopback $ln2 2000; $crStream = $crClient.GetStream()
  $crBytes = [Text.Encoding]::ASCII.GetBytes("RFB 003.008`r"); [void]$crStream.Write($crBytes, 0, $crBytes.Length)
  $crSw = [Diagnostics.Stopwatch]::StartNew(); while (-not $crSync.done -and $crSw.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 20 }
  $crHit = $null; [void]$crSync.found.TryDequeue([ref]$crHit)
  $crOk = ($crSync.done -and $crHit.kind -eq 'banner' -and $crHit.banner -eq '' -and (Get-VncReachOutcome $crHit) -eq 'offline' -and (Test-VncUsePassword ([pscustomobject]@{ host = '127.0.0.1'; banner = $crHit.banner; session = $true }) $true))
  $crClient.Close(); $ln2.Stop(); $crPs.Dispose(); $crRs.Dispose()
} catch { $crOk = $false }
Check 'loopback CR greeting is Offline and the password gate stays open' $crOk
$cxOk = $false; $cxMs = -1
try {
  $ln3 = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
  $ln3.Start(); $cxPort = ([System.Net.IPEndPoint]$ln3.LocalEndpoint).Port
  $cxSync = [hashtable]::Synchronized(@{ cancel = $false; done = $false; found = (New-Object System.Collections.Concurrent.ConcurrentQueue[object]) })
  $cxIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  foreach ($bn in 'Get-VncReachKind', 'ConvertTo-VncReachBanner') { $cxIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry $bn, (Get-Item "function:$bn").ScriptBlock.ToString())) }
  $cxRs = [runspacefactory]::CreateRunspace($cxIss); $cxRs.Open(); $cxPs = [powershell]::Create(); $cxPs.Runspace = $cxRs
  [void]$cxPs.AddScript($global:VncAllowedCheckScript).AddArgument(@(@{ key = "127.0.0.1:$cxPort"; host = '127.0.0.1'; port = $cxPort; probe = $true })).AddArgument(4000).AddArgument($cxSync)
  $cxH = $cxPs.BeginInvoke(); $cxClient = Wait-Loopback $ln3 2000
  Start-Sleep -Milliseconds 80; $cxSync.cancel = $true; $cxSw = [Diagnostics.Stopwatch]::StartNew()
  while (-not $cxSync.done -and $cxSw.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 20 }
  $cxMs = $cxSw.ElapsedMilliseconds; $cxHit = $null; [void]$cxSync.found.TryDequeue([ref]$cxHit)
  $cxOk = ($cxSync.done -and $cxMs -lt 1000 -and $cxHit.kind -eq 'cancelled')
  try { $cxClient.Close() } catch {}; try { $ln3.Stop() } catch {}; try { if (-not $cxH.IsCompleted) { [void]$cxPs.BeginStop($null, $null) } } catch {}; try { $cxPs.Dispose() } catch {}; try { $cxRs.Dispose() } catch {}
} catch { $cxOk = $false }
Check ('loopback cancel closes a stalled read without waiting out the 4 s budget: ' + $cxMs + ' ms') $cxOk
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
