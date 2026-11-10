# View only password diagnosis

Diagnosed at `0c0968dbe56537f96d9a0e515bf11f4f0e177e6b` (same behavior as reviewed v1.4.11 `37ea47df364fdfad29b07703fdd76fcbb925fdf4` for this path, plus the later freshness gate). The line numbers below are from that commit, before the fix. No password file on this machine was opened.

Charles (Nov 9, 6:56 PM ET): View only should use the built-in default unless he overrides it from the panel. When he tried it, the viewer asked for a password the same way Interact does.

## What the viewer is

The launcher starts UltraVNC `vncviewer.exe` (`Find-VncViewer`, `Launcher.ps1` around the viewer search). The argument string is built by `Get-VncViewerArgs` (`Launcher.ps1:2187-2197`):

- Interact: `host:port -autoscaling`
- View only, no password file: `host:port -viewonly -autoscaling`
- View only, password file: `host:port -config "<temp .vnc>" -viewonly -autoscaling`

`-viewonly` is only the input lock. It does not supply a password, and UltraVNC does not ignore `-config` when that file is actually passed. The `-password` switch is never used (`Launcher.ps1:2029`).

## Where the password comes from

There is no built-in default.

- Legacy file `vnc-viewonly.dat` beside `buttons.json` is deleted unread at startup (`Clear-VncSecret`, `Launcher.ps1:2350-2352` and the startup call at `Launcher.ps1:4651`). It is not the store.
- The only store is DPAPI CurrentUser in `%LOCALAPPDATA%\ButtonLauncher\vnc-viewonly-v2.dat` (`Get-VncViewOnlyPath`, `Launcher.ps1:2318`; `Save-VncSecret`, `Launcher.ps1:2330-2348`).
- Setup > View-only password (`Launcher.ps1:1346`, dialog `Launcher.ps1:2425-2463`) writes that file. If the file is absent, the dialog says View only will ask (`Launcher.ps1:2439`).
- Nothing in `buttons.json` holds the password.

`Get-VncSecretHex` (`Launcher.ps1:2353-2359`) returns null when the file is missing or DPAPI fails. The plaintext bytes are not logged.

## The gate that skips the file

`Start-VncViewer` (`Launcher.ps1:3072-3103`) creates the `.vnc` only here:

```
if ($viewOnly -and (Test-VncUsePassword $row (Test-VncSecret))) { $hex = Get-VncSecretHex; if ($hex) { $file = New-VncTempConfig ... } }
```

`Test-VncUsePassword` (`Launcher.ps1:2310`) is true only when all of these are true:

1. A secret file exists (`Test-VncSecret`).
2. `$row.session` is true.
3. `$row.banner` matches `RFB ddd.ddd` (`Test-VncBannerText`, `Launcher.ps1:2183`).
4. `$row.host` is a literal IPv4 (`Test-VncIPv4`).

`session` is set only when the shown reachability is Online (`Get-VncReachView`, `Launcher.ps1:2888`). Online means a finished RFB greeting that is not older than 60 seconds (`VncReachFresh`, `Launcher.ps1:2032`; stale handling at `Launcher.ps1:2880`). The banner kept for the row is cleared unless the row is currently Online (`Launcher.ps1:2886-2888`). A CR-terminated greeting is not a banner (`ConvertTo-VncReachBanner`), so it is Offline and `session` is false.

Interact never enters this `if`. It always launches with no password file.

## How a password is passed, when the gate opens

`New-VncConfigText` (`Launcher.ps1:2210-2213`) writes a short `.vnc`:

```
[connection]
host=...
port=...
password=<16 hex digits>
[options]
viewonly=1
AutoScaling=1
```

The hex is the first 8 password bytes, DES-ECB with the well-known VNC fixed key (`ConvertTo-VncObfuscated`, `Launcher.ps1:2199-2208`). That is obfuscation, not encryption. The file is created under `%TEMP%\bl-vnc-<guid>\c.vnc` with an owner-only ACL (`New-VncTempConfig`, `Launcher.ps1:2407-2423`) and deleted on a timer (`Remove-VncTempSoon`, `Launcher.ps1:2392-2405`).

## ShellExecute

`New-VncStartInfo` (`Launcher.ps1:3171-3175`) sets `UseShellExecute = $true` and the one argument string. `Start-VncProcess` (`Launcher.ps1:3177-3182`) calls `Shell.Application.ShellExecute(exe, arguments, workingDirectory, 'open', 1)` and, on failure, `Process.Start` with the same start info. Neither path adds or removes `-viewonly` or `-config`. The password is not in the argument string. The log redacts the temp path and records only `saved` or `none` (`Get-VncLaunchLogText`, `Launcher.ps1:3189-3192`).

