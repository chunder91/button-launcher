# Button Launcher: modern button mockups (BOX MOCKUPS, not Windows captures)
**Rev 2 (10:00 AM ET): Squint (squint.md) and Kern (kern.md) both recommend Option B.** Changes in rev 2 are listed at the end.
Switchboard, Oct 29 2026. Built on Kern's tokens (/home/box/shared/kern/styles/button-launcher.md + his relayed spec) and Squint's UX needs. Nothing in the launcher code changed.

Files: option-a.html/.png, option-b.html/.png, compare.png, gen.py (regenerates both HTML files and contrast.json), assets/ (copies of src/images on review-fixes-1).
Rendered as HTML/CSS in headless Chrome at 2x. Font: **Inter SemiBold as a substitute** for Segoe UI Variable Semibold (Windows has Segoe; the box doesn't).

## Options
- **A · Windows 11 dark:** #141414 Mica-like panel. Tiles are dark tints of each button's own colour (62% toward #262626), with a 4px accent bar and a full-colour icon chip, so no tile is plain dark grey.
- **B · Bold flat colourful:** same panel, Kern's solid fills as-is, with a white or #111 label depending on contrast.

## Palette and WCAG contrast (label on fill; AA needs 4.5:1)
| Button | Family | B fill / label | B ratio | A tile / label | A ratio | B fill vs panel #141414 |
|---|---|---|---|---|---|---|
| Red Dog Back Office | cyan | #0B6E99 / #FFFFFF | 5.67:1 | #1C4152 / #FFFFFF | 10.90:1 | 3.25:1 |
| View Register | green | #0E7A4B / #FFFFFF | 5.38:1 | #1D4634 / #FFFFFF | 10.62:1 | 3.42:1 |
| Internet | violet | #7B4FD6 / #FFFFFF | 5.34:1 | #463669 / #FFFFFF | 10.54:1 | 3.45:1 |
| Email | yellow | #FACC15 / #111111 | 12.33:1 | #776520 / #FFFFFF | 5.73:1 | 12.03:1 |
| User Guides | grey | #5F6368 / #FFFFFF | 6.05:1 | #3C3D3F / #FFFFFF | 10.87:1 | 3.05:1 |
| PLCE | red | #C40000 / #FFFFFF | 6.27:1 | #621818 / #FFFFFF | 12.63:1 | 2.94:1 |
| Dept of Revenue | khaki | #F0E68C / #111111 | 14.75:1 | #736F4D / #FFFFFF | 5.11:1 | 14.39:1 |
| Restart ScreenConnect | salmon | #B8432F / #FFFFFF | 5.41:1 | #5D3129 / #FFFFFF | 10.84:1 | 3.41:1 |
| Start Jartrek Security | gold | #8A6100 / #FFFFFF | 5.54:1 | #4C3C18 / #FFFFFF | 10.68:1 | 3.33:1 |
| Restart Computer | danger | #B3261E / #FFFFFF | 6.54:1 | #5C2623 / #FFFFFF | 11.96:1 | 2.82:1 |
Every label passes AA, and the lowest is Option A Revenue at 5.11:1. Option A icon chips use the B fill colours. The danger zone tint is rgba(179,38,30,.14) on the panel, with a 1px rgba(179,38,30,.45) outline.

## Shape, type and sizes
- Panel: 290 DIP base, radius 14, padding 6, #141414, borderless tiles. Gap 6.
- Tile: radius 8, padding 12/8. Row height 72 (Kern rows 80–85 map here; keep 80 in WPF if preferred), hero 120, tall half 92, Small strip 44 (minimum).
- Type: Semibold, Title Case, sizes 22 hero / 16 full / 13 half / 11 sub-line ("Version 11" at 85% opacity), floor 12, line height 1.2.
- Icons: 24 half, 32 full, sitting left of the label with a 10px gap. On half-width tiles taller than 80, the icon goes above the label with a 6px gap (guides). Option A puts icons on a 7px-radius colour chip with 5px padding.
- Red Dog: full-colour logo on a white plate (radius 8, padding 4) at 64px. Kern's head-only 40px version wasn't available (Smudge removed alt-reddog-full-head-48.png), so the hero uses the 64px full mark.
- Labels changed in the mock only: "Restart ScreenConnect" (one word, a soft hyphen breaks it onto two lines) and Title Case everywhere.

## States and animation (all 150ms or less, and none of them delay a launch)
- Rest: no shadow, only an inset 1px top highlight of #FFFFFF at 8%.
- Hover: translateY −1px, shadow 0 4 10 #000 at 35%, fill +6% lighter, 120ms ease-out.
- Press: translate back to 0, no shadow, fill −8% darker, 60ms. Scale 0.98 is optional.
- Launch flash: #FFFFFF overlay at 45%, 60ms in and 240ms out. It starts after Start-Process returns.
- Focus: 2px white ring at a 2px offset.
- Edit mode: 2px dashed white outline at 60% inside each tile, plus a 28px #2B2B2B "Editing" bar at the top of the panel. Locked mode shows neither (clean).
- Missing program: 8px #F59E0B dot, top-right with a 6px inset and a 1.5px ring in the panel colour (shown on Start Jartrek Security).
- Danger row: Restart ScreenConnect + Restart Computer at the very bottom, with a 12px gap, a "Restarts" caption, and a red-tinted, outlined group.
- Menu inset: everyday items first, then edit items, then a Setup submenu, then the Close items. The locked menu shows only Unlock and Close.

## Mapping to WPF in PowerShell 5.1 (feasibility)
| Mock feature | WPF approach | Feasible on 5.1? |
|---|---|---|
| Rounded tile | `Border.CornerRadius = 8` (replaces the 3px bevel border) | Yes, trivial |
| Panel radius 14 | Window `AllowsTransparency=$true`, `Background=Transparent`, with an outer Border CornerRadius 14. AllowsTransparency turns off hardware composition for that window. A small panel is fine, but test on low-end shop PCs. Fallback: square panel | Yes, test performance |
| Inset top highlight | Child Border with BorderThickness 0,1,0,0 and brush #14FFFFFF | Yes |
| Hover lift + shadow | `TranslateTransform` Y −1 + `DropShadowEffect` (BlurRadius 10, ShadowDepth 4, Opacity .35, Direction 270), animated with `DoubleAnimation` 120ms + `CubicEase EaseOut`. Wire-Button already animates in code-behind, so swap its brushes and animations instead of writing a XAML Style | Yes. DropShadowEffect is GPU-accelerated; only apply it on hover |
| Fill ±6/8% | Precompute lighter/darker `SolidColorBrush` per button, then a `ColorAnimation` 60–120ms | Yes |
| Launch flash | Existing white overlay; change opacity to .45 and timing to 60/240 | Yes, a few lines |
| Focus ring | `FocusVisualStyle` with a Rectangle Stroke white 2, Margin −2; tiles need `Focusable=$true` + KeyDown Enter | Yes, needs keyboard wiring |
| Edit outline / bar | Rectangle `StrokeDashArray 4 3` overlay + a 28px Border docked top, toggled in Apply-Lock (already rebuilds panels) | Yes |
| Missing dot | Already in the branch (Add-MissingPicCue). Change the size and colour to 8px #F59E0B with a panel-colour ring, and also drive it from Test-ButtonReady | Yes |
| Icon chip / plate | Border CornerRadius 7/8 with a background colour around the Image | Yes |
| Accent bar (A) | Border Width 4 HorizontalAlignment Left inside the tile grid, clipped by `ClipToBounds` + CornerRadius (or OpacityMask) | Yes. Corner clipping needs a Border clip trick |
| Font | `FontFamily = 'Segoe UI Variable Text Semibold, Segoe UI Semibold, Segoe UI'`, FontWeight SemiBold. Segoe UI Variable is Win11 only; Win10 falls back to Segoe UI Semibold | Yes |
| Title Case labels | buttons.json label text edits (data, not code) | Yes |
| Danger group | Second StackPanel inside a Border (tinted background + outline), with buttons tagged `"group":"danger"` in buttons.json | Yes, small Build-Panel change |
| Menu tidy | ContextMenu with a Setup submenu (MenuItem with child items) | Yes |
| Easing / scale on press | `ScaleTransform` RenderTransform with CenterX/Y, 60ms | Yes |

Overall: both options are doable in PS 5.1 + WPF without extra libraries. B is simpler; A needs the accent bar and chip layering. Estimated effort is moderate, mostly in New-Bevel, Wire-Button, New-Content and Build-Panel. Needs Charles's pick through Groot before any code changes.

## Rev 2 changes (Squint + Kern), applied to both options
1. **Restart tiles stand apart** (Squint Major 1). Restart ScreenConnect and Restart Computer now have a neutral **#2A2A2A** fill, a white label (14.35:1), a red **#E5484D** icon and a **2px #E5484D inside outline**. The red is 4.71:1 against the panel and 3.67:1 against the tile, so it passes the 3:1 non-text rule. Kern's danger #B3261E is only 2.82:1 against the panel, so it isn't used. PLCE is now the only solid red tile. The red-tinted group, the "Restarts" caption and the 12px gap stay.
   WPF: Border Background #2A2A2A, BorderBrush #E5484D, BorderThickness 2. For the red icon, use an `OpacityMask` (ImageBrush of the white Set A PNG) on a #E5484D rectangle, or ship red PNG copies.
2. **Editing bar is amber** #F59E0B with #111 text (8.79:1). It's a fixed single line of 12px with an ellipsis, and the full text "Editing: right-click a button to change it. Lock when done." is in a tooltip (Squint 2 + Kern 3). WPF: `TextTrimming=CharacterEllipsis` and `ToolTip`.
3. **"Restart / ScreenConnect"** on two lines with no hyphen. Both restart tiles use the icon-above layout (24px icon, 6px gap, 13px label) (Squint 3 + Kern 1).
4. **Missing-program dot** now shows its tooltip "Not set up on this PC yet" in the mock (drawn open above the dot).
5. **Menu:** "Setup ▸" is a 44px item with a 12px #A0A0A0 second line, "PC setup, panels, installer" (5.41:1 on #2B2B2B), instead of a caption on the separator (Kern 2).
6. The order change stays: Start Jartrek Security sits above the Restarts group.

**Conflicts (resolved in favour of your brief):** Squint suggested a **1px** outline and fill **#2E2E2E**; your brief said **2px** and **#2A2A2A**, so I used those. Squint left the exact values to Kern. Squint also offered "Restart Remote" as a fallback label; it isn't needed, because "ScreenConnect" fits at 13px. Nothing else conflicts.
contrast.json now holds the per-button ratios plus the restart-tile, Editing-bar and menu-caption values.
