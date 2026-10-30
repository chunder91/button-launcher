# Button Launcher release notes

## v1.4.1: View Register shows only allowed computers

Pending review (build of 2026-10-30). Includes everything in v1.4.0.

- **Only the computers you allow.** View Register now lists only the computers an administrator puts in Setup > Allowed computers (admin)... (one per line: Name, address, for example `Register 1, 192.168.1.21`). Saving asks Windows for an administrator, and the list applies to every Windows user on the PC; users can't add, remove or rename computers. There is no network scan any more: each listed computer shows Online or Offline from a quick check (F5 checks again). Until a list is saved, View Register says "No computers have been allowed yet. Ask your administrator."
- **View only never asks for a password.** It connects with no password. If your computers do need a view-only password, save it once in Setup > View-only password (optional, only if your computers need one)... and it's used for every allowed computer.
- **Interact still uses UltraVNC's own password box** (nothing is filled in for you). Fix: if UltraVNC's own settings for that computer use an encryption plugin, the launcher now passes the same plugin, so it connects the same way as opening the computer in UltraVNC directly. The launcher's log notes which viewer it started.

## v1.4.0: unread email count on the Email button

Pending review (build of 2026-10-29). Includes everything in v1.3.0. Waiting on the ClaudeCode and Lockjaw reviews, Charles's OK and a test on a real Windows PC. **v1.4.0 replaces v1.3.0, which was pulled.**

