# Button Launcher: look-and-feel proposal (needs Charles's OK through Groot)
Switchboard, Oct 29 2026. From design.md (Squint UX + Kern UI). Nothing here is applied. The functional fixes are on branch `review-fixes-1`.

Preview (MOCKUPS drawn with Python/PIL on the box, NOT Windows captures):
- Before/after side by side: reviews/lookfeel/before-after-mockup.png
- Before only: reviews/lookfeel/before-mockup.png · After only: reviews/lookfeel/after-mockup.png
(The 12/13 px minimum text size in the "after" picture is already in the branch as a readability fix. Everything else in "after" is a proposal.)

## Pick yes or no for each (safe default = keep as is)
1. **Readable colors (Kern P3 / finding 1).** Same color families, darker so white text passes contrast: Back Office #1C8FC0, View Register #0B7A4A, Internet #7B4FD6, Email #FFE600 (black text), guides #666666, PLCE #C40000 with white text (now gold on red), Revenue text #4A3D00, Restart SC #C8402F, Security #9A6B00, Restart Computer #2B2B2B.
2. **Sharper 3D edge (Kern P1 / finding 4).** Hard white top/left and dark bottom/right edges like the original shop panel, instead of today's soft diagonal smear. Pressing swaps the edges.
3. **Panel background #1A1A1A plus a thin grey outline on dark buttons (finding 5).** Restart Computer stops blending into the black panel.
4. **Softer launch flash (finding 7 / P4).** Flash at 45% instead of 80% so the label stays readable. Grip bar #8C8C8C with grip dots.
5. **Type scale (P2).** Arial Bold caps sized 30/22/16/13. "VERSION 11" goes on a smaller second line.
6. **Shorter labels (Squint).** "PA REVENUE", "JARTREK SECURITY", "GUIDE: BACK OFFICE v11" / "GUIDE: REGISTER v11". RED DOG BACK OFFICE and EMAIL stay as they are (your own picks).
7. **Danger row (Squint).** Restart ScreenConnect and Restart Computer together at the bottom with a gap above them, so Start Jartrek Security isn't next to Restart Computer.
8. **Visible edit mode (Squint/Kern 6).** Yellow "Editing" bar and dashed outlines while unlocked. Auto-relock after 10 minutes. Optional 4-digit unlock PIN.
9. **Amber "not set up" dot for missing programs/files** (the branch already shows it for missing pictures), plus a green-tick checklist look for "Set up this PC".
10. **Menu tidy (Squint 7).** Everyday items on top, a "Setup" submenu, Close items at the bottom. Also "Close all" asks first and says how to reopen it (Squint 3).
11. **Friendlier edit window (Squint 5).** Multi-line label box, Small/Medium/Large sizes, and Test for every type.
12. **Density modes (P5)** Compact/Classic/Large-touch, keyboard hotkey Ctrl+Alt+L, 44px minimum touch height.
13. **Icon art spec for Smudge.** Flat one-color line icons, left of the text. Black glyphs on yellow/khaki. Real Red Dog logo on Back Office only.
