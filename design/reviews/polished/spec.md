# Button Launcher: polished Fluent spec (Kern, Oct 29 2026, ~11:45 AM ET)
For Switchboard + Smudge. **A proposal only. Nothing gets applied until Charles picks a direction through Groot.**
Base: Option B rev 2 (`reviews/modern/spec.md`), one-panel layout (`reviews/one-panel/`), current look `reviews/laptop-test/retest-dedfc23-panel.png`.
Unchanged in both directions: button order (Start Jartrek Security above the Restarts group), Option B hue per button, #111 labels on Email/Revenue, the full-colour Red Dog logo (`art/reddog/reddog-full-64.png`, on its white plate, as-is), Restarts group treatment (rev 2), missing-program dot, amber Editing bar, menu.
Contrast: WCAG relative luminance in python3, script saved as `contrast.py` here. AA labels 4.5:1 at **both gradient stops** in rest, hover and pressed; non-text 3:1. All sizes in DIPs.

## Shared (both directions)
| Token | Value |
|---|---|
| Panel width | 290 base (one-panel min 180 / max 560 unchanged) |
| Grid | padding 8, gap 6, 2 columns for half tiles and chips |
| Tile heights | hero 120, full 72, half 80 (icon above), half-tall 92 (guides), restart 72, chip 64 (52 icon-only) |
| Font | `Segoe UI Variable Display Semibold` for hero 22, `Segoe UI Variable Text Semibold` for 16 full / 13 half / 12 chips; sub-line 11 Regular at 85% (floor 12 except the existing "Version 11" sub-line). Fallback `Segoe UI Semibold, Segoe UI` on Win10. Title Case. Line height 1.2. `TextOptions.TextFormattingMode=Display` at 100%, `Ideal` at 125/150 (set by DPI). |
| Icon sizes | full 32, half 24, chip 32, hero = Red Dog 64 plate; icon→label gap 10 (left) / 6 (above) |
| Icon format | Pre-raster PNG at 1x/1.25x/1.5x (24→24/30/36 px, 32→32/40/48 px) picked by `VisualTreeHelper.GetDpi`, `RenderOptions.BitmapScalingMode=HighQuality`, `UseLayoutRounding=True`, `SnapsToDevicePixels=True`. Alt for Direction 1: SVG→XAML `DrawingImage` (free: `svg2xaml` / Inkscape XAML export), crisp at any scale. Direction 2 emoji ship as 256 px PNGs: pre-downscale to the 3 sizes (don't let WPF scale 256→24 at runtime). |
| Focus | 2 px #FFFFFF ring at 2 px offset, radius = tile radius + 2 (17.0:1 vs panel) |
| Disabled | fill #2A2A2A, label + icon #8A8A8A (4.16:1; disabled is AA-exempt), icon at 40% opacity + desaturate (ship a grey PNG), no hover, no shadow |
| Launch flash | white overlay 45%, 60 ms in / 240 ms out, after Start-Process returns (unchanged) |
| Timings | hover in 150 ms CubicEase EaseOut, out 200 ms; press 60 ms; release 120 ms. Nothing delays a launch. |
| Restarts | rev 2: label #FFFFFF, red #E5484D icon, 2 px #E5484D inside outline; group tint rgba(179,38,30,.14) + 1 px rgba(179,38,30,.45) |

### WPF / PS 5.1 performance rules (both)
- Gradients: `LinearGradientBrush` StartPoint 0,0 EndPoint 0,1 (vertical, 90°) unless noted; precompute frozen brushes per button per state (`$b.Freeze()`), swap on hover/press; animate only `Opacity` and `TranslateTransform`, never re-create effects.
- **One** `DropShadowEffect` on the panel's outer Border only. **No per-tile DropShadowEffect** (each is a separate offscreen pass and re-renders on every animation frame).
- Hover glow = a pre-built sibling `Border` behind each tile (same radius + 3, Margin −3, Background = `RadialGradientBrush` of the glow colour → transparent), Opacity 0 at rest, animated to the hover value. Cost ≈ one brush fill; no effect pass.
- No real acrylic in plain WPF. Mica is **simulated** with a semi-opaque tinted gradient + a 1 px top highlight (no noise texture, no BlurEffect).
- Optional opt-in (off by default): Win11 22H2+ (build ≥ 22621) `DwmSetWindowAttribute(hwnd, 38 /*DWMWA_SYSTEMBACKDROP_TYPE*/, 2 /*Mica*/ or 3 /*Acrylic*/)` via `Add-Type` P/Invoke, plus `DWMWA_USE_IMMERSIVE_DARK_MODE` (20) = 1. Requires window Background = Transparent **without** `AllowsTransparency` (that combination breaks the DWM backdrop) and `DWMWA_WINDOW_CORNER_PREFERENCE` (33) = 2 for rounded corners. Fallback: the solid tinted panel below on Win10/older builds or when the call returns non-zero. Contrast with the real backdrop must be re-measured on captures, since Mica tints from the wallpaper.
- `AllowsTransparency=$true` (needed for the 14 radius panel without DWM) puts the window on software-composited layered rendering: fine at 290×~1000, but test on the slowest shop PC at 150%; fallback square panel.
- BlurEffect: not used. If ever wanted, only on a static glow Border with `RenderOptions.CachingHint`/`BitmapCache` so it rasterises once.

---
## Direction 1: "Fluent Color" (flat Mica, Fluent System Icons Color)
Calm, Windows-Settings-like. Subtle top-to-bottom gradient, hairline strokes, colour icons on soft chips.

**Panel:** gradient #202024 (0) → #1C1C1E (1), opacity 0.94 (simulated Mica); 1 px stroke #FFFFFF at 8%; radius 14; panel shadow DropShadowEffect BlurRadius 24, ShadowDepth 6, Direction 270, Color #000000, Opacity 0.40, RenderingBias Performance. Label on panel (#A0A0A0 captions): 6.21:1.
**Tiles:** radius 8; stroke 1 px #FFFFFF at 10% (inside); top highlight 1 px #FFFFFF at 12% (BorderThickness 0,1,0,0). Icon chip behind icon: radius 6, padding 4, #FFFFFF at 14% (white-label tiles) / #000000 at 8% (Email, Revenue).
**Hover:** gradient → hover stops; glow Border opacity 0 → 0.55 (glow colour below, RadialGradient centre 0.5,0.5 radius 0.6, stop 0 colour @ 45% → stop 1 transparent); TranslateY −1; highlight stroke 12% → 20%.
**Pressed:** pressed stops; glow 0.25; TranslateY 0; ScaleTransform 0.98 (centre); highlight 6%.

| Button | Rest (top→bottom) | Hover | Pressed | Label ratios rest / hover / pressed (min of both stops) | Glow colour |
|---|---|---|---|---|---|
| Red Dog Back Office | #0B6A93→#0A6187 | #0B6E99→#0A658D | #0A638A→#095A7D | 6.00 / 5.67 / 6.64 | #549AB8 |
| View Register | #0D7548→#0C6B42 | #0E7A4B→#0D7045 | #0D6E44→#0B643E | 5.75 / 5.38 / 6.30 | #56A281 |
| Internet | #764CCD→#6C46BC | #7B4FD6→#7149C5 | #6F47C1→#6541AF | 5.70 / 5.34 / 6.27 | #A384E2 |
| Email (#111) | #FACE1E→#EBC014 | #FAD12C→#FACC15 | #F0C414→#DCB412 | 10.86 / 12.33 / 9.51 | #FCDB5B |
| Back Office / Register User Guide | #5B5F64→#54575C | #5F6368→#575B60 | #56595E→#4E5155 | 6.43 / 6.05 / 7.03 | #8F9295 |
| PLCE | #BC0000→#AC0000 | #C40000→#B40000 | #B00000→#A10000 | 6.69 / 6.27 / 7.38 | #D64C4C |
| Dept of Revenue (#111) | #F1E791→#E2D884 | #F2E898→#F0E68C | #E6DD86→#D3CA7B | 12.94 / 14.75 / 11.24 | #F4EEAE |
| Start Jartrek Security | #845D00→#795500 | #8A6100→#7F5900 | #7C5700→#715000 | 5.92 / 5.54 / 6.52 | #AD904C |
| Restart ScreenConnect / Computer | #2E2E2E→#242424 | #333333→#2A2A2A | #242424→#1E1E1E | 13.58 / 12.63 / 15.52 | #E5484D @ 30% |

**Chips (desktop files):** #141414 at 65% + 1 px #FFFFFF 16% (one-panel Major, unchanged), radius 8; hover #FFFFFF overlay 6% (label stays ≥ 5.7:1 per one-panel table at 65%).

---
## Direction 2: "Fluent 3D" (glassy acrylic-look, Fluent Emoji 3D)
Richer, more playful. Deeper vertical gradients, glass sheen band, 3D emoji icons that sit slightly proud of the tile.

**Panel:** gradient #26262C (0) → #16161A (1), opacity 0.90; 1 px stroke #FFFFFF at 12%; inner top highlight 1 px #FFFFFF 18%; radius 16; panel DropShadowEffect BlurRadius 32, ShadowDepth 10, Direction 270, #000000, Opacity 0.50, RenderingBias Performance. Caption #A0A0A0 on #16161A: 6.90:1.
**Tiles:** radius 12 (hero 14, chips 10); stroke 1 px LinearGradient #FFFFFF 28% (top) → #FFFFFF 6% (bottom); **glass sheen** = Border inside the tile, height 10, top-aligned, radius 12,12,0,0, gradient #FFFFFF 22% → 0%. The sheen stays inside the 12 px top padding, never behind text or icon (so it doesn't touch label contrast). Bottom inner shade 1 px #000000 25%.
**Icon depth:** emoji PNG + a pre-baked 6 px soft ellipse shadow PNG under it (#000 30%, offset y +2) — a static image, not an effect.
**Hover:** hover stops; glow Border opacity 0 → 0.70 (glow colour @ 55% → transparent, radius 0.65); TranslateY −2; icon ScaleTransform 1.0 → 1.06 (150 ms); sheen 22% → 30%.
**Pressed:** pressed stops; glow 0.30; TranslateY 0; tile scale 0.97; icon scale 1.0; sheen 12%.

| Button | Rest (top→bottom) | Hover | Pressed | Label ratios rest / hover / pressed (min) | Glow |
|---|---|---|---|---|---|
| Red Dog Back Office | #0B6E99→#085171 | #15749D→#095A7D | #0A638A→#074B68 | 5.67 / 5.23 / 6.64 | #549AB8 |
| View Register | #0E7A4B→#0A5A38 | #187F52→#0B643E | #0D6E44→#0A5333 | 5.38 / 5.00 / 6.30 | #56A281 |
| Internet | #7B4FD6→#5B3A9E | #8056D8→#6541AF | #6F47C1→#543692 | 5.34 / 4.95 / 6.27 | #A384E2 |
| Email (#111) | #FAD028→#D7AF12 | #FBD336→#EBC014 | #EBC014→#C39F10 | 9.02 / 10.86 / 7.45 | #FCDB5B |
| User Guides (both) | #5F6368→#46494D | #65696E→#4E5155 | #56595E→#414347 | 6.05 / 5.53 / 7.03 | #8F9295 |
| PLCE | #C40000→#910000 | #C60A0A→#A10000 | #B00000→#850000 | 6.27 / 6.09 / 7.38 | #D64C4C |
| Dept of Revenue (#111) | #F1E895→#CEC678 | #F2EA9C→#E2D884 | #E2D884→#BBB36D | 10.77 / 12.94 / 8.80 | #F4EEAE |
| Start Jartrek Security | #8A6100→#664800 | #8F670A→#715000 | #7C5700→#5E4200 | 5.54 / 5.11 / 6.52 | #AD904C |
| Restarts | #2E2E2E→#1E1E1E | #333333→#242424 | #242424→#1A1A1A | ≥12.6 | #E5484D @ 35% |

Restart icon/outline #E5484D vs tile bottom #1E1E1E 4.26:1, vs panel 4.71:1 (non-text pass).
**Chips:** #141414 65% + gradient stroke as tiles, radius 10, sheen 8 px at 14%.

---
## Icon table (all verified to exist on `main` today via raw.githubusercontent HTTP 200)
Sources (both MIT): https://github.com/microsoft/fluentui-system-icons (path `assets/<Name>/SVG/…`), https://github.com/microsoft/fluentui-emoji (path `assets/<Name>/3D/…_3d.png`).

| Button | Direction 1 (Fluent System, Color) | Direction 2 (Fluent Emoji 3D) |
|---|---|---|
| Red Dog Back Office | Red Dog full-colour logo, unchanged | same |
| View Register | `ic_fluent_receipt_32_color` | `Receipt` (`receipt_3d.png`) — no cash-register emoji exists |
| Internet | `ic_fluent_globe_24_color` (no 32 Color; render the SVG at 24 on half tiles, fine) | `Globe with meridians` |
| Email | `ic_fluent_mail_24_color` | `E-mail` (alt `Envelope`) |
| Back Office User Guide | `ic_fluent_book_open_32_color` | `Open book` |
| Register User Guide | `ic_fluent_book_open_32_color` (alt `ic_fluent_book_24_color`) | `Books` (to tell the two guides apart) |
| PLCE | `ic_fluent_shield_32_color` (`shield_checkmark` Color exists at 24 only) | `Police car light` (alt `Shield`) |
| Dept of Revenue | `ic_fluent_building_government_32_color` | `Classical building` (alt `Dollar banknote`) |
| Start Jartrek Security | `ic_fluent_lock_closed_32_color` | `Locked with key` (alt `Locked`) |
| Restart ScreenConnect | `ic_fluent_arrow_sync_24_color` (no `desktop`/`remote`/`arrow_clockwise` Color variant exists) | `Laptop` (alt `Counterclockwise arrows button`) |
| Restart Computer | **no Color power icon exists** → `ic_fluent_power_24_regular` tinted #E5484D (as rev 2) | `Electric plug` (no power-symbol emoji); alt `Counterclockwise arrows button` |
| Chips: documents | `ic_fluent_document_text_32_color` | `Page facing up` |
| Chips: other files / "4 more" | `ic_fluent_document_24_color` / text chevron | `Card file box` |
| Missing-program alert (tooltip) | `ic_fluent_warning_24_color` | — (keep 8 px amber dot) |

Note on restart icons: for the red-outline danger style, Direction 1 keeps single-colour #E5484D glyphs for both restarts (arrow_sync Color is blue and would weaken the danger cue — Smudge may tint `ic_fluent_arrow_sync_24_regular` red instead; both exist). Direction 2 emoji keep their own colours; the red outline carries the cue.

## Changes forced by contrast (vs Option B values)
- **Gradients can't lighten white-label fills.** Option B white-label fills sit at 5.34–6.27:1; a "lighter top" (+6%) dropped Internet/Register/Jartrek to 4.75–4.80 at rest and ~4.27 on hover; the deeper D2 draft (+12% top) hit 3.85–4.33. So: the Option B fill is the **lightest** stop allowed (D1 rest starts 4% darker; D2 rest starts at B and only darkens). Hover may lighten at most 4% (D2) and is lowest at Internet 4.95:1.
- "Fill +6% on hover" (old token) is retired for white-label tiles; hover reads through glow + lift instead.
- Gradient bottoms are 2.3–3.0:1 against the panel (tile edge is decorative; the label/icon carry meaning; 1 px stroke adds the edge). Email/Revenue unaffected.
- The glass sheen is confined to the 10 px top band so it never sits behind text.

## Smudge render brief
- Render both directions, full one-panel at **100% (290 px wide)** and **150% (435 px)**, over the same light and dark wallpapers as `reviews/one-panel/wall.png`; include the Restarts group and 2 chips.
- Close-ups (3× zoom): View Register + Internet + Email in rest / hover / pressed / focus; Start Jartrek Security disabled; a Restart tile hover.
- Use Inter SemiBold only if Segoe UI Variable is unavailable, and label the mock "font substitute".
- Use the exact hex/opacity values above; use the real icon files from the repos (MIT, keep the license note in the asset folder).
- Save to `reviews/polished/` as `fluent-color-100.png`, `fluent-color-150.png`, `fluent-3d-100.png`, `fluent-3d-150.png`, `states-closeup.png`, `compare.png`.
- **Mockups only. Nothing is applied to Launcher.ps1 or buttons.json until Charles picks a direction through Groot.** Kern re-measures on real Windows captures (100/125/150%) after any build.
