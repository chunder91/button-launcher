# Kern UI review: View Register picker v1.3.0 (vnc-picker @ da5117b)
Source: picker.png / picker.html (HTML mock at 620x480, not a WPF render), design.md, D2 tokens from reviews/polished/spec.md. Times ET, 2026-10-29.

**Verdict: SHIP WITH FIXES.** All text passes AA. The fixes are layout (the wrap) and matching D2. I'll re-measure on real Windows captures at 100/125/150%.

## Findings (ranked by visual impact)
1. **Major: button row wraps.** "View-only password..." drops onto a second row by itself (7 buttons, about 640 px wide, in 588 px). It looks broken and uneven. Crop: `kern/assets/button-launcher/vnc-picker-buttons-wrap.png`.
   Fix: use one row with no WrapPanel. Make it a Grid with Auto columns and 8 px gaps, every button 32 px high (D2 chip height), padding 14,0.
   Left group: **View only** (primary, MinWidth 104) and **Interact** (primary-blue, MinWidth 92).
   Right group (HorizontalAlignment Right): **Rescan** (84), **Add...** (72), then a **More** overflow button, 36x32, with the Fluent `More horizontal` glyph (Segoe Fluent Icons E712) at 16 px.
   The More menu holds Rename / pin..., Remove, a separator, and View-only password...: ContextMenu items 36 px high, 14 px text, radius 8, background #26262C, 1 px #FFFFFF 12% stroke.
   Total is about 104+92+84+72+36+4x8 = 420 px, which leaves more than 160 px of slack at 125/150% with longer strings. Don't widen the window.
