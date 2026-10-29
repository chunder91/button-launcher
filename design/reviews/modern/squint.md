# Modern launcher mockups: UX pass (Squint), Oct 29 2026, 9:55 AM ET
Reviewed compare.png, option-a and option-b, and spec.md (these are box mockups, not Windows captures).

**I recommend Option B (bold flat colorful), with 3 fixes.** The order change (Start Jartrek Security moves above the restarts) is **OK from UX**, and it's better. Both the order change and the option pick still need Charles's OK through Groot.

## Why B
Staff find buttons by color first and words second, which is how the old panel trained them. B keeps each button's color at full strength, so finding one takes a glance. A's dark tints squash the colors together: PLCE, Restart ScreenConnect and Restart Computer all read as the same dark maroon, and Email and Department of Revenue both read as olive. Staff would have to read labels to tell those apart, and the restart buttons stop standing out from PLCE. A looks sleeker, but it's slower at the counter.

## Fixes (for whichever option is picked)
1. **Major: the restarts look like PLCE.** In B, PLCE (#C40000) and Restart Computer (#B3261E) are almost the same red, and Restart ScreenConnect is a red-orange. The faint red tint behind the group doesn't separate them. A staff member reaching for PLCE in a hurry sees three red buttons. Fix: make the restart group the one place that looks different. Give the two restart tiles a neutral dark fill (around #2E2E2E) with a red icon and a 1px red outline. That echoes the original black Restart Computer, so PLCE stays the only solid red button. Kern can set the exact values.
2. **Minor: the Editing bar is easy to miss.** It's a small dark #2B2B2B strip on a #141414 panel, so the main cue is the dashed outlines. Fix: make the bar amber (#F59E0B) with #111 text reading "Editing: right-click a button to change it. Lock when done." Then nobody walks away from a panel that's still editable.
3. **Minor: "Restart Screen-Connect" breaks mid-word.** The soft hyphen splits the product name, and that reads like a typo. Fix: break it onto two lines, with "Restart" on one line and "ScreenConnect" on the next. If it doesn't fit, use 13px for that half tile, or shorten it to "Restart Remote" with a tooltip that says "Restarts ScreenConnect". Wording is Charles's call.

## Checked and fine
- **Scannability:** Title Case with icons on the left makes each button quick to read. The hero Red Dog button anchors the top panel well.
- **Hitting buttons fast:** tiles are at least 44px at Small, there's a 6px gap, and animations take 150ms or less, starting only after the launch, so nothing slows a click.
- **Danger row:** having it at the bottom with a 12px gap and a "Restarts" caption works. With the order change, no launch button sits next to a restart anymore. Restart Computer still needs to confirm with No as the default.
- **Edit mode:** dashed outlines plus the bar (with fix 2) make it obvious. Locked mode looks clean.
- **Menus:** the locked menu shows only "Unlock to edit..." and "Close this panel", as asked. The unlocked menu groups make sense, and the "Setup" hint line helps.
- **Missing-program dot:** 8px works as a hint, as long as hovering shows "Not set up on this PC yet" and clicking still explains what's wrong. Please add the tooltip.
- **Keyboard:** the focus ring is clear. Each tile still needs Enter to launch and a name for screen readers when it's wired up.
