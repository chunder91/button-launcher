# One-panel launcher: BOX MOCKUP notes (not Windows captures)
Switchboard, Oct 29 2026, about 10:05 AM ET. This is a mockup only; the launcher code is unchanged. It answers Charles's ask: "make it all one panel, but make the panel that connects them a invisble panel, that cna hold icons of our choosing".
Files: one-panel-normal.png, one-panel-edit.png, one-panel-small.png, compare.png (all three side by side), the *.html sources, gen_one.py (reuses ../modern/gen.py Option B tiles, run `python3 gen_one.py`), assets/ and wall.png. The desktop is the box wallpaper with a colour wash added (blue, yellow and purple areas) to stress-test legibility; it isn't a real Windows desktop. The middle icons are stand-in drawings. The real build would use each target's own icon.

## Layout
- **One window docked to the right edge.** Today the Top panel anchors top-right and the Bottom panel anchors bottom-right (buttons.json on review-fixes-1). The window is 290 DIP wide (Medium) and exactly as tall as the work area, so it never covers the taskbar.
- **Top group** (Option B): Red Dog Back Office (hero), View Register, Internet | Email. It sits flush with the top, with rounded bottom-left corners.
- **Middle (transparent):** user-chosen shortcuts float over the desktop in a 2-column grid of 8 examples: Notepad, Chrome, Price List.pdf, Daily Backup.ps1, Nightly Report.xlsx, KBS Portal (website), Calculator, Shared Drive (folder). They're vertically centred in the free space.
- **Bottom group** (Option B, approved order): the guides, PLCE | Revenue, Start Jartrek Security, then the Restarts group (dark tiles with a red outline) at the very bottom.
- **Icon tile:** 32px icon plus an 11.5px Semibold label. Option B tiles stay 72/92/120 tall (44 minimum).

