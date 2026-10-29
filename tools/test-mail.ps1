# v1.4.0 unread email count: offline checks (no network, no real server, no real credentials).
# IMAP quoting and CR/LF rejection, STATUS parsing, the session against a mock server, the state machine,
# the copy, and source checks (no certificate bypass, nothing but LOGIN / STATUS / LOGOUT, no password in config or log).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Launcher.ps1'), [ref]$null, [ref]$null)
$src = $ast.Extent.Text
$fns = 'Get-ButtonType', 'ConvertTo-ImapQuotedBytes', 'Get-ImapLoginBytes', 'Get-ImapTagged', 'Get-ImapStatusUnseen', 'Invoke-ImapSession', 'Invoke-MailCheckWorker', 'Get-MailWorkerScript',
       'New-MailState', 'Update-MailState', 'Step-MailResume', 'Get-MailNextDelaySec', 'Get-MailBadgeText', 'Get-MailBadgeWidth', 'Test-MailShowBadge', 'Test-MailShowRing',
       'Get-MailMotion', 'Format-MailTime', 'Get-MailCountText', 'Get-MailTipLine', 'Get-MailMenuLine', 'Get-MailAccessName', 'Get-MailTestText', 'Format-MailLogLine',
       'Get-MailAddress', 'Test-MailAddress', 'Test-MailTile', 'ConvertTo-MailSettings', 'Get-MailSettingsJson'
