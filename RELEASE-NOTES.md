# Button Launcher release notes

## v1.3.0: find registers automatically, new 3D look

Pending release (build of 2026-10-29). Includes everything in v1.2.0. ClaudeCode and Lockjaw passed; Kern's and Squint's fixes are in. Waiting on Charles's OK and a test on a real Windows PC.

### New look (Fluent 3D)
- **Glassy panel and 3D buttons.** The panel is dark glass with a thin light edge. Buttons have a soft top shine, a gentle color fade and colorful 3D icons. The Red Dog button keeps the real Red Dog logo.
- **Glow on hover.** A button lifts and glows in its own color when you point at it, and presses in when you click. It's all cheap drawing, so the launcher still uses next to no CPU when idle.
- **Restarts look the same as before:** dark, with the red outline, at the bottom. Restart Computer still asks first.
- Your own button colors still work; they get the same 3D treatment.
- **Register list is clearer.** Before any scan it says "Not scanned yet" instead of "No registers found". The scan question is in plain words, and Rescan defaults to Yes. Add a register is one small window (address, optional name); Cancel adds nothing.

### Find registers

- **View Register finds the registers.** Clicking it opens a list of PCs on this network that answer as UltraVNC servers. The last list shows straight away; Rescan (F5) looks again. It only looks at this PC's own private network (normally the 254 addresses next to it), gently, and only when the list opens and is over a day old, or when you press Rescan.
- **View only or Interact.** Enter or double-click is View only. Both open the UltraVNC Viewer scaled to fit your screen.
- **Names and pins.** Name a register (e.g. "Register 1") to pin it to the top, or add one by hand.
- **View-only password, saved once.** The first View only asks for the shared view-only password (or "No password"). It's saved for this Windows user only, encrypted by Windows. Change or clear it with the picker's "View-only password..." button or Setup > View-only register password. Interact always asks for its own password.
- Old setups: a View Register button that already had an address in its arguments keeps working the old way.

## v1.2.0 (modern-b): new modern look

Not released yet. It's waiting on the ClaudeCode and Lockjaw reviews and a test on a real Windows PC.

### What's new
- **Modern buttons.** The buttons are flat now, with rounded corners, on a dark panel. They keep their familiar colors, a bit deeper so the words are easier to read. Labels use Title Case ("View Register" instead of "VIEW REGISTER"), and each icon sits to the left of its words.
- **Red Dog logo.** The Red Dog button shows the full-color logo on a small white plate so it stands out.
- **Feels like a button.** A button lifts slightly when you point at it and dips when you click it. These effects are quick and never slow down opening a program.
- **Restarts are separate.** Restart ScreenConnect and Restart Computer now sit together at the bottom under "Restarts". They're dark with a red outline so you don't hit them by accident. Restart Computer still asks first, and No is the default. Start Jartrek Security moved above them.
- **Shows what still needs setup.** A small orange dot on a button means that program isn't set up on this PC yet. Point at the dot to see that.
- **Clear editing mode.** When the panels are unlocked, an orange "Editing" bar shows at the top and the buttons get dashed outlines. Lock the panels and they look clean again.
- **Tidier right-click menu.** Everyday items come first, then the editing items, then a "Setup" menu (PC setup, installer, Reload), then Close.
- **Keyboard.** Tab moves between buttons with a white outline, and Enter opens the selected one.

### Start with Windows
It's still on by default. To turn it off, unlock the panels, right-click a panel and uncheck **Start with Windows**. Uninstalling also removes it.

### Your setup is kept
Reinstalling or upgrading keeps your buttons, the programs you picked, and any pictures you added or changed. If your bottom panel was still in the original order, Start Jartrek Security moves above the restarts automatically. If you had moved things around, your order stays as it is.

### If a PC feels slow
The rounded panel corners take a little more work for Windows to draw. On a slow PC, right-click a panel, choose **Setup > Square panel corners (for slow PCs)**, then **Setup > Reload**.

### Windows "protected your PC" message
The launcher isn't signed with a paid certificate, so the first time you run a downloaded copy Windows may show "Windows protected your PC". Click **More info**, then **Run anyway**. That's expected for this program. It only happens once per copy.

### New: bring the launcher forward any time
- **Tray icon.** The launcher now has a small icon by the clock, at the bottom right of the taskbar. If it's hidden, click the ^ arrow. Click the icon to bring the launcher to the front, even when Red Dog or a browser fills the screen. Right-click it for **Show**, **Lock/Unlock**, **Settings** and **Exit**.
- **Ctrl+Alt+L.** Press Ctrl+Alt+L anywhere to bring the launcher to the front. If another program already uses that shortcut, the tray icon still works.
- **Show desktop (Windows key + D)** may hide the launcher like any other window. Press Ctrl+Alt+L or click the tray icon to bring it back.

### New: one-panel layout (now the default)
New installs open as **one tall panel docked to the edge of the screen**. If you already chose a layout, it is kept. Your top buttons sit at the top, your bottom buttons and the Restarts sit at the bottom, and the space in between shows your desktop. Clicks in that empty space go straight through to whatever is behind it.
- **Switch layouts:** unlock the panels, right-click a panel, choose **Setup > Layout > One panel, docked to the edge** (or **Two panels** to go back), then **Setup > Reload**. Two panels are still available the same way.
- **Your own icons in the middle.** The middle starts empty. To add an icon, unlock, right-click the middle and choose **Add icon...**. It can be a program, website, file or script, and it shows that program's own icon.
- **Remove an icon:** unlock, right-click the icon and choose **Remove this icon**. An **Undo** button shows for 5 seconds in case you didn't mean it.
- **Move icons:** unlock, then drag an icon onto another spot. You can also right-click it and choose **Move earlier** or **Move later**.
- **Lots of icons?** If they don't all fit, a **+N more** button opens the rest.
- The panel isn't "always on top" unless you turn that on. It fills the height of the screen it's on and re-docks itself when the screen, the scaling or the taskbar changes.
