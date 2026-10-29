# View Register picker (v1.3.0, branch vnc-picker; first cut da5117b, review fixes on top)

Mock: picker.png (from picker.html, HTML at the real 620x480 window size; not a WPF render). Code: `Show-VncPicker` in Launcher.ps1.

## Look (Option B)
- Window #141414, list #1E1E1E with #2A2A2A border, Segoe UI Variable (the launcher's `$global:UiFont`), 14 px body, 20 px SemiBold title, 12 px #A0A0A0 status line.
- Primary actions use the existing palette: View only #0E7A4B (the View Register green), Interact #0B6E99. Others are #2A2A2A. All labels white, AA contrast.
- Columns: pin star, Name (200), Address (170; `:port` only when not 5900), Greeting (120, the RFB banner as plain text).
- Buttons sit in a WrapPanel, so at 620 px "View-only password..." wraps to a second row (visible in the mock). Kern/Squint: is that acceptable, or should it go into a small "..." menu?
- Keyboard: list has focus on open, first row selected. Enter or double-click = View only. F5 = Rescan. Esc closes. Tab reaches every button.
- Status line: "Looking for registers on this network (n of N)...", "Found n. Looking up names...", "Found n register(s). Scanned N addresses at 11:40 AM.", or "Last scan ...". If there's no private network it says so and suggests Add.

## Behaviour
- Scan only when the picker opens and the cache (vnc-cache.json, next to buttons.json) is empty or over 1 day old, or on Rescan. Never at launcher start.
- Targets: adapters that are up, not loopback/tunnel, IPv4, not APIPA, RFC1918 only. Range = this PC's subnet narrowed to /24 by default (`vnc.prefix`, clamped to /22../30). No network/broadcast/self.
- One background runspace: 16 TCP connects at a time to `vnc.port` (5900), 300 ms timeout, 40 ms pause between batches (a /24 takes about 6 s). Reads at most 12 bytes, then closes. Nothing is ever sent. Reverse DNS for hits only, 800 ms each, in a second runspace. A 200 ms DispatcherTimer drains results on the UI thread. Closing the window cancels and disposes both.
- Favourites (`vnc.favorites` in buttons.json: host, port, name, pinned). Naming pins a row; an empty name unpins it. Add by hand takes host or host:port.
- Viewer: the button's saved target if local, else its detect paths, else App Paths\vncviewer.exe (HKCU, HKLM), else ask once (OpenFileDialog). It must pass Test-LocalFixedPath. It's saved on the button.
- Launch: `Start-Process -FilePath vncviewer.exe -ArgumentList` with no shell. Interact: `host::port -autoscaling`. View only: `host::port -autoscaling -viewonly`. With a saved view-only password: `-config "<temp .vnc>" -autoscaling -viewonly`.
- Back compat: `"vncPicker": true` in the new default. Old configs without the flag get the picker only on the stock View Register (program, no args, UltraVNC detect). A button with an address in args keeps launching the old way. `"vncPicker": false` turns it off.

