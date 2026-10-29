# Squint UX review: View Register picker v1.3.0 (vnc-picker @ da5117b)
Source: picker.png / picker.html (HTML mock at 620x480, not a WPF render), design.md, ultravnc-viewonly-note.md, kern.md. 2026-10-29, ET.

**Verdict: SHIP WITH FIXES.** No Blockers. The flow is short (open, pick, Enter) and the safe action is the default. The fixes are about telling registers apart and making the empty/failed states say what to do.

## Findings (ranked by user impact)
1. **Major: unnamed rows are just IPs, and naming is hidden.** First run, most rows look like `192.168.1.77` with a blank Name, so staff guess which register is which. Naming is behind "Rename / pin...", which also pins (hidden coupling).
   Fix: blank names show `Unnamed (F2 to name)` in #A0A0A0. F2 = Rename. Split pinning from naming: clicking the star column toggles pin; naming no longer pins. Rename dialog prefills the reverse-DNS name if there is one.
2. **Major: empty and no-network states need real copy** (Kern's empty-state line, my words):
   - Scanning, 0 found so far: `Looking for registers on this network (176 of 253)...` (keep).
   - Scan done, 0 found (centred in the list): **No registers found.** `Check the register is turned on and on the shop network, then press Rescan (F5). Or use Add... to type its address.`
   - No private network (centred in the list): **This PC isn't on the shop network.** `Connect to the shop Wi-Fi or cable, then press Rescan (F5). Or use Add... to type a register's address.`
   - From cache: `Last scan 9:12 AM. Press F5 to rescan.`
   Put Add... focus-ready in both empty states (Tab lands on it first).
3. **Minor: Greeting column means nothing to staff.** "RFB 003.889" is the VNC protocol version. It takes a column and invites "what is this?".
   Fix: drop it from the grid and put the banner in the row tooltip. Use the space for a **Seen** column (`Now` / `Not found last scan`) so a stale cached row doesn't look live. Rows not found in the latest scan go #A0A0A0.
4. **Minor: Remove on a scanned row does nothing lasting.** A scanned (unsaved) row comes back on the next Rescan, so Remove looks broken.
   Fix: only saved rows (pinned, named or added) get **Remove from favourites**. Disable it for scanned-only rows, with tooltip `Only saved registers can be removed`.
5. **Minor: Interact gives no hint it takes over a live till.** A cashier can be mid-sale.
   Fix: tooltip on Interact: `Take control of this register's mouse and keyboard. Asks for the full password.` Ctrl+Enter = Interact as the keyboard path. No extra confirm (the viewer's password prompt is already the guard).
6. **Minor: a wrong saved view-only password dead-ends.** If the saved password is wrong, the viewer just prompts or fails, and staff won't know why.
   Fix: if the viewer exits within a few seconds of a View only launch with a saved password, status line: `Couldn't connect with the saved view-only password. Change it in Setup > View-only register password...`. Also add that sentence to the first-time ask-once prompt.
7. **Minor: duplicate title.** "View Register" is in the title bar and again as the heading, which spends about 40 px saying it twice.
   Fix: keep one. If the standard chrome stays, drop the H1 and put a one-line hint in its place: `Pick a register. View only to watch, Interact to take control.` (12-13 px #A0A0A0). If Kern's custom chrome (WindowStyle None) ships, the in-window heading is the title and the hint goes under it.

## Answers to Kern's questions
1. **Remove and Rename:** agree with the ⋯ menu. Rows also get a right-click menu with the same items, so it matches the launcher's right-click edit model: View only, Interact, separator, Rename... (F2), Pin / Unpin, Remove from favourites (Del, with a confirm or an Undo toast, same as the one-panel review). The ⋯ menu acts on the selected row.
2. **Enter = View only:** yes. Watching can't disturb a sale; taking control can. Make View only `IsDefault` so it looks like the default, and add Ctrl+Enter for Interact. Double-click = View only too.
3. **Empty / no-network copy:** see finding 2.
4. **View-only password in the picker:** no. It's a one-time setup item and it already lives at Setup > View-only register password... (per ultravnc-viewonly-note.md). Take it out of the picker's ⋯ menu entirely; the first-use ask-once prompt plus the Setup item cover it, and finding 6 covers the wrong-password case. Update the note's "picker's View-only password... button" line to match.
5. **Title twice:** keep one (finding 7).

## Accessibility (non-contrast)
- Keyboard: list focused on open, Enter, F5, Esc, Tab all good. Add F2, Del, Ctrl+Enter, and Space toggles pin. Esc while scanning should cancel and close in one press.
- Screen reader: give the ⋯ button `AutomationProperties.Name="More actions"`, the star column `Pinned` / `Not pinned`, and announce the status line (LiveSetting Polite) so "Found 5 registers" is read out.
- Targets: 32 px rows and buttons are fine for mouse; the 36x32 ⋯ is the smallest target and is OK.

## Not verified
WPF render, real keyboard flow, viewer behaviour on a wrong saved password. Recheck on a Windows build.
