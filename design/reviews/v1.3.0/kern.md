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
