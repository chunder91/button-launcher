# Lockjaw security review: Button Launcher (static, box copy at src/ as of Oct 29 2026 9:35 AM ET)

**Verdict: PASS. Critical 0 / High 0 / Medium 0 / Low 4 / Info 6.** No secrets (gitleaks --redact --no-git: none; manual read: none). Nothing blocks use.

## Findings

**L1 Low · Launcher.ps1:121, :149-172 · Elevation lure via user-writable script/config**
Installed to %LOCALAPPDATA%\Programs\<name> (user-writable). Any same-user process can edit Launcher.ps1 or set `runAsAdmin`/`target` in buttons.json, and the next click shows a genuine "Windows PowerShell" (Microsoft-signed) UAC prompt for attacker code. On shop PCs where a standard user gets an over-the-shoulder admin login, this is a real path to admin.
Fix: don't type admin creds into a launcher-triggered prompt on a PC you suspect; for shop PCs consider installing per-machine to Program Files (admin-only write) if standard users run it.

**L2 Low · Launcher.ps1:50, :159-163, :364 · "website" type accepts any URI scheme**
`Start-Process $u` runs anything with a scheme: `file:`, `ms-*:` handlers, `search-ms:`, or a drive path like `C:\x.exe` (the `^[a-z]...:` check matches `C:`). Type inference also routes any `scheme:` target to this branch. Config-only (same user), so low.
Fix: allow only `^(https?|mailto):` in the website branch and the Test button; reject the rest with a message.

**L3 Low · Launcher.ps1:144-155, :369-371 · Forced restart confirmation is optional**
`shutdown /r /f /t 0` only asks if `confirm` text is set. Shipped buttons.json sets it, but a button created via Edit (Built-in defaults to "Restart computer (force)") has no confirm, so one click force-reboots with unsaved work lost.
Fix: always confirm for `restart-computer` (use a default message when `confirm` is blank).

**L4 Low · Build-Installer.ps1:8-9, :44-50 · Title flows unescaped into generated Uninstall.ps1 / rmdir**
`$AppName` is interpolated into Uninstall.ps1 inside double quotes (:48) and single quotes (:45, :47, :49): a title with `$(...)` becomes code in Uninstall.ps1, an apostrophe breaks it. If the title sanitizes to empty (e.g. `***`), `$dest` = `%LOCALAPPDATA%\Programs\` and :50 `rmdir /s /q` wipes every per-user program. Title is author-controlled, so low.
Fix: restrict title to `[A-Za-z0-9 _.-]`, fall back to `Launcher` when empty; in Uninstall.ps1 use `$PSScriptRoot` for the folder and single-quote escape the name.

## Info
- I1 Launcher.ps1:110-121: elevation uses `-EncodedCommand` of a fixed script; the only interpolated value is a GUID temp path. No config/user text reaches the elevated command. Good. Wildcard `ScreenConnect Client*` matches only ScreenConnect's own client service naming; creating a look-alike service needs admin already.
- I2 Launcher.ps1:118/128: result file sits in user %TEMP% (GUID name); a same-user process could fake the result message. Cosmetic.
- I3 Launcher.ps1:170: script args are string-joined (`-File "$path" $a`); `args` is config text the user owns, run as that user (or elevated via runAsAdmin, see L1). Expected behavior.
- I4 Build-Installer.ps1:32-33: payload zip uses a predictable %TEMP% name; same-user only. Setup.exe is unsigned with no integrity check; copy it over trusted media only.
- I5 Build-Installer.ps1:81: Windows' installer detection may auto-elevate unsigned exes named "*Setup*"; if a UAC prompt appears on install, decline it, or it installs into the admin's profile. Verify once on a test PC.
- I6 `-ExecutionPolicy Bypass` (vbs, cmd, installer, uninstaller): not a security boundary; doesn't widen risk here.

## Checked and fine
- Config parsed with ConvertFrom-Json only; no iex/Invoke-Expression, Import-Clixml, or dot-sourcing anywhere.
- No `cmd /c` with config text in the launcher; env-var expansion (ExpandEnvironmentVariables) is on the user's own values.
- UNC/`\\` targets without a scheme get `https://` prefixed in website mode (not executed as files).
- Log (launcher-error.log) records only exception message + stack trace; no secrets; WPF MessageBox output isn't an injection sink.
- Install dir under %LOCALAPPDATA% is per-user ACL'd; no HKCU Run key (Startup-folder shortcut instead); uninstall registry string is quoted.
- .vbs/.cmd launchers quote the path correctly; hidden window is intended.
- No network downloads, hardcoded hosts besides the two pa.gov/google URLs, or credentials.

