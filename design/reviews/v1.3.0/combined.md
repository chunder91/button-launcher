# Launcher v1.3.0 (e8dc049) - combined design review - 2026-10-29

**Verdict: SHIP WITH FIXES** (UX: ship with fixes, UI: ship with fixes). Merged by Kern. Real Windows captures at 100/125/150% still needed.

## UX (Squint)

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

## UI (Kern)

# Kern UI review: Launcher v1.3.0, Direction 2 "Fluent 3D" (branch v1.3.0 @ e8dc049)
Source: panel-preview.png and panel-preview.html, which I rendered at 1.0, 1.25 and 1.5 (Chrome) over the preview wallpaper #3A4A5C and over a light wallpaper #F3F3F3. I also read Launcher.ps1 @ e8dc049 (Set-D2Surface, Set-D2Panel, the tile builder at about lines 562-640, the panel edge at 1115-1128 and 1559). Spec: reviews/polished/spec.md, D2. Checked 2026-10-29 ET. The box can't run WPF, so this is HTML plus a code read.

**Verdict: SHIP WITH FIXES.** Colours, gradients, labels, the icon list, the order and the Red Dog logo all match the spec. Every label passes AA at both gradient ends and on hover. The lowest is Internet hover at 4.95:1. Four visual fixes are below, plus one item for the real-Windows check.