- **Off unless you turn it on.** Setup > Unread email count... (or right-click the Email button > Unread email count... once it's on). Nothing checks email, and nothing is sent anywhere, until someone turns it on for their own Windows login.
- **Your own Jartrek email.** Type your full email address (the box starts with @jartrek.net; type your name in front of it, or change it) and the same password you use for webmail, press Test, then Save. Save only works after a good Test. The password is saved for this Windows user only, encrypted by Windows, and never in buttons.json or the log.
- **Shared PCs.** The setup window warns that everyone who uses this Windows login on this PC will see how many unread emails the account has. The address shows only in the setup window, never on the button.
- **The count.** A small black badge with a yellow number on the Email button shows how many unread emails are in your Inbox (99+ for 100 or more). It checks every 3 minutes by default (pick 2, 3, 5, 10, 15 or 30 minutes in the same window; it changes as soon as you Save), again 1 and 3 minutes after you click Email, once after the PC wakes up, and whenever you pick Check email now.
- **While there are unread emails:** Pulse the Email button (the default) or Just show the number. With "Pulse the Email button" chosen, the button slowly fades to red (unless Windows animations are off, or you pick Just show the number in Setup) and back (about every 3.5 seconds) the whole time your Inbox has unread email, and stops as soon as there's none. The number shows either way. It doesn't move while you're editing the panel or when the panel is hidden, and with Windows animation effects off it just shows the number (Setup says so, and your choice is kept for when they're back on; it notices the change right away). If you had already set this up, any moving choice is now Pulse, and Just show the number stays as it was.
- **Problems are quiet and clear.** A small grey ring replaces the number when it can't sign in or can't reach email for about 6 minutes. Point at the button, or right-click it, to see why. If the sign-in fails it stops trying (so it can't lock your account) until Test or Check email now works.
- **Turning it off** (untick the box, Save, Yes) clears the badge and forgets the login on this PC.
- Clicking Email still opens your email exactly as before.
- **Start Jartrek Security is gone.** In its spot there's a row of 2 buttons you set up yourself: click **+ Add** (or right-click > Add a button here...) and pick a Program, a Website (http or https) or a File, a name and a picture. Right-click a button to edit it or remove it. With both empty, right-click > Remove this row hides the row and the Restarts move up; Setup > Add the row of 2 custom buttons brings it back. These buttons never run scripts, take no command-line arguments and never run as admin. Upgrading keeps every other button as it is and saves your old buttons.json as buttons.json.pre-v1.4.bak.
- **If you had set up Start Jartrek Security** (picked its program), your setup isn't lost: it becomes the left button of the new row, with the same name, picture and program, and the right spot is empty. Any command-line arguments and "run as admin" are not carried over (custom buttons never use them); if you need them, add the program again as a regular button. If its target is something a custom button can't open (a script or shortcut, for example), the old button stays exactly where it was. Only the untouched, never-set-up button is removed.
- **Custom buttons are strict about what they open.** A Program must be an .exe. A File must be a document, picture or media file (.pdf, .txt, .csv, .docx, .xlsx, .pptx, .png, .jpg/.jpeg, .gif, .bmp, .webp, .tif/.tiff, .mp3, .wav, .m4a, .mp4, .mov, .wmv, .avi); older or macro Office files (.doc, .xls, .ppt, .rtf, .odt, .ods, .docm and so on), archives, disk images and anything else are refused. Paths with * ? [ ], a ':' after the drive letter, or a name ending in a dot or space are refused, and %VARIABLES% are checked after they're filled in. Web addresses can't contain a user name before the site (user@site). The "can't find it, pick it" window follows the same rules.
- **Custom row, polish:** while the panels are locked, an empty spot is plain blank space (nothing to click), and with both spots empty the row disappears until you unlock. Removing a button asks first (No is the default). "Remove this row" says to remove both buttons first when it can't be used yet. Long button names stop at 3 lines with "..."; point at the button to see the full name.
- **View Register finds computers on a local-only network.** The scan now also checks a wired or Wi-Fi connection that has no internet (no gateway), like a separate register network. Each network is still asked about once, and only its own /24 is checked. VPN, virtual and self-assigned (169.254) connections are still skipped.
- **For IT: install as the user.** Setup installs per user. A silent `/S` install run as SYSTEM or as another admin account installs Launcher into that account, not the user's. Run Setup as the person who will use it, without elevation (no "Run as administrator").
- **Fixed:** pressing Test in Setup > Unread email count... showed "The property 'busy' cannot be found on this object". The same kind of mistake also put the View Register "More" menu in the wrong place; both are fixed, and the tests now check for it.
- **Fixed:** opening Setup > Unread email count... showed "The property 'Background' cannot be found on this object". The same fix covers Setup > View-only password and Add a computer.
- **Email Test messages say what went wrong.** "Can't reach the mail server" now means only that Launcher couldn't connect. A certificate problem says Launcher couldn't confirm it's the real mail server, so it didn't send your password (check the PC's date and time). An answer Launcher didn't expect says to press Test again and tell your IT contact if it keeps happening, a test that stopped early says it's a Launcher problem, not your password, and something going wrong inside Launcher says so and asks you to tell your IT contact Each failed Test also writes one line to launcher-error.log with the failing step (for example `step=login reply=NO`), never your address, password or the server's text.
- **Sign-in uses AUTHENTICATE PLAIN** when the mail server offers it (jartrek.net does), so any password characters go through unchanged; other servers still get LOGIN.

### Known issues
- CSV files on a custom button open in Excel (or whatever opens .csv on that PC). Excel warns before running anything in a file that looks like a formula; say no if you didn't expect it.
- Custom buttons need the full long path. Short 8.3 names like C:\PROGRA~1\... or X~1.DOC are refused; Browse... always gives the full path.
- Custom Program and File buttons may point at a network share or mapped drive (\\server\share\..., Z:\...). That's allowed on purpose, the same as other buttons: the share is only contacted when you click the button, and clicking it sends your Windows sign-in to that share, the same as opening it in File Explorer. Only point buttons at shares you trust.

## v1.3.0: find computers you can view automatically, new 3D look (PULLED)

**Pulled on Oct 29, 2026:** its Setup windows (View-only password, Add a computer) could crash with "The property 'Background' cannot be found on this object". Fixed in v1.4.0, which replaces it. The GitHub pre-release was deleted; the v1.3.0 tag is kept for history.

Released Oct 29, 2026 as a private pre-release. Includes everything in v1.2.0. ClaudeCode and Lockjaw passed; Kern's and Squint's fixes are in. Still needs a test on a real Windows PC.

### New look (Fluent 3D)
- **Glassy panel and 3D buttons.** The panel is dark glass with a thin light edge. Buttons have a soft top shine, a gentle color fade and colorful 3D icons. The Red Dog button keeps the real Red Dog logo.
- **Glow on hover.** A button lifts and glows in its own color when you point at it, and presses in when you click. It's all cheap drawing, so the launcher still uses next to no CPU when idle.
- **Restarts look the same as before:** dark, with the red outline, at the bottom. Restart Computer still asks first.
- Your own button colors still work; they get the same 3D treatment.
- **Computer list is clearer.** Before any scan it says "Not scanned yet" instead of "No computers found". The scan question is in plain words, and Rescan defaults to Yes. Add a computer is one small window (address, optional name); Cancel adds nothing.

### Find computers you can view

- **View Register finds computers you can view.** Clicking it opens a list of PCs on this network that answer as UltraVNC servers. The last list shows straight away; Rescan (F5) looks again. It only looks at this PC's own private network (normally the 254 addresses next to it), gently, and only when the list opens and is over a day old, or when you press Rescan.
- **View only or Interact.** Enter or double-click is View only. Both open the UltraVNC Viewer scaled to fit your screen.
- **Names and pins.** Name a computer (e.g. "Register 1") to pin it to the top, or add one by hand.
- **View-only password, saved once.** The first View only asks for the shared view-only password (or "No password"). It's saved for this Windows user only, encrypted by Windows. Change or clear it with Setup > View-only password (for viewing computers)... Interact always asks for its own password.
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