## Legibility over any wallpaper: frosted chip (chosen)
Each middle icon sits on a rounded 12px chip filled #141414 at 55% with a 14px background blur, a faint 1px top highlight and a soft shadow.
- **Why:** a text shadow alone fails on busy or bright wallpapers. The chip gives white text at least 4.5:1 even on a white background (#141414 at 55% over white is roughly #7A7A7A → 4.4–5:1, and darker over typical wallpapers).
- It also gives each icon a clear click target and matches the panel's dark tiles.
- **WPF note:** WPF has no real backdrop blur for a layered window. Use a solid 60–65% chip (no blur) for guaranteed contrast, so the build looks slightly flatter than the mock. Win11 Acrylic/Mica can't be applied per element.

## Frames
1. **Normal (locked), 1920×1080:** clean, no outlines. Callouts mark the click-through middle and the work-area bottom.
2. **Edit mode:** the amber Editing bar (single line with "…" and a tooltip), dashed outlines on the tiles and middle icons, a ⠿ drag handle (top-left) and a red × remove badge (top-right) on each icon, a "Drag ⠿ to reorder · × to remove" hint, and an amber "+ Add icon" slot. The slot opens the existing Edit window (Program / Website / File / Script). The middle switches to 3 columns so 8 icons plus the Add slot fit.
3. **Small screen, 1366×768 (work area 720):** the groups go compact (46px rows, 64 hero, 12px text floor) and the middle shows one row of 4 icon-only-ish chips plus a "▾ 4 more (scroll)" pill. Rule: the middle gets whatever height is left. If it can't fit one row (about 60px), it collapses to a single ⋯ chip that opens a flyout. Groups never shrink below 44px tiles. If even that doesn't fit, the window falls back to today's two separate panels.

## buttons.json storage (proposal)
Add one top-level group beside the panels, using the same button schema and target types (program / website / file / script / builtin), so Edit-Button, Invoke-Button, Resolve-ButtonPath, Get-SafeUrl, Test-ButtonReady and the missing dot all work unchanged:
```json
"layout": "single",                  // "single" = one docked window; "panels" = today's two windows (default, safe)
"dock": { "edge": "right", "monitor": -1, "size": "Medium" },
"middle": {
  "columns": 2, "showLabels": true,
  "items": [
    { "label": "Notepad", "type": "program", "target": "notepad.exe", "image": "icon" },
    { "label": "KBS Portal", "type": "website", "target": "https://example.invalid" },
    { "label": "Price List", "type": "file", "target": "%USERPROFILE%\\Documents\\Price List.pdf", "image": "icon" },
    { "label": "Daily Backup", "type": "script", "target": "C:\\Scripts\\Daily Backup.ps1", "image": "icon" }
  ]
}
```
The top and bottom groups are the existing `panels[0]` and `panels[1]` buttons, so nothing is migrated. `"image": "icon"` uses the target's own Windows icon (Get-IconImage already does this). Middle items could also be dropped from Explorer onto the middle area to add them (a later phase).

## Click-through (the key technical point)
- **Window:** `WindowStyle=None`, `AllowsTransparency=$true`, `Background=[Brushes]::Transparent` (or `$null`). WPF then renders a per-pixel-alpha layered window (WS_EX_LAYERED with UpdateLayeredWindow). Windows hit-tests layered windows per pixel, so a pixel with alpha 0 passes the click to whatever is behind it.
- **Middle container:** `Background = $null` (NOT Transparent). In WPF, `Transparent` is still hit-testable inside the window, while `$null` isn't. The icon chips have a real (semi-opaque) background, so they stay clickable. Empty gaps between chips pass clicks through.
- **Drag in edit mode:** to drag-reorder, give the middle a near-invisible `#01000000` background only while unlocked, so it catches drops, then set it back to `$null` when locked.
- **Alternative if needed:** WS_EX_TRANSPARENT toggling via SetWindowLongPtr (we already P/Invoke it), but that makes the whole window click-through, so per-pixel is the better fit.

## DPI and work area
- The window height comes from the monitor's work area. Today's code uses Get-WorkArea (Screen.WorkingArea plus SHAppBarMessage for auto-hide) per monitor. Prefer it over `SystemParameters.WorkArea`, which only covers the primary monitor and is in DIPs.
- The window is placed in device pixels via SetWindowPos, with per-monitor-V2 DPI, as in Layout-Panel.
- **Re-dock triggers:** the existing relayout timer on `SystemEvents.DisplaySettingsChanged` and the power-resume handling, plus `SystemParameters.StaticPropertyChanged` (WorkArea) or a WM_SETTINGCHANGE (SPI_SETWORKAREA) hook through HwndSource.AddHook, so it re-docks when the taskbar moves or resizes. WM_DISPLAYCHANGE and WM_DPICHANGED also trigger a re-fit.
- Height = work-area height ÷ DPI scale. The middle gets the leftover after the groups are measured.

## WPF feasibility and risks
| Item | Feasible | Risk / note |
|---|---|---|
| One tall docked window | Yes | Low. Reuses Layout-Panel with anchor right and stretch-to-work-area |
| Transparent middle with per-pixel click-through | Yes | **Medium.** AllowsTransparency turns off hardware composition for that window, so the whole (tall) window is rendered in software. Test on the slowest shop PC; animations may stutter. |
| Frosted blur chips | Partly | No per-element backdrop blur in WPF. Use solid 60% chips |
| Icons from targets | Yes | Get-IconImage exists. Some .lnk or UNC icons are slow, so load async on startup |
| Drag to reorder / drop files to add | Yes | Medium effort (DragDrop API in PowerShell). Phase 2 |
| Small screens | Yes | Needs the fit rules above. Fall back to two panels if the groups alone don't fit |
| Always-on-top tall window | Yes | **UX risk:** it covers the right edge of maximized apps (scrollbars, close buttons) unless it reserves space as an AppBar. Option: register as an AppBar (SHAppBarMessage ABM_NEW) so maximized windows stop at its edge. That's more complex, and AppBars can misbehave with multiple monitors. Default: not topmost, as today. |
| Locked mode clean / edit mode visible | Yes | Same Apply-Lock rebuild as the branch |
| Keep two-panel layout | Yes | `"layout": "panels"` stays the default until Charles tests the single layout on a real PC |

Recommendation: build it behind `"layout": "single"`, as a choice with a safe default (two panels).