2. **Major: selected row uses the Interact blue (#0B6E99).** The selection reads as the same thing as the Interact button. Enter = View only (green), so the colours give the wrong cue. Crop: `vnc-picker-selection-vs-interact.png`.
   Fix: give the selected row the Win11 list style. Fill #FFFFFF at 9% (#2E2E2E on #1E1E1E), with a 3x16 px accent pill on the left (radius 1.5, #22C55E, 5.96:1 vs #2E2E2E, a non-text pass; the #0E7A4B tile green is only 2.52:1 there), and keep the text white (≥12:1).
   Hover row: #FFFFFF 5%. Row radius 6, inset 4 px from the list edges.
3. **Major: no D2 styling yet.** It has square corners, flat fills and no window depth, so it looks like the old Win7 look next to the D2 launcher. Crop: `vnc-picker-title-corners.png`. Fix: see the Match D2 list below.
4. **Minor: secondary buttons and the list border have no edge.** #2A2A2A on #141414 is 1.28:1, and the list border #2A2A2A on #1E1E1E is 1.16:1. Labels pass (14.35:1), but the shapes melt into the background. Crop: `vnc-picker-primary-buttons.png`.
   Fix: use the D2 Restarts fill for secondary buttons, #2E2E2E→#1E1E1E, with a 1 px stroke going from #FFFFFF 28% at the top to 6% at the bottom. The list gets a 1 px #FFFFFF 10% stroke.
5. **Minor: dead space.** There's about 35 px of empty space under the status line, and the list ends with about 105 px of empty rows. Crop: `vnc-picker-bottom-space.png`.
   Fix: pin the status line 16 px above the bottom edge (12 px, #A0A0A0, 6.90:1 on #16161A) and give the list Height=* so it fills the space. Show an empty-state line, centred, 13 px, #A0A0A0, when it has 0 rows.
6. **Minor: pin star is a text glyph in white**, so it carries the same weight as the names. Fix: Segoe Fluent Icons E735 (filled star) at 14 px, #F59E0B (7.76:1 on #1E1E1E), in a 28 px column. Unpinned rows get no glyph.
7. **Minor: column header.** 12 px #A0A0A0 (6.38:1) passes. Make it SemiBold, 28 px high, separator 1 px #FFFFFF 8%. Body rows 32 px (not 26) to match D2 density. Let the Greeting column take the remaining width (\*), not 120.

## Match D2 checklist
- [ ] Window: WindowStyle None + AllowsTransparency only if perf is fine. Otherwise keep the chrome and paint the client area with a gradient going from #26262C at the top to #16161A at the bottom. 1 px #FFFFFF 12% stroke, 1 px top highlight #FFFFFF 18%, radius 16 (with custom chrome). DropShadowEffect: BlurRadius 32, Depth 10, Direction 270, Opacity 0.50, RenderingBias Performance.
- [ ] Padding 20. Title 20 px Segoe UI Variable Display SemiBold, white (18.0:1), 12 px gap below, plus an optional 24 px Receipt 3D emoji 8 px left of the title (same icon as the View Register tile).
- [ ] List: #000000 at 18% over the panel (about #1E1E1E), radius 10, 1 px #FFFFFF 10% stroke, rows 32 px, 14 px Text Regular, selection and hover as in finding 2, focus ring 2 px #FFFFFF at radius 8.
- [ ] Primary View only: #0E7A4B→#0A5A38, hover #187F52→#0B643E, pressed #0D6E44→#0A5333 (5.38/5.00/6.30). 14 px SemiBold white.
- [ ] Primary Interact: #0B6E99→#085171, hover #15749D→#095A7D, pressed #0A638A→#074B68 (5.67/5.23/6.64). 14 px SemiBold white.
- [ ] Secondary (Rescan, Add..., More): #2E2E2E→#1E1E1E, hover #333333→#242424, pressed #242424→#1A1A1A, 14 px Regular white (≥12.6).
- [ ] All buttons: radius 10 (chip), height 32, gradient stroke #FFFFFF 28%→6%, sheen 8 px at 14% confined to the top band, bottom shade 1 px #000 25%. Hover: TranslateY −1 (not −2 at this size), glow 0.70 using the spec glow colour. Pressed: scale 0.97, glow 0.30, 60 ms. Focus: 2 px white ring at 2 px offset, radius 12.
- [ ] Disabled (e.g. View only/Interact with no selection, Rescan while scanning): #2A2A2A, label #8A8A8A, no glow or shadow, emoji grey PNG.
- [ ] Status line: 12 px Regular #A0A0A0. While scanning, add a 12 px ProgressRing or a 2 px indeterminate bar under the list, accent #0E7A4B (no blur).
- [ ] Icons: Fluent Emoji 3D PNGs pre-downscaled to 16/20/24 px for 100/125/150%, with UseLayoutRounding and SnapsToDevicePixels. In-button icons are optional. If used, put Eye (View only) and Keyboard (Interact) at 16 px, 6 px before the label.
- [ ] Type: Segoe UI Variable ($global:UiFont), 12 DIP floor everywhere.

**Wrap answer:** Not fine. Keep one row: View only, Interact | Rescan, Add..., ⋯. Rename / pin, Remove and View-only password go into the ⋯ menu (spec in finding 1). Don't widen the window.

**For Squint:** (a) Menu placement for Remove and Rename / pin, and whether Rename/Remove should also be on a right-click row menu. (b) The Enter = View only default, and the empty / no-private-network state copy. (c) Whether View-only password belongs in the picker at all or in a settings place. (d) The title is duplicated in the title bar and the H1.

## Recheck bef8da9 (2026-10-29 ET)
Source: new picker.png and picker-menu.png (HTML mock at 620x480), plus a code read of Launcher.ps1 @ bef8da9.

**Verdict: SHIP WITH FIXES.** Six of my seven findings are fixed. One is partly open, and the new ⋯ menu has a Blocker: its labels render black.

**Accepted decisions:**
- **View-only password moves to Setup.** Accepted.
- **Standard window frame.** Fine visually. The client area carries the D2 gradient (#26262C→#16161A) and the hint line replaces the duplicate H1.
- **Icons.** Segoe Fluent Icons glyphs are acceptable for v1.3.0 (E712 ⋯ and the E735/E734 stars). They're monochrome and crisp at every scale, and the picker is a utility dialog. Optional for later: a 24 px Receipt 3D emoji by the title.

### My 7 findings
1. **Button row wraps: FIXED.** It's one row: View only, Interact | Rescan, Add..., ⋯. All buttons are 32 px, and nothing wraps at 620 px.
2. **Selection used the Interact blue: FIXED.** The selected row is #2F2F34 with a #22C55E pill (5.84:1 against the row), and the text is white.
3. **No D2 styling: FIXED for v1.3.0.** The buttons have gradients, the sheen and the rim, and the list has radius 10. The frame stays standard, which I accept above.
4. **Secondary buttons and the list border have no edge: PARTLY OPEN.** The buttons now have the rim (#4A4A4A top), so they're fine. The list border measures 1.08:1 against the window and still melts in. Fix: set the list Border BorderBrush to #1FFFFFFF (12%). It's #1AFFFFFF now and gets lost over the darkened list fill. Alternatively, make the list Background #2E000000 → #40000000 so the box reads by its fill. Crop: `kern/assets/button-launcher/vnc-picker-bef8da9-rows.png`.
5. **Dead space: FIXED in code.** The list is Height=* with the empty-state text, and the status line sits at the bottom. The mock still shows about 45 px under the status line, so on the real capture confirm the bottom margin is 16 px (Window Padding 20,20,20,16).
6. **Pin star: FIXED.** It's amber #F59E0B. Unpinned rows show the outline star at #80FFFFFF, which is fine because the star toggles pin.
7. **Column header and row height: FIXED.** The header is 12 px SemiBold #A0A0A0, rows are 32 px, and the Seen column replaces Greeting.

### New ⋯ menu
- **Shape: OK.** The menu is #26262C with a 1 px 12% rim, radius 8 and padding 4. Items are 36 px, the highlight is #37373C at radius 6, and the separator is 1 px.
- **Blocker: the item labels render black.** Measured #000 on #26262C is 1.40:1, and #000 on the #37373C highlight is 1.77:1. A ContextMenu is a separate popup, so it doesn't inherit the window's Foreground. Crop: `vnc-picker-bef8da9-menu.png`. Fix: set `Foreground="#FFFFFF"` and `FontFamily=$global:UiFont` with FontSize 14 on the ContextMenu, or in the MenuItem style. Disabled items should be #8A8A8A. White gives 15.04:1 on the menu and 11.84:1 on the highlight.
- **Minor: the shortcut text needs more contrast.** #A0A0A0 on the highlight is 4.53:1, which passes only barely. Fix: use #B4B4B4 for InputGestureText, which gives ≥5.6:1 on both fills.
- **Minor: the menu covers Rescan and Add....** Fix: set Placement=Top on the ⋯ button, with the menu's right edge aligned to the button and a 4 px VerticalOffset. The popup then sits above the row and keeps the buttons visible. Crop: `vnc-picker-bef8da9-buttons.png`.

**Still needed:** real Windows captures at 100%, 125% and 150%, including the menu open.
