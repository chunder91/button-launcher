# v1.4.0 Unread-mail indicator, D2 Email tile: visual spec (Kern, 2026-10-29 ET)
UX (flows, copy, opt-in setup) is Squint's; this is the visual spec. All sizes in DIP. Contrast is WCAG, measured in python3 against every D2 Email gradient stop (rest #FAD028→#D7AF12, hover #FBD336→#EBC014, pressed #EBC014→#C39F10).
Base tile: D2 half tile, about 135 x 80, radius 12, Fluent Emoji 3D `E-mail` icon at 32 centred above the label, 12 px top padding.

## 1. Count badge
**Picked: #111111 fill + #FACC15 number.** The red option fails against yellow (see table).
| Option | Number on fill | Fill vs tile (worst stop) | Verdict |
|---|---|---|---|
| #111111 fill / #FACC15 text | 12.33:1 | 7.45:1 (pressed bottom #C39F10) | **pass, chosen** |
| #B3261E fill / white text | 6.54:1 | 2.58:1 (pressed bottom) and 3.12 (rest bottom) | fails 3:1 |
| #C42B1C fill / white text | 5.66:1 | 2.23:1 | fails |
- Ring: 1.5 px #FFFFFF at 70% around the badge (outside), which separates it from the 3D emoji. Fill vs tile already passes, so the ring only adds polish.
- Position: anchored to the icon's top-right corner. The badge centre sits on the icon's top-right point: HorizontalAlignment Left, Margin = icon right − 8, icon top − 8. The badge overlaps the envelope by about 8 x 8 and must stay ≥ 4 inside the tile edge (it never crosses the tile radius). The badge goes on a Canvas/Grid overlay that is a sibling of the icon (Panel.ZIndex 2), so it causes no layout pass.
- Size: height 18, min width 18, CornerRadius 9 (pill). Horizontal padding: 1 char gives width 18 (a circle); 2 chars give width 24 (padding 5); "99+" gives width 30 (padding 5). Use a fixed Width per bucket so the width doesn't change with the digits.
- Type: `Segoe UI Variable Text` falling back to `Segoe UI Semibold`, 11 px, Bold (700), tabular figures (`Typography.NumeralAlignment=Tabular`), centred, line height 18. 11 px is under the 12 floor, but it's a numeral badge (bold, 12.33:1), which is the accepted exception.
- 99+: counts ≥ 100 show "99+" at width 30. The tooltip carries the real count.

## 2. Pulse (setting = Pulse)
- What animates: the badge Border only. `RenderTransform` ScaleTransform with `RenderTransformOrigin 0.5,0.5`, plus Opacity. No blur and no effect animation. This is cheap in WPF: a Storyboard on a render transform of an 18x18 element, so no measure or arrange.
- Trigger: on the first non-zero count, or when the count goes up. A decrease or the same count only swaps the number, with no pulse.
- One cycle is 1200 ms with SineEase EaseInOut: scale 1.00 → 1.12 at 600 ms → 1.00 at 1200 ms; opacity 1.00 → 0.75 → 1.00. RepeatBehavior 3x (3.6 s total), then it holds steady at scale 1 and opacity 1.
- Appear (the first time): opacity 0 → 1 and scale 0.6 → 1.0 over 150 ms with CubicEase EaseOut, then the 3 pulses.
- Idle breathe: optional, **default off**. It would run opacity 1.0 ↔ 0.85 every 4 s for "something is waiting" users, but it's off because a constantly moving element on a work panel distracts and keeps the compositor awake.

## 3. Count goes to 0
Opacity 1 → 0 over 150 ms (CubicEase EaseIn), then Visibility=Collapsed. No pulse and no flash. The tile returns to its rest look.

## 4. Reduced motion / still
Motion is off when `[System.Windows.SystemParameters]::ClientAreaAnimation -eq $false` (Windows "Animation effects" off) **or** the launcher setting is Badge only. Then the badge appears, changes and disappears with at most a 120 ms opacity fade, with no scale. Pulse and Flash both drop to Badge only. Re-read the system flag on each poll.

## 5. Error marker (login failed, offline)
- An 8 px circle at the badge's position (centred where the badge centre would be), outline only: 1.5 px stroke #4A4A4A with no fill. It never pulses or flashes, and there's no count and no red.
- #4A4A4A vs the rest top 5.96:1 and vs the pressed bottom 3.50:1. It passes 3:1 at every stop. #8A8A8A was rejected because it gives 1.36-2.38:1 on yellow.
- Shown for: login failed, and offline (or a poll error) for 2 polls in a row (6 min), so one network blip doesn't show it. Not configured or disabled shows nothing. Checking shows nothing new (the last state holds).
- The tooltip explains each state.

