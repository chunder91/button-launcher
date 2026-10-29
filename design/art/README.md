# Button Launcher icons (Keystone Bingo Supply)

These are concepts until they're approved. Nothing in `../src/` was changed. To use a set, copy its 256 px PNGs into `src/images/`. The file names already match.

## Files
- `set-a-line/`: Set A, built to Kern's spec (reviews/design.md).
  - Flat single-colour line glyphs with no gradients.
  - 2 px rounded stroke on a 24 px artboard with 2 px padding.
  - Glyphs are white, except on EMAIL (#FFFF00) and REVENUE (#F0E68C), where they're #000000.
  - No offset shadow. A 1 px #000 α0.35 outline is added only on the light buttons: Red Dog (cyan), Internet (lavender), Screen Connect (salmon) and Security (gold).
  - VIEW REGISTER is a cash-register outline.
  - Contents:
    - `*.png`: 256 px drop-ins. Names: reddog, register, globe, email, guide (used by both user guides), badge, revenue, screenconnect, security, power.
    - `sizes/<name>-{16,24,32,48,64}.png`
    - `svg/<name>.svg`: SVG masters.
- `set-b-retro/`: Set B, a chunky retro "die-cut sticker" style.
  - Thick #1b1b2a ink outline, flat retro fills, white highlight swooshes and a hard offset shadow.
  - To follow Kern's colour rule, the sticker rim is cream on dark buttons and black on EMAIL/REVENUE.
  - Same layout as Set A: drop-ins, `sizes/` and `svg/`. The 16 px slot reuses Set A's 16 px glyphs.
- `reddog/`: the Red Dog mark, shared by both sets and used only on the Back Office button.
  - `original-download-red-dog-pos-logo.png`: the original download, unchanged. sha256 83d03401f9475bb1fa20dcb633ad32da82990bcfa47e6d5141e00d235e039867.
  - `reddog-full-*.png`: full colour, for picture-only mode. It's only trimmed and padded, and the brand red is never recoloured.
  - `reddog-knockout-*.png`: one-colour white knockout for the cyan button. Near-black ink lines become cut-outs.
  - Both sets use this as their `reddog.png`.
  - 15% clear space on all sides. At 48 px and below only the dog head is used; the full mark is for 64 px and up.
  - The knockout has a 1 px #000 α0.35 outline so it holds on cyan.
  - The 256 px drop-in `reddog.png` in both sets is the head-only knockout, because the panel shows it at about 48 px.
  - `*.svg`: masters that embed the raster. Nothing is redrawn.
- `app-icon/`: `launcher.ico` (16/24/32/48/256), `launcher.svg` and the PNGs. The glyph is a small button panel. There's no app icon in src yet, and the installer currently uses imageres.dll,15.
- `contact-sheet.png`: both sets side by side on the real button colours, at 256, 48, 32, 24 and 16 px.
- `panel-mock.png`: a rough mock of the panel layout from buttons.json with each set.

## Red Dog source
https://reddogpos.com/red-dog-pos-logo.png. This is the logo shown on the reddogpos.com homepage.

## Notes
- PLCE and Revenue use generic symbols only: no state seals and no agency logos. UltraVNC, ScreenConnect and JarTrek are generic metaphors too.
- Kern measured low white contrast on several fills: cyan 2.05:1, lavender 2.62, salmon 2.50 and gold 2.24. Kern's darker colour tokens haven't been applied because they need approval.
- SVGs were rendered with resvg.