## Switches (verified)
- https://uvnc.com/docs/ultravnc-viewer/52-ultravnc-viewer-commandline-parameters.html lists `-viewonly` and `-autoscaling`.
- UltraVNC source (github.com/ultravnc/UltraVNC @ 7bd294a): `vncviewer/VNCOptions.cpp` parses `viewonly`, `autoscaling` and `config`. `ClientConnectionFile.cpp` LoadConnection reads `[connection] host=`, `port=` and `password=` (8 bytes as 16 hex digits). `rfb/vncauth.c` encrypts with DES and the fixed key {23,82,107,6,35,78,88,7}.
- Port syntax: `host::port` is a literal port. `host:N` is display N (port 5900+N; see the server doc https://uvnc.com/docs/ultravnc-server/51-ultravnc-server-commandline-parameters.html). We always use `::`. Positional host, not `-connect` (see GitHub issue ultravnc/UltraVNC#84).

## View-only password: threat model (for Lockjaw)
**What it protects:** the shared view-only VNC password. It only allows watching a register, not control. Interact (full) passwords are never saved or filled in; the viewer always prompts for them.

**Storage:** `vnc-viewonly.dat` next to buttons.json, never inside it. It holds the first 8 bytes (UltraVNC only uses 8) wrapped with DPAPI `ProtectedData.Protect`, CurrentUser scope, entropy `ButtonLauncher.VNC.ViewOnly.v1`. It's written via a .tmp file and then a Replace. It's entered in a WPF PasswordBox and read only as SecurePassword. It goes BSTR, then a byte[], then Protect, and then ZeroFreeBSTR plus Array.Clear. It's never shown, logged, put in buttons.json, or put on a command line (no `-password`; a test checks this). Clear it with "No password", or replace it with Save. Uninstall removes the folder.

**Use:** Unprotect, then DES-obfuscate with the fixed VNC key into 16 hex digits, then zero the plaintext bytes. The hex goes into `%TEMP%\bl-vnc-<guid>\c.vnc`. That folder is created with a protected DACL (inheritance off, current user FullControl only, owner set) and the file is opened with CreateNew/FileShare.None. The viewer gets `-config <path>`. Deletion: a timer waits 3 s, then WaitForInputIdle (up to 5 s), then 3 s, then up to 5 deletes 3 s apart. Folders left behind (older than 2 min) are removed the next time the picker opens.

**Accepted residual risks:**
1. The .vnc value is obfuscation, not encryption. Anyone who can read it can recover the password. That's mitigated by the user-only ACL and the seconds-long lifetime.
2. Any process running as the same Windows user can call DPAPI Unprotect, or read the temp file. DPAPI CurrentUser doesn't defend against same-user malware. An admin can read it too.
3. The 16-hex string is a managed .NET string, so it can't be zeroed. The SecureString-to-bytes path is zeroed, but the PasswordBox internals and GC copies are outside our control.
4. The viewer could read the file later than our delay on a very slow PC. Then the connect falls back to a prompt, or fails. Needs a Windows test.
5. A crash before deletion leaves the file until the next picker open (still ACL'd).
6. Rogue host on the LAN: a fake VNC server on the subnet could collect the view-only password if Charles picks it. The list shows IP, name and banner, but there's no server authentication in classic VNC auth.
7. Spoofed network identity (Lockjaw V4-I1, Info, accepted 2026-10-29 @f02af81): a LAN host that spoofs the router's MAC, or a network that reuses a Windows profile name, makes the range key match an already-confirmed range, so the "Look for registers on this network?" prompt is skipped. It can't widen or retarget the scan: the range always comes from the local RFC1918 adapter allow-list (Ethernet/Wi-Fi, gateway inside the subnet, /22 cap), never from the network. The saved view-only password still only goes to hosts that gave an exact RFB greeting in this session (Test-VncUsePassword). Impact: one unprompted light scan of the PC's own subnet.

**Scan risks:** a light connect scan of the own /24 can still trip an IDS or endpoint firewall alert. It never runs at startup, and it's limited to RFC1918 and the PC's own subnets.

## Not verified (needs real Windows)
WPF rendering and keyboard flow; real UltraVNC reading `-config` with host, port and password and honouring `[options] viewonly=1`; whether the cmd-line `-viewonly` and `-autoscaling` still apply after `-config` LoadOptions (we put both in the file too); delete timing vs. viewer read; DPAPI and ACL calls (pwsh on Linux can't run them); NetworkInterface prefix lengths on real adapters; WaitForInputIdle on the viewer; the PS 5.1 runspace and ConcurrentQueue behaviour.

## Round 2 changes (Kern, Squint, Lockjaw, ClaudeCode)
- **Look (D2):** The standard chrome stays, so the title shows once. The client area is a gradient (#26262C to #16161A) with 20 px padding and a one-line hint instead of the H1. The list is radius 10 with a 10% white stroke, a 28 px SemiBold header, 32 px rows, Win11 selection (white 9%, a 3x16 #22C55E pill, radius 6; hover 5%), and a keyboard ring.
- **Buttons:** one 32 px row with 8 px gaps: View only, Interact | Rescan, Add..., ⋯. They're D2 chips: radius 10, gradient fill, 28% to 6% stroke, sheen, 1 px lift on hover with glow, 0.97 press, focus ring, disabled #2A2A2A/#8A8A8A. A 2 px #0E7A4B busy bar shows while scanning. The window stays 620x480. The mocks are picker.png and picker-menu.png.
- **⋯ menu and row menu:** Rename... (F2), Pin/Unpin (Space), separator, Remove from favourites (Del, saved rows only, with a confirm). The row right-click menu adds View only and Interact. View-only password is no longer in the picker.
- **Rows:** unnamed rows read 'Unnamed (F2 to name)' in grey. The star column toggles the pin (E735 filled #F59E0B; an outline E734 appears on hover or selection). Naming no longer pins. The Greeting column is replaced by Seen (Now / Last scan / Not found last scan / Looking...), with the banner in the tooltip. Rows not found are greyed.
- **Keys:** Enter = View only (IsDefault), Ctrl+Enter = Interact, double-click = View only, F2, Space, Del, F5, and Esc (cancels a scan and closes). The status line is announced politely (LiveSetting).
- **Empty states:** Squint's copy, centred in the list, with Add... focused.
- **Scan scope (H1):** only Ethernet and Wi-Fi adapters, never PPP, VPN or virtual (by name or description), and only with an IPv4 gateway inside the adapter's subnet. Each new range is confirmed once ("Scan 192.168.1.0/24 (Wi-Fi) for registers?", default No) and remembered in `vnc.confirmedRanges`; a changed range asks again. Favourites-first: when favourites exist, opening the picker only scans for a new confirmed range, otherwise only on Rescan. The status line always names the range.
- **Workers:** a failed or early-ended worker shows "Scan failed: ..." in the status line, is logged and stops the timer (M1). Rescan stops and disposes the old scan and name workers first (L1). No timer runs while idle. Sockets are closed in finally, also on cancel.
- **Only exact RFB greetings** (`RFB ddd.ddd\n`, 12 bytes) are listed or cached (L4). The saved password file is only used for a row whose last greeting was RFB. Hand-added favourites never seen in a scan get View only without the file, so the viewer prompts.
- **Staleness (L3):** an empty result isn't stale; the age limit is 1 day.
- **Config (L5):** invalid favourites stay in buttons.json untouched and are listed in a status-line warning. Names are kept whole and shown with an ellipsis past 40 characters.
- **Temp file:**
  - **Polling (M2):** no WaitForInputIdle. A 1 s timer deletes the file 3 s after the viewer shows a window, or at 8 s. A viewer that quits within 6 s triggers the "saved view-only password" hint.
  - **Deletion (V13-L1):** only `bl-vnc-<32 hex>` folders are touched. `c.vnc` is deleted by literal path, then the folder is removed without -Recurse, and a folder holding anything else is skipped.
  - **Creation:** done in try/finally, so a failure leaves nothing behind.
- **Picker button (L2):** the picker only takes over the explicit `vncPicker` flag, or the stock View Register (label VIEW REGISTER, stock askTitle or UltraVNC shortcut, no args).
- **Password characters (V13-I1):** characters above 0xFF are refused before anything is saved, with a clear message.
- **Bug fixed while testing:** `[IO.File]::Replace(..., $null)` passed an empty string in PowerShell (it now uses `[NullString]::Value`). `Set-VncFavorite`'s `[string]$name` turned $null into '' (it's now untyped).

### Threat-model updates
- **Auto-reconnect trade-off (M2):** UltraVNC calls GetConnectDetails again on reconnect, which re-reads the `-config` file. The file is gone by then, so a reconnect after a dropped View only session falls back to the viewer's host or password prompt. We keep the delete, because a seconds-long lifetime matters more than silent reconnect. Needs a Windows test.
- **Rogue-host risk (risk 6) is narrowed:** the password file only goes to an address whose latest scan greeting was an exact RFB banner.
- **Scan posture:** confirmed per range, never at startup, favourites-first. Tell store or office IT before rollout; the IDS note from ClaudeCode stands.