## 6. Tooltip - SUPERSEDED
Superseded by Squint's table in `squint.md` > "Tooltip copy (replaces section 6)" and its status-line wording. Use that copy as final. Visual only: launcher tooltip style; line 1 stays `Open email`, the email line goes under it.

## 7. Notification style setting (Pulse / Flash / Badge only)
Setting (Squint's version, final): checkbox `Show unread email count on the Email button` (off by default), then **`When new mail arrives:`** Pulse the number (default) / Flash the button 3 times / Just show the number. These map to (a) Pulse, (b) Flash, (c) Badge only below. All three show the count badge.

### (a) Pulse
As in section 2.

### (b) Flash: a burst flash of the whole tile, photosensitivity-safe
- Flash-on state: a pre-frozen gradient #C49A0C → #A8850A (a darker yellow), swapped with the rest gradient. Better: an overlay Border with this brush whose Opacity toggles 0/1, so no brush gets re-created.
- Text holds: #111 on #C49A0C is 7.17:1 and on #A8850A is 5.42:1 (rest is 12.69/9.02). Both pass 4.5:1. The badge (#111 fill) vs the flash bottom is 5.42:1, which passes.
- Luminance change: rest top L 0.656 → flash top 0.349 (ΔL 0.31); rest bottom 0.452 → 0.251. That counts as a "flash" (the darker state is < 0.80), so the frequency limit applies. The colour is yellow, not saturated red, so the red-flash rule doesn't apply. The tile is about 135x80, a small part of the screen, but the timing stays safe anyway.
- Timing: 500 ms flash-on, 500 ms off, **1 Hz** (well under 3 Hz). DiscreteObjectKeyFrame or a 60 ms opacity ramp at each edge (softer). The **burst is 3 flashes (3.0 s)**, then steady with the badge.
- Trigger: only when the count goes up. It repeats at most once per poll (3 min), and only if the count went up again. A hover or click on the tile cancels the burst at once and resets the overlay to opacity 0. It's not continuous, because a flash that never stops is exactly the kind of alert people turn off, and it adds risk with no gain.
- The glow, the lift and the badge are unaffected. If the flash is running during hover, the hover wins and the flash stops.
- With reduced motion on, Flash becomes Badge only (no tile change at all).

### (c) Badge only
The badge appears, changes and disappears with no animation (a 120 ms opacity fade is allowed).

## 8. Scaling, hover, pressed
| Scale | Badge h x min w (px) | 99+ w | Ring | Font px | Error dot / stroke |
|---|---|---|---|---|---|
| 100% | 18 x 18 | 30 | 1.5 → 2 px (snap) | 11 | 8 / 1.5 → 2 px |
| 125% | 22.5 → 23 x 23 | 37.5 → 38 | 1.9 → 2 | 13.75 | 10 / 2 |
| 150% | 27 x 27 | 45 | 2.25 → 2 | 16.5 | 12 / 2.25 → 2 |
Minimums: badge ≥ 18 px tall and number ≥ 11 px at 100%. Set `UseLayoutRounding` and `SnapsToDevicePixels` on the badge. Keep the pill radius = height / 2 after rounding.
- Hover: the badge rides the tile's TranslateY −2 (it's inside the tile's transform group). It does **not** take the icon's 1.06 scale (it's a sibling of the icon, not a child) or the glow. Its colours are fixed and unaffected by the hover gradient.
- Pressed: it rides the tile scale 0.97. Contrast vs the pressed bottom stop is 7.45:1.

## 9. Smudge render brief (D2 panel crop at 100%, Email tile + neighbours, plus 150% stills)
Stills at 100% and 150%: no badge, 3, 27, 99+, the error marker, the tooltip ("3 unread in Inbox - last checked 9:41 AM"), and hover with the badge "3".
GIFs: **20 fps (50 ms/frame), 100%, loop forever with a 1 s still hold at the end**. The before still is no badge; the after still is the badge "3" at rest.
**(a) Pulse GIF (0-4000 ms):**
| ms | Badge scale | Badge opacity |
|---|---|---|
| 0 | 0.60 | 0 (count arrives) |
| 150 | 1.00 | 1.00 |
| 750 | 1.12 | 0.75 |
| 1350 | 1.00 | 1.00 |
| 1950 | 1.12 | 0.75 |
| 2550 | 1.00 | 1.00 |
| 3150 | 1.12 | 0.75 |
| 3750 | 1.00 | 1.00, hold |
Sine-interpolate the frames between the keyframes. 3-frame pulse strip: 150 / 750 / 1350 ms.
**(b) Flash GIF (0-4000 ms):** the badge appears at 0 ms (opacity 0→1 over 150 ms, scale 1).
| ms | Tile fill |
|---|---|
| 0-500 | flash #C49A0C→#A8850A |
| 500-1000 | rest #FAD028→#D7AF12 |
| 1000-1500 | flash |
| 1500-2000 | rest |
| 2000-2500 | flash |
| 2500-4000 | rest + badge, hold |
**(c) Badge-only GIF:** 0-1000 ms no badge, then the badge "3" at 1000 ms (opacity 0→1 over 120 ms: frames at 1000 = 0, 1050 = 0.42, 1100 = 0.83, 1150 = 1), hold to 3000.
Use Segoe UI Variable, or Inter SemiBold labelled "font substitute".

## Kern check - Smudge mockups (2026-10-29)
**Verdict: OK to show Charles** - size, position, colours, pulse and flash timing all match the spec; 2 Minors to fix in a re-render (tooltip copy and top inset), neither changes what Charles is choosing between.
Measured in python3/PIL on the stills and on GIF frame durations (`ImageSequence`). Every GIF has a 1000 ms before-still lead, so GIF time = spec time + 1000.
- Badge size: the pill core measures 16-17 x 16-17 (1 digit), 22-24 (2 digits), 28-29 (99+) wide at both 100% and 150% (divided by 1.5), which is 18 / 24 / 30 once anti-aliasing and the ring are counted. Pass.
- Position: the badge centre sits on the 32 px icon box's top-right point (x +0, y +0 within 0.5 DIP) at 100% and 150%. Pass.
- Colours: fill #111111, number #FACC15 (anti-aliased to #F3C614): 12.33:1. Fill vs the rest bottom #D9B113: 9.0:1. Pass.
- Pulse: frames are 50 ms (20 fps). Appear 0-150 ms, peaks at 650-800 ms, 1850-2000, 3050-3200 (period 1200 ms), 3 cycles, hold from 3750 ms. At the peak the fill blends to #493D17 (= 75% opacity), and the number still reads 6.99:1 on it and the fill is 5.22:1 on the tile. Pass.
- Flash: durations on 500 / off 500 / on 500 / off 500 / on 500, then a 2500 ms hold. That's 3 flashes at 1.0 Hz (period 1000 ms), well under 3 Hz. Flash state measures #C1950C top to #AE890A bottom (GIF palette for #C49A0C to #A8850A). Label #111 on it: 6.81:1 top, 5.74:1 bottom; rest 12.69 / 9.02. Pass.
- Error ring: 8 x 8 at the badge centre, darkest #4A4A4A, 5.78:1 on the rest top and 4.33:1 on the rest bottom. No count, no pulse. Pass.
- 99+: present at 100% and 150% (`v140-badge-99plus-150.png`). Pass.
- Known deviations: Selawik for Segoe OK; 32 px icons are the spec value OK; GIF banding OK; hard flash edges OK (the spec allows DiscreteObjectKeyFrame), but see Minor 3.

1. **Minor - tooltip still shows the superseded copy** ("3 unread in Inbox - last checked 9:41 AM", one line). Fix: re-render still-tooltip-3-100/150 with two lines: `Open email` then `3 unread emails in Inbox. Checked 9:41 AM.` (Squint's table). Crop: `kern/assets/button-launcher/v140-tooltip-old-copy.png`.
2. **Minor - badge top inset is 3 DIP, not >= 4** (ring outer edge about 1.5 DIP from the tile top). That's my spec's fault: icon top - 8 with 12 px top padding lands at 3. Fix (spec and build): badge Margin top = icon top - 6 (the centre sits 2 DIP below the icon corner); horizontal stays icon right - 8. Re-render the stills. Crop: `v140-badge-inset-100.png`.
3. **Minor - flash edges hard.** OK for the mockup and allowed. For the build, prefer the 60 ms opacity ramp on the overlay at each edge (it doesn't change the 1 Hz rate) so the swap reads as a blink, not a jump. Crop: `v140-flash-on-off.png`.
Other crops: `v140-pulse-rest-peak-rest.png`, `v140-error-ring-150.png`.

## Setup dialog (D2)
Title `Unread email count` (Squint's copy and flow in squint.md; this is visual only). Tokens match v1.3.0 combined.md Minor 6. Contrast is measured against both window gradient stops (#26262C / #16161A).
- **Window:** width 440, SizeToContent Height (about 460 with the result line, 420 without; MinHeight 380). ResizeMode NoResize, WindowStartupLocation CenterOwner. Background LinearGradient vertical #26262C to #16161A, 1 px #FFFFFF 12% border, CornerRadius 12 if custom chrome, otherwise the standard title bar. Padding 16.
- **Grid:** single column, content width 408. Label to its control 8. Between rows 16. Between groups (account / warning / alert style / buttons) 24. Section heading `When new mail arrives:` 14 SemiBold.
- **Type:** Segoe UI Variable Text. Labels 14 Regular #FFFFFF (15.04 / 18.04:1). Intro and helper text 13 Regular #B4B4BC (7.30 / 8.76:1), TextWrapping Wrap. Nothing under 12.
- **Inputs (Email address, Password):** height 32, CornerRadius 6, fill #FFFFFF 6% (#333339 / #242428), 1 px #FFFFFF 12% stroke, padding 10,0. Text 14 white. The `@jartrek.net` suffix is a fixed 14 #B4B4BC TextBlock inside the box at the right, 8 from the edge. Placeholder #9A9AA4 (4.50:1 on the light input fill). Rest bottom line 1 px #FFFFFF 40% (3.67:1, so the field edge passes 3:1, since the 12% stroke alone is 1.46:1). Focus: 2 px #22C55E bottom line (6.60 / 7.92:1). Error (after a failed Test): 2 px #F87171 bottom line (5.44:1). Disabled: whole control 45% opacity.
- **Checkbox** (`Show unread email count on the Email button`): box 18 x 18, CornerRadius 4, 10 gap to the 14 px label, row height 24. Unchecked: transparent fill, 1.5 px #FFFFFF 55% stroke (5.56:1). Hover: fill #FFFFFF 8%. Checked: fill #22C55E, no stroke, check glyph 12 px 2 px stroke #111111 (8.4:1 on the green; the green is 6.60:1 on the window). Focus: 2 px #FFFFFF ring 2 px outside.
- **Radios** (Pulse the number / Flash the button 3 times / Just show the number): outer 18 diameter, 1.5 px #FFFFFF 55% stroke unchecked. Checked: stroke #22C55E 1.5 px and an 8 px #22C55E centre dot. 10 gap to the label, rows 28 high (no extra margin), indented 0 under the heading. Same focus ring.
- **Shared-PC warning:** a strip, CornerRadius 8, fill #F59E0B 12% over the window, 1 px #F59E0B 35% stroke, padding 10,8. 16 px Fluent `Warning` (color) icon, 8 gap, text 13 #FBBF24 (7.26:1 on its strip; 9.01:1 on the window).
- **Test result line:** directly under the Test button row's left side or the inputs, 8 above the buttons, min height 20, 16 px icon + 8 gap + 13 px text, wraps. Success: #4ADE80 with Fluent `CheckmarkCircle` filled #22C55E (8.63 / 10.36:1). Sign-in error: #F87171 with `ErrorCircle` (5.44 / 6.52:1). Offline: #FBBF24 with `WifiOff` (9.01 / 10.81:1). Checking: 13 #B4B4BC `Testing...` with a 16 px ProgressRing or no icon. AutomationProperties.LiveSetting Polite. No fills behind the line.
- **Buttons:** 32 high, CornerRadius 10, MinWidth 88, padding 16,0, 8 apart. Row right-aligned at the bottom: **Test** (secondary, left of the group) / **Save** (primary green #0E7A4B to #0A5A38, 14 SemiBold white 5.38:1; hover #187F52 to #0B643E; pressed #0D6E44 to #0A5333) / **Cancel** (secondary #2E2E2E to #1E1E1E with the 28% to 6% white rim, 14 Regular white). Save is IsDefault, Cancel IsCancel. Save disabled until a good Test: 45% opacity, no hover. Turning off: the confirm uses the same dialog shell at 380 wide with No (primary, default) and Yes, turn off (secondary).
- Scale: all values DIP; UseLayoutRounding on. At 150% the window is 660 px wide. Re-measure on real Windows captures.