foreach ($n in $fns) {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(MailDomain|MailLogDetails|MailWorkerScript)\s*=') { Invoke-Expression $l.Extent.Text } }
$fake = 'test-not-real'   # a fake password, used only in this test
function Ascii([byte[]]$b) { [Text.Encoding]::ASCII.GetString($b) }

# --- quoted strings (RFC 3501) ---
Check 'quote plain' ((Ascii (ConvertTo-ImapQuotedBytes 'abc'.ToCharArray())) -ceq '"abc"')
Check 'quote escapes backslash and dquote' ((Ascii (ConvertTo-ImapQuotedBytes 'a\b"c'.ToCharArray())) -ceq '"a\\b\"c"')
Check 'quote empty' ((Ascii (ConvertTo-ImapQuotedBytes ([char[]]@()))) -ceq '""')
Check 'quote keeps spaces, braces, percent, star' ((Ascii (ConvertTo-ImapQuotedBytes 'p w{1}%*()'.ToCharArray())) -ceq '"p w{1}%*()"')
foreach ($bad in "a`rb", "a`nb", "a`r`nb", ("a" + [char]0 + "b")) { $t = $false; try { [void](ConvertTo-ImapQuotedBytes $bad.ToCharArray()) } catch { $t = $true }; Check ("CR/LF/NUL rejected: " + ($bad -replace "`r", '\r' -replace "`n", '\n' -replace [char]0, '\0')) $t }
Check 'non-ASCII needs a literal' ($null -eq (ConvertTo-ImapQuotedBytes ('caf' + [char]0xE9).ToCharArray()))
Check 'tab needs a literal' ($null -eq (ConvertTo-ImapQuotedBytes "a`tb".ToCharArray()))
$lb = Get-ImapLoginBytes 'cc@jartrek.net' $fake.ToCharArray()
Check 'LOGIN quoted' ((Ascii $lb.cmd) -ceq "a1 LOGIN `"cc@jartrek.net`" `"$fake`"`r`n" -and $null -eq $lb.literal)
$lb = Get-ImapLoginBytes 'cc@jartrek.net' 'x"y\z'.ToCharArray()
Check 'LOGIN escapes the password' ((Ascii $lb.cmd) -ceq "a1 LOGIN `"cc@jartrek.net`" `"x\`"y\\z`"`r`n")
$pw = ('p' + [char]0xE9 + 'ss')
$lb = Get-ImapLoginBytes 'cc@jartrek.net' $pw.ToCharArray()
Check 'LOGIN literal for non-ASCII: {5} + UTF-8 bytes + CRLF' ((Ascii $lb.cmd) -ceq "a1 LOGIN `"cc@jartrek.net`" {5}`r`n" -and [Text.Encoding]::UTF8.GetString($lb.literal) -ceq ($pw + "`r`n"))
$t = $false; try { [void](Get-ImapLoginBytes 'cc@jartrek.net' "ab`r`nc a2 LOGOUT".ToCharArray()) } catch { $t = $true }; Check 'LOGIN: CR/LF in password throws (no command injection)' $t
$t = $false; try { [void](Get-ImapLoginBytes "cc`r`n@jartrek.net" 'x'.ToCharArray()) } catch { $t = $true }; Check 'LOGIN: CR/LF in user throws' $t
$t = $false; try { [void](Get-ImapLoginBytes ('c' + [char]0xE9 + '@jartrek.net') 'x'.ToCharArray()) } catch { $t = $true }; Check 'LOGIN: non-ASCII user throws' $t

# --- tagged / STATUS parsing ---
Check 'tagged OK' ((Get-ImapTagged 'a1 OK LOGIN completed' 'a1') -eq 'OK')
Check 'tagged no lowercase' ((Get-ImapTagged 'a1 no [AUTHENTICATIONFAILED] bad' 'a1') -eq 'NO')
Check 'tagged BAD' ((Get-ImapTagged 'a2 BAD syntax' 'a2') -eq 'BAD')
Check 'other tag ignored' ($null -eq (Get-ImapTagged 'a11 OK x' 'a1') -and $null -eq (Get-ImapTagged '* OK a1 OK' 'a1'))
$cases = @(
    @('* STATUS INBOX (UNSEEN 3)', 3), @('* STATUS "INBOX" (UNSEEN 0)', 0), @('* status inbox (unseen 42)', 42), @('* STATUS INBOX (MESSAGES 231 UNSEEN 7 RECENT 1)', 7),
    @('* STATUS INBOX (UNSEEN 128)', 128), @('*  STATUS   INBOX   ( UNSEEN   5 )  ', 5), @('* STATUS "INBOX" (UIDNEXT 44292 UNSEEN 12)', 12), @("* STATUS INBOX (UNSEEN 3)`r", 3),
    @('* STATUS INBOX (MESSAGES 3)', -1), @('* STATUS INBOX (UNSEENX 3)', -1), @('* STATUS INBOX (UNSEEN x)', -1), @('* OK [UNSEEN 4] first unseen', -1), @('a2 OK STATUS done', -1),
    @('* STATUS INBOX (UNSEEN 1234567890)', -1), @('', -1))
foreach ($c in $cases) { Check ("STATUS parse: '{0}' -> {1}" -f ($c[0] -replace "`r", '\r'), $c[1]) ((Get-ImapStatusUnseen $c[0]) -eq $c[1]) }

# --- the session against a mock server (injectable read/write) ---
function New-Mock([string[]]$lines) {
    $m = @{ q = New-Object System.Collections.Queue; sent = New-Object System.Collections.ArrayList }
    foreach ($l in $lines) { $m.q.Enqueue($l) }
    $m.read = { if ($m.q.Count -eq 0) { throw 'closed' }; [string]$m.q.Dequeue() }.GetNewClosure()
    $m.write = { param([byte[]]$b) [void]$m.sent.Add([Text.Encoding]::UTF8.GetString($b)) }.GetNewClosure()
    return $m }
$m = New-Mock @('* OK [CAPABILITY IMAP4rev1] Dovecot ready.', '* CAPABILITY IMAP4rev1 IDLE', 'a1 OK [CAPABILITY IMAP4rev1] Logged in', '* STATUS INBOX (UNSEEN 3)', 'a2 OK Status completed.', '* BYE Logging out', 'a3 OK Logout completed.')
$r = Invoke-ImapSession $m.read $m.write 'cc@jartrek.net' $fake.ToCharArray()
Check 'session ok: 3 unread' ($r.kind -eq 'ok' -and $r.unseen -eq 3)
Check 'session sends exactly LOGIN, STATUS INBOX (UNSEEN), LOGOUT' ($m.sent.Count -eq 3 -and $m.sent[0] -like 'a1 LOGIN *' -and $m.sent[1] -ceq "a2 STATUS INBOX (UNSEEN)`r`n" -and $m.sent[2] -ceq "a3 LOGOUT`r`n")
Check 'session result carries no password' (-not (($r | ConvertTo-Json -Compress) -match [regex]::Escape($fake)))
$m = New-Mock @('* OK ready', 'a1 NO [AUTHENTICATIONFAILED] Authentication failed.')
$r = Invoke-ImapSession $m.read $m.write 'cc@jartrek.net' $fake.ToCharArray()
Check 'session NO -> auth, nothing sent after LOGIN' ($r.kind -eq 'auth' -and $m.sent.Count -eq 1)
$m = New-Mock @('* OK ready', 'a1 BAD unknown')
Check 'session BAD at login -> auth' ((Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $fake.ToCharArray()).kind -eq 'auth')
$m = New-Mock @('* OK ready', '* BYE too many bad logins')
Check 'session BYE at login -> auth (never retried on a timer)' ((Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $fake.ToCharArray()).kind -eq 'auth')
$m = New-Mock @('* BYE server shutting down')
$r = Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $fake.ToCharArray(); Check 'session BYE greeting -> net, nothing sent' ($r.kind -eq 'net' -and $m.sent.Count -eq 0)
$m = New-Mock @('HTTP/1.1 400 Bad Request')
Check 'session non-IMAP greeting -> proto' ((Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $fake.ToCharArray()).kind -eq 'proto')
$m = New-Mock @('* PREAUTH ready', '* STATUS INBOX (UNSEEN 2)', 'a2 OK', 'a3 OK')
$r = Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $fake.ToCharArray(); Check 'PREAUTH: no LOGIN sent' ($r.unseen -eq 2 -and -not ($m.sent -like 'a1*'))
$m = New-Mock @('* OK ready', 'a1 OK', 'a2 NO no such mailbox', 'a3 OK')
Check 'STATUS NO -> proto (a network-type failure, not auth)' ((Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $fake.ToCharArray()).kind -eq 'proto')
$m = New-Mock @('* OK ready', 'a1 OK')
$t = $false; try { [void](Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $fake.ToCharArray()) } catch { $t = $true }; Check 'connection drop throws (the worker maps it to net)' $t
$m = New-Mock @('* OK ready', '+ go ahead', 'a1 OK', '* STATUS INBOX (UNSEEN 1)', 'a2 OK', 'a3 OK')
$r = Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $pw.ToCharArray()
Check 'literal login waits for + then sends the literal' ($r.unseen -eq 1 -and $m.sent[0] -ceq "a1 LOGIN `"u@jartrek.net`" {5}`r`n" -and $m.sent[1] -ceq ($pw + "`r`n"))
$m = New-Mock @('* OK ready', 'a1 NO literal refused')
$r = Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $pw.ToCharArray(); Check 'literal refused -> auth, literal not sent' ($r.kind -eq 'auth' -and $m.sent.Count -eq 1)
$m = New-Mock @('* OK ready')
$r = Invoke-ImapSession $m.read $m.write 'u@jartrek.net' "x`ry".ToCharArray(); Check 'CR in password: nothing sent, auth (stops)' ($r.kind -eq 'auth' -and $m.sent.Count -eq 0)
$pc = $fake.ToCharArray(); $m = New-Mock @('* OK ready', 'a1 NO')
[void](Invoke-ImapSession $m.read $m.write 'u@jartrek.net' $pc); Check 'caller-owned password chars untouched by the session (the worker zeroes them)' ((-join $pc) -ceq $fake)

# --- state machine ---
$now = [datetime]'2026-10-29 09:41'
$s = New-MailState; Check 'starts checking, no count' ($s.phase -eq 'checking' -and -not (Test-MailShowBadge $s) -and -not (Test-MailShowRing $s))
$o = Update-MailState $s @{ kind = 'ok'; unseen = 3; epoch = 0 } $now; Check 'first non-zero count grows' ($o.grew -and $s.count -eq 3 -and (Test-MailShowBadge $s))
$o = Update-MailState $s @{ kind = 'ok'; unseen = 3; epoch = 0 } $now; Check 'same count: no flash' (-not $o.grew)
$o = Update-MailState $s @{ kind = 'ok'; unseen = 2; epoch = 0 } $now; Check 'decrease: no flash' (-not $o.grew -and $s.count -eq 2)
$o = Update-MailState $s @{ kind = 'ok'; unseen = 5; epoch = 0 } $now; Check 'increase: flash once' ($o.grew)
$o = Update-MailState $s @{ kind = 'ok'; unseen = 0; epoch = 0 } $now; Check 'zero hides the badge' (-not $o.grew -and -not (Test-MailShowBadge $s))
$s = New-MailState; [void](Update-MailState $s @{ kind = 'ok'; unseen = 0 } $now); $o = Update-MailState $s @{ kind = 'ok'; unseen = 0 } $now; Check 'zero to zero: no flash' (-not $o.grew)
$s = New-MailState; [void](Update-MailState $s @{ kind = 'ok'; unseen = 3 } $now)
[void](Update-MailState $s @{ kind = 'net' } $now.AddMinutes(3)); Check '1 failed poll: count kept, no ring' ($s.phase -eq 'retry' -and (Test-MailShowBadge $s) -and -not (Test-MailShowRing $s) -and (Get-MailNextDelaySec $s) -eq 180)
[void](Update-MailState $s @{ kind = 'cert' } $now.AddMinutes(6)); Check '2 failed polls: offline ring, count hidden' ($s.phase -eq 'offline' -and (Test-MailShowRing $s) -and -not (Test-MailShowBadge $s))
Check 'backoff 6 min after 2 fails' ((Get-MailNextDelaySec $s) -eq 360)
[void](Update-MailState $s @{ kind = 'proto' } $now); Check 'backoff 12 min after 3' ((Get-MailNextDelaySec $s) -eq 720)
[void](Update-MailState $s @{ kind = 'net' } $now); [void](Update-MailState $s @{ kind = 'net' } $now); Check 'backoff capped at 15 min' ((Get-MailNextDelaySec $s) -eq 900)
$o = Update-MailState $s @{ kind = 'ok'; unseen = 3 } $now; Check 'reconnect same count: ring clears, no flash' ($s.phase -eq 'ok' -and -not $o.grew -and -not (Test-MailShowRing $s) -and $s.fails -eq 0)
$s = New-MailState; [void](Update-MailState $s @{ kind = 'ok'; unseen = 3 } $now)
[void](Update-MailState $s @{ kind = 'auth' } $now); Check 'auth failure: ring at once, polling stopped' ($s.phase -eq 'authfail' -and $s.stopped -and (Test-MailShowRing $s) -and -not (Test-MailShowBadge $s))
Check 'auth failure: no timer retry (-1)' ((Get-MailNextDelaySec $s) -eq -1)
[void](Update-MailState $s @{ kind = 'net' } $now); Check 'still no timer after a later network error' ((Get-MailNextDelaySec $s) -eq -1)
$o = Update-MailState $s @{ kind = 'ok'; unseen = 4 } $now; Check 'Check email now success restarts polling' (-not $s.stopped -and $s.phase -eq 'ok' -and (Get-MailNextDelaySec $s) -eq 180 -and $o.grew)
$s = New-MailState; [void](Update-MailState $s @{ kind = 'ok'; unseen = 3; epoch = 0 } $now)
[void](Update-MailState $s @{ kind = 'net'; epoch = 0 } $now)
Step-MailResume $s
$o = Update-MailState $s @{ kind = 'net'; epoch = 0 } $now; Check 'sleep: a check from before sleep is ignored, not counted' ($o.ignored -and $s.fails -eq 1 -and $s.phase -eq 'retry')
[void](Update-MailState $s @{ kind = 'ok'; unseen = 3; epoch = 1 } $now); Check 'first poll after wake clears' ($s.phase -eq 'ok' -and $s.fails -eq 0)
foreach ($c in @(@(0, ''), @(1, '1'), @(9, '9'), @(10, '10'), @(99, '99'), @(100, '99+'), @(12345, '99+'))) { Check "badge text $($c[0]) -> '$($c[1])'" ((Get-MailBadgeText $c[0]) -ceq $c[1]) }
Check 'badge widths 18 / 24 / 30' ((Get-MailBadgeWidth '3') -eq 18 -and (Get-MailBadgeWidth '27') -eq 24 -and (Get-MailBadgeWidth '99+') -eq 30)
Check 'animations off -> badge only' ((Get-MailMotion 'flash' $false) -eq 'badge' -and (Get-MailMotion 'pulse' $false) -eq 'badge' -and (Get-MailMotion 'pulse' $true) -eq 'pulse')
Check 'unknown style -> flash (Charles default)' ((Get-MailMotion 'zap' $true) -eq 'flash')

# --- copy (Squint) ---
$s = New-MailState; Check 'tip: checking' ((Get-MailTipLine $s $now) -ceq 'Checking email...')
[void](Update-MailState $s @{ kind = 'ok'; unseen = 1 } $now); Check 'tip: singular' ((Get-MailTipLine $s $now) -ceq '1 unread email in Inbox. Checked 9:41 AM.')
[void](Update-MailState $s @{ kind = 'ok'; unseen = 3 } $now); Check 'tip: plural' ((Get-MailTipLine $s $now) -ceq '3 unread emails in Inbox. Checked 9:41 AM.')
Check 'menu: ok' ((Get-MailMenuLine $s $now) -ceq 'Email count: 3 unread, checked 9:41 AM')
Check 'name: Email, 3 unread' ((Get-MailAccessName 'Email' $s) -ceq 'Email, 3 unread')
[void](Update-MailState $s @{ kind = 'ok'; unseen = 128 } $now); Check 'tip: 99+ carries the real count' ((Get-MailTipLine $s $now) -ceq '128 unread emails in Inbox. Checked 9:41 AM.')
[void](Update-MailState $s @{ kind = 'ok'; unseen = 0 } $now); Check 'tip: none' ((Get-MailTipLine $s $now) -ceq 'No unread email. Checked 9:41 AM.')
[void](Update-MailState $s @{ kind = 'ok'; unseen = 3 } $now)
[void](Update-MailState $s @{ kind = 'net' } $now.AddMinutes(3)); Check 'tip: one failed poll' ((Get-MailTipLine $s $now) -ceq '3 unread emails in Inbox. Couldn''t check at 9:44 AM, trying again.')
[void](Update-MailState $s @{ kind = 'net' } $now.AddMinutes(6)); Check 'tip: offline' ((Get-MailTipLine $s $now) -ceq 'Can''t reach email since 9:44 AM. The count is hidden until it reconnects.')
Check 'menu: offline' ((Get-MailMenuLine $s $now) -ceq 'Email count: offline since 9:44 AM')
[void](Update-MailState $s @{ kind = 'auth' } $now); Check 'tip: sign-in failed (Squint final)' ((Get-MailTipLine $s $now) -ceq 'Email count stopped: can''t sign in. If you changed your webmail password, update it in Setup > Unread email count...')
Check 'menu: sign-in failed' ((Get-MailMenuLine $s $now) -ceq 'Email count: can''t sign in')
Check 'name: sign-in failed' ((Get-MailAccessName 'Email' $s) -ceq 'Email, email count can''t sign in')
Check 'time: another day adds the date' ((Format-MailTime ([datetime]'2026-10-28 16:10') $now) -ceq 'Oct 28, 4:10 PM')
Check 'test result ok' ((Get-MailTestText @{ kind = 'ok'; unseen = 3 }).text -ceq 'Signed in. 3 unread emails in Inbox.')
Check 'test result auth' ((Get-MailTestText @{ kind = 'auth' }).text -ceq 'Couldn''t sign in. Check the email address and password, the same ones you use for webmail.')
Check 'test result net / cert' ((Get-MailTestText @{ kind = 'cert' }).text -ceq 'Can''t reach the mail server. Check this PC is online, then press Test again.')
Check 'UI strings use email, not mail (bar the approved heading)' (-not ([regex]::Matches($src, "'[^'\r\n]*\b[Mm]ail count[^'\r\n]*'")).Count)
Check 'heading: When new mail arrives:' ($src.Contains("'When new mail arrives:'"))
Check 'setup copy present' ($src.Contains("'Show unread email count on the Email button'") -and $src.Contains("'Uses your Jartrek email, the same login as webmail.'") -and $src.Contains("'Everyone who uses this Windows login on this PC will see how many unread emails this account has.'") -and $src.Contains("'Turn off the email count and forget this login on this PC?'"))
Check 'menu items: Check email now, Email count settings..., Setup item Unread email count...' ($src.Contains("'Check email now'") -and $src.Contains("'Email count settings...'") -and $src.Contains("'Unread email count...'"))

# --- address, settings, log: no password anywhere ---
Check 'address: name gets @jartrek.net' ((Get-MailAddress ' cc ') -ceq 'cc@jartrek.net' -and (Get-MailAddress 'a@b.com') -ceq 'a@b.com')
foreach ($a in 'cc@jartrek.net', 'first.last+x@jartrek.net') { Check "address ok: $a" (Test-MailAddress $a) }
foreach ($a in '', 'cc', 'cc@', "cc@jartrek.net`r`nx", 'c c@jartrek.net', 'cc@jartrek', '"x"@jartrek.net') { Check ("address rejected: " + ($a -replace "`r`n", '\r\n')) (-not (Test-MailAddress $a)) }
$j = Get-MailSettingsJson @{ enabled = $true; address = 'cc@jartrek.net'; style = 'pulse'; password = $fake; secret = $fake }
Check 'settings json: only enabled/address/style, no password' ($j -ceq '{"enabled":true,"address":"cc@jartrek.net","style":"pulse"}' -and -not $j.Contains($fake))
Check 'settings default: off, Flash' ((ConvertTo-MailSettings @{}).enabled -eq $false -and (ConvertTo-MailSettings @{}).style -eq 'flash')
Check 'settings: enabled needs a valid address' (-not (ConvertTo-MailSettings @{ enabled = $true; address = 'nope' }).enabled)
$ll = Format-MailLogLine @{ kind = 'auth'; detail = $fake; unseen = -1; password = $fake; user = 'cc@jartrek.net' }
Check 'log line: no password, no address' (-not $ll.Contains($fake) -and -not $ll.Contains('jartrek') -and $ll -ceq 'email count: auth')
Check 'log line: known detail kept' ((Format-MailLogLine @{ kind = 'net'; detail = 'connect timed out' }) -ceq 'email count: net (connect timed out)')
Check 'Email tile found by what it opens' ((Test-MailTile ([pscustomobject]@{ type = 'website'; target = 'mailto:' })) -and -not (Test-MailTile ([pscustomobject]@{ type = 'website'; target = 'https://www.google.com' })))
$cfg = Get-Content -LiteralPath (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
Check 'default config has exactly one Email tile' (@($cfg.panels | ForEach-Object { $_.buttons } | Where-Object { Test-MailTile $_ }).Count -eq 1)
Check 'default config has no email settings or secrets' (-not ((Get-Content -LiteralPath (Join-Path $root 'buttons.default.json') -Raw) -match '(?i)password|emailCount|email-count'))

# --- source checks ---
$tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Launcher.ps1'), [ref]$tokens, [ref]$null)
$codeText = -join @($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text + ' ' })
Check 'no certificate validation callback anywhere' (-not ($codeText -match '(?i)CertificateValidationCallback|CertificateValidation|RemoteCertificate'))
Check 'ServicePointManager never touched' (-not ($codeText -match '(?i)ServicePointManager'))
Check 'no CheckCertificateRevocationList / SecurityProtocol global changes' (-not ($codeText -match '(?i)SecurityProtocol\s*='))
$w = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Invoke-MailCheckWorker' }, $true).Extent.Text
Check 'TLS: SslStream with no callback argument' ($w -match 'New-Object System\.Net\.Security\.SslStream\(\$ns, \$false\)')
Check 'TLS: AuthenticateAsClient(mail.jartrek.net, null, Tls12[+13], revocation on)' ($w -match "AuthenticateAsClient\('mail\.jartrek\.net', \`$null, \`$proto, \`$true\)" -and $w -match 'SslProtocols\]::Tls12' -and $w -match 'SslProtocols\]::Tls13')
Check 'TLS: port 993, 10 s timeouts' ($w -match "BeginConnect\('mail\.jartrek\.net', 993" -and $w -match 'WaitOne\(10000\)' -and $w -match 'ReadTimeout = 10000')
Check 'worker zeroes the BSTR and the char copy' ($w -match 'ZeroFreeBSTR' -and $w -match '\[Array\]::Clear\(\$chars')
Check 'TLS failure is an error (cert), never ignored' ($w -match "kind = 'cert'")
$imapCmds = [regex]::Matches($codeText, "a\d (LOGIN|STATUS|LOGOUT|[A-Z]+)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Check "IMAP commands in code: only LOGIN, STATUS, LOGOUT ($($imapCmds -join ','))" ((@($imapCmds) -join ',') -ceq 'LOGIN,LOGOUT,STATUS')
Check 'one host only: mail.jartrek.net' (@([regex]::Matches($codeText, '(?i)[a-z0-9-]+\.jartrek\.net') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique) -join ',' -ceq 'mail.jartrek.net')
$ws = Get-MailWorkerScript
Check 'worker script has every protocol function and no callback' ($ws -match 'function global:Invoke-ImapSession' -and $ws -match 'function global:Invoke-MailCheckWorker' -and -not ($ws -match '(?i)ValidationCallback'))
Check 'secret: DPAPI ConvertFrom-SecureString with no -Key' ($codeText -match 'ConvertFrom-SecureString -SecureString \$ss \)' -and -not ($codeText -match '(?i)SecureString[^\r\n]{0,60}-(Key|SecureKey)\b'))
Check 'secret file under LocalApplicationData, not beside buttons.json' ($src -match "GetFolderPath\('LocalApplicationData'\)\) 'ButtonLauncher'" -and $src -match "'email-count\.dat'")
Check 'no -AsPlainText / plain conversion of the password' (-not ($codeText -match '(?i)AsPlainText|PtrToStringAuto|PtrToStringBSTR|PtrToStringUni|NetworkCredential'))
Check 'Save-Config never writes email settings' (-not (($ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Save-Config' }, $true)).Extent.Text -match '(?i)mail'))
Check 'polling skips a stopped (sign-in failed) count unless the user asked' ($src -match 'if \(\$m\.state\.stopped -and -not \$byUser\) \{ return \}')
Check 'flash cancelled by hover and click' ($src -match 'Add_MouseEnter\(\{ Stop-MailFlash \}\)' -and $src -match 'Add_PreviewMouseLeftButtonDown\(\{ Stop-MailFlash \}\)')
Check 'flash: 3 x 500 ms on at 1 Hz with 60 ms ramps' ($src.Contains('$fm = @(0, 60, 500, 560, 1000, 1060, 1500, 1560, 2000, 2060, 2500, 2560)'))
Check 'badge: Kern -6 top, -8 right' ($src.Contains('SetLeft($bd, $ipx - 8); [System.Windows.Controls.Canvas]::SetTop($bd, -6)'))
Check 'motion follows Windows animation setting' ($src -match 'ClientAreaAnimation')
Check 'exit stops the email check' ($src -match 'try \{ Stop-Mail \} catch \{\}')
Check 'resume hooks the email check' ($src -match 'Resume-Mail')
Check 'version 1.4.0' ($src -match "\`$global:AppVersion\s+= '1\.4\.0'")
""
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