ShellExecute returns no process object, so the old "wrong password" early-exit hint does not run (`Launcher.ps1:2385-2386`). That is a separate gap. It is not why the viewer asks before connecting.

## Every condition that leads to the viewer prompt

The viewer shows its own password box, the same box Interact uses, whenever no `.vnc` is passed:

| Condition | Why no file is written |
|---|---|
| No override saved | `Test-VncSecret` is false. There is no default. This is the usual case. |
| Saved, but the row is Not checked (missing, in progress, timeout, cancelled, invalid) | `session` is false |
| Saved, but the last Online/Offline result is older than 60 seconds | stale; `session` is false and the banner is dropped |
| Saved, but the check finished Offline (refused, closed, or a non-RFB greeting, including a CR ending) | `session` is false |
| Saved, but the allowed computer is a name, not an IPv4 | `Test-VncIPv4` is false |
| Saved file exists but DPAPI unprotect fails | `Get-VncSecretHex` returns null, so the `if ($hex)` does not create the file |
| Interact | `$viewOnly` is false, so the branch is skipped on purpose |

The allowlist already limits which rows the picker can launch. It is not what decides the password. A listed computer that is not a fresh Online IPv4, or that has no saved override, is started as `host:port -viewonly -autoscaling`. UltraVNC then asks. That is the same prompt Interact gets from `host:port -autoscaling`.

## Why the password box does not take the keyboard

At `93482a47890442a275bd14af0df01e1853334849`, before the focus handoff:

Charles (Nov 9, 6:57 PM ET): after View Register closes he has to click the viewer, then click the password field, before he can type.

Three things stack up.

1. `Start-VncProcess` (`Launcher.ps1:3202` at that commit) calls `ShellExecute` and returns no process (`Launcher.ps1:3204`). There is no PID to hand the foreground right to.
2. `Close-VncPickerAfterStart` (`Launcher.ps1:3563`) closes View Register as soon as the start did not throw, on a dispatcher callback (`Launcher.ps1:3566`), before UltraVNC has created its password dialog. Closing the picker gives the foreground back to the launcher panel.
3. Windows will not let a process that was not the foreground, and was not granted `AllowSetForegroundWindow` by the foreground process, call `SetForegroundWindow` for itself. The dialog can appear behind the launcher, or in front without keyboard focus in the password edit. `-viewonly` and the `.vnc` file do not change that. Nothing in this path called `AllowSetForegroundWindow` or `SetForegroundWindow`.

The admin ScreenConnect restart prompt and the force-restart prompt are separate message boxes. They are not this dialog.

## Focus handoff

The fix, still least privilege and still not typing into the field:

- When Interact starts, or when View only had to fall back to a prompt (no password file), snapshot `vncviewer.exe`, start the viewer the same way, then take the new PID (`Process.Id` when ProcessStartInfo was used, otherwise a new process with that exe path that was not in the snapshot).
- Call `AllowSetForegroundWindow` for that PID while the launcher is still allowed to grant it, before waiting for the dialog.
- A dispatcher timer polls for up to 2 seconds, so the UI thread is not asleep. Each tick retries the process list. A candidate must be a new `vncviewer.exe` with that exact path and must not be a PID from before the start. Two new processes with the same start time are refused. A window counts only when its process id is that PID, its class is `#32770`, and its title says Authentication or Password. Any other window of that process is ignored. No window to attach the timer to: one pass, no wait.
- Interact closes View Register first, in the same dispatcher turn, and then activates that dialog. View only that is still showing the picker activates it without closing. Activation is `SetForegroundWindow` on the dialog, then `WM_NEXTDLGCTL` so the dialog itself focuses its password edit (`ES_PASSWORD` if one is present, otherwise the last visible Edit). The edit's text is never read. Nothing is typed, pasted, or sent with SendKeys.
- If the dialog is not there when the 2 seconds end, log `not found` and close (Interact) or stay (View only) exactly as before.

`BL.Waits` gained `AllowForeground`, `ListVisibleWindows`, and `ActivatePrompt`. The match and the timeout are PowerShell functions so they can be tested here. Whether the real UltraVNC dialog comes forward has to be checked on Windows. This host cannot do that.

## Decision for the fix

- View only on an allowed computer always gets a password file: the DPAPI override if one is saved, otherwise the built-in default. Stale and Not checked do not block it. A name on the allowlist does not block it either, so those rows do not prompt. A computer that is not on the allowlist still gets no password file.
- Interact is unchanged and still prompts.
- The password stays in the short-lived obfuscated `.vnc` passed as `-config`. It is not placed on the command line. The tradeoff: the VNC DES form is reversible by anyone who can read that file during the few seconds before it is deleted. A plaintext `-password` argument would also be visible in the process list and in the launcher log, so the file is the safer of the two mechanisms UltraVNC actually supports.