## Measured label contrast (white text unless marked #111)
| Tile | Rest top / bottom | Hover top / bottom |
|---|---|---|
| Red Dog #0B6E99→#085171 | 5.67 / 8.66 | 5.23 / 7.58 |
| View Register #0E7A4B→#0A5A38 | 5.38 / 8.29 | 5.00 / 7.22 |
| Internet #7B4FD6→#5B3A9E | 5.34 / 8.26 | **4.95** / 7.17 |
| Email (#111) #FAD028→#D7AF12 | 12.69 / 9.02 | 13.01 / 10.86 |
| Guides #5F6368→#46494D | 6.05 / 9.05 | 5.53 / — |
| PLCE #C40000→#910000 | 6.27 / 9.53 | 6.09 / — |
| Revenue (#111) #F1E895→#CEC678 | 15.03 / 10.77 | 15.31 / 12.94 |
| Start Jartrek Security #8A6100→#664800 | 5.54 / 8.43 | 5.11 / — |
| Restarts #2E2E2E | 13.58 | ≥12.6 |
| Chips over light wallpaper (65% #141414 → #626262) | 6.10 | — |

## What matches the spec
- **Code matches the spec:** tile radius 12 and hero 14. The rim gradient runs from #47FFFFFF (28%) to #0FFFFFFF (6%). The sheen is 10 px, uses a #4DFFFFFF brush at 0.73 opacity (22% at rest, 30% on hover, 12% pressed) and stays inside the top padding. The bottom shade is #40000000.
- **States match the spec:** hover lifts 2 px over 120 ms, the icon scales to 1.06 and the glow goes to 0.70 (0.35 on the danger tiles). Pressed scales to 0.97 over 60 ms, with the glow at 0.43 of max. Focus is a 2 px white ring. Chips are #A6141414 with an 8 px sheen at 14%.
- **Option B colours and order:** all hover and pressed stop tables match spec rows. The order is the one-panel order, with Start Jartrek Security directly above Restarts. The Red Dog full-colour logo sits on a white plate (radius 8, padding 4). The danger group is the red tint with 2 px #E5484D outlines.
- **Icons:** all follow the D2 list: Receipt, Globe with meridians, E-mail, Open book, Books, Police car light, Classical building, Locked with key, Laptop, Electric plug, plus chip icons Page facing up and Card file box. The exception is the plug (finding 2).
- **Scaling:** the 125% and 150% renders keep the layout. No label wraps beyond the 2 lines already there at 100%.

## Findings (ranked by visual impact)
1. **Major: the hover glow is invisible.** The glow Border is Margin -3 behind an opaque tile, so only a 3 px ring can show. At 0.70 its outer pixels measure (32,35,41) against (31,33,40) at rest, which is no visible change. In the preview, hover reads only as the 2 px lift. The preview also doesn't apply the hover stops, although the code does (overlay `$hov` with f[2]→f[3]). Crop: `kern/assets/button-launcher/v130-hover-glow.png`.
   Fix: glow `Margin='-6'` (it stays inside the panel's 3+3 px padding and the 6 px gaps) and `CornerRadius = rad+6`. Glow brush: RadialGradientBrush with RadiusX 0.62 and RadiusY 0.75, stops at glow colour 85% (offset 0.70) → glow colour 0% (offset 1.0). Opacity 0.70 (danger 0.35). Keep ClipToBounds False on the tile wrap. Nothing changes under the label, so contrast is unaffected. Re-render the preview with the hover stops so it shows the real hover.
2. **Major: the Restart Computer "Electric plug" emoji disappears on the dark tile.** Its body is about #453E5E on #2B2B2B, 1.42:1, below the 3:1 non-text minimum. Crop: `v130-restart-plug.png`.
   Fix: use the spec alt `Counterclockwise arrows button` (3D) for Restart Computer, at the same 24 px with the pre-baked shadow. Restart ScreenConnect keeps `Laptop`, which passes. If the plug must stay, put it on a 28 px #FFFFFF 85% circle plate, which gives ≥3:1.
3. **Minor: the panel corner radius drifts.** Set-D2Panel builds the panel at 16, but the docking code at line 1559 resets the inner corners to 14 ('0,0,14,0' / '14,0,0,0'). The spec and the preview say 16. Fix: use 16 in line 1559 for both panels, and keep 0 on the docked edge.
4. **Minor: "Version 11" is 11 px at 85% opacity** (white 85% on #5F6368, about 4.9:1). It passes AA but sits under the 12 DIP floor in the spec type rules, and it reads fuzzy at 100%. Crop: `v130-guides-type.png`. Fix: 12 px Regular (not SemiBold), Opacity 0.85, line height 14. Contrast stays ≥4.9:1.
5. **Minor: font check for real Windows.** The family string 'Segoe UI Variable Text Semibold, Segoe UI Semibold, Segoe UI' depends on WPF on .NET Framework resolving the named instance of a variable font. If it doesn't, the text falls back silently, and the preview can't show that because it uses a Noto substitute. Fix: no code change now. On the real captures, confirm that the glyphs are Segoe UI Variable, for example by the shape of the "y" in "Security". If they fall back, use `FontFamily='Segoe UI'` with `FontWeight=SemiBold`, which is identical in metrics.

## Shadow answer
**Accept dropping the panel DropShadowEffect. Don't grow the window.** Against light wallpaper, the rim (#4B4B4F) is 7.83:1 and the panel body is >11:1, so the edge is clear without a shadow. Against mid-dark wallpaper (#3A4A5C), the rim is 1.21:1 and the body is 1.75:1, and a 32 px shadow there would add little. That matches how Windows 11 flyouts look. The window already uses AllowsTransparency for the rounded corners (line 1123), so the real cost of growing it is per-pixel-alpha area, plus a blur that re-renders on every hover animation. Cheap substitute, optional: a 1 px outer hairline #66000000 (40%) just outside the existing 18%→12% white rim, on the three non-docked sides only. It costs nothing, sharpens the edge on light and mid wallpapers, and stays off with "squarePanels". Crops: `v130-panel-edge-light.png`, `v130-panel-edge-dark.png`.

**Still needed:** real Windows captures at 100%, 125% and 150%, over a light and a dark wallpaper, with one tile in rest, hover and pressed states. That checks the glow, the font, the emoji downscale crispness and the corner radius. Full renders: `v130-full-100.png`, `v130-full-125.png`, `v130-full-150.png`.

**For Squint (UX):** none from the visuals. The plug-to-arrows icon swap changes meaning slightly ("restart" rather than "power"), so Squint may want to confirm it.

6. **Minor - Add and View-only password dialogs are unstyled** (Squint's note, not yet measured by Kern). Fix: same D2 tokens as the picker. Window background is the panel gradient #26262C to #16161A. Text boxes are 32px high, radius 6, fill #FFFFFF at 6%, 1px #FFFFFF at 12% stroke, and a 2px #22C55E bottom line when focused. Buttons use the picker's primary and secondary styles (32px, radius 10). Labels are 14px, with 8px between a label and its box and 16px dialog padding. Re-measure on real captures.

## Recheck - real Windows captures (2026-10-29)
Kern (UI), 1:05 PM ET. Sources: windows/ (100% screen captures from KBS-LT-Charlie at 96 DPI; 125/150 are in-app renders, weighted less), code on origin/v1.3.0 @ 6795095 (includes f5e23a4). real-launcher-rest.png clipping ignored as instructed.

**UI verdict: SHIP WITH FIXES** - every label passes AA on real Windows (lowest 5.57:1), the old menu blocker is fixed, but the hover glow is still too faint and the harness captures miss the chip row and dialogs.

### Findings
1. **Major - hover glow still reads as nothing.** Code now has glow Margin -6 / CornerRadius rad+6 / radial brush, but on the 100% hover render the halo outside View Register changes the backdrop by only 1.13-1.15:1 (rest #0B5F3B vs hover #0D6941). Fix: glow brush alpha 0.85 -> 1.0 with inner stop 0.70 -> 0.45 so the colour reaches the tile edge, and glowMax 0.70 -> 0.90 (danger 0.35 -> 0.55); target at least 1.5:1 halo-vs-rest 3px outside the rim. Crops: v130-win-glow-vr.png, v130-win-glow-restart.png.
2. **Major - middle chip row not captured.** Both 100% renders show a ~370px black void between Email and the guides (y 280-645) and the real screen capture has another window (JARTREK APPS) on top of that area, so the Jartrek/Manual/Tools/Web chips have never been seen on Windows. Fix (harness): bring the panel Topmost before CopyFromScreen and render the chip host (or the whole edge Border) with RenderTargetBitmap after UpdateLayout. Crops: v130-win-render-void.png, v130-win-overlap-editmode.png.
3. **Minor - real capture was taken in Edit mode.** Dashed outlines, the amber Editing bar and a stray "New icon" tile show, so rest-state edges and radii can't be judged on real pixels. Fix: harness locks edit mode and removes test tiles before capture. Crop: v130-win-real-rest.png.
4. **Minor - dialogs not verifiable.** add-dialog-screen.png and more-menu-screen.png captured the wallpaper/another app, and add-dialog-render.png has a transparent background (body text white on nothing). On a #202024 composite the D2 Add/Cancel buttons look right. Fix: render dialogs onto their window Background (or set Background before RenderTargetBitmap) and capture after Activate(). Crop: v130-win-add-dialog.png.
5. **Minor - ⋯ menu disabled item 4.36:1** (#8A8A8A on #26262C). Disabled text is exempt from AA, but use #9A9A9A (5.2:1) to keep it legible. The black-text blocker is fixed: Rename 11.84:1. Crop: v130-win-menu-disabled.png.
6. **Minor - dialog button glow still Margin -3 / CornerRadius 13** (Launcher.ps1 dialog template ~line 2270). Fix: Margin -6, CornerRadius 16, same radial brush as tiles.
7. **Minor - panel scaled to 0.928 on the real screen** (269x1032 of 290 DIP). 12px text becomes about 11.1 px on screen. The code claims a 12 DIP floor after scale; please confirm "Version 11" and the "Restarts" caption are FontSize >= 12.94 before scale, or clamp after.

### Measured label contrast (real 100% capture, panel-rest-screen-current-scale.png)
Red Dog Back Office 7.14 | View Register 6.06 | Internet 6.82 | Email (#111) 11.26 | Back Office User Guide 7.06 | Version 11 8.36 | PLCE 7.95 | Department of Revenue (#111) 12.93 | Start Jartrek Security 6.21 | Restarts caption 6.77 | Restart ScreenConnect / Computer 15.13 | View Register hover 5.57. All pass 4.5:1.
Type: harness logs "UI font: Segoe UI". Segoe UI Variable is not installed on KBS-LT-Charlie, so the Segoe UI Semibold fallback is in use. Its greyscale-AA edges look clean, with no ClearType colour fringes in the crops, and the glyphs aren't substituted.

### Status of open UI items
| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Hover glow invisible at 3px | Open (partly) | Code fixed (-6, rad+6, radial), but measured halo 1.13-1.15:1 - still too faint (Finding 1) |
| 2 | Restart Computer plug icon 1.42:1 | Fixed | 444a72a Counterclockwise arrows button; icon vs #262626 tile max 14.8:1 |
| 3 | Docked inner corners 14 -> 16 | Fixed (code) | CornerRadius '16' / '0,0,16,0' etc; can't confirm on pixels while Edit mode is on |
| 4 | Version 11 at 12px | Fixed (code) / Can't verify on screen | f02af81 12 px subtitle; 0.928 panel scale may take it to ~11.1 px (Finding 7) |
| 5 | Segoe UI Variable on Windows | Fixed (fallback works) | Not installed on the test PC; Segoe UI Semibold used, detected via SystemFontFamilies |
| 6 | Add and password dialogs in D2 | Can't verify | Add buttons look D2 in the render. Screen captures missed both dialogs, and the password dialog wasn't captured |

### Jartrek chip (Fluent 3D key) verdict
**OK - ship.** From Smudge's preview at 100% and the 3x view (crops v130-win-jartrek-chip-100.png and v130-win-jartrek-chip-3x.png), the gold-to-orange key is clear at chip size and reads as a key, not a document. Estimated from colour picks, the gold body is about 5:1 and the orange tail about 3.5:1 against the ~#444 chip fill, both above 3:1. It's clearly different from the receipt: warm and diagonal against cool, upright and lined. It's also different from Start Jartrek Security's padlock-with-key, which is a padlock body on gold. It sits on the same grid as Manual, Tools and Web, with the same icon box, a centred baseline and the soft shadow. Caveat: I measured the mockup only. 125% and 150% are unchecked because the chip row is missing from every Windows capture (Finding 2).

**Still needed:** real 125% and 150% captures (not in-app renders), a real-launcher-rest re-capture on f5e23a4+, and captures of the chip row, the Add dialog and the password dialog with the panel locked and on top.

## Recheck - real Windows captures, UX (Squint, 2026-10-29 1:07 PM ET)
Sources: windows/ (picker-render.png, harness-log.txt, results.json; the other picker, prompt, menu and dialog screen grabs caught the wallpaper), code on origin/v1.3.0 @ 24a29ee (includes 49f8859 and f5e23a4).

**UX verdict: SHIP WITH FIXES** - no Blockers or Majors left on my side. All 5 of my earlier items are fixed in code, and the real scan on the shop network shows 3 small copy and layout fixes.

### Status of my earlier items
| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | "No registers found" with no scan (Major) | Fixed (code) / not captured | 'notscanned' empty state and the declined status line (Launcher.ps1 :2444, :2456, :2523) |
| 2 | Scan prompt jargon, default No on Rescan | Fixed (code) / not captured | "Look for registers on this network (Ethernet)?", range and port in small print, default Yes from Rescan (:2181). scan-prompt.png caught the wallpaper. |
| 3 | Jartrek chip shared the receipt icon | Fixed | f5e23a4 key icon. Kern checked it on the mockup. Still a look change for Charles to OK. |
| 4 | Two input boxes; Cancel on name still added | Fixed (code) | One Add dialog with Address and optional Name, and Cancel adds nothing (:2045). The harness cancelled it and favoritesAfter is 0. |
| 5 | Seen repeated the age on every row | Fixed | Rows say Now / Earlier / Not found last scan (:1905). The render shows "Now". |

### New findings (from the real scan, 10.200.1.0/24, 4 hosts in 9.4 s)
1. **Minor: the finder lists any PC running VNC as a "register".** It found KBS-LT-CSR (a staff laptop, by its name) next to 3 unnamed hosts, and the status says "Found 4 register(s)". Staff can't tell which unnamed row is a till and which is a coworker's PC. Interact still asks for the full password, so this isn't a safety hole, but it's a wrong label.
   Fix: say `Found 4 computers you can view` in the status, and keep "register" for named or pinned rows. Whether non-register PCs should be listed at all is Charles's call (through Groot), not a UX fix.
2. **Minor: long reverse-DNS names run into the Address column.** "KBS-LT-CSR.bingo.keystonebingo.com" fills the Name column and touches "10.200.1.101" with no gap (picker-render.png, row 2).
   Fix: show the short name before the first dot (`KBS-LT-CSR`) with the full name in the tooltip, and add 12 px between the columns.
3. **Minor: the status line still has the range.** "Found 4 register(s) on 10.200.1.0/24 (Ethernet) at 12:54 PM" puts the network jargon from the old prompt back in front of staff.
   Fix: `Found 4 on the shop network at 12:54 PM. Press F5 to rescan.` Put the range in the tooltip or the log. Use the same wording for "Looking for registers on ...".

### Still not seen on Windows
The scan prompt, the Not scanned yet state, the Add dialog with text, the ⋯ menu, the password dialog, keyboard flow (Enter / Ctrl+Enter / F2 / Space / Del / F5 / Esc), and Narrator reading the status line. These need the same harness fix Kern asked for (Topmost, Activate, then capture). They don't hold the release, but please run one keyboard-only pass on the shop PC before Charles's OK.

## Final verdict (Squint, finishing second)
**SHIP WITH FIXES.** No Blockers. Open: Kern's Major 1 (the hover glow is still faint) and Major 2 (the chip row was never captured, a harness fix), Kern's Minors 3-7, and my Minors 1-3 above. The D2 look and the Jartrek key icon stay proposals until Charles OKs them through Groot.
