# Squint UX review: Button Launcher v1.3.0 (branch v1.3.0 @ e8dc049, D2 look + View Register finder)
Source: panel-preview.png / .html (HTML render, not WPF), Launcher.ps1 from ButtonLauncher-Setup-v1.3.0.exe (SHA-256 451e5591...), RELEASE-v1.3.0.txt. 2026-10-29, ET.

**Verdict: SHIP WITH FIXES.** No Blockers. Every item from the picker review landed: one button row, F2/Space/Del/Ctrl+Enter, `Unnamed (F2 to name)`, star toggles pin, Seen column, empty and no-network copy, Remove only for saved rows, Interact tooltip, View-only password moved to Setup with the "change it in Setup" line, title shown once, live status line and "More actions" name. The new changes (remembered declines, Rename clears with a confirm, cache age, stale rows dimmed) read well. One Major left.

## Findings (ranked by user impact)
1. **Major: "No registers found" shows when nothing was scanned.** When this network was declined and there are no saved registers, opening the picker skips the scan, and `refresh` shows the 'none' empty state: **No registers found. Check the register is turned on...** That sends staff to check hardware that's fine. The same text also flashes behind the first-time "Scan ...?" prompt, because `refresh` runs before the scan starts. (Launcher.ps1 `$ui.refresh` -> `showEmpty('none')`; the open path never sets the "Not scanned" status when declined.)
   Fix: add a third empty kind, 'notscanned': **Not scanned yet.** `Press Rescan (F5) to look for registers on this network, or use Add... to type an address.` Use it whenever no scan has run in this session and the cache has no hosts, including while the first-time prompt is up. Also set the status line on open when declined (reuse `Not scanned. Press Rescan (F5) to scan anyway...`).
2. **Minor: the scan prompt is in network jargon.** "Scan 192.168.1.0/24 (Ethernet) for registers? ... checks port 5900 on each address" means nothing to staff, and it defaults to No even after they pressed Rescan on purpose.
   Fix copy: `Look for registers on this network (Ethernet)?` / `This quickly checks the shop network for registers you can view. You'll only be asked again if the network changes.` Keep the range and port in a second, smaller line or the log. Default Yes when it came from Rescan (an explicit ask); keep No on automatic opens.
3. **Minor: Jartrek chip and View Register use the same receipt icon.** Staff find things by picture, and these are two different jobs side by side (preview: middle row, first chip vs the green tile).
   Fix: give the Jartrek chip its own picture (the Jartrek app icon, or a cash-register glyph). This is an icon swap, so it goes to Charles as a proposal with the D2 look.
4. **Minor: Add is two old-style input boxes.** Add asks for the address, then a second box for the name. Cancelling the name box still adds the register, which looks like Cancel didn't work. Both boxes are the grey Win95 VisualBasic style inside the D2 window.
   Fix: label the second box `Name (optional, e.g. Register 1). Leave empty to name it later with F2.` Later, one small dialog with Address and Name fields (Kern to style).
5. **Minor: Seen repeats the age on every row.** Every cached row says `Last scan, 3 h ago`, while the status line already says it. That's noise in a narrow column.
   Fix: rows say `Earlier` (or `Now` after a fresh scan) and `Not found last scan`. The age lives only in the status line, which also gets "(out of date)".

## Panel (D2 look), UX notes
- Order, grouping and the Restarts danger zone with its caption read clearly. Labels are short and the guides show "Version 11" as a subtitle, which is good.
- Hover can't be judged from the preview: the "hovered" column looks the same as at rest. On the real Windows captures, check that hover and press are visible on every tile colour (Kern to measure), since staff on touch screens get no hover at all.

## Recheck on Windows
The not-scanned empty state, the scan prompt, keyboard flow (Enter/Ctrl+Enter/F2/Space/Del/F5/Esc), the Narrator reading the status line, and the wrong-saved-password message (OnEarlyExit).
