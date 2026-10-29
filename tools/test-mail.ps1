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
       'New-MailState', 'Get-MailFreshState', 'Update-MailState', 'Step-MailResume', 'Get-MailLostResult', 'Get-MailNextDelaySec', 'Get-MailBadgeText', 'Get-MailBadgeWidth', 'Test-MailShowBadge', 'Test-MailShowRing',
       'Get-MailMotion', 'Format-MailTime', 'Get-MailCountText', 'Get-MailTipLine', 'Get-MailMenuLine', 'Get-MailAccessName', 'Get-MailTestText', 'Format-MailLogLine', 'Get-MailSecretPath', 'Get-MailSettingsPath', 'Remove-MailLogin',
       'Get-MailAddress', 'Test-MailAddress', 'Test-MailTile', 'ConvertTo-MailSettings', 'Get-MailSettingsJson', 'ConvertTo-MailFullAddress', 'Get-MailInterval', 'Get-MailAddressProblem', 'Write-LauncherError'
foreach ($n in $fns) {
    $f = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq "global:$n" }, $true)
    Check "defines $n" ([bool]$f); if ($f) { Invoke-Expression $f.Extent.Text } }
foreach ($l in $ast.EndBlock.Statements) { if ($l.Extent.Text -match '^\$global:(MailDomain|MailLogDetails|MailWorkerScript|MailIntervals|MailDialogXaml)\s*=') { Invoke-Expression $l.Extent.Text } }
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
$lb = Get-ImapLoginBytes 'test.user@example.invalid' $fake.ToCharArray()
Check 'LOGIN quoted' ((Ascii $lb.cmd) -ceq "a1 LOGIN `"test.user@example.invalid`" `"$fake`"`r`n" -and $null -eq $lb.literal)
$lb = Get-ImapLoginBytes 'test.user@example.invalid' 'x"y\z'.ToCharArray()
Check 'LOGIN escapes the password' ((Ascii $lb.cmd) -ceq "a1 LOGIN `"test.user@example.invalid`" `"x\`"y\\z`"`r`n")
$pw = ('p' + [char]0xE9 + 'ss')
$lb = Get-ImapLoginBytes 'test.user@example.invalid' $pw.ToCharArray()
Check 'LOGIN literal for non-ASCII: {5} + UTF-8 bytes + CRLF' ((Ascii $lb.cmd) -ceq "a1 LOGIN `"test.user@example.invalid`" {5}`r`n" -and [Text.Encoding]::UTF8.GetString($lb.literal) -ceq ($pw + "`r`n"))
$t = $false; try { [void](Get-ImapLoginBytes 'test.user@example.invalid' "ab`r`nc a2 LOGOUT".ToCharArray()) } catch { $t = $true }; Check 'LOGIN: CR/LF in password throws (no command injection)' $t
$t = $false; try { [void](Get-ImapLoginBytes "cc`r`n@example.invalid" 'x'.ToCharArray()) } catch { $t = $true }; Check 'LOGIN: CR/LF in user throws' $t
$t = $false; try { [void](Get-ImapLoginBytes ('c' + [char]0xE9 + '@example.invalid') 'x'.ToCharArray()) } catch { $t = $true }; Check 'LOGIN: non-ASCII user throws' $t

# --- tagged / STATUS parsing ---
Check 'tagged OK' ((Get-ImapTagged 'a1 OK LOGIN completed' 'a1') -eq 'OK')
Check 'tagged no lowercase' ((Get-ImapTagged 'a1 no [AUTHENTICATIONFAILED] bad' 'a1') -eq 'NO')
Check 'tagged BAD' ((Get-ImapTagged 'a2 BAD syntax' 'a2') -eq 'BAD')
Check 'other tag ignored' ($null -eq (Get-ImapTagged 'a11 OK x' 'a1') -and $null -eq (Get-ImapTagged '* OK a1 OK' 'a1'))
$cases = @(
    @('* STATUS INBOX (UNSEEN 3)', 3), @('* STATUS "INBOX" (UNSEEN 0)', 0), @('* status inbox (unseen 42)', 42), @('* STATUS INBOX (MESSAGES 231 UNSEEN 7 RECENT 1)', 7),
    @('* STATUS INBOX (UNSEEN 128)', 128), @('*  STATUS   INBOX   ( UNSEEN   5 )  ', 5), @('* STATUS "INBOX" (UIDNEXT 44292 UNSEEN 12)', 12), @("* STATUS INBOX (UNSEEN 3)`r", 3),
    @('* STATUS INBOX (MESSAGES 3)', -1), @('* STATUS INBOX (UNSEENX 3)', -1), @('* STATUS INBOX (UNSEEN x)', -1), @('* OK [UNSEEN 4] first unseen', -1), @('a2 OK STATUS done', -1),
    @('* STATUS INBOX (UNSEEN 9876543210)', -1), @('', -1))
foreach ($c in $cases) { Check ("STATUS parse: '{0}' -> {1}" -f ($c[0] -replace "`r", '\r'), $c[1]) ((Get-ImapStatusUnseen $c[0]) -eq $c[1]) }

# --- the session against a mock server (injectable read/write) ---
function New-Mock([string[]]$lines) {
    $m = @{ q = New-Object System.Collections.Queue; sent = New-Object System.Collections.ArrayList }
    foreach ($l in $lines) { $m.q.Enqueue($l) }
    $m.read = { if ($m.q.Count -eq 0) { throw 'closed' }; [string]$m.q.Dequeue() }.GetNewClosure()
    $m.write = { param([byte[]]$b) [void]$m.sent.Add([Text.Encoding]::UTF8.GetString($b)) }.GetNewClosure()
    return $m }
$m = New-Mock @('* OK [CAPABILITY IMAP4rev1] Dovecot ready.', '* CAPABILITY IMAP4rev1 IDLE', 'a1 OK [CAPABILITY IMAP4rev1] Logged in', '* STATUS INBOX (UNSEEN 3)', 'a2 OK Status completed.', '* BYE Logging out', 'a3 OK Logout completed.')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()
Check 'session ok: 3 unread' ($r.kind -eq 'ok' -and $r.unseen -eq 3)
Check 'session sends exactly LOGIN, STATUS INBOX (UNSEEN), LOGOUT' ($m.sent.Count -eq 3 -and $m.sent[0] -like 'a1 LOGIN *' -and $m.sent[1] -ceq "a2 STATUS INBOX (UNSEEN)`r`n" -and $m.sent[2] -ceq "a3 LOGOUT`r`n")
Check 'session result carries no password' (-not (($r | ConvertTo-Json -Compress) -match [regex]::Escape($fake)))
$m = New-Mock @('* OK ready', 'a1 NO [AUTHENTICATIONFAILED] Authentication failed.')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()
Check 'session NO -> auth, nothing sent after LOGIN' ($r.kind -eq 'auth' -and $m.sent.Count -eq 1)
$m = New-Mock @('* OK ready', 'a1 BAD unknown')
Check 'session BAD at login -> auth' ((Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()).kind -eq 'auth')
$m = New-Mock @('* OK ready', '* BYE too many bad logins')
Check 'session BYE at login -> auth (never retried on a timer)' ((Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()).kind -eq 'auth')
$m = New-Mock @('* BYE server shutting down')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray(); Check 'session BYE greeting -> net, nothing sent' ($r.kind -eq 'net' -and $m.sent.Count -eq 0)
$m = New-Mock @('HTTP/1.1 400 Bad Request')
Check 'session non-IMAP greeting -> proto' ((Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()).kind -eq 'proto')
$m = New-Mock @('* PREAUTH ready', '* STATUS INBOX (UNSEEN 2)', 'a2 OK', 'a3 OK')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray(); Check 'PREAUTH: no LOGIN sent' ($r.unseen -eq 2 -and -not ($m.sent -like 'a1*'))
$m = New-Mock @('* OK ready', 'a1 OK', 'a2 NO no such mailbox', 'a3 OK')
Check 'STATUS NO -> proto (a network-type failure, not auth)' ((Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()).kind -eq 'proto')
$m = New-Mock @('* OK ready', 'a1 OK')
$t = $false; try { [void](Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()) } catch { $t = $true }; Check 'connection drop throws (the worker maps it to net)' $t
$m = New-Mock @('* OK ready', '+ go ahead', 'a1 OK', '* STATUS INBOX (UNSEEN 1)', 'a2 OK', 'a3 OK')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $pw.ToCharArray()
Check 'literal login waits for + then sends the literal' ($r.unseen -eq 1 -and $m.sent[0] -ceq "a1 LOGIN `"test.user@example.invalid`" {5}`r`n" -and $m.sent[1] -ceq ($pw + "`r`n"))
$m = New-Mock @('* OK ready', 'a1 NO literal refused')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $pw.ToCharArray(); Check 'literal refused -> auth, literal not sent' ($r.kind -eq 'auth' -and $m.sent.Count -eq 1)
$m = New-Mock @('* OK ready')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' "x`ry".ToCharArray(); Check 'CR in password: nothing sent, auth (stops)' ($r.kind -eq 'auth' -and $m.sent.Count -eq 0)
$pc = $fake.ToCharArray(); $m = New-Mock @('* OK ready', 'a1 NO')
[void](Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $pc); Check 'caller-owned password chars untouched by the session (the worker zeroes them)' ((-join $pc) -ceq $fake)

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
foreach ($c in @(@(0, ''), @(1, '1'), @(9, '9'), @(10, '10'), @(99, '99'), @(100, '99+'), @(54321, '99+'))) { Check "badge text $($c[0]) -> '$($c[1])'" ((Get-MailBadgeText $c[0]) -ceq $c[1]) }
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
Check 'heading: When new email arrives:' ($src.Contains("'When new email arrives:'"))
Check 'setup copy present' ($src.Contains("'Show unread email count on the Email button'") -and $src.Contains("'Uses your Jartrek email, the same login as webmail.'") -and $src.Contains("'Everyone who uses this Windows login on this PC will see how many unread emails this account has.'") -and $src.Contains("'Turn off the email count and forget this login on this PC?'"))
Check 'menu items: Check email now, Setup item Unread email count...' ($src.Contains("'Check email now'") -and $src.Contains("'Unread email count...'"))

# --- address, settings, log: no password anywhere ---
Check 'address: only trimmed, typed as is' ((Get-MailAddress ' test.user ') -ceq 'test.user' -and (Get-MailAddress 'a@b.com') -ceq 'a@b.com')
foreach ($a in 'test.user@jartrek.net', 'first.last+x@jartrek.net') { Check "address ok: $a" (Test-MailAddress $a) }
foreach ($a in '', 'cc', 'cc@', "test.user@jartrek.net`r`nx", "test.user@jartrek.net`n", 'c c@jartrek.net', 'cc@jartrek', '"x"@jartrek.net') { Check ("address rejected: " + ($a -replace "`r", '\r' -replace "`n", '\n')) (-not (Test-MailAddress $a)) }
$j = Get-MailSettingsJson @{ enabled = $true; address = 'test.user@example.invalid'; style = 'pulse'; password = $fake; secret = $fake }
Check 'settings json: only enabled/address/style, no password' ($j -ceq '{"enabled":true,"address":"test.user@example.invalid","style":"pulse","interval":3}' -and -not $j.Contains($fake))
Check 'settings default: off, Flash' ((ConvertTo-MailSettings @{}).enabled -eq $false -and (ConvertTo-MailSettings @{}).style -eq 'flash')
Check 'settings: enabled needs a valid address' (-not (ConvertTo-MailSettings @{ enabled = $true; address = 'no pe' }).enabled)
$ll = Format-MailLogLine @{ kind = 'auth'; detail = $fake; unseen = -1; password = $fake; user = 'test.user@example.invalid' }
Check 'log line: no password, no address' (-not $ll.Contains($fake) -and -not $ll.Contains('example.invalid') -and $ll -ceq 'email count: auth')
Check 'log line: known detail kept' ((Format-MailLogLine @{ kind = 'net'; detail = 'connect timed out' }) -ceq 'email count: net (connect timed out)')
Check 'Email tile found by what it opens' ((Test-MailTile ([pscustomobject]@{ type = 'website'; target = 'mailto:' })) -and -not (Test-MailTile ([pscustomobject]@{ type = 'website'; target = 'https://www.google.com' })))
$cfg = Get-Content -LiteralPath (Join-Path $root 'buttons.default.json') -Raw | ConvertFrom-Json
Check 'default config has exactly one Email tile' (@($cfg.panels | ForEach-Object { $_.buttons } | Where-Object { Test-MailTile $_ }).Count -eq 1)
Check 'default config has no email settings or secrets' (-not ((Get-Content -LiteralPath (Join-Path $root 'buttons.default.json') -Raw) -match '(?i)password|emailCount|email-count'))

# --- fix round 1 (ClaudeCode M1/L1/N1, Lockjaw M14-I1..I5, Kern, Squint) ---
# M1 race (cf. ClaudeCode probe/v140/race.ps1): a check started before Save / turn off must never land on the new state
foreach ($stale in @(@{ kind = 'auth'; unseen = -1 }, @{ kind = 'ok'; unseen = 9 }, @{ kind = 'net'; unseen = -1 })) {
    $old = New-MailState; [void](Update-MailState $old @{ kind = 'ok'; unseen = 2; epoch = 0 } $now)
    $runEpoch = [int]$old.epoch                                   # the poll in flight was started with this epoch
    $fresh = Get-MailFreshState $old                              # Save after a good Test
    $test = @{ kind = 'ok'; unseen = 3; epoch = $fresh.epoch }; [void](Update-MailState $fresh $test $now)
    $stale.epoch = $runEpoch; $o = Update-MailState $fresh $stale $now
    Check "M1: stale '$($stale.kind)' after Save is ignored (state stays ok, 3, polling on)" ($o.ignored -and $fresh.phase -eq 'ok' -and $fresh.count -eq 3 -and -not $fresh.stopped) }
$a = New-MailState; Step-MailResume $a; Step-MailResume $a; $b = Get-MailFreshState $a; $c = Get-MailFreshState $b
Check 'M1: epoch only goes up across sleep, Save and turn off' ($b.epoch -eq 3 -and $c.epoch -eq 4)
$off = Get-MailFreshState $c; $o = Update-MailState $off @{ kind = 'auth'; epoch = $c.epoch } $now; Check 'M1: stale result after turn off ignored' ($o.ignored -and -not $off.stopped)
$sv = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Show-MailSetupDialog' }, $true).Extent.Text
Check 'M1: Save stops the check in flight and takes a fresh epoch' ($sv -match 'Stop-MailRunObjects \$global:mailRun; \$global:mail\.state = Get-MailFreshState \$global:mail\.state' -and $sv -notmatch 'state = New-MailState')
$dv = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Disable-Mail' }, $true).Extent.Text
Check 'M1: turn off stops the check (Stop-Mail) and takes a fresh epoch' ($dv -match 'Stop-Mail;' -and $dv -match 'Get-MailFreshState' -and $dv -notmatch 'New-MailState')
$sr = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Stop-MailRunObjects' }, $true).Extent.Text
Check 'L1: stopping a check never blocks the UI (BeginStop, no ps.Stop())' ($sr -match 'BeginStop\(\$null, \$null\)' -and $sr -notmatch '\.ps\.Stop\(\)')
Check 'L1: stopped checks are freed later (Clear-MailDeadRuns at the next check)' ($src -match 'function global:Clear-MailDeadRuns' -and $src -match '\{ return \$false \}\s+if \(-not \(Test-MailAddress \$user\)\) \{[^\r\n]*\r?\n[^\r\n]*\r?\n[^\r\n]*\r?\n[^\r\n]*return \$true \}\s+Clear-MailDeadRuns')
# N1: untagged lines before '+'
$m = New-Mock @('* OK ready', '* CAPABILITY IMAP4rev1', '* OK [ALERT] hello', '+ go', 'a1 OK', '* STATUS INBOX (UNSEEN 4)', 'a2 OK', 'a3 OK')
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $pw.ToCharArray()
Check 'N1: literal waits through untagged lines until +' ($r.kind -eq 'ok' -and $r.unseen -eq 4 -and $m.sent[1] -ceq ($pw + "`r`n"))
# I4: no definite tagged reply after LOGIN = sign-in failure (stops polling)
$m = New-Mock @('* OK ready'); $r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray(); Check 'I4: drop after LOGIN -> auth' ($r.kind -eq 'auth')
$m = New-Mock @('* OK ready', '* CAPABILITY x'); $r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray(); Check 'I4: untagged only, then drop -> auth' ($r.kind -eq 'auth')
$m = New-Mock @('* OK ready', '* OK still here'); $r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $pw.ToCharArray(); Check 'I4: literal never continued -> auth, literal not sent' ($r.kind -eq 'auth' -and $m.sent.Count -eq 1)
$s = New-MailState; [void](Update-MailState $s $r $now); Check 'I4: that result stops timed polling' ((Get-MailNextDelaySec $s) -eq -1)
Check 'I4: a drop after a good LOGIN is still a network error' ($src -match "kind = 'net'; unseen = -1; detail = 'network error'")
# I2
Check 'I2: a reply line over 16 KB stops the check' ($src -match "if \(\`$buf\.Length -ge 16384\) \{ throw 'line too long' \}")
# I3: turning off removes exactly the email files, crash leftovers included
$tmpd = Join-Path ([IO.Path]::GetTempPath()) ('bl-mailtest-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory $tmpd)
Invoke-Expression "function global:Get-MailDir { '$tmpd' }"
foreach ($n in 'email-count.json', 'email-count.dat', 'email-count.json.tmp', 'email-count.dat.tmp', 'other.txt', 'email-count.keep') { Set-Content -LiteralPath (Join-Path $tmpd $n) 'x' }
Remove-MailLogin
$left = @(Get-ChildItem -LiteralPath $tmpd | ForEach-Object Name | Sort-Object)
Check "I3: turn off deletes json, dat and both .tmp, nothing else ($($left -join ','))" (($left -join ',') -ceq 'email-count.keep,other.txt')
Remove-Item -LiteralPath $tmpd -Recurse -Force
# Kern / Squint
Check 'Kern: focus ring grid 26 for checkbox and radio, ring radius 8' (([regex]::Matches($src, '<Grid Width="26" Height="26"')).Count -eq 2 -and $src -match '<Border x:Name="Ring" CornerRadius="8"')
Check 'Kern: input padding 8,0 (no suffix padding now the address is typed in full)' ($src -match "\`$field\.Padding = '8,0'" -and $src -notmatch "\`$ta\.Padding = '8,0,96,0'")
Check 'Kern: buttons MinWidth 88, padding 16,0' ($src -match '\$b\.MinWidth = 88' -and $src -match "\`$b\.Padding = '16,0'")
Check 'Kern: red line on the password after a failed sign-in, cleared on typing' ($sv -match "\`$pErr\.Background = Brush '#F87171'" -and $sv -match "if \(\`$kind -eq 'auth'\) \{ 'Visible' \}" -and $sv -match "Add_PasswordChanged\(\{ \`$ds\.tested = \`$false; \`$pErr\.Visibility = 'Hidden'")
Check 'Kern: 8 between the result line and the buttons' ($sv -match "\`$rline\.Margin = '0,16,0,8'" -and $sv -match "\`$row\.Margin = '0'")
Check 'Squint: Enter is Test until a Test passes, then Save' ($sv -match '\$bSave\.IsDefault = \$ok; \$bTest\.IsDefault = -not \$ok' -and $sv -notmatch '\$bSave\.IsDefault = \$true')
Check "Squint: menu item 'Unread email count...', no 'Email count settings...'" (-not $src.Contains("'Email count settings...'") -and ([regex]::Matches($src, "'Unread email count\.\.\.'")).Count -ge 2)
Check "Squint: no 'mail arrives' left" (-not $src.Contains('new mail arrives'))
Check 'I5: no @jartrek.net address in tests outside the format checks' (@((Get-Content -LiteralPath $PSCommandPath) | Where-Object { $_ -match '[A-Za-z0-9.]+@jartrek\.net' -and $_ -notmatch "^(Check 'address|foreach \(\`$a in )" -and $_ -notmatch 'Get-ImapLoginBytes "cc`r`n' }).Count -eq 0)

# --- polish round (Lockjaw M15-I1, ClaudeCode I4 note: two kinds of sign-in failure) ---
$r = Get-MailLostResult @{ loginSent = $true } 'timed out'; Check 'M15-I1: 45 s cap after LOGIN went out -> unclear sign-in failure' ($r.kind -eq 'auth' -and $r.unclear)
$s = New-MailState; [void](Update-MailState $s $r $now); Check 'M15-I1: ... which stops polling (no timer retry)' ($s.stopped -and (Get-MailNextDelaySec $s) -eq -1 -and $s.authUnclear)
$r = Get-MailLostResult @{ loginSent = $false } 'timed out'; Check 'M15-I1: cap before LOGIN -> network retry' ($r.kind -eq 'net')
$r = Get-MailLostResult $null 'no result'; Check 'M15-I1: lost result with no sync -> network' ($r.kind -eq 'net')
$fl = @{ loginSent = $false }; $m = New-Mock @('* OK ready'); [void](Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray() $fl); Check 'M15-I1: the session sets loginSent before LOGIN' ($fl.loginSent)
$fl = @{ loginSent = $false }; $m = New-Mock @('* BYE bye'); [void](Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray() $fl); Check 'M15-I1: no LOGIN, no flag' (-not $fl.loginSent)
$sr2 = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Start-MailRun' }, $true).Extent.Text
Check 'M15-I1: Start-MailRun maps the cap and lost results through Get-MailLostResult' ($sr2 -match "Get-MailLostResult \`$run\.sync 'timed out'" -and $sr2 -match "Get-MailLostResult \`$run\.sync 'no result'" -and $sr2 -match 'loginSent = \$false' -and $src -match 'Invoke-ImapSession \$readLine \$write \$user \$chars \$sync')
# (a) definite NO/BAD = clear password failure; (b) anything else after LOGIN = unclear
$clear = 'Email count stopped: can''t sign in. If you changed your webmail password, update it in Setup > Unread email count...'
$unc = 'Email count stopped: couldn''t confirm sign-in. Check the connection, then choose Check email now. If you changed your webmail password, update it in Setup > Unread email count...'
foreach ($c in @(@('NO', @('* OK ready', 'a1 NO [AUTHENTICATIONFAILED] x')), @('BAD', @('* OK ready', 'a1 BAD x')))) {
    $m = New-Mock $c[1]; $r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()
    $s = New-MailState; [void](Update-MailState $s $r $now)
    Check "(a) $($c[0]) to LOGIN: clear failure, Squint's tip, menu, name, Test line" (-not $r.unclear -and $s.stopped -and (Get-MailTipLine $s $now) -ceq $clear -and (Get-MailMenuLine $s $now) -ceq 'Email count: can''t sign in' -and (Get-MailAccessName 'Email' $s) -ceq 'Email, email count can''t sign in' -and (Get-MailTestText $r).kind -eq 'auth' -and (Get-MailTestText $r).text -like 'Couldn''t sign in.*') }
foreach ($c in @(@('hang-up', @('* OK ready')), @('BYE', @('* OK ready', '* BYE going away')), @('garbage then drop', @('* OK ready', 'zzzz', 'qqqq')), @('no continuation', @('* OK ready')))) {
    $pwc = if ($c[0] -eq 'no continuation') { $pw } else { $fake }
    $m = New-Mock $c[1]; $r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $pwc.ToCharArray()
    $s = New-MailState; [void](Update-MailState $s @{ kind = 'ok'; unseen = 3 } $now); [void](Update-MailState $s $r $now)
    Check "(b) $($c[0]) after LOGIN: unclear failure stops polling, ring, no count, unclear tip/menu/name/Test line" ($r.kind -eq 'auth' -and $r.unclear -and $s.stopped -and (Test-MailShowRing $s) -and -not (Test-MailShowBadge $s) -and (Get-MailTipLine $s $now) -ceq $unc -and (Get-MailMenuLine $s $now) -ceq 'Email count: couldn''t confirm sign-in' -and (Get-MailAccessName 'Email' $s) -ceq 'Email, email count couldn''t confirm sign-in' -and (Get-MailTestText $r).kind -eq 'unclear' -and (Get-MailTestText $r).text -ceq 'Couldn''t confirm sign-in. Check this PC is online, then press Test again.') }
$s = New-MailState; [void](Update-MailState $s @{ kind = 'auth'; unclear = $true } $now); $o = Update-MailState $s @{ kind = 'ok'; unseen = 2 } $now
Check '(b) Check email now success clears it and polling resumes' ($s.phase -eq 'ok' -and -not $s.stopped -and (Get-MailNextDelaySec $s) -eq 180)
Check '(b) Test line uses the amber (net) look, not the red password line' ($sv -match "\{ \`$_ -eq 'net' -or \`$_ -eq 'unclear' \}" -and $sv -match "if \(\`$kind -eq 'auth'\) \{ 'Visible' \}")
Check 'exit frees parked checks (Clear-MailDeadRuns, best effort)' ($src -match 'try \{ Stop-Mail \} catch \{\}; try \{ Clear-MailDeadRuns \} catch \{\}')

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

# --- polish round 3 (ClaudeCode L1: loginOk after a tagged OK; Lockjaw M16-I1: close before reading the flags) ---
# dripstatus: LOGIN gets a tagged OK, then STATUS drips (a few untagged bytes, then the 45 s cap closes the socket)
$fl = @{ loginSent = $false; loginOk = $false }; $m = New-Mock @('* OK ready', 'a1 OK Logged in', '* STATUS INBOX (UN')
$thrown = $false; try { [void](Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray() $fl) } catch { $thrown = $true }
Check 'CC L1 dripstatus: tagged OK to LOGIN sets loginOk' ($fl.loginSent -and $fl.loginOk -and $thrown)
$r = Get-MailLostResult $fl 'timed out'; Check 'CC L1 dripstatus: cap after a good sign-in -> network retry, not a sign-in stop' ($r.kind -eq 'net' -and -not $r.unclear)
$s = New-MailState; [void](Update-MailState $s $r $now); Check 'CC L1 dripstatus: ... polling continues with backoff' (-not $s.stopped -and -not $s.authUnclear -and (Get-MailNextDelaySec $s) -gt 0)
$r = Get-MailLostResult $fl 'no result'; Check 'CC L1 dripstatus: lost result after a good sign-in -> network' ($r.kind -eq 'net')
$fl = @{ loginSent = $false; loginOk = $false }; $m = New-Mock @('* OK ready', '* CAPABILITY IMAP4rev1')
$thrown = $false; try { $x = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray() $fl } catch { $thrown = $true }
Check 'CC L1: LOGIN sent, no tagged OK -> loginOk stays false' ($fl.loginSent -and -not $fl.loginOk)
$r = Get-MailLostResult $fl 'timed out'; Check 'CC L1: cap with LOGIN sent but no OK is still an unclear sign-in failure' ($r.kind -eq 'auth' -and $r.unclear)
foreach ($c in @(@('NO', 'a1 NO [AUTHENTICATIONFAILED] bad'), @('BAD', 'a1 BAD syntax'))) { $fl = @{ loginSent = $false; loginOk = $false }; $m = New-Mock @('* OK ready', $c[1])
    $r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray() $fl
    Check "CC L1: $($c[0]) to LOGIN stays a clear failure, loginOk false" ($r.kind -eq 'auth' -and -not $r.unclear -and -not $fl.loginOk) }
Check 'CC L1: Start-MailRun starts loginOk false' ($sr2 -match 'loginOk = \$false')
$capLine = @($sr2 -split "`n" | Where-Object { $_ -match "'timed out'" })
Check 'LJ M16-I1: on the cap tick Stop-MailRunObjects runs before Get-MailLostResult' ($capLine.Count -eq 1 -and $capLine[0].IndexOf('Stop-MailRunObjects $run') -ge 0 -and $capLine[0].IndexOf('Stop-MailRunObjects $run') -lt $capLine[0].IndexOf('Get-MailLostResult $run.sync'))
# --- v1.4.0 laptop bug (2:41 PM): "The property 'Background' cannot be found on this object" on Setup > Unread email count...
# Root cause: New-D2Field($input). $input is PowerShell's pipeline enumerator, so the TextBox/PasswordBox never arrived and
# $input.Background = ... hit the enumerator. These run without Windows: a lint, a WPF property table, and a stand-in run.
. (Join-Path $PSScriptRoot 'wpf-props.ps1')
$autoBad = @(); foreach ($f in @(Get-ChildItem (Join-Path $root '*.ps1')) + @(Get-ChildItem (Join-Path $PSScriptRoot '*.ps1'))) {
    $fa2 = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null); $autoBad += @(Find-AutomaticVarMisuse $fa2 | ForEach-Object { "$($f.Name): $_" }) }
Check ('no parameter or assignment named after an automatic variable ($input, $args, $this, ...) ' + ($autoBad -join '; ')) ($autoBad.Count -eq 0)
$propBad = @(Find-WpfPropMisuse $ast)
Check ('every WPF property the launcher sets exists on that element type ' + ($propBad -join '; ')) ($propBad.Count -eq 0)
$oldBug = [System.Management.Automation.Language.Parser]::ParseInput("function global:New-D2Field(`$input) { `$input.Background = 1 }", [ref]$null, [ref]$null)
Check 'the lint catches the exact 349e026 bug (New-D2Field($input))' (@(Find-AutomaticVarMisuse $oldBug).Count -eq 1)
$probe = [System.Management.Automation.Language.Parser]::ParseInput("function global:P { `$r = New-Object System.Windows.Shapes.Rectangle; `$r.Background = 1; `$t = New-Object System.Windows.Controls.Primitives.Popup; `$t.Background = 1 }", [ref]$null, [ref]$null)
Check 'the property table catches Background on a Rectangle and a Popup' (@(Find-WpfPropMisuse $probe).Count -eq 2)
# stand-in run of the real New-D2Field: strict objects throw the same error the laptop showed on any unknown property
function New-Strict([string]$t) {
    $o = New-Object psobject; foreach ($pn in $global:WpfProps[$t]) { $o | Add-Member NoteProperty $pn $null }
    $o | Add-Member NoteProperty WpfType $t; $o | Add-Member NoteProperty Handlers @{}
    if ($t -match 'Grid|StackPanel|DockPanel') { $o | Add-Member NoteProperty Children (New-Object System.Collections.ArrayList) -Force }
    foreach ($ev in 'GotKeyboardFocus', 'LostKeyboardFocus', 'Click', 'TextChanged', 'PasswordChanged') { $o | Add-Member ScriptMethod ("Add_" + $ev) ([scriptblock]::Create("param(`$h) `$this.Handlers['$ev'] = `$h")) }
    return $o }
$d2 = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:New-D2Field' }, $true).Extent.Text
$d2 = $d2 -replace 'New-Object (System\.Windows\.[\w.]+)', 'New-Strict ''$1''' -replace '\[System\.Windows\.Media\.Brushes\]::Transparent', '''transparent''' -replace 'function global:New-D2Field', 'function global:Test-D2FieldRun'
function global:Brush($h) { $h }
Invoke-Expression $d2
foreach ($kind in 'System.Windows.Controls.TextBox', 'System.Windows.Controls.PasswordBox') {
    $in = New-Strict $kind; $e = $null; $fb = $null; try { $fb = Test-D2FieldRun $in } catch { $e = $_.Exception.Message }
    Check "New-D2Field styles the real $($kind.Split('.')[-1]) it is given (not-configured setup dialog opens)" (-not $e -and $in.Background -eq 'transparent' -and $in.Padding -eq '8,0' -and $fb.Child.Children[0] -eq $in -and $in.Handlers['GotKeyboardFocus']) }
Invoke-Expression (($d2 -replace '\$field\b', '$input') -replace 'Test-D2FieldRun', 'Test-D2FieldOld')
$e = $null; try { [void](Test-D2FieldOld (New-Strict 'System.Windows.Controls.PasswordBox')) } catch { $e = $_.Exception.Message }
Check 'stand-in run reproduces the laptop error on the old code' ($e -match "The property 'Background' cannot be found on this object")
$sd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Show-MailSetupDialog' }, $true).Extent.Text
Check 'not configured: the setup dialog builds both fields through New-D2Field and reads no saved secret unless enabled' ($sd.Contains('$fa = New-D2Field $ta') -and $sd.Contains('$fp = New-D2Field $pb') -and $sd.Contains('if ($was.enabled -and (Test-Path -LiteralPath (Get-MailSecretPath)))'))
$kinds = @((Get-MailTestText @{ kind = 'ok'; unseen = 2 }).kind, (Get-MailTestText @{ kind = 'auth' }).kind, (Get-MailTestText @{ kind = 'auth'; unclear = $true }).kind, (Get-MailTestText @{ kind = 'net' }).kind, (Get-MailTestText @{ kind = 'cert' }).kind)
Check 'Test results: ok, clear fail, unclear fail, network' (($kinds -join ',') -eq 'ok,auth,unclear,net,net')
Check 'Test results: the dialog has a branch for each and sets only Text/Foreground on its TextBlocks' ($sd.Contains("'ok' { `$ri.Text") -and $sd.Contains("'auth' { `$ri.Text") -and $sd.Contains("{ `$_ -eq 'net' -or `$_ -eq 'unclear' }") -and $sd -notmatch '\$r[it]\.Background')
foreach ($st in 'flash', 'pulse', 'badge') { Check "style ${st}: motion path picked, badge only when animations are off" ((Get-MailMotion $st $true) -eq $st -and (Get-MailMotion $st $false) -eq 'badge') }
$ov = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Add-MailOverlay' }, $true)
Check 'flash/pulse/badge overlay: every property set exists on its element (property table)' ($ov -and @(Find-WpfPropMisuse $ov).Count -eq 0)
# --- v1.4.0 laptop bug (4:38 PM): pressing Test -> "The property 'busy' cannot be found on this object" ---
# Root cause: GetNewClosure copies only LOCAL variables. $onDone (and the wait timer) are closures made inside the Test click
# closure, so they never had $ds/$showResult/$refresh; when the check finished, "$ds.busy = $false" ran on $null.
# The suites missed it: they tested the mail functions and New-D2Field, never the click handler's closures, and the
# property table only knew WPF types. Now: a closure-capture lint over every .ps1, and a run of the REAL Test handler below.
$capBad = @(); foreach ($f in @(Get-ChildItem (Join-Path $root '*.ps1')) + @(Get-ChildItem (Join-Path $PSScriptRoot '*.ps1'))) {
    $fa3 = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null); $capBad += @(Find-ClosureCaptureMisses $fa3 | ForEach-Object { "$($f.Name): $_" }) }
Check ('every variable a closure reads is captured (GetNewClosure copies locals only) ' + ($capBad -join '; ')) ($capBad.Count -eq 0)
$nest = [System.Management.Automation.Language.Parser]::ParseInput('function global:P { $ds = @{ busy = 1 }; $b = { $cb = { $ds.busy = 0 }.GetNewClosure() }.GetNewClosure() }', [ref]$null, [ref]$null)
Check 'the closure lint catches the exact 632a4be bug shape ($ds in a closure inside a closure)' (@(Find-ClosureCaptureMisses $nest).Count -eq 1)
$hook = [System.Management.Automation.Language.Parser]::ParseInput('function global:P { $w = 1; $x = { $w; $s.AddHook({ param($h, $msg) $msg }) }.GetNewClosure() }', [ref]$null, [ref]$null)
Check 'the closure lint leaves params of an inner delegate alone' (@(Find-ClosureCaptureMisses $hook | Where-Object { $_ -match 'msg|\$h ' }).Count -eq 0)
$pco = [System.Management.Automation.Language.Parser]::ParseInput('function global:P { $o = [pscustomobject]@{ a = 1 }; $o.a = 2; $o.busy = 3 }', [ref]$null, [ref]$null)
Check 'the property lint flags a key that a [pscustomobject] does not have' (@(Find-WpfPropMisuse $pco).Count -eq 1 -and (@(Find-WpfPropMisuse $pco)[0] -match 'busy'))
# run the REAL Test click handler from Show-MailSetupDialog, built the same way (a closure made inside the dialog's scope)
$sdAst = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Show-MailSetupDialog' }, $true)
$tc = $sdAst.Find({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Expression.Extent.Text -eq '$bTest' -and $x.Member.Extent.Text -eq 'Add_Click' }, $true)
$handlerText = $tc.Arguments[0].Expression.ScriptBlock.Extent.Text
Check 'found the real Test handler' ($handlerText -match 'Start-MailRun \$addr \$sec \$onDone')
$global:pendingDone = $null
function global:Start-MailRun($user, $sec, $OnDone) { $global:pendingDone = $OnDone; $global:pendingUser = $user; return $true }   # like the real one: OnDone runs later, from a timer tick
function global:Read-MailSecret { $null }
function Build-TestHandler([string]$text) {   # mirrors the dialog: these are locals of the dialog function, the handler is a closure over them
    $was = @{ enabled = $false; address = '' }; $origAddr = ''
    $ds = @{ tested = $false; addr = ''; result = $null; busy = $false; closed = $false; wait = $null }
    $shown = New-Object System.Collections.ArrayList
    $showResult = { param($kind, $txt) [void]$shown.Add("$kind|$txt") }.GetNewClosure()
    $refresh = { [void]$ds.busy }.GetNewClosure()
    $ta = [pscustomobject]@{ Text = '  Test.User@example.invalid ' } | Add-Member ScriptMethod Focus { $true } -PassThru
    $ss = New-Object System.Security.SecureString; foreach ($ch in $fake.ToCharArray()) { $ss.AppendChar($ch) }
    $pb = [pscustomobject]@{ SecurePassword = $ss } | Add-Member ScriptMethod Focus { $true } -PassThru
    $h = ([scriptblock]::Create($text.Substring(1, $text.Length - 2))).GetNewClosure()
    return @{ h = $h; ds = $ds; shown = $shown } }
function Fire-Done($r) { $ds = 'not the dialog state'; $showResult = $null; & $global:pendingDone $r }   # another scope, like DispatcherTimer.FireTick
$bt = Build-TestHandler $handlerText; $err = $null
try { & $bt.h; Fire-Done @{ kind = 'ok'; unseen = 2 } } catch { $err = $_.Exception.Message }
Check 'real Test handler: press Test, the check ends from a timer tick -> no error, busy cleared, result shown, Save allowed' (-not $err -and $bt.ds.busy -eq $false -and $bt.ds.tested -and $bt.ds.addr -eq 'Test.User@example.invalid' -and ($bt.shown -join ';') -match 'busy\|Testing.*;ok\|Signed in. 2 unread')
Check 'real Test handler: the full typed address (trimmed) is what signs in' ($global:pendingUser -ceq 'Test.User@example.invalid')
$bt = Build-TestHandler $handlerText; $err = $null
try { & $bt.h; Fire-Done @{ kind = 'auth'; detail = 'NO' } } catch { $err = $_.Exception.Message }
Check 'real Test handler: failed sign-in -> no error, busy cleared, red line, not tested' (-not $err -and $bt.ds.busy -eq $false -and -not $bt.ds.tested -and ($bt.shown -join ';') -match 'auth\|Couldn''t sign in')
$old = $handlerText -replace '\$ds = \$ds; \$showResult = \$showResult; \$refresh = \$refresh', ''
$bt = Build-TestHandler $old; $err = $null
try { & $bt.h; Fire-Done @{ kind = 'ok'; unseen = 2 } } catch { $err = $_.Exception.Message }
Check 'the same run reproduces the laptop error on the 632a4be handler' ($err -match "The property 'busy' cannot be found on this object")
# --- full address (Charles types and edits it), validated as untrusted ---
foreach ($a in 'cc@jartrek.net', 'First.Last@jartrek.net', 'a+b_c-d@mail.jartrek.net', ('a' * 64 + '@jartrek.net')) { Check "address ok: $a" (Test-MailAddress (Get-MailAddress " $a ")) }
foreach ($bad in '', 'cc', '@example.invalid', 'cc@', 'cc@@example.invalid', 'c@c@example.invalid', 'c c@example.invalid', "cc@example.invalid`r`na2 LOGOUT", "cc`n@example.invalid", 'c"c@example.invalid', 'c\c@example.invalid', 'c(c)@example.invalid', 'c{1}@example.invalid', 'c*@example.invalid', 'c%@example.invalid', 'c]@example.invalid', "c`t@example.invalid", ('c' + [char]0 + '@example.invalid'), ('c' + [char]0xE9 + '@example.invalid'), 'cc@example', ('a' * 65 + '@example.invalid'), ('a@' + ('b' * 250) + '.net')) {
    Check ("address refused: " + ($bad -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t' -replace [char]0, '\0')) (-not (Test-MailAddress (Get-MailAddress $bad))) }
Check 'Get-MailAddress only trims (no hidden @jartrek.net)' ((Get-MailAddress ' cc ') -ceq 'cc')
Check 'address migration: saved user part only -> full address; full address kept' ((ConvertTo-MailSettings @{ enabled = $true; address = 'cc' }).address -ceq 'cc@jartrek.net' -and (ConvertTo-MailSettings @{ enabled = $true; address = 'x@other.invalid' }).address -ceq 'x@other.invalid' -and -not (ConvertTo-MailSettings @{ enabled = $true; address = 'c c' }).enabled)
$sd2 = $sdAst.Extent.Text
Check 'dialog: no locked suffix; the field starts as editable "@jartrek.net", caret at the start' ($sd2 -notmatch '\$suffix' -and $sd2.Contains('$ta.Text = if ($was.address) { [string]$was.address } else { $global:MailDomain }') -and $sd2.Contains('$ta.CaretIndex = 0'))
Check 'server unchanged: mail.jartrek.net:993, Windows certificate check, no callback' ($src -match "mail\.jartrek\.net" -and $src -match '993' -and $src -notmatch 'RemoteCertificateValidationCallback\s*=|ServerCertificateValidationCallback')
# --- recheck interval ---
foreach ($c in @(@($null, 3), @('', 3), @('x', 3), @($true, 3), @(0, 3), @(1, 3), @(1.9, 3), @(-5, 3), @(2, 2), @(3, 3), @('5', 5), @(7, 7), @(30, 30), @(60, 60), @(61, 60), @(1e9, 60), @('NaN', 3), @('Infinity', 3))) {
    Check ("interval {0} -> {1}" -f $(if ($null -eq $c[0]) { 'null' } else { $c[0] }), $c[1]) ((Get-MailInterval $c[0]) -eq $c[1]) }
Check 'interval choices are 2, 3, 5, 10, 15, 30; default 3' (($global:MailIntervals -join ',') -eq '2,3,5,10,15,30' -and (ConvertTo-MailSettings @{ enabled = $false }).interval -eq 3)
$s0 = New-MailState
Check 'timer uses the saved interval (2 min -> 120 s, 10 -> 600 s, hand-edited 1 -> 180 s)' ((Get-MailNextDelaySec $s0 2) -eq 120 -and (Get-MailNextDelaySec $s0 10) -eq 600 -and (Get-MailNextDelaySec $s0 1) -eq 180 -and (Get-MailNextDelaySec $s0) -eq 180)
$s0.fails = 2; Check 'network backoff never sooner than the interval' ((Get-MailNextDelaySec $s0 3) -eq 360 -and (Get-MailNextDelaySec $s0 30) -eq 1800)
$js = Get-MailSettingsJson @{ enabled = $true; address = 'test.user@example.invalid'; style = 'flash'; interval = 5; password = $fake }
Check 'interval is stored in the non-secret settings; nothing else survives (no password)' ($js -ceq '{"enabled":true,"address":"test.user@example.invalid","style":"flash","interval":5}')
Check 'Save applies the interval at once (no restart)' ($sd2.Contains('interval = $iv }') -and $sd2.Contains('Set-MailTimer (Get-MailNextDelaySec $global:mail.state $set.interval)') -and $sd2.Contains('Start-MailPolling -firstSec (60 * $set.interval)') -and $src.Contains('Set-MailTimer (Get-MailNextDelaySec $m.state $m.set.interval)'))
# --- the password never reaches the log (failing sign-in path) ---
$global:logPath = Join-Path ([IO.Path]::GetTempPath()) ('bl-maillog-' + [guid]::NewGuid() + '.log')
function global:Get-Date { param([string]$Format) '2026-10-29T16:00:00' }   # the log formats only
$m = New-Mock @('* OK ready', "a1 NO [AUTHENTICATIONFAILED] wrong password $fake")
$r = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray()
Add-Content -LiteralPath $global:logPath -Value (Format-MailLogLine $r)
$m = New-Mock @('* OK ready'); $m.write = { param([byte[]]$b) throw ('socket closed while sending ' + [Text.Encoding]::ASCII.GetString($b).Length + ' bytes') }
$r2 = $null; try { $r2 = Invoke-ImapSession $m.read $m.write 'test.user@example.invalid' $fake.ToCharArray() } catch { Write-LauncherError 'while running' $_ }
if ($r2) { Add-Content -LiteralPath $global:logPath -Value (Format-MailLogLine $r2) }
try { [void](Get-ImapLoginBytes 'test.user@example.invalid' ("$fake`r`nx").ToCharArray()) } catch { Write-LauncherError 'while running' $_ }
Remove-Item Function:\Get-Date
$logText = [IO.File]::ReadAllText($global:logPath); Remove-Item -LiteralPath $global:logPath -Force
Check 'failing sign-ins: the error log has lines, and never the password (server echo, socket error, bad characters)' ($logText.Length -gt 0 -and $logText -notmatch [regex]::Escape($fake) -and $r.kind -eq 'auth')
Check 'password never in buttons.json, a command line or the settings JSON (source)' ($src -notmatch 'ArgumentList[^\r\n]*(SecurePassword|\$pass\b|\$secure)' -and $src -notmatch 'Set-Prop \$global:cfg[^\r\n]*(password|secret)')
# --- Kern/Squint email setup fixes + Lockjaw M21 (6c96c6b review) ---
Check 'address: empty name before @ gets its own words (Squint) (Test and Save)' ((Get-MailAddressProblem '@jartrek.net') -ceq 'Type your name before @jartrek.net.' -and (Get-MailAddressProblem ' @jartrek.net ') -ceq 'Type your name before @jartrek.net.' -and (Get-MailAddressProblem 'cc') -ceq 'Type your full email address, like name@jartrek.net.' -and $null -eq (Get-MailAddressProblem 'test.user@example.invalid'))
$sd3 = $sdAst.Extent.Text
Check 'Squint: Test and Save both use the address message' (([regex]::Matches($sd3, '\$why = Get-MailAddressProblem \$addr; if \(\$why\) \{ & \$showResult ''auth'' \$why')).Count -eq 2)
Check 'Squint: focus into a field that says only @jartrek.net puts the caret first, via Dispatcher.BeginInvoke' ($sd3.Contains('$ta.Add_GotKeyboardFocus(') -and $sd3.Contains('if ($t.Text -ceq $global:MailDomain) { [void]$t.Dispatcher.BeginInvoke([Action]{ $t.CaretIndex = 0 }.GetNewClosure()'))
Check 'Squint: HelpText and a grey 12 px hint under the field' ($sd3.Contains("SetHelpText(`$ta, 'Type your name before @jartrek.net')") -and $sd3.Contains("`$hint.Text = 'Type your name before @jartrek.net'; `$hint.FontSize = 12; `$hint.Foreground = Brush '#B4B4BC'"))
Check 'Kern: combo uses the D2Combo style, 32x140, no own margin (16 above the buttons comes from the row)' ($sd3.Contains("`$cbI.Width = 140; `$cbI.Height = 32") -and $sd3.Contains("`$cbI.Margin = '0'") -and $sd3.Contains("TryFindResource('D2Combo')") -and $sd3.Contains("`$row.Margin = '0,16,0,0'"))
[xml]$mx = $global:MailDialogXaml
$xs = $global:MailDialogXaml
Check 'Kern: D2Combo/D2ComboItem in the dialog XAML (well-formed)' ($mx.ResourceDictionary.Style.Count -ge 4 -and $xs.Contains('x:Key="D2Combo"') -and $xs.Contains('x:Key="D2ComboItem"'))
Check 'Kern: box = field fill #0FFFFFFF, radius 6, 40% bottom line, #22C55E 2 px on focus/open, E70D chevron #B4B4BC' ($xs.Contains('Background="#0FFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" CornerRadius="6"') -and $xs.Contains('Height="1" VerticalAlignment="Bottom" Background="#66FFFFFF"') -and $xs.Contains('x:Name="Focus" Height="2" VerticalAlignment="Bottom" Background="#22C55E"') -and $xs.Contains('Text="&#xE70D;"') -and $xs.Contains('Foreground="#B4B4BC"') -and $xs.Contains('Property="IsKeyboardFocusWithin"'))
Check 'Kern recheck: popup edge 35% white #59FFFFFF + 1 px #40000000 hairline ring (margin -1, radius 9), no offset block' ($xs.Contains('Background="#2B2B30" BorderBrush="#59FFFFFF" BorderThickness="1" CornerRadius="8"') -and $xs.Contains('<Border Margin="-1" CornerRadius="9" BorderBrush="#40000000" BorderThickness="1" IsHitTestVisible="False"/>') -and -not $xs.Contains('Margin="1,3,-3,-5"'))
Check 'Kern: popup #2B2B30, radius 8; items 32 tall, 9% hover, green pill when selected; disabled 0.4' ($xs.Contains('Background="#2B2B30" BorderBrush="#59FFFFFF" BorderThickness="1" CornerRadius="8"') -and $xs.Contains('<Setter Property="Height" Value="32"/><Setter Property="FocusVisualStyle"') -and $xs.Contains('Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#17FFFFFF"') -and $xs.Contains('x:Name="Pill" Width="3" Height="16"') -and $xs.Contains('Value="0.4"'))
Check 'keyboard kept: real ComboBox with PART_Popup + ItemsPresenter, toggle not focusable (arrows, Alt+Down, Esc stay the ComboBox''s own)' ($xs.Contains('x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}"') -and $xs.Contains('<ItemsPresenter') -and $xs.Contains('<ToggleButton x:Name="Toggle" Focusable="False"'))
Check 'CC: interval clamp - any number over 60 -> 60 ([double]::MaxValue, 1e300, decimal, long), NaN / +-Infinity -> 3' ((Get-MailInterval ([double]::MaxValue)) -eq 60 -and (Get-MailInterval 1e300) -eq 60 -and (Get-MailInterval ([decimal]::MaxValue)) -eq 60 -and (Get-MailInterval ([long]::MaxValue)) -eq 60 -and (Get-MailInterval '1e300') -eq 60 -and (Get-MailInterval ([double]::NaN)) -eq 3 -and (Get-MailInterval ([double]::PositiveInfinity)) -eq 3 -and (Get-MailInterval ([double]::NegativeInfinity)) -eq 3 -and (Get-MailInterval ([double]::MinValue)) -eq 3)
Check 'interval clamp still holds (hand-edited 0 / 99 / text)' ((Get-MailInterval 0) -eq 3 -and (Get-MailInterval 99) -eq 60 -and (Get-MailInterval 'abc') -eq 3 -and (ConvertTo-MailSettings @{ interval = 1 }).interval -eq 3)
# LJ M21-I1: the More-menu statements were commented out by a mid-line comment
$vp = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Show-VncPicker' }, $true)
$mc = $vp.Find({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Expression.Extent.Text -eq '$bMore' -and $x.Member.Extent.Text -eq 'Add_Click' }, $true)
$mset = @($mc.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true) | ForEach-Object { $_.Left.Member.Value })
Check 'LJ M21-I1: the More menu really sets PlacementTarget, Placement and VerticalOffset (code, not comment)' ($mset -contains 'PlacementTarget' -and $mset -contains 'Placement' -and $mset -contains 'VerticalOffset' -and $mset -contains 'HorizontalOffset')
$cmt = @(); foreach ($f in @(Get-ChildItem (Join-Path $root '*.ps1')) + @(Get-ChildItem (Join-Path $PSScriptRoot '*.ps1'))) { $cmt += @(Find-CommentedOutCode $f.FullName | ForEach-Object { "$($f.Name) $_" }) }
Check ('no statements hidden inside a comment ' + ($cmt -join '; ')) ($cmt.Count -eq 0)
$tmpc = Join-Path ([IO.Path]::GetTempPath()) ('bl-cmt-' + [guid]::NewGuid() + '.ps1')
[IO.File]::WriteAllText($tmpc, '$b.Add_Click({ $b = $b; $m = 1;   # note $m.PlacementTarget = $b; $m.Placement = ''Top'' })'); $caught = @(Find-CommentedOutCode $tmpc).Count; Remove-Item -LiteralPath $tmpc
Check 'the comment lint catches the exact 6c96c6b line' ($caught -eq 1)
# LJ M21-I2: Start-MailRun refuses a bad address itself (fail closed, nothing started, password disposed)
$smr = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'global:Start-MailRun' }, $true).Extent.Text
Invoke-Expression ($smr -replace 'function global:Start-MailRun', 'function global:Start-MailRunReal')
function global:Clear-MailDeadRuns { throw 'a check was started' }
$global:mailRun = $null; $global:mail = $null
foreach ($bad in @('', 'x y@example.invalid', "a@example.invalid`r`na2 LOGOUT", '@jartrek.net', 'a"b@example.invalid')) {
    $ss = New-Object System.Security.SecureString; $ss.AppendChar('x'); $got = @{ r = $null }; $err = $null; $ret = $null
    try { $ret = Start-MailRunReal $bad $ss { param($r) $got.r = $r }.GetNewClosure() } catch { $err = $_.Exception.Message }
    $disposed = $false; try { $ss.AppendChar([char]120) } catch { $disposed = $true }
    Check ("LJ M21-I2: Start-MailRun fails closed on '" + ($bad -replace "`r", '\r' -replace "`n", '\n') + "' (no check started, sign-in failure reported, password disposed)") (-not $err -and $ret -eq $true -and $got.r.kind -eq 'auth' -and $got.r.detail -cin $global:MailLogDetails -and $disposed) }
Check 'LJ M21-I2: the address check is the first thing after the busy check' ($smr.IndexOf('Test-MailAddress $user') -gt 0 -and $smr.IndexOf('Test-MailAddress $user') -lt $smr.IndexOf('Clear-MailDeadRuns') -and $smr.IndexOf('Test-MailAddress $user') -lt $smr.IndexOf('CreateRunspace'))
""
if ($fail) { "FAILED: $fail"; exit 1 } else { 'ALL PASS' }
