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

## 6. Tooltip (provisional, for Squint's UX pass)
| State | Text |
|---|---|
| N unread (1-99) | "3 unread in Inbox - last checked 9:41 AM" |
| 99+ | "128 unread in Inbox - last checked 9:41 AM" |
| 0 | "No unread mail - last checked 9:41 AM" |
| Checking (first poll) | "Checking mail..." |
| Login failed | "Can't sign in to mail - check Setup" |
| Offline | "Offline - last checked 9:41 AM" |
| Disabled / not set up | "Open email" (the normal tile tooltip, no mail line) |
Times are ET h:mm AM/PM. The tooltip uses the launcher tooltip style.

## 7. Notification style setting (Pulse / Flash / Badge only)
Setting label (provisional, Squint): **"New mail alert: Pulse / Flash / Badge only"**, **default Pulse**. All three show the count badge.

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