## Addendum (Oct 29, 2026, after reading ClaudeCode's review)
- **I7 (Info), the elevated script quotes the temp path in single quotes (Launcher.ps1:111-121).** The result path is built from $env:TEMP and pasted into the encoded admin script inside single quotes. A user profile name with an apostrophe (for example O'Brien) breaks the elevated script, and in theory the rest of the name would run as admin code. Only the PC's own account name controls this value, and no attacker can set it across a boundary, so it's a robustness issue rather than a vulnerability. Smallest fix: double any ' in the path (`$res -replace "'", "''"`) or pass the path as a separate argument.
- **Severity note on L4 and ClaudeCode's H1/M1:** the security rating stays Low. Both the empty-title wipe and the $(...) in the title need someone to edit their own buttons.json, and they run only as that user, so no boundary is crossed. The wipe is still real data loss, and I agree it should be fixed before the build ships.

## Re-check: review-fixes-1 @772f83a

Static review of `git diff main...772f83a` (25 commits, private repo chunder91/button-launcher), done Oct 29 2026 9:52 AM ET. gitleaks --redact over the full branch history found nothing.

**Verdict: PASS. Critical 0 / High 0 / Medium 0 / Low 0 / Info 5 (new). All 4 earlier Lows are fixed or documented.**

### Earlier items
- **L1, fixed (documented):** README.txt:134-144 covers the user-writable install, "Run as admin" and args trust, and says to click No on unexpected prompts or on a Setup.exe UAC prompt.
- **L2, fixed:** `Get-SafeUrl` (Launcher.ps1:50-56) is used in both the run path (:179) and the Test button (:419). It trims, then allows only a case-insensitive `https?://` or `mailto:` prefix. Any other scheme, a drive path or a `\`/`/` path is rejected. A leading control or odd character (not trimmed) fails both regexes, so the result is `https://<junk>`, which only opens a browser. `host:8080` also gets the https prefix. Bypass checked and not possible.
- **L3, fixed:** Launcher.ps1:156-163 always confirms `restart-computer`, with a built-in message when the confirm text is blank. The YesNo box defaults to No.
- **L4, fixed:** Build-Installer.ps1:11-12 allow-lists the name to `[A-Za-z0-9 _-]` and defaults to `Launcher`, so it can't be empty, `..`, rooted or quoted. Uninstall.ps1 is a literal template that only has `__NAME__` substituted. It uses `$PSScriptRoot` and requires the full path to equal `%LOCALAPPDATA%\Programs\<AppName>`, the name to re-match the allow-list, and Launcher.ps1 to be present (:44-49). Because the name is non-empty, the target can never resolve to `Programs` itself or a parent. The delete uses PowerShell `-LiteralPath` with the path escaped, and no cmd.
- **I4, fixed:** Build-Installer.ps1:78 now gives the payload zip a GUID name.
- **M5 (CC) / I7, fixed:** Launcher.ps1:123,130 escapes the `'` in the elevated script's result path and uses `-LiteralPath`. The elevated command still contains only a GUID temp path.
- **I1-I3, I5, I6:** unchanged and still Info. README now covers I5.

### New surface (all fine)
- **ButtonLauncher.exe stub (exe/ButtonLauncher.cs):**
  - The folder comes from `AppDomain.BaseDirectory` (the exe's own folder), not the current directory.
  - PowerShell is called by its full `System32\WindowsPowerShell\v1.0\powershell.exe` path with `UseShellExecute=false`.
  - The script path and forwarded args are quoted to CommandLineToArgvW rules, and the args go after `-File`, so they're script args only. Launcher.ps1 only acts on `-Reload`.
  - I rebuilt it from source (dotnet, offline): same size and the same strings. The only byte differences are the PDB path and the IDs derived from it, so the committed binary matches the source.
- **HKCU Run (Build-Installer.ps1:108-110, Launcher.ps1 Set-Autostart):** the value is the quoted exe path (or `wscript.exe "<vbs>"`), so no unquoted-path problem. Uninstall removes it only if it points into its own folder.
- **HKCU Uninstall key:** UninstallString is `powershell.exe ... -File "<dest>\Uninstall.ps1"` with the path quoted. QuietUninstallString adds `-Quiet`.
- **.lnk files:** they target the installed exe (or powershell with a quoted -File), with WorkingDirectory set to the install folder. The desktop shortcut is opt-in, default No.
- **Single instance:** `Local\ButtonLauncher-<sha1(folder)>` mutex plus a `Local\...-show` AutoReset event. Both are per-session, not Global\. The event carries no data and only triggers Show-AllPanels. No sockets, pipes or listeners.
- **Other new code:**
  - Save-Config now does a tmp-file swap with a `.bak`, and startup falls back to the `.bak`. Both are still parsed with ConvertFrom-Json only.
  - Locked menus now hide edit items.
  - The "Set up this PC" picker uses the same Ask-ForPath as before.
  - The missing-picture log line records only the label and image path.
  - Pictures now load through a FileStream.
  - The image-copy rename loop compares hashes and doesn't overwrite.
  - Nothing new is elevated.

### New Info
- **N1, Launcher.ps1:93/Resolve-ButtonPath:** a button explicitly typed `program` with a target like `ms-settings:` still goes to ShellExecute, so the L2 allow-list covers website buttons only. Program buttons run arbitrary exes by design, so this adds no capability.
- **N2, Get-SafeUrl:** a `mailto:` value can carry `?attach=`-style parameters. Outlook ignores attach. It's config-only, so no action needed.
- **N3, exe stub:57-58:** if System32's powershell.exe is ever missing, it falls back to the bare name, which would search the exe's own (user-writable) folder first. That's same-user and practically never reached.
- **N4, Local\ mutex:** a same-session process could pre-create the name and stop the launcher starting. Same-user denial of service only.
- **N5, Uninstall:** `Remove-Item -Recurse` on PS 5.1 can follow a junction planted inside the install folder. That needs same-user write and doesn't escalate.

### Checked and fine
No secrets, no Invoke-Expression in the shipped code (only tools/test-installer-dryrun.ps1, a dev test on the repo's own source, uses it), no downloads, and no new elevation paths. ExecutionPolicy Bypass is unchanged and not a boundary.

## Re-check 2: 772f83a..cde5cf55

Range 772f83a..cde5cf55fbdbbcacbcd9b00567f8a3e746efbf94 (9 commits). Static review, Oct 29 2026 10:05 AM ET. gitleaks --redact on the new commits found nothing.

**Verdict: PASS. Critical 0 / High 0 / Medium 0 / Low 0 / Info 3 new (N6-N8). N3 closed. N5 still Info.**

### Items
- **7bfb896 R-M3, fixed (closes N3):** ButtonLauncher.cs uses only `Environment.SystemDirectory\WindowsPowerShell\v1.0\powershell.exe`, with no fallback. If it's missing, the stub shows an error box and exits with code 3.
- **3a6e0af R-M1, fixed:**
  - I rebuilt offline with dotnet. The committed exe, the recorded `exe/ButtonLauncher.exe.sha256` and my build are all `a72fa22a…2715e`.
  - Build-Installer computes the exe's hash itself with Get-FileHash, checks the recorded value is 64 hex characters, and throws on any mismatch or a missing .sha256. It fails closed and has no skip flag (the only parameter is `-OutDir`).
  - The .sha256 sits next to the exe, so it catches accidental mismatches, not a deliberate swap (see N8).
- **0112e21 R-L1, fixed:** the reserved-name check covers CON, PRN, AUX, NUL, COM1-9 and LPT1-9 in any case and with any extension, both before and after the allow-list. Names are capped at 64, trailing dots and spaces are trimmed, and anything rejected falls back to `Launcher`. The copies in the launcher and the builder are identical.
- **ba9003e R-L2, fixed for Uninstall keys:** old keys are removed only when `InstallLocation` exactly equals the install folder (case-insensitive, trailing `\` trimmed), so a prefix like `Launcher2` can't match. Run values still use a substring check (see N6).
- **b01a1c4, uninstall delete, fixed and safe:**
  - The name is now filled into the template on the builder side (Build-Installer.ps1:169), using the allow-listed `$safe` only.
  - `__NAME__` appears once in each template, the name can't contain quotes or `$`, so there's no injection.
  - Guard (Build-Installer.ps1:69-71):
    - The name must re-match the allow-list.
    - `GetFullPath($PSScriptRoot)` must exactly equal `%LOCALAPPDATA%\Programs\<name>` (case-insensitive).
    - Launcher.ps1 must be present.
  - The name can't be empty or `..`, so the target can never be `Programs` itself or a parent.
- **Junctions (N5), Info, still open:**
  - On Windows PowerShell 5.1, `Remove-Item -Recurse -Force` is known to follow directory junctions and symlinks during recursion. A junction planted inside the install folder (or the install folder itself made a junction) could have its target's contents deleted.
  - Realistically that needs same-user write and only deletes files that user can already delete, so it's not an escalation.
  - Smallest fix: delete with `[IO.Directory]::Delete($dest, $true)`, which removes reparse points without following them on .NET Framework, or `cmd /c rmdir /s /q`.
- **a08cf4a R-M2, fixed for buttons.json:**
  - The payload ships only `buttons.default.json`.
  - The installer (and the launcher at startup) copies it to `buttons.json` only when that file is missing.
  - User-added pictures with new names are kept. A picture that has the same name as a shipped one is overwritten, which is a data note, not a security issue.
- **Image path traversal, Info:**
  - `image` values may be rooted or contain `..`, but they're only read for display or with Test-Path.
  - New pictures are copied in under `GetFileName()`, so they can't escape `images\`.
  - Zip extraction joins entry names without a traversal check, but the zip is built by Build-Installer from its own staging folder (N7).
- **Other changes, fine:**
  - Reload now keeps running after the 10 s wait and logs it.
  - check-launcher.ps1 changed its default path (dev tool only).
  - The dry-run tests were extended.
  - .gitignore now ignores buttons.json.

### New Info
- **N6, Build-Installer.ps1 Uninstall template (Run loop) and install Run section:** Run-value cleanup uses `IndexOf($dest)`, so `...\Programs\Launcher` also matches `"...\Programs\Launcher2\ButtonLauncher.exe"`. Installing or uninstalling "Launcher" could remove a legacy `ButtonLauncher` autostart value that belongs to a `Launcher2` install. That's an annoyance, not a security issue. Fix: match against `'"' + $dest + '\ButtonLauncher.exe"'`, or compare exactly against the expected command.
- **N7, install extraction:** `Join-Path $dest $e.FullName` has no `..` check. The payload is self-built, so the risk is theoretical. Fix: skip entries whose full path doesn't start with `$dest\`.
- **N8, R-M1 hash:** the recorded hash travels with the exe, so it isn't authenticity. That's fine for a personal tool; code signing would be the real fix.

## Re-check 3: cde5cf5..d4fa6e84

Range cde5cf5..d4fa6e843ea56f1ad4b9c9af2d124d41343d4d18 (7 commits). Static review, Oct 29 2026 10:18 AM ET. gitleaks --redact on the new commits found nothing.

**Verdict: PASS. Critical 0 / High 0 / Medium 0 / Low 0 / Info 0 new. N5, N6 and N7 are closed.**

- **N5, 5a84420: fixed.**
  - If the install folder itself is a reparse point, `Directory.Delete(d,false)` removes only the link.
  - Otherwise a stack walk with `GetDirectories` unlinks every reparse-point subfolder (non-recursive delete, so the link only), and only then runs `Directory.Delete(d,true)`.
  - `FileAttributes.ReparsePoint` is set for both junctions and directory symlinks, and `RemoveDirectory` on either removes only the link.
  - Nested links are covered: the walk descends only into real folders, and every link it meets is unlinked.
  - File symlinks are removed as files by the recursive delete, without touching their target.
  - Race: a link created by the same user between the walk and the final delete is still safe, because .NET Framework's recursive `Directory.Delete` checks for reparse points and doesn't recurse into them. The walk is defence in depth.
  - I couldn't test a real junction on the Linux box, so this is from the code and the .NET/Win32 docs.
- **N6, 463ddb4: fixed.** A Run value is removed only on an exact, case-insensitive match with `"<dest>\ButtonLauncher.exe"` or `wscript.exe "<dest>\Start Launcher.vbs"`, in both the installer and the uninstaller. `Launcher2` can't match.
- **N7, 7033509: fixed.** Extraction skips rooted entries and any `..` segment (either slash), then requires `GetFullPath(target)` to start with the full install path plus a trailing `\` (case-insensitive).
- **781c190, image manifest: fine.**
  - Lines in `shipped-images.txt` are only used as lookup keys, after a `^[0-9a-f]{64}\s+` regex.
  - Write paths always come from zip entries that have passed the N7 checks, so a manifest entry can't redirect a write.
  - An existing image is replaced only if its current hash equals the hash recorded when it shipped. Otherwise it's kept and the skip is logged.
- **cb10fcb, tests: fine.** They cover N5 (symlink only), N6, N7 and the manifest.
- **Others: fine.**
  - The Reload timeout now asks Yes/No, default No.
  - RELEASE.md and the reminder text are new.
  - No new launch, network or registry surface.

## modern-b: d4fa6e8..8f9f6cf0

One commit, 8f9f6cf06d1e936696e9278fada635b341fe1983.

**Verdict: PASS. Critical 0 / High 0 / Medium 0 / Low 0 / Info 1.**

- **Unchanged security paths:** I extracted `Invoke-Button`, `Restart-ScreenConnect`, `Get-SafeUrl` and `Resolve-ButtonPath` from both branches. They're byte-identical, so the restart confirm (default No), URL allow-list and elevation script are unchanged.
- **Diff grep:**
  - No new Start-Process. The Build installer and Notepad items only moved into a Setup submenu, unchanged.
  - None of the following: Invoke-Expression/iex, Net./WebClient/Invoke-WebRequest, HKCU/registry, RunAs, `cmd /c`, Add-Type, DllImport.
  - Build-Installer only bumps the version to 1.2.0.
- **XAML: none.** No XamlReader or loaded XAML. The UI is built in code, the font family is a hardcoded string, and colours go through a fixed palette map.
- **Image/URL loading:** unchanged (the same Get-PicSource, which reads from a stream). No URL loading.
- **Migration (`Update-OldDefaultOrder`):**
  - It runs only when `layoutVersion` is below 2, and reorders a panel only when all 7 labels exactly match the old default, case-sensitive and in order. Customised panels are left alone.
  - It moves the same button objects, so target, args, type, runAsAdmin and confirm are untouched. It changes only width and height, and adds `group: 'danger'` to the two restart buttons.
  - `group` is only read for styling (Launcher.ps1:252) and never reaches a launch.
  - The write is atomic (`.tmp`, then `File.Replace`, keeping `.bak`).
  - buttons.default.json only swaps the order of the ScreenConnect and Jartrek Security buttons. Their fields are unchanged.
- **N9, Info, Launcher.ps1:457:** tiles now launch on Enter or Space when focused, so a stray keypress can start a button. Restart computer still confirms (default No) because the keypress goes through the same Invoke-Button. ScreenConnect still gets its UAC prompt. No action needed.

## Re-check 4: modern-b @d6d4cb3

Diff 8f9f6cf0..d6d4cb368a07dbf3587b1e648a3008c2e7a4a48c (8 commits). Static review, Oct 29 2026 10:28 AM ET. gitleaks --redact on the new commits found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 0 / Info 1.**
- **R4-L2, fixed.**
  - The delete first walks the tree, unlinking any reparse-point subfolder (`Directory.Delete(x,false)` removes the link only) and descending only into real folders.
  - It then deletes bottom-up, re-checking ReparsePoint on every folder right before deleting it. It deletes files one by one after clearing read-only, and never calls a recursive Directory.Delete.
  - If the install folder itself is a link, only the link is removed.
  - The exact-folder and Launcher.ps1 guards are unchanged.
  - The whole delete is wrapped in try/catch, so the first error stops it and leaves the rest in place, which is fail-safe.
  - **N10, Info:** `File.SetAttributes(Normal)` on a file symlink may clear the read-only flag on its target. It deletes nothing outside the folder, so it's harmless.
- **R4-L1, fixed.** With no manifest, a hardcoded table of v1.1.0 picture hashes is used. It's lookup-only, and paths still come from the N7-checked zip entries.
- **R4-N1, fixed.** Entry names containing `:`, invalid path characters or `*?"<>|` are skipped and logged. Only the payload entry name (self-built) is logged, with no user data or secrets.
- **MB-M1, fixed.** The KeyDown handler ignores `IsRepeat`, and repeats are marked handled, so a held Enter or Space fires once, including the ScreenConnect UAC prompt.
- **Unchanged:** Invoke-Button, Restart-ScreenConnect, Get-SafeUrl and Resolve-ButtonPath are byte-identical to 8f9f6cf. The other commits only touch the migration (move only, TryParse, write failure caught) and animation.

## one-panel @4acb0e5

Diff base: merge-base with modern-b, which is d6d4cb3 (one-panel merged modern-b at e6e4cda). The main merge-base is older, at 0a8528f. Diff d6d4cb3..4acb0e5171f16846561fda28d0d96cd24de95e7e (2 commits plus the merge). gitleaks found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 1 / Info 3.**
- **Launch path, fine.** Middle chips call the same `Invoke-Button` on click, and on Enter/Space with key repeat ignored. The four security functions are byte-identical to modern-b, so chips go through the same Get-SafeUrl, Resolve-ButtonPath, restart confirm and ScreenConnect elevation. No other launch path exists.
- **Diff grep, clean.** No new Start-Process, iex, network, registry/HKCU, RunAs or `cmd /c`. The only new Add-Type entries are the RegisterHotKey/UnregisterHotKey P/Invokes (plain user32 signatures, safe).
- **OP-L1, Low, Launcher.ps1 `Get-ChipIcon` (~:1074), automatic UNC touch.**
  - When the panel renders, every chip whose target isn't a website runs `Test-Path` and `[Drawing.Icon]::ExtractAssociatedIcon` on its target, with no click needed. New chips default to `image='icon'`.
  - A `\\host\share\...` target, or a `.lnk` whose IconLocation points at UNC (the shell resolves the shortcut's icon chain), makes Windows try SMB auth and can leak the user's NTLMv2 hash to that host on every launcher start.
  - It's limited because targets are user-set. It matters on work and shop PCs if someone is handed a shortcut or config.
  - The older `image:'icon'` path on tiles had the same behaviour, but chips make it the default.
  - Smallest fix: skip icon extraction (use the type fallback icon) when the expanded target, or a .lnk's resolved icon location, starts with `\\`, or isn't on a local fixed drive.
- **Icon reading, Info.** ExtractAssociatedIcon only reads icon resources and doesn't execute the target. For some file types the shell loads an icon-handler extension in-process, but those are already-installed handlers.
- **Tray icon, fine.** Menu items are Show, Lock/Unlock, Settings and Exit, with no launches. `Stop-TrayAndHotkey` runs on app Exit, hides and disposes the tray icon, and unregisters the hotkey.
- **Ctrl+Alt+L, fine.**
  - It's registered on a message-only window (HWND_MESSAGE) with MOD_NOREPEAT.
  - The hook acts only on WM_HOTKEY with its own id, calls Show-AllPanels, and never launches anything.
  - If another program owns the hotkey, that's logged.
- **Transparent single window, Info.**
  - It uses WPF `AllowsTransparency` per-pixel alpha (transparent pixels click through), not WS_EX_TRANSPARENT over content.
  - It's topmost only if the panel was already set that way.
  - It can't cover the UAC prompt, which runs on the secure desktop. Its only visible content is the launcher's own tiles, so it's no realistic clickjacking surface.
- **Admin prompt and restart confirm:** unchanged.
- **Info:** buttons.default.json adds `layout: 'two'` and an empty middle list, with no targets.

## Re-check 5: modern-b d6d4cb3..402e7f7

Range d6d4cb3..402e7f7d3c6262a3628ce3e4c4b08a32b3b058db (3 commits). Static review, Oct 29 2026 10:35 AM ET. gitleaks --redact on the new commits found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 1 (TS-L1, pre-existing) / Info 0 new.**
- **N10, 519e295: fixed.** Read-only is cleared only when the file isn't a reparse point. Links are deleted as-is.
- **402e7f7: fixed, fail-closed.**
  - After extraction, the installer checks for Launcher.ps1, ButtonLauncher.exe and buttons.default.json.
  - If any is missing, it logs the missing names only, shows an error and exits 1. That happens before the buttons.json copy, the Uninstall.ps1 write, any shortcut and any Run or Uninstall registry write.
- **3934eed: fine.** The hashes are a hashtable of name to an array of hashes, used only for the overwrite decision (`-notcontains`). Write paths still come from the N7-checked zip entries.
- **Unchanged:** Invoke-Button, Restart-ScreenConnect, Get-SafeUrl and Resolve-ButtonPath are identical to d6d4cb3.
- **TS-L1, Low, pre-existing, Launcher.ps1:336 (Test-Path) and :338 (detect Get-ChildItem) in `Test-ButtonSetUpQuick`, called at :425 while tiles draw.**
  - A UNC or mapped-network target, or `detect.paths` entry, is touched on every draw, so it can send SMB auth (NTLM) with no click.
  - It's the same class as OP-L1.
  - Fix: run these checks only for `Test-LocalFixedPath` targets, and treat anything non-local as "unknown" (no dot) until a click.
  - Tiles with `image:'icon'` (`Get-IconImage`, ExtractAssociatedIcon on the target) have the same draw-time touch and should get the same gate.

## Re-check 5: one-panel 4acb0e5..dca60d3

Range 4acb0e5..dca60d300c51341073395d4328b862843026efdc (7 commits plus 2 merges of modern-b). gitleaks found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 1 (TS-L1, pre-existing) / Info 2.**
- **OP-L1, cd151f7: fixed.** `Test-LocalFixedPath` (:1080-1088) trims spaces and quotes, then:
  - rejects any path starting with `\\`, `//`, `\/` or `/\`, which covers UNC, `\\?\UNC\`, `\\.\` and `\\?\C:` (a safe false negative);
  - requires `^[A-Za-z]:[\\/]`, which rejects relative paths, `file://`, URLs and bare names;
  - requires the real `DriveInfo.DriveType` to be `Fixed`, so mapped network and WebDAV drives (Network), removable drives and CD-ROMs are rejected.

  A SUBST drive can only alias a local folder, so it's fine. Env vars are expanded before the check, both for the target and for the .lnk TargetPath and IconLocation (with the `,index` stripped), so a `%VAR%` that expands to UNC is rejected. The .lnk is read only after its own path passes.
- **OP-N2, Info:** a symlink or junction on a fixed drive that points at UNC passes the string and drive check, and Get-Item or the icon extraction would follow it to SMB. It needs a local plant. Fix if wanted: also reject when the target's attributes include ReparsePoint.
- **OP-N3, Info:** a crafted .lnk can carry shell data blocks that WScript's TargetPath and IconLocation don't show, such as an IconEnvironmentDataBlock or a network LinkInfo. The shell's icon resolution could still reach UNC through those. It needs a crafted .lnk saved locally and picked by the user. Fix if wanted: don't extract icons from .lnk; extract from its verified TargetPath instead.
- **dca60d3, icon cache: fine.** It's in memory only (`$global:iconCache`), so nothing goes to disk and nothing is parsed. The key is `lowercased path|LastWriteTimeUtc ticks`. A stale icon only happens if a file changes without its mtime changing, which is cosmetic.
- **Startup `finally { Stop-TrayAndHotkey }` (:1452) and tray icon dispose (:1382-1383): fine.** Cleanup unregisters the hotkey, disposes the source, tray and icon, and nulls the globals, so it's safe to run twice.
- **Other commits: fine.** Chip press and capture now match the tile pattern, there's a shared Undo timer, and the modern-b fixes are merged. The diff adds no Start-Process, iex, network, registry, RunAs, `cmd /c` or Add-Type. The launch functions are identical.
- **TS-L1, Low, pre-existing:** `Test-ButtonSetUpQuick` Test-Path at :346 and detect Get-ChildItem at :348.
  - Tiles call it ungated at :435.
  - Chips call it at :1148, gated by `Test-LocalFixedPath` for the target, but the `detect.paths` loop at :348 isn't gated.
  - The fix is the same as on modern-b.

## Re-check 6: modern-b 402e7f7..89f76f4

Range 402e7f7..89f76f416b0d256a946f45c82ab77b8072b3365a (4 commits). Static review, Oct 29 2026 10:45 AM ET. gitleaks --redact on the new commits found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 1 (TS-L2, residual) / Info 3.**
- **TS-L1, 1ea6f31/3adcb4d: fixed for the paths it targeted.**
  - `Get-SetupState` returns ok, missing or unchecked. The tile call (:494-496) uses it.
  - The target touch (Test-Path) and the .lnk read happen only after `Test-LocalFixedPath` passes. Each `detect.paths` entry is gated before Get-ChildItem.
  - `Get-IconImage` (:213-216) only reads a path returned by `Resolve-IconTarget` (or explorer.exe).
  - Non-local targets show an "unchecked" tooltip and no dot.
  - No timer or refresh path calls anything else. Relayout and rebuild re-run the same gated functions.
- **TS-L2, Low, new residual of the same class.** Two draw or automatic touches are still ungated:
  - (a) `Get-PicSource` Test-Path on a tile's own `image` value (:230 for the -small probe, :232). `Resolve-Img` accepts rooted paths, so `image: "\\host\x.png"` triggers SMB on every draw.
  - (b) First-run `Show-SetupWindow -OnlyIfNeeded` (:1144) calls `Test-ButtonReady` (:659-664), which runs Test-Path on the target and `Find-Detected` (detect Get-ChildItem, recursive .lnk search, WScript TargetPath plus Test-Path) with no local gate. That happens automatically once per install.

  Both are config-only. Fix:
  - In Get-PicSource, return `$null` unless `Test-LocalFixedPath $p`.
  - In Test-ButtonReady, treat non-local as ready or unchecked.
  - In Find-Detected, skip non-local `detect.paths`.
- **OP-N2 (reparse points): fixed.**
  - Attributes are read for the path and each parent with `[IO.File]::GetAttributes`, only after the string and drive-type checks pass, so the probe itself is local.
  - It rejects ReparsePoint (0x400), Offline (0x1000), RECALL_ON_OPEN (0x40000) and RECALL_ON_DATA_ACCESS (0x400000).
  - A component that doesn't exist yet is treated as fine, which is OK because nothing is read from it.
- **Subst and redirectors: fixed.**
  - The new P/Invoke is `kernel32!QueryDosDevice(string, StringBuilder, int)` with CharSet Unicode, a 1024 buffer and the size passed. It's safe.
  - A `\??\UNC\` subst is rejected. A `\??\X:\dir` subst is re-checked recursively (depth limited to 4).
  - `\Device\Mup`, `LanmanRedirector` and `WebDavRedirector` are rejected, and mapped network drives already fail on DriveType.
- **Offline and recall placeholders: fixed** (same attribute mask).
- **OP-N3: fixed.** `Resolve-IconTarget` takes the icon only from the checked target (for a .lnk, its checked TargetPath), never the .lnk icon location.
  - Reading a local .lnk through `WScript.Shell.CreateShortcut(...).TargetPath` parses the file and returns the stored path without calling `IShellLink::Resolve`, so realistically it makes no network access.
- **89f76f4, staged install swap: fine.**
  - The staging folder is `%LOCALAPPDATA%\Programs\<name>.new-<8 hex>` and the backup is `<dest>.old-<8 hex>`. Both use random names under the install's parent.
  - `Copy-Tree` skips links. The core files must come from this payload.
  - On failure, rollback moves the old folder back only if dest is missing. `Remove-Tree` only targets `$stage` or `$old`, both built from dest or parent plus a GUID, so it can't delete outside them. Remove-Tree never recurses into a link.
  - The log `%TEMP%\<name>-install.log` records only timestamps, paths and exception messages. No secrets.
- **I-R6a, Info:** the log name is fixed, so a same-user symlink plant could redirect the appends. No escalation.
- **I-R6b, Info:** `Remove-Tree` sets `Attributes='Normal'` on file links inside `$old`, which is the N10 pattern again (it can clear read-only on a link's target). Harmless. Fix: skip it for reparse points.
- **I-R6c, Info:** wildcards in `detect.paths` (for example `Jartrek*`) can match a local junction pointing off-PC during Get-ChildItem, because the attribute check runs on the literal pattern. That needs a local plant.
- **3934eed/da04ac9 (known hashes):** used for lookup only.
- **Unchanged:** Invoke-Button, Restart-ScreenConnect, Get-SafeUrl and Resolve-ButtonPath are identical to 402e7f7.

## Re-check 6: one-panel dca60d3..ad77a2c

Range dca60d3..ad77a2cc78fa118a675e4f9fe220ea438647293e (one commit plus merges of modern-b). gitleaks found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 1 (TS-L2) / Info 3.** These are the same I-R6a/b/c via the merge.
- **Chip path: fully gated.**
  - The chip's own image is checked with `Test-LocalFixedPath` before Get-PicSource (:1161-1163).
  - The target icon comes only from `Resolve-IconTarget`, and Get-Item and ExtractAssociatedIcon then run only on that checked local file (:1168-1180).
  - The setup dot uses `Get-SetupState` (:1203).
  - The fallback icons are the launcher's own images.
- **Icon cache:** in memory, capped at 256 with the oldest dropped first, and keyed by path plus mtime. Cosmetic only.
- **TS-L2:** the same as modern-b, for tiles. Get-PicSource is at :242/:244, and the first-run Test-ButtonReady is at :671-676, called from :1504.
- **Unchanged:** Invoke-Button, Restart-ScreenConnect, Get-SafeUrl and Resolve-ButtonPath are identical.

## Re-check 7: modern-b 89f76f4..3250cd7

Range 89f76f4..3250cd7821cc841730cfbea3ca010ada5644b926 (3 commits). Static review, Oct 29 2026 10:50 AM ET. gitleaks --redact on the new commits found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 0 / Info 2. TS-L2 is closed.**
- **0b18c23: fixed.**
  - `Get-PicSource` substitutes the type's default art (a local install file) when `Test-LocalFixedPath` fails on the picture path, before any touch (:251).
  - `Test-ButtonReady` returns ready for non-local targets before Test-Path (:690-691), and isn't listed as missing.
  - `Find-Detected`: automatic calls skip non-local `detect.paths`. Local ones go through `Find-LocalMatch`, which walks one segment at a time, skips reparse-point matches and re-checks the result.
  - Redirected Desktop and Start folders are detected by running `Test-LocalFixedPath` on the folder path. A UNC, mapped or Mup/WebDAV redirect, or a reparse point in the path, is skipped. A found .lnk's TargetPath is only Test-Path'd if it's local.
  - Click calls pass `-AllowNetwork`, which is the only change to `Resolve-ButtonPath`. That's acceptable, because the user acted.
  - The reparse walk now goes root-down and stops at the first missing folder or link.
- **3ad25ed: fixed.**
  - The `%TEMP%` log name has 12 random hex characters and is created with `FileMode.CreateNew`, so it fails rather than following a planted file or link.
  - Swap cleanup clears read-only only on non-links.
  - A failed copy-over removes only `$stage`.
  - If both the swap and the rollback fail, nothing is deleted and both folder paths are reported.
  - Rollback stays bounded: `Remove-Tree` targets only `$stage` and `$old` (dest or parent plus a GUID), never follows links, and runs only when the restore succeeded.
- **3250cd7:** refactor only, with no behaviour change.
- **Known gap, Info (R7-I1):** `Get-ChildItem -Recurse` over local Start menu and Desktop folders for `lnkNames` (:112) follows a junction planted inside them on PS 5.1. It's the same class as I-R6c: it needs a local plant.
- **Info (R7-I2):** the `-small` picture probe (:253) checks a sibling of an already-gated local picture. The sibling itself could be a planted file symlink to UNC. That needs a local plant.
- **Unchanged:** Invoke-Button, Restart-ScreenConnect and Get-SafeUrl are identical. Resolve-ButtonPath differs only by the `-AllowNetwork` flag on its click-time `Find-Detected` call.

### Final no-click sweep (modern-b @3250cd7)
I enumerated every Test-Path, Get-ChildItem, Get-Item, Get-Content, Add-Content, Set-Content, Copy-Item, [IO.File]/[IO.Directory] call, ExtractAssociatedIcon, CreateShortcut, OpenRead, SoundPlayer and Get-FileHash in Launcher.ps1. Every call reachable without a click is gated or local by construction:
- **Startup:** the config, `.bak`, default and dpi-log files are all under `$global:here`, the install folder.
- **Draw (tiles):**
  - `Get-SetupState` is gated.
  - `Get-PicSource` is gated, and the default art is under `$here`.
  - `Get-IconImage` uses `Resolve-IconTarget` or explorer.exe.
  - The missing-picture log is under `$here`.
- **First run:** `Show-SetupWindow`, then `Test-ButtonReady` and `Find-Detected`, all gated as above (except R7-I1).
- **Timers, relayout, reload:** they only rebuild through the same gated functions.
- **Hotkey and tray:** `Show-AllPanels` and Lock/Unlock (Save-Config writes to `$here`). The tray icon (one-panel) is `$here\images\app.ico`.

Click-only paths aren't gated by design: Invoke-Button, Resolve-ButtonPath, Find-Detected -AllowNetwork, Play-Click, the edit dialog, the image picker, the ScreenConnect result file, and autostart toggles.

**Not gated:** none, beyond the two plant-dependent Info items above.

## Re-check 7: one-panel ad77a2c..0b6ee94

Range ad77a2c..0b6ee9442a153d6022e863427ac91f88bdb075d5 (merge 0b6ee94 of modern-b). gitleaks found nothing.

**PASS. Critical 0 / High 0 / Medium 0 / Low 0 / Info 2** (the same R7-I1 and R7-I2).
- **Clean merge confirmed.** The added and removed lines in Launcher.ps1 and Build-Installer.ps1 for ad77a2c..0b6ee94 are identical to modern-b's 89f76f4..3250cd7.
- **Chip paths still gated.**
  - The image is checked with `Test-LocalFixedPath` before Get-PicSource (:1189).
  - The target icon only comes from `Resolve-IconTarget`, and Get-Item and ExtractAssociatedIcon then run on that checked local file (:1195+).
  - The setup dot uses `Get-SetupState` (:1232).
  - The only extra filesystem touches compared with modern-b are those chip calls and the tray's `$here\images\app.ico`.
- **No-click sweep:** same result as modern-b, plus the gated chip paths above.
- **Unchanged:** the same function-identity result as modern-b.

## Re-check 8 (Oct 29, 2026)
**modern-b 3250cd7..10d9a51: PASS, 0 C/H/M/L, 0 Info open.**
- R7-I1 closed. Find-LnkLocal (Launcher.ps1 ~:95-104) is a manual walk with -LiteralPath that skips ReparsePoint entries, matches the exact name, is capped at depth 6, and replaces the recursive Get-ChildItem in Find-Detected (~:122). The resolved target is still gated by Test-LocalFixedPath unless -AllowNetwork (click).
- R7-I2 closed. The -small sibling goes through Test-LocalFixedPath before Test-Path (~:263).
- Find-LocalMatch escapes [ ] and backticks, so only * and ? are wildcards. Correctness only.
- Tests only, with Invoke-Expression on the script's own AST in the test harness, not shipped.
**one-panel 0b6ee94..05d8d53: PASS, 0 C/H/M/L, 0 Info open.** The same Launcher.ps1 hunks as modern-b, plus the default layout set to single (Get-LayoutMode and buttons.default.json) and docs and tests. No new security surface.
gitleaks --redact on the added lines of both deltas: clean. Launch, elevation and confirm functions are untouched in both.

## Re-check 9 (Oct 29, 2026)
**one-panel 05d8d53..9229019: PASS, 0 C/H/M/L, 0 Info open.**
- The show signal now uses a ThreadPool RegisterWaitForSingleObject on the existing per-user $global:showEvent. Its creation, name and ACL are unchanged. The callback only BeginInvokes Show-AllPanels on the UI thread, so a signal has the same effect as before (bring panels forward). The fallback is a 1 s poll. The Add-Type stub is a static, constant source that builds in the user's own %TEMP%, with no outside input and no boundary crossing.
- Get-LayoutSig and Invoke-Relayout are layout-only. The config JSON is used in memory only and never logged.
- The Get-LayoutMode trim and case fix and the >2-panels fallback have no security surface. The hint copy is UI only.
- The Setup dialog default button is Close, and pickers open only on click. Safer.
- Launch, elevation and confirm functions are untouched. gitleaks --redact on the added lines: clean.

## Re-check 10 (Oct 29, 2026)
**one-panel 9229019..eba0a5c: PASS, 0 C/H/M/L, 0 Info open.**
- WatchHandle and WatchResume moved into the existing BL.Native Add-Type (~:17-21), which is constant source with no outside input. The separate ShowWaiter Add-Type is gone. Callbacks only BeginInvoke Show-AllPanels or a forced relayout on the UI thread. The show event is the same per-user event as before, and its creation and ACL are unchanged. A resume event only re-docks.
- Forced relayout on show and resume, plus the GetWindowRect signature (already declared at :9), is layout-only.
- The one-time hiddenPanelsNoticeShown flag is a boolean written through the existing Save-Config. The notice is a constant MessageBox that shows only a panel count, with no paths or config values.
- Launch, elevation and confirm functions are untouched. gitleaks --redact on the added lines: clean.

## Re-check 11 (Oct 29, 2026)
**one-panel eba0a5c..dedfc23: PASS, 0 C/H/M/L, 0 Info open.**
- BL.Native is restored to its pre-eba0a5c members and references.
- BL.Waits is a separate Add-Type built from $global:WaitsSource, a script-literal here-string assigned just before use (~:1511). It reads no config or outside input. The callbacks still only BeginInvoke on the UI thread. The PowerModeChanged handler is held in a static field and removed in Stop-TrayAndHotkey. On failure it logs only the exception message and falls back to the 1 s poll.
- hiddenPanelsNoticed is type-checked to numeric, and anything else reads as 0. It's written through the existing Save-Config after the constant MessageBox.
- Layout-Single now sizes with SetWindowPos (flags 0x0014, NOZORDER|NOACTIVATE). Geometry only.
- tools/verify-waits.sh is a dev-only compile check, not shipped. It uses a mktemp dir and cleans it up.
- Launch, elevation and confirm functions are untouched. gitleaks --redact on the added lines: clean.

## Re-check 12 (Oct 29, 2026)
**one-panel dedfc23..3029a64: PASS, 0 C/H/M/L, 0 Info open.**
- BL.Native adds POINT, MonitorFromPoint (user32) and GetDpiForMonitor (shcore, a KnownDLL loaded from System32), all with correct signatures. Get-WorkAreaDpi is wrapped in try with a fallback. Geometry only.
- Layout-Single does a move-then-size SetWindowPos (0x0015). Layout only.
- WatchResume is in its own try, and a failure logs only the exception message.
- tools/verify-waits.sh (dev-only) adds -nodeReuse:false, UseSharedCompilation=false, an offline RestoreSources from the user's own NuGet cache and a build-server shutdown on exit. This narrows the tool's footprint.
- Launch, elevation and confirm functions are untouched. gitleaks --redact on the added lines: clean.

## Re-check 13 (Oct 29, 2026): v1.2.0 NSIS installer

**Verdict: PASS. 0 Critical, 0 High, 0 Medium, 1 Low, 3 Info.** Branch nsis-installer @ e57a531 (base 3029a64). Exe sha256 4c623e58…9e29 verified; unsigned. Static only; exe was extracted with 7z and never run.

- **R13-L1 (Low)** installer/launcher.nsi:104-124 (SAFE_RMDIR), uninstall :345-376. There is a check-then-act window between the WalkLinks count pass and `RMDir /r`. A same-user process could plant a junction there, and NSIS myDelete would follow it. This needs a same-user attacker who is already running, so it crosses no boundary. Smallest fix: none required. Optionally re-run IsLink on the root just before `RMDir /r`.
- **R13-I1 (Info)** installer/stop-launcher.ps1:1. `-like` puts `$env:BL_DIR` in the pattern without escaping it. A profile path containing `[` or `]` would make the match fail, so the launcher would not be stopped. The rename would then fail safely through Fail. The pattern also matches any powershell.exe command line that has `<dir>\Launcher.ps1` as a substring, which is same-user only. Fix: `[WildcardPattern]::Escape($env:BL_DIR)`.
- **R13-I2 (Info)** installer/pictures-restore.ps1:1. `Remove-Item -Recurse` (the N5 pattern) runs on `$PLUGINSDIR\keep`. That folder is created only by the installer inside its random plugins dir, from link-free stage files, so the risk is negligible. Fix: none needed.
- **R13-I3 (Info)** The setup exe is unsigned, so SmartScreen will warn. The build is reproducible and its hash is pinned. Fix: sign it when a certificate exists.

**Verified clean**
- Launcher.ps1 is byte-identical between 3029a64 and e57a531, and the payload copy matches too.
- All 29 payload files match the repo at e57a531 (ButtonLauncher.exe.sha256 matches exe/). shipped-images.txt is generated by the build. The embedded ButtonLauncher.exe matches its committed sha256 a72fa22a….
- The payload has no Build-Installer.ps1, check-launcher.ps1, tests, tools or installer/. The build also enforces this (build-nsis.sh).
- Plugins: System.dll and nsExec.dll are byte-identical to stock Debian nsis 3.11 x86-unicode.
- 7z did not produce [NSIS].nsi, so the script was reviewed from the repo.
- Per-user only (:7 RequestExecutionLevel user). There are no HKLM writes, Program Files paths, services or UAC.
- $INSTDIR is pinned in .onInit (:133), which overrides /D=. There is no directory page (:34).
- HKCU Run (:283) and UninstallString/QuietUninstallString (:299-300) are quoted. Their paths come only from LOCALAPPDATA.
- PowerShell helpers run inline through `-Command` (:17, :167, :205, :221). No files are written to %TEMP%, so there is no planting or TOCTOU risk. Bypass applies to the process only. Data passes through env vars, never through script text. The build asserts there are no quotes, backticks or newlines (build-nsis.sh nsis()).
- Staged swap (:170-265): a link check comes before the copy. The order is copy, then payload, then core-file check, then rename old aside, then rename stage in, then roll back. If both renames fail, nothing is deleted (:254). Deletes touch only $Stage, $Old and $INSTDIR, which are fixed siblings.
- Every `RMDir /r` goes through SAFE_RMDIR (:195, :215, :232, :242, :259, :264, :376).
- The CopyFiles at :193 is preceded by a link refusal (:177-191). The one at :224 copies a single freshly unpacked file.
- There are no wildcard Deletes.
- WalkLinks never recurses into reparse points (:59-75). It unlinks with RMDir/Delete, which act on the link only. Hardlinked files only lose a name.
- The uninstaller requires exactly `$LOCALAPPDATA\Programs\Launcher` with Launcher.ps1 in it and no link root (:319-331).
- The Run value is removed only on an exact match (:369-373).
- There are no network calls in the installer or helpers (no inetc/NSISdl/IWR).
- gitleaks --redact found nothing in the added lines or in the extracted payload.

### Re-check 13 amendment (Oct 29, 2026 11:40 AM ET)
**Revised verdict: PASS with one must-fix before ship. 0 C/H, 1 M, 1 L, 3 Info.**
- **R13-M1 (Medium), installer/launcher.nsi:17 (`!define PS` with bare `powershell.exe`), used at :167, :205, :221, :341.** This confirms ClaudeCode's R14-M2. nsExec uses CreateProcess search order, which checks the Setup exe's own folder first (usually Downloads) and the uninstaller's %TEMP% copy folder. A powershell.exe planted there runs with Bypass on install or uninstall. This is the same class as the launcher's R-M3. Fix: `"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"`, quoted. I missed this in the first pass.
- ClaudeCode's R14-L3 (a merge into a foreign Programs\Launcher folder) I agree is Low or a data-integrity issue. The uninstall guard requires Launcher.ps1, so a stranger's folder without it is refused.

## v1.3.0 VNC (Oct 29, 2026): vnc-picker @da5117b

**Verdict: PASS (0 Critical, 0 High, 0 Medium, 1 Low, 3 Info).** Diff 80d6dd28f19e..da5117bb6a89 (one commit). Static review only, nothing run.

### Findings
- **V13-L1 (Low), Launcher.ps1:1754, :1776, :1840.** The temp cleanup runs `Remove-Item -Recurse` on `bl-vnc-*` folders. Only the top-level folder is checked for a reparse point (:1753), and PS 5.1 recursive delete follows inner junctions (the N5 pattern). Same-user only, because %TEMP% is per-user. **Why it matters:** a process running as the same user that plants a junction inside a `bl-vnc-*` folder can make the launcher delete files outside %TEMP%. **Smallest fix:** delete `c.vnc` by literal path, then remove the folder without -Recurse. In leftovers, skip any folder holding anything other than `c.vnc` (or reuse the bottom-up walk that unlinks links).
- **V13-I1 (Info), Launcher.ps1:1735.** Save-VncSecret keeps only the low byte of each UTF-16 character, so non-Latin-1 passwords are silently mangled. This is functional, not a security issue. Fix: reject characters above 0xFF in the dialog.
- **V13-I2 (Info), Launcher.ps1:101.** The adapter filter excludes Loopback and Tunnel types only. A VPN adapter that reports as Ethernet or Ppp with an RFC1918 address would be scanned (still capped at /22). Optional fix: also skip Ppp, or skip adapters with no gateway or DHCP on the local link.
- **V13-I3 (Info), design.md risk 6 (accepted).** A rogue LAN VNC server can collect the view-only auth. Accepted, not re-filed. As claimed, the list shows the IP, the validated PTR name and the sanitized banner. The Interact password is never stored.

### Verified clean
- **Adapter filter (:98-108).** Only adapters that are Up, not Loopback and not Tunnel. IPv4 only. 169.254 and 127 are skipped. Test-Rfc1918 (:76-80) checks 10/8, 172.16-31 (`-ge 16 -and -le 31`) and 192.168/16 on parsed int octets. Test-VncIPv4 (:51-55) rejects leading zeros and octets over 255.
- **Prefix cap (:83-97).** The prefix defaults to /24. Config is clamped to 22..30, and `Max(adapterPrefix, cfg)` means neither config nor a wide adapter prefix can go past /22. Adapters at /31 or /32 give no targets. Every target is re-checked as RFC1918 (:95).
- **Port (:63-68, :1671, :1675).** The port must be `^\d{1,5}$` and 1-65535, with a fallback to 5900.
- **Scan behavior (:1845-1864, :43-45).** Scan settings: 16 parallel, 300 ms connect and read timeout, 40 ms pacing. It reads into a 12-byte buffer and never writes to the stream. Get-RfbBanner keeps printable ASCII only (:115-121).
- **Scan trigger (:1916+, :466; Start-VncScan via :446, :445).** The scan starts only when the picker opens with a stale cache (empty, older than 1 day, or dated in the future, :1710) or on Rescan/F5. There is no startup call. Reverse DNS for hits only, 800 ms each.
- **Cache (:1692-1709).** The cache stores only the time, host, port, name and banner. On reload it re-checks IPv4, port and host-name rules and sanitizes the banner. No secret is in it.
- **Validation (:56-62, :69-75, :109-114, :1676-1677).** Host is IPv4 or `[A-Za-z0-9.-]` labels (no leading '-', so no switch injection, and no spaces or quotes). Names and banners have control characters (C0/C1) stripped and length capped. WPF shows them through DisplayMemberBinding or TextBlock.Text, with no XAML parse.
- **Viewer args (:1638-1650).** Viewer args are an array: `host::port`, `-autoscaling` and `-viewonly`, or `-config "<path>"` where the path must match `^[A-Za-z]:\\[^"]+\.vnc$` and is quoted. `-password` is never used. No element can contain a space or quote except the quoted config path.
- **Viewer exe (:1809-1825).** The exe comes from the button target, Find-Detected, or App Paths (HKCU/HKLM), or the user picks it. A .lnk is resolved first. Every path goes through Test-LocalFixedPath plus a Leaf check and is launched by absolute path, so there is no bare-name search-path lookup. The working directory is the exe's folder.
- **Stored secret (:1727-1750).** DPAPI CurrentUser with app entropy, saved atomically through a tmp file to `vnc-viewonly.dat` beside buttons.json, inside the per-user %LOCALAPPDATA% install folder. Plaintext buffers and the BSTR are zeroed.
- **Temp .vnc file (:1756-1769).** The folder is `bl-vnc-<GUID v4>` with a protected DACL (inheritance off) granting FullControl to the current user only. The DACL is applied atomically in CreateDirectory before the file is written. The file is opened CreateNew with FileShare None, and its values are re-validated (:1662-1666). Deletion: waits for input idle, then retries 5 times at 3 s. Leftovers older than 120 s are cleared when the picker opens. Interact never writes a file (:1831-1834).
- **Password UI (:1780-1807).** The entry is a PasswordBox (MaxLength 64) using SecurePassword, cleared on every button. The password never appears in a log, exception, clipboard, command line or config. The error path shows only the Start-Process exception message (:1841).
- **No new exposure.** No network calls other than the LAN scan and PTR lookups. No UNC paths and no new elevation. Invoke-Button gains only the picker branch (:242). Launch, elevation and confirm code is otherwise unchanged (the diff removes only the AppVersion line).
- **Leak checks.** gitleaks `--redact` is clean on the working tree at da5117b, on the full history (82 commits) and on /home/box/shared/button-launcher (excluding private/). Plaintext grep (locations only) over the tree, the full `git log --all -p`, the diff, reviews/, design and release/ found **no real occurrences**. The only hit was a coincidental substring inside an unrelated pre-existing test literal (tools/test-modern.ps1:32, from 8f9f6cf, before the VNC work), which is not a leak. Grep for the DES-obfuscated hex: **no occurrences**.

## Re-check 14 (Oct 29, 2026): installer e57a531..449d4cd

**Verdict: PASS.** 0 Critical, 0 High, 0 Medium, 0 Low, 4 Info. Exe sha256 c40dad10...11bf7 verified. Static review only; the exe was extracted with 7z and never run.

### Prior items
- R13-M1 **closed.** launcher.nsi:17 `PS` is `"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"`, quoted. It is the only PowerShell launch path (lines 183, 235, 267 and 403 in the uninstaller). generated.nsh only supplies the one-liner bodies. The only other Exec is :363 `"$INSTDIR\ButtonLauncher.exe"`, which is absolute. There is no cmd, reg, taskkill, icacls or ExecShell anywhere. On a 64-bit OS, $SYSDIR in 32-bit NSIS is SysWOW64, which is still a trusted system folder.
- R13-L1 **closed.** SAFE_RMDIR at :118-122 re-runs IsLink on the root after the count walk, and RMDir /r runs only if both the root check and the inner-link count are 0. Nothing that can be influenced runs in between. The residual TOCTOU between those calls is same-user only and can't be removed in NSIS.
- R13-I1 **closed.** In stop-launcher.ps1 the pattern is `[WildcardPattern]::Escape($env:BL_DIR)`. The script calls CloseMainWindow, then waits with WaitForExit(3000), then calls Stop-Process. It acts only on processes that pass the same filter (`powershell.exe` with a command line like `*<dir>\Launcher.ps1*`), so it can't close or kill a different process.
- R13-I2 and R13-I3: no code change in this delta, so their status is the same as in Re-check 13 (open, Info, accepted).

### New (Info)
- **R14-I1:** launcher.nsi:190 and pictures-save.ps1. `$Keep` is `Launcher.pictures-backup-<GetTickCount>`, and the script creates it with `md -Force`. It is never link-checked before the write. A same-user process that pre-plants a junction there would redirect the copies. This crosses no boundary because that process already has the same rights. It is removed through SAFE_RMDIR (:320, :236), so the delete is safe. Smallest fix if wanted: in the script, fail if `$k` already exists.
- **R14-I2:** :233 and :265. The success files sit in `$PLUGINSDIR` (a random nsXXXX.tmp folder under the user's %TEMP%). Only same-user code could fake one, and both gates also need exit code 0. Acceptable.
- **R14-I3:** :143-145 and :376-377. The ownership check accepts `Launcher.ps1` OR `.buttonlauncher`. This means a pre-marker IExpress v1.1 install upgrades normally, and a folder with neither file is refused. A foreign folder that happens to contain a Launcher.ps1 would be adopted. The name collision is unlikely, so this is acceptable.
- **R14-I4:** :193-204. The stale-folder cleanup matches `Launcher.new-*` and `Launcher.old-*` and deletes each match through SAFE_RMDIR under `$LOCALAPPDATA\Programs`. Any folder with that prefix would be removed, not only ones with numeric suffixes. The removal itself is link-safe. Smallest fix: require that the suffix is all digits. Separately, NSIS takes $LOCALAPPDATA from the shell folder API, not the environment variable, so the empty check at :136 is belt-and-braces. A UNC LOCALAPPDATA only happens under admin-set folder redirection and is not attacker-controlled.

### Verified clean
- The payload in the exe matches 449d4cd byte for byte: Launcher.ps1, both Start Launcher files, buttons.default.json, README, all images and svgs, and ButtonLauncher.exe (sha a72fa22a… matches the committed exe/ButtonLauncher.exe.sha256). Build-Installer.ps1, check-launcher.ps1, tools/, exe sources and tests are not included.
- Picture save and restore: Copy-Item instead of Move, try/catch around everything, and exit 1 on error. Setup fails before the swap when the exit code is not 0 or the success file is missing (:237-244, :269-274). When the restore fails, the backup is kept and its path is shown.
- Launcher.ps1:957 is the only change in Launcher.ps1. The Test-Path is on `$global:here` (the install folder, local) and the menu action is byte-identical. The launch, elevation and confirm functions are unchanged.
- The uninstaller guard at :375-386 requires an exact path, a non-empty LOCALAPPDATA, and the marker or Launcher.ps1. The Run value is removed only on an exact match.
- No network calls in the installer or helpers. build-nsis.sh adds a makensis v3.11 pin. gitleaks --redact found no leaks in either the added lines or the extracted payload.

### v1.3.0 VNC amendment (Oct 29, 2026 11:48 AM ET)
- **V13-I2 raised to V13-L2 (Low), Launcher.ps1:101 / Get-VncLocalSubnets (~:1614-1623).** With a VPN (Ppp, or a VPN that reports as Ethernet) or a Hyper-V/WSL switch up, the sweep covers up to 1022 VPN-side or virtual addresses. There's no privilege crossing, but it can trip a corporate VPN's IDS or policy. Fix before ship: allowlist Ethernet and Wireless80211 adapters that have a default gateway, and exclude vEthernet and known VPN descriptions. ClaudeCode rated this H1; my rating is Low.
- ClaudeCode's L4 (hosts listed without checking the RFB greeting) stays Info. VNC auth is DES challenge-response, so a non-VNC service never gets the password. Gating the list on the greeting is still recommended.
- Revised counts: 0 C/H/M, 2 Low (V13-L1, V13-L2), 2 Info.

## Re-check 15 (Oct 29, 2026): installer 449d4cd..01e6eb0

R14-I4 was underrated; ClaudeCode R15-H1 correctly rated the unbounded stale-folder delete as data destruction outside the install folder. Removed in this delta.

**Verdict: PASS.** 0 Critical, 0 High, 0 Medium, 0 Low, 0 new Info.
Exe sha256 7dcd057d…407d verified. 7z payload: 28 files byte-identical to 01e6eb0; 3 build-generated lists (known-pictures.txt, shipped-images.txt, ButtonLauncher.exe.sha256) plus the NSIS plugins. ButtonLauncher.exe = a72fa22a…2715e, matching its .sha256. No builder, tests or tools in the payload. gitleaks --redact found nothing in the added lines or the payload. No network calls. All 3 PowerShell runs use `${PS}` = quoted `$SYSDIR\WindowsPowerShell\v1.0\powershell.exe` (:17, :222, :288, :326, :466). No new bare exe names.

Checks:
- R15-H1 (fixed): the FindFirst/SAFE_RMDIR loops over Launcher.new-*/old-* are gone. The new :237-247 path only *refuses*, through Fail (which Quits), when Launcher is missing and a Launcher.old-*/new-* exists. It deletes nothing.
- Backup name (:226-236): local time (GetTime) + `%04x` of (GetTickCount XOR PID) & 0xFFFF. This is a uniqueness value, not a secret, which is fine because of the next check. Refuse-if-any-of-Stage/Old/Keep-exists (:237-242) runs before CreateDirectory "$Stage" (:258) and before PICS_SAVE creates $Keep. The IsLink on $Keep (:297-303) runs after save and before anything else writes to or deletes $Keep. SAFE_RMDIR also refuses a link root.
- Backup kept on failure: the restore failure (:328-333) keeps $Keep and tells the user where it is. The rollback-failed path (:368-371) keeps everything (KeepNote). DropKeep (:187-196) deletes $Keep only when $5=1 (created this run) and $INSTDIR\images exists. Every caller is a path where the install was never swapped or was rolled back. After success, :382-384 deletes it only once the swap and restored.ok have passed.
- nsExec: `$0 S!= "0"` (:291, :328) treats "error", "timeout" and non-zero as failures, plus the required *.ok file, and stops before the swap.
- Empty Launcher (:142-162): only when the folder has no Launcher.ps1 or marker, IsLink is 0, and the entry count is 0. It uses a plain `RMDir` (non-recursive; it fails harmlessly if the folder is not empty). Otherwise the R14-L3 refuse (:164-170) applies.
- Launcher.ps1 :954: a ternary subtitle string only (Test-Path on a local Join-Path). Launch, elevation and confirm are untouched.

Prior items: R13-I2 and R13-I3 stay Info (unchanged). R14-I1 closed (unique name + refuse + link check). R14-I2 and R14-I3 stay Info (unchanged). R14-I4 closed (superseded by R15-H1, code removed).

Every delete in launcher.nsi at 01e6eb0:
- :65/:67 WalkLinks: removes the link entry only (RemoveDirectory / DeleteFile on the link) inside a SAFE_RMDIR target.
- :108 SAFE_RMDIR link root: plain RMDir of the link itself, never the target.
- :122 SAFE_RMDIR RMDir /r: only after an unlink pass, a 0-link recount, and a root re-check.
- :160 RMDir $INSTDIR: non-recursive, empty, non-link, no marker.
- :192, :294, :383 $Keep: this run's unique name (refused if it already existed), created by this run's PICS_SAVE.
- :270 RMDir $Stage (plain) and :277/:293/:302/:314/:330/:344/:355/:374 SAFE_RMDIR $Stage: this run's unique stage.
- :307 Delete $Stage\Uninstall.ps1: inside this run's stage.
- :380 $Old: this run's renamed install, after a successful swap ($2=1).
- :393/:395/:483-486: the app's own shortcut .lnk names. :404/:497 Run value (exact match). :411/:487/:491 own Uninstall keys.
- :501 uninstaller SAFE_RMDIR $INSTDIR: the exact Programs\Launcher, after the marker/Launcher.ps1 check (re-check 13/14).

## v1.3.0 VNC round 2 (Oct 29, 2026): da5117b..bef8da9

**Verdict: PASS.** 0 Critical, 0 High, 0 Medium, 0 Low, 1 new Info. Nothing blocks v1.3.0 on security. The review was static only, of one commit (bef8da9: Launcher.ps1 and tools/test-vnc.ps1).

**Prior items**
- **V13-L1: closed.** See Launcher.ps1:1801-1813, Remove-VncTempDir.
  - The leaf name must match the anchored `^bl-vnc-[0-9a-f]{32}$`.
  - It refuses if the folder is a reparse point. It refuses on any entry other than a plain, non-link file named c.vnc.
  - It deletes c.vnc with `Remove-Item -LiteralPath` (no -Recurse) and then calls `[IO.Directory]::Delete($dir,$false)`.
  - Leftovers (:1814-1818) are enumerated only under `$env:TEMP` with the `bl-vnc-*` filter, skip links and anything under 120 s old, and go through the same gate. They run when the picker opens (:2190).
- **V13-I1: closed.** Save-VncSecret (:1782) checks every UTF-16 unit and returns $false if any is above 0xFF, before anything is truncated or protected. The UI clears the box and asks again (:1878-1879). The only `-band 0xFF` is at :1784, after the guard, so nothing truncates silently.
- **V13-L2 (ClaudeCode H1): closed.**
  - Test-VncAdapter (:1616-1624) allows only the `Ethernet` and `Wireless80211` types, so Ppp, Tunnel and Loopback are out.
  - Up is checked at :1631.
  - The deny regex (:1615) covers VPN, TAP, TUN, WireGuard, Wintun, AnyConnect, GlobalProtect/PANGP, Forti, OpenVPN, Zscaler, Tailscale, ZeroTier, Juniper, Pulse, Hyper-V, vEthernet, WSL, VirtualBox, VMware, Npcap, WAN Miniport, Teredo, isatap and Virtual. It is matched against both the description and the name.
  - The adapter needs an RFC1918 address and a non-zero IPv4 gateway inside its own subnet.
  - RFC1918 and the /22 cap are still enforced: Get-VncPrefix (:1599) clamps to 22-30, and Get-VncScanTargets (:1605) checks Test-Rfc1918 for each address.
  - The confirm prompt defaults to No (:1973), and confirmedRanges is saved through Save-Config (:1976).
  - **Tamper check:** confirmedRanges is used only as a `-notcontains` lookup (Get-VncNewRanges, :1641). Targets are always computed from the live adapter (:1978). A pre-seeded value can only skip the prompt and cannot widen the range.
- **ClaudeCode L4: closed, with one Info (V2-I1).**
  - The scanner enqueues a host only on exactly 12 bytes matching `^RFB \d{3}\.\d{3}\n$` (:1947).
  - Read-VncCache re-validates the host, port and banner (`^RFB \d{3}\.\d{3}$`) and drops anything that fails (:1725-1735).
  - Test-VncUsePassword (:1773) needs a saved secret and a valid banner.
  - A favourite that the scan or cache hasn't seen gets banner '' (Merge-VncRows), so it opens the viewer's own prompt with no file.
- **V13-I3: accepted, unchanged.** The design.md risk still applies: a rogue LAN RFB server could collect the view-only auth.

**New**
- **V2-I1 (Info), Launcher.ps1:1773 with :1725-1735.**
  - Why: the password-eligible flag is the cached banner string, and the host isn't probed again before the .vnc file is written. Anyone who can write vnc-cache.json is already the same user, and that user can read the DPAPI secret anyway, so no boundary is crossed.
  - Optional fix: before you hand over the file, require `seen` from the current session's scan, or probe the host for RFB again.

**Verified clean**
- **Temp file**
  - No WaitForInputIdle remains.
  - Remove-VncTempSoon (:1825-1838) is a 1 s DispatcherTimer on the UI thread. It deletes 3 s after the viewer window appears, at 8 s at the latest, or when the viewer exits, and retries up to 6 times.
  - The viewer reads -config at startup, before its window appears, so the 3 s-after-window rule has no security race.
  - New-VncTempConfig (:1840-1857) uses a protected user-only ACL and CreateNew/FileShare None, and its try/finally deletes the file on failure. The catch block in Start-VncViewer also deletes it (:1923-1924).
- **Sockets:** they are closed in a finally block for each batch (:1948).
- **Network:** no new network calls. The only ones are the TcpClient scan and the existing reverse-DNS lookup (also present at da5117b), and there are no UNC paths.
- **Viewer launch**
  - The viewer is found by absolute path through Test-LocalFixedPath (Find-VncViewer).
  - Arguments are passed as a list (:1664-1676): host::port, or -config with a path matching `^[A-Za-z]:\\[^"]+\.vnc$`, plus -autoscaling and -viewonly.
  - -password is never used.
  - Interact never uses the saved password (:1915).
- **Unchanged:** the diff touches no launch, elevation (RunAs/Restart-Service) or confirm function.
- **Leak check**
  - gitleaks --redact found nothing, on both the added lines and the full tree.
  - The plaintext password matches no file except the known coincidental tools/test-modern.ps1 hit, and it has 0 hits in bef8da9.
  - Its DES-obfuscated hex has 0 hits across the tree and all history.

## v1.3.0 release (Oct 29, 2026): v1.3.0 @e8dc049 + Setup-v1.3.0.exe

**Verdict: PASS.** 0 Critical, 0 High, 0 Medium, 0 Low, 0 new Info. Branch head e8dc049e5b01629751c2fbaee911b56d31bc8036. Exe sha256 451e5591724a8eb3580602f39fd37b227d05fc4062840273b63d46e01c5154ec matches the claim (451e5591…54ec).

**Open items:** V2-I1 is CLOSED. Test-VncUsePassword (Launcher.ps1:1860) now requires `row.session`. That flag is set only in Step-VncScan (:2119) from a live RFB greeting dequeued this session. It is never read from vnc-cache.json, so the cache can't feed it. Any other row gets the viewer's own prompt, plus a status hint (:2315). There is no automatic re-probe, which is the stricter choice. Earlier optional Info items from Re-check 15 and VNC round 2 are unchanged.

**New findings:** none.

**Verified clean:**
- **Merge ba86f01.** The only conflict hunk is in Launcher.ps1 Panel-Menu. It is an exact union of the nsis-installer conditional 'Build installer...' line and the vnc-picker 'View-only register password...' item. The test-onepanel.ps1 conflict is test-only. installer/, tools/build-nsis.sh and exe/ are byte-identical to 01e6eb0, so these are intact: the quoted $SYSDIR\WindowsPowerShell powershell (launcher.nsi:17), SAFE_RMDIR with the link re-check, no stale .new/.old delete, the .buttonlauncher marker, and the backup refuse-if-exists. The VNC safety code is also intact: the V13-L1 cleanup, Latin-1 only, the allowlist, and RFB-only rows.
- **6f1e361.**
  - Get-VncRangeKey (:1717) lowercases the DNS suffix and replaces it with '?' unless it matches ^[a-z0-9.-]{0,253}$. The key is used only in config. The prompt text shows the range and label, not the suffix.
  - Declines (Get-VncRangeState, Get-VncScanPlan) only append a key and only skip a range. Rescan asks again, default No. Nothing widens.
  - The deny-list (:1675) is a strict superset (Tunnel, NordLynx, WARP, Cloudflare, Surfshark, Mullvad, Proton, Windscribe, Sophos, Check Point, SonicWall, NetExtender, Citrix, Ivanti). The only type added is GigabitEthernet. RFC1918, the /22 cap and the in-subnet gateway checks are unchanged (:1684-1688).
  - Async stop uses BeginStop plus a cancel flag, and the parked workers are disposed on the next Stop-VncScan once they have ended. Sockets still close in the workers' finally blocks. UI updates happen only on the DispatcherTimer (UI thread). The XAML is an embedded constant parsed in try/catch.
- **961cd4b.** This commit is more than icons. It also has the D2 tile and panel rendering in Launcher.ps1 (static gradients and animations, with no launch or exec changes), AppVersion 1.3.0, and one default-image path. All 14 PNGs have the PNG magic bytes. The SVGs are unchanged since the passed heads, and their only href is reddog.svg's embedded data:image/png (no script or external ref). Nothing loads XAML from a file. tools/sync-icons.sh makes no network fetch: it copies local files from /home/box/shared/button-launcher/art/fluent-3d, unpinned, and it is dev-only.
- **Launch, elevation and confirm.** Every launch, elevation, confirm, process or shutdown function is byte-identical to a passed head. The only changed match is Start-VncScan, reviewed above. Network code is still only the VNC TcpClient scan (:2023) and reverse-DNS (:2043). No HTTP and no UNC.
- **Installer payload.**
  - Every file equals e8dc049 byte for byte, apart from the build-generated shipped-images.txt and ButtonLauncher.exe.sha256.
  - ButtonLauncher.exe a72fa22a…715e matches exe/ButtonLauncher.exe.sha256.
  - The builder, tests and tools are excluded.
  - known-pictures.txt has 66 entries, all images/* relative paths with no '..'. pictures-save.ps1 uses it only to decide which pictures under <install>\images get copied to the keep folder (user-changed) and which are skipped (shipped). Nothing is deleted based on it, so a wrong hash can at worst skip preserving a picture inside the install's own images folder.
- **Leak check.**
  - gitleaks --redact found no leaks in the new-commit patches (01e6eb0..e8dc049 and bef8da9..e8dc049), the e8dc049 tree, or the extracted payload.
  - The password and DES-hex grep over the same set hit only the known coincidental tools/test-modern.ps1:32, and nothing in the payload.

## v1.3.0 delta (Oct 29, 2026): e8dc049..f02af81 + Setup-v1.3.0.exe c90a0d73

**Verdict: PASS.** 0 Critical, 0 High, 0 Medium, 0 Low, 1 Info.
- Head: f02af8130c3e73e722e2340b66335e9c63ec2796 (commits 49f8859, 27c5e18, f02af81).
- Exe sha256: c90a0d7331c246c210173e46d40e84d0e94ce609d7e3a934b279ff182149f7d8. It matches the claim.

### Findings
- **V4-I1 (Info).** Launcher.ps1:1747, 1751-1765, 2155.
  - Why: an attacker on the LAN can spoof the router's ARP reply, which gives a known MAC in Get-NetNeighbor, or reuse a remembered profile name. That makes the network key match a confirmed key, so the confirm prompt is skipped.
  - Boundary: the range still comes only from the PC's own allowlisted RFC1918 adapter (/22 cap) and the gateway must be inside the subnet. The key never widens the scan or changes its target, and the password still only goes to hosts seen with RFB this session.
  - Fix: none needed. Optionally, document it in design.md as an accepted residual.

### Verified clean
1. **Network key.**
   - Get-NetNeighbor -IPAddress <gw> reads only the local neighbor (ARP) cache, with no probe (:1763). Get-NetConnectionProfile is a local read (:1764).
   - The MAC must match `^[0-9a-f]{2}(-[0-9a-f]{2}){5}$`, and all-zero and broadcast values are rejected (:1753). The profile name is reduced to `[a-z0-9 ._-]` and capped at 64 characters (:1754).
   - Get-VncRangeKey re-validates the id and falls back to '?' (:1747). The key is never logged, and the confirm dialog shows only the range, label and port (:2158).
   - The migration filter (:1831) applies only to the in-memory confirmed and declined lists. They are written back only through the existing confirmedRanges and declinedRanges Set-Prop calls. No other config field is touched.
   - The Rescan-initiated confirm now defaults to Yes. It is user-initiated, so this is acceptable. Automatic opens still default to No.
2. **Add dialog.**
   - Show-VncAddDialog (:2025) returns $null on Cancel, close or Esc. The caller returns before ConvertTo-VncEndpoint or Set-VncFavorite (:2481-2482).
   - The address is still strictly validated by ConvertTo-VncEndpoint. Nothing is saved until both fields are taken, so there's no half-saved state. The VisualBasic InputBox is gone.
3. **Worker cleanup.**
   - Closed runs Stop-VncScan: cancel flag, then BeginStop, then the dead-workers list. A 3 s DispatcherTimer then runs Clear-VncDeadWorkers -All only if no new picker is open (:2487-2490). App Exit also runs Clear-VncDeadWorkers -All (:2561).
   - Timers run on the UI thread, and workers don't touch the UI. Sockets still close in the workers' finally blocks, and dispose disposes the runspace.
   - Workers only probe. The password and launch paths ($ui.go) are UI-thread only and unreachable after close, because $ui.scan is $null. The temp .vnc cleanup is unchanged.
4. **SVGs.**
   - Eight Set A SVGs were removed, and Launcher.ps1 has 0 'svg' references.
   - Build-Installer.ps1 and the payload's known-pictures.txt list them only as hashes for upgrade swaps, which is not a loader.
   - The payload ships only images/svg/reddog.svg. There's no outside-path image fallback, and Get-PicSource is unchanged.
5. **Styling.**
   - The other hunks are fonts, glow, hairline, D2 dialogs, menu template, status copy and the 'notscanned' state.
   - No hunk touches the launch, elevation, confirm, Start-Process, Test-LocalFixedPath or BL.Native code. The diff adds no Start-Process, UNC, web or socket code.
   - The only new Win32 call is the existing SetWindowPos.
6. **Installer.**
   - The hash matches. The 7z extraction has 27 files, and 25 are byte-identical to f02af81. The other 2 are build-generated: ButtonLauncher.exe.sha256 and shipped-images.txt.
   - ButtonLauncher.exe is a72fa22a...e2715e, which matches exe/ButtonLauncher.exe.sha256.
   - Build-Installer, check-launcher, tests, tools, reviews and exe/ are all excluded.
   - installer/ and Build-Installer.ps1 are unchanged since e8dc049.
7. **Leak check.**
   - gitleaks 8.30.1 --redact found no leaks in the e8dc049..f02af81 patches or the extracted payload.
   - The grep for the plaintext password plus its DES-hex, upper and lower case, both bit orders, covered the new-commit patches, the tree and the payload. It hit only the known tools/test-modern.ps1:32 and found 0 hits in the new commits or the payload.

## v1.3.0 follow-on (Oct 29, 2026): f02af81..a843719 + Setup-v1.3.0.exe 61d8a962

**Verdict: PASS.** 0 Critical, 0 High, 0 Medium, 0 Low, 0 Info. No V5 findings.
- Head: a84371957f68c088d44b11a27ec1bafd63068969. f02af81..a843719 is exactly 444a72a, 1b5bbe3 and a843719.
- Exe sha256: 61d8a9623285447917c33c2b7303ee7d2f5a62e5a36eaf6143bdd68cf05c976b. It matches the claim.

### Verified clean
- **New icon.**
  - images/power.png is a PNG, not an SVG. Its only chunks are IHDR, IDAT and IEND, with no text or metadata chunks, so there's no place for a script or an external reference.
  - images/LICENSES/LICENSES.txt:26 records Fluent Emoji 3D "Counterclockwise arrows button", MIT, unmodified. The MIT licence file ships in the payload.
- **Plate removal.**
  - Launcher.ps1 New-Content (~:556) only lost the plate block. There's no new image path or fallback, and Get-PicSource is unchanged.
  - The default still resolves to the relative images/power.png (:277, buttons.default.json:218).
- **MAC lookup.**
  - Get-VncGatewayId (:1754-1763) and Select-VncGatewayMac (:1765-1772) still read only the local neighbor cache, now scoped with -InterfaceIndex. There is still no probe.
  - $ifIndex comes from GetIPv4Properties().Index of the adapter that already passed Test-VncAdapter in Get-VncLocalSubnets.
  - The validation runs ConvertTo-VncGatewayId, which accepts only the hex format and rejects all-zero and broadcast values. Unreachable and Incomplete entries and entries on other adapters are skipped.
- **Empty-ID no-cache.**
  - An empty ID just yields `id=`. A key only matches an exact confirmed string, so skipping the cache only causes a retry on the next open.
  - It can't skip the prompt for a network that wasn't already confirmed under the same key. The range still comes from the adapter, so the scan is never wider.
  - V4-I1 is recorded as accepted risk 7 in /home/box/shared/button-launcher/reviews/vnc-picker/design.md:41. That file lives in the shared folder, not the repo.
- **Dialog styles.**
  - Get-D2DialogResources (:2000-2005) now parses only the constant in-file `<Window.Resources>` block as a ResourceDictionary.
  - The source is a constant here-string with no external input, so the change is UI-only.
- **Tests and tooling.**
  - The test-modern Kern M2 check was inverted to assert the plate is gone.
  - test-vnc parses the real here-string body and adds R4-L1 and N2 checks. No security assertion was removed or weakened.
  - check-launcher.ps1 only adds Get-NetNeighbor and Get-NetConnectionProfile to the Windows-only cmdlet list.
- **Untouched code.** No hunk touches launch, elevation, confirm, Start-Process, Test-LocalFixedPath, BL.Native, sockets or UNC handling.
- **Installer.**
  - The 7z payload has 27 files. 25 are byte-identical to a843719. The other 2 are build-generated: ButtonLauncher.exe.sha256 and shipped-images.txt.
  - ButtonLauncher.exe is a72fa22a...e2715e, which matches exe/ButtonLauncher.exe.sha256.
  - The builder, tests and tools are excluded. installer/ and Build-Installer.ps1 are unchanged.
- **Leak check.**
  - gitleaks --redact found no leaks in the delta patches or the payload.
  - The grep for the plaintext password and its DES hex covered the tree, the delta and the payload. It hit only the known tools/test-modern.ps1:32.

## v1.3.0 delta 4 (Oct 29, 2026): a843719..6795095 + Setup-v1.3.0.exe f3011e8a

**Verdict: PASS.** 0 Critical, 0 High, 0 Medium, 0 Low, 0 Info. No V6 findings.
- Head: 679509583650c8f4cbb7a993c7faf1cd5e05cb45.
  - f5e23a4 is the code commit.
  - 6795095 is a preview re-render that touches only reviews/v1.3.0/panel-preview.html and panel-preview.png.
- Exe sha256: f3011e8ac2fea1e9913061e15c334088238ca54f2b6fa70fee33a408143f5164. It matches the claim.

### Verified clean
- **Key icon.**
  - images/jartrek-security.png is a valid PNG. Its only chunks are IHDR, IDAT and IEND.
  - The MIT credit for Fluent Emoji 3D "Key" is at images/LICENSES/LICENSES.txt:30, and the file ships in the payload.
- **Jartrek match.**
  - Get-ChipFallbackPic (Launcher.ps1:1330-1333) does a constant regex `(?i)jartrek` against the label plus target. The label and target are only the input being tested, never the pattern, so there is no injection.
  - It returns the constant relative 'images/jartrek-security.png' through the existing Get-PicSource. No config value becomes a path.
  - This only runs after the local-fixed-path icon branch has fallen through, and website chips are excluded.
- **DPI fix.**
  - Get-WpfDpi (:893) reads PresentationSource.CompositionTarget.TransformToDevice, which is managed WPF.
  - The other changes are Add_DpiChanged leading to Request-Relayout (:1549), the pure-math Get-SingleSize (:1556), the extra field in the layout signature, and the dock width going from -6 to -8.
  - There is no new P/Invoke or Add-Type. Only existing BL.Native calls are used.
  - Line 1 gained a UTF-8 BOM. That is benign, because PS 5.1 needs the BOM to read non-ASCII correctly.
- **Untouched code.** Nothing in the delta touches launch, elevation, confirm, Start-Process, Test-LocalFixedPath, the BL.Native definition, sockets, UNC handling or VNC.
- **Installer.**
  - installer/ and Build-Installer.ps1 are unchanged.
  - known-pictures.txt went from 66 to 67 entries. The only new line is images/jartrek-security.png, whose hash a5709643...49ba2 equals the committed file's.
  - The swap and delete logic is unchanged, so nothing new is in scope. tools/sync-icons.sh only adds the icon to its copy list.
- **Payload.**
  - The 7z payload has 28 files. 26 are byte-identical to 6795095. The other 2 are build-generated: ButtonLauncher.exe.sha256 and shipped-images.txt.
  - ButtonLauncher.exe is a72fa22a...e2715e, which matches the committed hash.
- **Leak check.**
  - gitleaks --redact found no leaks in the delta patches or the payload.
  - The grep for the plaintext password and its DES hex hit only the known tools/test-modern.ps1:32.

## v1.3.0 delta 5 (Oct 29, 2026): 6795095..ca190b6 + Setup-v1.3.0.exe 387e67b7

**Verdict: PASS on the code.** 0 Critical, 0 High, 0 Medium, 1 Low (data, not code), 1 Info.
- Head: ca190b62574f0dc205496aaac032ec23ab56d360. The delta is exactly 24a29ee (test colour) and ca190b6 (Kern and Squint recheck fixes).
- Exe sha256: 387e67b70ca35df010267cf68df9b3fb85356e59f568aa2ddc98aa99edf51ec2. It matches the claim.

### Findings
- **V7-L1 (Low, data).** The view-only password value (private/vnc-viewonly.txt, and the deployed UltraVNC servers).
  - Why: the value is 4 characters, all digits, which is only 10^4 possibilities.
  - A LAN observer can capture the VNC DES challenge-response, which is unencrypted RFB, and brute-force it offline instantly. Even online guessing is trivial.
  - The impact is limited to view-only access to the register screens on the shop LAN.
  - Fix: set a random 8-character password (the VNC DES maximum) on each register, then re-enter it in Setup > View-only register password. This is a data-only change with no code change.
- **V7-I1 (Info).** Git history of tools/test-modern.ps1, line 32 in older revisions.
  - The old sample hex colour coincidentally contains the value as a substring, in 61 commits from 8f9f6cf through 6795095. The count at head is 0.
  - The line has no VNC, password or secret label. The repo is private, with 0 forks and no fork list.
  - Fix: none. Rewriting history isn't worth it, and rotating the value per V7-L1 makes the fragment meaningless anyway.

### Verified clean
- **Name display.**
  - Get-VncShortName (Launcher.ps1:1908) and nameText and nameFull (:1921-1922) only affect display.
  - The full name goes into the tooltip through Get-SafeText and a plain {Binding} (:2378). Untrusted strings are never parsed as XAML.
  - The connect argument is still built from the validated $h::$p at :1815, never from the reverse-DNS name.
  - Get-VncFoundText and the status tooltip are plain property sets.
- **Styling.** The rest is the glow values (:593), the 12 px floor on the Editing bar (:402), menu grey and wording changes.
- **Untouched code.** Nothing touches launch, elevation, confirm, Start-Process, Test-LocalFixedPath, BL.Native, sockets, UNC handling or VNC auth.
- **Installer.**
  - installer/ and Build-Installer.ps1 are unchanged.
  - The 7z payload has 28 files. 26 are byte-identical to ca190b6, and the other 2 are build-generated: ButtonLauncher.exe.sha256 and shipped-images.txt.
  - ButtonLauncher.exe is a72fa22a...e2715e, which matches the committed hash.
- **Leak check.**
  - gitleaks --redact found no leaks in the delta or the payload.
  - The grep for the plaintext password and its DES hex found 0 hits at head and 0 in the payload. The only 2 hits are in the 24a29ee patch, on the removed lines.
- **Storage facts.**
  - The password is stored with DPAPI CurrentUser plus app entropy in vnc-viewonly.dat beside buttons.json (:1934-1956).
  - It is passed to the viewer only as the DES-obfuscated value in a temp c.vnc file, in a per-user-ACL folder that is deleted after launch (:1999).
