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
       'Save-VncFavorites', 'Set-VncFavorite', 'Read-VncCache', 'Save-VncCache', 'Test-VncCacheStale', 'Merge-VncRows', 'Test-VncPickerButton',
       'Test-VncAdapter', 'Get-VncRangeText', 'Get-VncNewRanges', 'Test-VncAutoScan', 'Test-VncBannerText', 'Get-VncDisplayName', 'Get-VncInvalidText',
       'Get-VncRowView', 'Get-VncShortName', 'Get-VncFoundText', 'Test-VncUsePassword', 'Get-VncWorkerFault', 'Get-VncTempAction', 'Remove-VncTempDir',
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
Check 'no saved password: never a file' (-not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889' }) $false))

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
Check 'M2: no WaitForInputIdle anywhere; polled' ($src -notmatch 'WaitForInputIdle' -and $soon -match 'MainWindowHandle' -and $soon -match 'Get-VncTempAction')
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
Check 'Kern 2: Win11 selection: white 9%, 3x16 #22C55E pill, radius 6, hover 5%' ($xaml -match 'Value="#17FFFFFF"' -and $xaml -match 'Width="3" Height="16"[^>]*Fill="#22C55E"' -and $xaml -match 'x:Name="bg" CornerRadius="6"' -and $xaml -match 'Value="#0DFFFFFF"' -and $xaml -notmatch '#0B6E99"/>\s*</Trigger>')
Check 'Squint 7: title once (chrome), hint line, no H1' ($xaml -match 'Title="View Register"' -and $xaml -match 'Pick a computer\. View only to watch, Interact to take control\.' -and $xaml -notmatch 'FontSize="20"')
Check 'Squint 5: Interact tooltip' ($xaml -match [regex]::Escape("Take control of this computer's mouse and keyboard. Asks for the full password."))
$menu = & $fn 'New-VncRowMenu'
Check 'D2: gradient client area, radius 10 chips, stroke 28%->6%, sheen, list radius 10' ($xaml -match '#26262C' -and $xaml -match '#16161A' -and $xaml -match 'CornerRadius="10" Background="\{TemplateBinding Background\}"' -and $xaml -match '#47FFFFFF' -and $xaml -match '#0FFFFFFF' -and $xaml -match '#24FFFFFF' -and $xaml -match 'CornerRadius="10" Background="#2E000000"')
Check 'D2: primary gradients + hover/pressed per kern.md' ($xaml -match '#0E7A4B" Offset="0"/><GradientStop Color="#0A5A38"' -and $xaml -match '#187F52' -and $xaml -match '#0A5333' -and $xaml -match '#0B6E99" Offset="0"/><GradientStop Color="#085171"' -and $xaml -match '#15749D' -and $xaml -match '#074B68')
Check 'D2: hover lift 1 px, press 0.97, focus ring, disabled #2A2A2A/#8A8A8A, 2 px busy bar' ($xaml -match 'TranslateTransform Y="-1"' -and $xaml -match 'ScaleX="0.97"' -and $xaml -match 'x:Name="ring" CornerRadius="12"' -and $xaml -match 'Value="#2A2A2A"' -and $xaml -match 'Value="#8A8A8A"' -and $xaml -match 'ProgressBar x:Name="Busy"[^>]*Height="2"[^>]*Foreground="#0E7A4B"')
Check 'status line announced politely' ($pk -match "SetLiveSetting\(\`$status, 'Polite'\)")
$vncSrc = [regex]::Match($src, '(?s)# ---------- VNC register picker.*?# =+ MAIN').Value
Check 'VNC code: no -password switch, no Invoke-Expression, no cmd /c' ($vncSrc -notmatch "'-password'" -and $vncSrc -notmatch 'Invoke-Expression|iex ' -and $vncSrc -notmatch 'cmd(\.exe)?\s*/c')
Check 'launch: Start-Process with an argument list from Get-VncViewerArgs' ((& $fn 'Start-VncViewer').Contains('$vargs = @(Get-VncViewerArgs $h $p $viewOnly $file)') -and (& $fn 'Start-VncViewer').Contains('Start-Process -FilePath $exe -ArgumentList $vargs '))
Check 'viewer path must be a local fixed path' ((& $fn 'Find-VncViewer') -match 'Test-LocalFixedPath \$f' -and (& $fn 'Find-VncViewer') -match 'App Paths\\vncviewer\.exe')
Check 'secret: DPAPI CurrentUser + entropy, plaintext zeroed' ($sv -match "ProtectedData\]::Protect\(\`$raw, \`$global:VncEntropy, 'CurrentUser'\)" -and $sv -match 'ZeroFreeBSTR' -and (& $fn 'Get-VncSecretHex') -match 'Array\]::Clear')
Check 'secret: separate file, not buttons.json' ((& $fn 'Get-VncSecretPath') -match "'vnc-viewonly\.dat'")
$sv2 = & $fn 'Start-VncViewer'
Check 'v1.4.2: no mode reads the saved password or writes a .vnc (registers have none)' (-not ($sv2 -match 'Get-VncSecretHex|New-VncTempConfig|Test-VncSecret'))
Check 'temp .vnc: random folder, protected ACL for this user, CreateNew, deleted soon + leftovers' ($tcfg -match "bl-vnc-' \+ \[guid\]" -and $tcfg -match 'SetAccessRuleProtection\(\$true, \$false\)' -and $tcfg -match 'CreateNew' -and $sv2 -match 'Remove-VncTempSoon' -and $pk -match 'Remove-VncTempLeftovers')
Check 'LJ M39-I1: View-only password Setup item and dialog removed; start-up deletes a leftover vnc-viewonly.dat without reading it' ($src -notmatch 'Show-VncPasswordDialog' -and $src -notmatch "'View-only password \(for viewing computers\)\.\.\.'" -and $src.Contains('try { Clear-VncSecret } catch {}') -and ([regex]::Matches($src, 'Clear-VncSecret')).Count -eq 2 -and (& $fn 'Clear-VncSecret') -notmatch 'Get-Content|ReadAll|Unprotect|Get-VncSecretHex')
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
               'ConvertTo-VncAllowedText', 'Get-VncAllowedRows', 'Get-VncAllowedSaveError', 'Get-VncAllowedWriterText', 'Get-VncAllowedWriterCommand', 'Test-VncAllowedAclSafe') {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "v1.4.1 defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(VncAllowedMax|VncAllowedWriterScript)\s*=') { Invoke-Expression $l.Extent.Text } }
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
Check 'picker rows: Online / Offline, no star, names from the admin' ($rows.Count -eq 2 -and $rows[0].seen -eq 'Online' -and $rows[1].seen -eq 'Offline' -and $rows[0].star -eq '' -and $rows[0].nameText -eq 'Register 1')
Check "picker rows: 'Checking...' while the check runs" ((Get-VncAllowedRows $t.list @{} $true)[0].seen -eq 'Checking...')
Check 'empty list: rows empty' (@(Get-VncAllowedRows @() @{} $false).Count -eq 0)
$pk = & $fn 'Show-VncPicker'
Check "empty-state copy: 'No computers have been allowed yet. Ask your administrator.'" ($pk -match [regex]::Escape("'No computers have been allowed yet. Ask your administrator.'"))
Check 'picker: allowed list only (Read-VncAllowed), no scan, no favourites' ($pk -match 'Read-VncAllowed' -and $pk -notmatch 'Start-VncScan|Merge-VncRows|favorites|Read-VncCache')
Check 'picker: Rescan, Add and More hidden' ($pk -match "foreach \(\`$n in 'Rescan', 'Add', 'More'\) \{ \`$w.FindName\(\`$n\).Visibility = 'Collapsed' \}")
Check 'picker: Enter = View only, Ctrl+Enter = Interact, double-click = View only, F5 = online check, Esc closes' ($pk -match "'Return' -and \`$ctrl\) \{ \`$_.Handled = \`$true; \`$ui.go.Invoke\(\`$false\)" -and $pk -match 'MouseDoubleClick\(\{ if \(\$lv.SelectedItem\) \{ \$ui.go.Invoke\(\$true\)' -and $pk -match "'F5'\) \{ \`$_.Handled = \`$true; \`$ui.startCheck.Invoke\(\)" -and $pk -match "'Escape'")
Check 'picker: online check uses 300 ms (VncTimeoutMs) and only the allowed entries' ($pk -match 'VncAllowedCheckScript\).AddArgument\(\$items\).AddArgument\(\$global:VncTimeoutMs\)')
Check 'picker: closing stops the check' ($pk -match 'Add_Closed\(\{ \$ui.stopCheck.Invoke\(\)')
$rm = & $fn 'New-VncRowMenu'; Check 'row menu: allowed mode has only View only + Interact' ($rm -match 'if \(\$ui.allowedMode\) \{ \$m.Items.RemoveAt')
# View only never asks; password for any allowed row when saved
$sv = & $fn 'Start-VncViewer'
Check 'View only: no password prompt from the launcher (ask-once removed)' ($sv -notmatch 'Show-VncPasswordDialog' -and $sv -notmatch 'viewOnlyAsked')
Check 'L4: saved password used for a host that greeted RFB in this session' (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889'; session = $true }) $true)
Check 'V2-I1: cached RFB banner alone is not enough (not seen this session)' (-not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889'; session = $false }) $true) -and -not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889' }) $true))
Check 'L4: no password file for a host with no or a non-RFB greeting' (-not (Test-VncUsePassword ([pscustomobject]@{ banner = '' }) $true) -and -not (Test-VncUsePassword ([pscustomobject]@{ banner = 'SSH-2.0-Open' }) $true))
Check 'View only, nothing saved: -viewonly, no -config, no password (no-password registers)' (((Get-VncViewerArgs 'REG1' 5900 $true $null) -join ' ') -eq 'REG1::5900 -autoscaling -viewonly' -and -not (Test-VncUsePassword ([pscustomobject]@{ banner = 'RFB 003.889'; session = $true }) $false))
Check 'v1.4.2: Start-VncViewer always passes the picked host::port (no -config only launch)' ($sv.Contains('$vargs = @(Get-VncViewerArgs $h $p $viewOnly $file)') -and $sv -notmatch '\$file = New-VncTempConfig')
# Interact: no config, no password, no -viewonly (UltraVNC asks for the password itself)
$a = Get-VncViewerArgs 'REG1' 5900 $false $null
Check 'Interact never -password, -config, -viewonly or -dsmplugin' (-not ((Get-VncViewerArgs 'REG1' 5900 $false $null) -match '^-password$|^-config$|^-viewonly$|^-dsmplugin$'))
Check 'Interact: same args for an IP or a name, two colons (TCP port, not display)' (((Get-VncViewerArgs '192.168.1.21' 5900 $false $null) -join ' ') -eq '192.168.1.21::5900 -autoscaling')
Check 'DSM change reverted: no plugin code left' ($src -notmatch '(?i)dsmplugin|Get-VncHostDsm|Get-VncDsmFromLines')
Check 'Interact: host::port -autoscaling only (UltraVNC asks for the password)' (((Get-VncViewerArgs 'REG1' 5900 $false $null) -join ' ') -eq 'REG1::5900 -autoscaling')
Check 'viewer path, exact argument line and product/version logged; non-UltraVNC flagged; no secret in the line' ($sv.Contains('Get-VncViewerInfo') -and $sv.Contains('NOT UltraVNC') -and $sv.Contains('$exe, ($vargs -join '' '')') -and $sv -notmatch 'Write-LauncherLog[^\n]*(hex|Secret)')
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
Check 'Setup menu: Allowed computers (admin)... added; View-only password item removed (LJ M39-I1, CC L2)' ($src -match "'Allowed computers \(admin\)\.\.\.'" -and $src -notmatch "New-D2Dialog 'View-only password'")
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
Check 'v1.4.2: exact final args, View only and Interact, address and name' ((((Get-VncViewerArgs '192.168.20.51' 5900 $true $null) -join ' ') -ceq '192.168.20.51::5900 -autoscaling -viewonly') -and (((Get-VncViewerArgs '192.168.20.51' 5900 $false $null) -join ' ') -ceq '192.168.20.51::5900 -autoscaling') -and (((Get-VncViewerArgs 'POS1' 5901 $true $null) -join ' ') -ceq 'POS1::5901 -autoscaling -viewonly') -and (((Get-VncViewerArgs 'POS1' 5901 $false $null) -join ' ') -ceq 'POS1::5901 -autoscaling'))
# --- ClaudeCode FIX-FIRST on c202b8b ---
$on = Get-VncAllowedRows $t.list @{ '192.168.1.21:5900' = 'RFB 003.008'; 'REG2:5901' = 'SSH-2.0-x' } $false
Check 'CC MED-1: online allowed row carries the RFB banner + session -> saved password used (usePassword True)' ($on[0].row.banner -eq 'RFB 003.008' -and $on[0].row.session -and (Test-VncUsePassword $on[0].row $true))
Check 'CC MED-1: a non-RFB answer is not online and gets no password' ($on[1].seen -eq 'Offline' -and -not (Test-VncUsePassword $on[1].row $true))
Check 'CC MED-1: nothing saved -> no password and no launcher prompt' (-not (Test-VncUsePassword $on[0].row $false) -and (& $fn 'Start-VncViewer') -notmatch 'Show-VncPasswordDialog')
Check 'CC MED-1: online check queues key + banner; picker keeps only RFB banners' ($src -match 'Enqueue\(@\{ key = \$b.key; banner = ' -and (& $fn 'Show-VncPicker') -match 'if \(Test-VncBannerText \(\[string\]\$k.banner\)\) \{ \$ui.online\[\[string\]\$k.key\] = \[string\]\$k.banner \}')
Check 'CC LOW-L: a folder named vnc-allowed.json(.tmp) -> exit 6' ($global:VncAllowedWriterScript -match "Test-Path -LiteralPath \`$file -PathType Container\) -or \(Test-Path -LiteralPath \`$tmp -PathType Container\)\) \{ exit 6 \}")
Check 'CC LOW-L: planted .tmp in an untrusted folder goes aside with the folder; CreateNew never opens an old .tmp' ($global:VncAllowedWriterScript -match 'CreateNew' -and $global:VncAllowedWriterScript -match '\.untrusted-')
Check "CC LOW-L: clear 'Not saved' messages for codes 3, 4, 5, 6 and others" ((Get-VncAllowedSaveError 3) -like 'Not saved*' -and (Get-VncAllowedSaveError 6) -like 'Not saved: *unexpected*' -and (Get-VncAllowedSaveError 4) -eq (Get-VncAllowedSaveError 5) -and (Get-VncAllowedSaveError 2) -like 'Not saved (code 2)*')
# --- v1.4.3: find vncviewer.exe in Program Files (override, known, bounded scan, none, links) ---
foreach ($n in 'Get-VncProgramRoots', 'Get-VncFileVersion', 'Test-VncViewerFile', 'Find-VncViewerInProgramFiles', 'Get-VncViewerLogText') {
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
Check 'v1.4.3: Find-VncViewer order: valid saved path (override) > Program Files scan > HKLM App Paths > plain message + optional pick' ($fv.IndexOf("`$how = 'override'") -lt $fv.IndexOf('Initialize-VncViewerScan') -and $fv.IndexOf('Initialize-VncViewerScan') -lt $fv.IndexOf('HKLM:\Software') -and $fv.IndexOf('HKLM:\Software') -lt $fv.IndexOf("wasn't found in Program Files") -and $fv -notmatch 'HKCU:' -and $fv -notmatch 'Find-Detected')
Check 'v1.4.3: start-up logs the version and runs the scan once (cached)' ($src.Contains("Write-LauncherLog ('Launcher {0} started' -f `$global:AppVersion)") -and $src.Contains('try { [void](Initialize-VncViewerScan) } catch {}') -and (& $fn 'Initialize-VncViewerScan').Contains('if ($global:VncViewerScan) { return $global:VncViewerScan }'))
Check 'v1.4.3: each launch still logs the exact argv (no password switch exists)' ((& $fn 'Start-VncViewer').Contains("(`$vargs -join ' ')") -and $src -notmatch "'-password'")
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
