# Kern: UI notes on the modern mockups (Oct 29, 2026, ~10:00 AM ET)
**Recommendation: Option B (bold flat colourful).** Verdict on B: ship with fixes, 0 Blockers, 0 Majors, 3 Minors. Every item here is a proposal until Charles OKs it through Groot.

## Why B over A
- **A loses the colour coding staff navigate by.** Its tinted tiles collapse hue families that are distinct today:
  - Email #776520 vs Revenue #736F4D is 1.12:1, and both read as olive.
  - PLCE #621818 vs Restart Computer #5C2623 is 1.06:1, and Restart ScreenConnect #5D3129 is a third maroon.
  - The accent bar and icon chip are only 4px and about 34px of colour, too little to tell tiles apart at a glance on a shop PC.
- **B keeps every family distinct and passes AA everywhere:**
  - Labels range from 5.34:1 to 14.75:1.
  - On hover, with the fill 6% lighter, the lowest is violet at 4.76:1, and every label still passes.
  - "Version 11" at 85% opacity on grey reads at 4.92:1.
- B is also simpler in WPF: no accent-bar clip trick.

## Option B findings (crops are in /home/box/shared/kern/assets/button-launcher/)
1. **Minor: "Restart Screen-Connect" breaks with a hyphen over 3 lines** (modern-b-bottom.png). Tiles in the Restarts group are 92 tall, so use the icon-above layout (24px icon, 6px gap). Label "Restart" on line 1 and "ScreenConnect" on line 2 at 13px. ScreenConnect is about 95px at 13px Semibold and fits the roughly 115px text width. Drop the soft hyphen.
2. **Minor: the right-click menu caption "PC setup, panels, installer" sits on the separator line** and overlaps it (modern-b-menu.png).
   - Fix: put it as a second line under "Setup ▸", 12px, #A0A0A0 (6.5:1 on #2B2B2B), 2px below the label, and grow the item to 44px.
   - Or drop the caption.
3. **Minor: the "Editing" bar wraps to 2 lines,** so it's about 40px, not the 28px spec. Keep one line: 12px Semibold, padding 0 10px, ellipsis on overflow, with the full hint in the tooltip. Or spec it as a 40px two-line bar on purpose. Don't let the height change between panel widths.

## Departures from my spec: all OK
- **Inter for Segoe:** fine for the mock. Segoe UI Semibold is slightly narrower, so wraps will match or improve. Re-check the 3 two-line labels in the first Windows capture.
- **Red Dog at 64px full colour on a white plate in the hero:** OK. The hero is 120 tall, so 64px is above the full-mark threshold.
- **Rows at 72, not 80–85:** OK at 16/13px type. Keep the 12 DIP floor after the 0.92 laptop scale, which makes rows 66 there.
- **Start Jartrek Security moved above the Restarts group:** visually right. It keeps the danger group pure. The order itself is Squint's call.
- **Amber dot:** #F59E0B is 2.58:1 on gold. The 1.5px #141414 ring gives an 8.58:1 edge, so it passes 3:1 non-text on every fill. Keep the ring.

## Before code
- Take the first real Windows capture at 100% and 150% scaling. Then I'll measure the real Segoe wraps, the DropShadowEffect softness, and the corner clipping if AllowsTransparency stays on.
