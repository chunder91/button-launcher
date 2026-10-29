# Kern: UI notes on the one-panel mockup (Oct 29, 2026, ~10:10 AM ET)
**Verdict: visually sound, ship with fixes.** 0 Blockers, 1 Major, 3 Minors. It's a proposal until Charles OKs it through Groot.

Crops: /home/box/shared/kern/assets/button-launcher/one-panel-middle.png and one-panel-small.png.

## Findings
1. **Major: the chip fill needs at least 65% opacity, not 55%.**
   - Without blur, white labels on #141414 chips measure as follows over the worst backgrounds (white, yellow, cyan):

     | Chip opacity | White | Yellow | Cyan | AA |
     |---|---|---|---|---|
     | 55% | 4.06:1 | 4.31:1 | 4.88:1 | fails |
     | 60% | 4.81:1 | 5.09:1 | 5.73:1 | passes, barely |
     | 65% | 5.74:1 | 6.05:1 | 6.75:1 | passes |

   - WPF can't blur, so spec a solid **#141414 at 65%**.
   - Add a 1px #FFFFFF outline at 16% so the chip edge still shows on dark wallpapers, where the fill alone is about 1:1.
2. **Minor: make the chip grid match the tile grid.**
   - Chips should be the same width as the half tiles below. Today they're about 2px off at each column edge, with a 10px vertical gap against the tiles' 6px.
   - Use a 6px gap and the same 2 columns, so the middle reads as part of the panel.
   - Keep at least a 16px gap between the chip area and each group; the free space is centred.
3. **Minor: label size and overflow.**
   - 11.5px is under the 12 DIP floor. Use 12px Semibold, one line, ellipsis.
   - Hide file extensions by default (show "Price List", not "Price List.pdf") and put the full name in the tooltip. At 1366, "Daily Backup.ps1" touches the chip edge and "Price List.pdf" wraps.
   - Chip size: 32px icon, 6px icon-to-label gap, 8px padding, and a 64px chip height (52px icon-only).
4. **Minor: the "4 more" pill at 1366×768.**
   - At about 22px high with roughly 11px text, it's the smallest thing on the panel.
   - Spec: 28px high, the full chip-row width, 12px Semibold, the same 65% chip fill and outline, with a chevron. Label it "4 more", without "(scroll)".
   - Below about 60px of free height, use the ⋯ chip at the same 52px size as an icon-only chip.

## OK as drawn
- The top and bottom groups are unchanged from Option B.
- In edit mode, the amber bar fits on one line, and the dashed outlines match.
- Where the click-through ends lines up with the chips, so the chip edge is where clicks stop passing to the desktop.
- The Restarts group stays at the bottom.

## For the first Windows build
- Capture it at 100% and 150% over a light wallpaper and a dark one. Then I'll re-measure the chip contrast and the real Segoe label widths.
