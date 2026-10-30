BUTTON LAUNCHER
===============

RUN IT
  Installed: Start menu > the launcher's name (or type it in Windows search).
  From this folder: double-click ButtonLauncher.exe (or "Start Launcher.vbs").
  Starting it again while it's running just brings the panels to the front. One tall
  panel opens docked to the right edge of the screen (two separate panels are
  still available: Setup > Layout > Two panels). Right-click any panel for
  options.
  If Windows warns about the file the first time: right-click it > Properties >
  tick "Unblock" > OK. (Do this for Launcher.ps1 too.)

WHAT EACH BUTTON DOES
  RED DOG BACK OFFICE  Finds Red Dog Backoffice by itself (Program Files,
                       C:\Jartrek, C:\RedDog, or a "Red Dog Backoffice"
                       shortcut). If it can't, it asks you once to pick it.
  VIEW REGISTER        Opens UltraVNC Viewer (found by itself, or asks once).
                       v1.4.1: lists only the computers an administrator
                       allows in Setup > Allowed computers (admin)... (no
                       network scan). View only never asks for a password;
                       Interact uses UltraVNC's own password box.
                       To connect straight to a register, edit the button and
                       put e.g. 192.168.1.50:5900 in Arguments.
  INTERNET             Opens Google in your browser.
  EMAIL                Opens your email app. To use Outlook instead: edit the
                       button, set Type to Program, Browse to OUTLOOK.EXE.
                       Optional unread count (v1.4.0, off by default): unlock,
                       right-click > Setup > Unread email count..., tick the box,
                       type your @jartrek.net name and webmail password, Test,
                       then Save. Each Windows user signs in separately; the
                       password is encrypted by Windows for that user only.
                       Right-click Email for Check email now and its status.
                       While there are unread emails the button fades to red
                       (unless Windows animations are off, or you pick Just
                       show the number in Setup). "Pulse the Email button"
                       stops once every email is read.
  USER GUIDE buttons   First click asks you to pick the PDF; after that it
                       just opens it.
  PLCE                 PA State Police Liquor Control Enforcement page.
  DEPARTMENT OF REVENUE  PA Department of Revenue page.
  + Add (2 slots)      Your own buttons: click + Add, pick a Program,
                       Website (http/https) or File, a name and a picture.
                       Right-click to edit or remove. With both empty,
                       right-click > Remove this row; Setup brings it back.
  RESTART SCREEN CONNECT  Restarts the ScreenConnect service. Windows asks for
                       admin permission (click Yes), then a message says
                       whether it worked.
  RESTART COMPUTER     Always asks first (No is the default), then
                       force-restarts. It asks even if "Ask first" is blank.
  If a saved program or PDF isn't on this PC (like after installing on a
  different computer), the button asks you to pick it once, then remembers.

EDIT A BUTTON (no Notepad needed)
  Right-click the button > "Edit this button". At the top pick a Type:
    Program    - Browse to it. Optional Arguments and "Run as admin".
    Website    - a web address (or mailto:). "Test" opens it to check.
    File / PDF - any document; opens in its normal app.
    Script     - a .bat, .cmd, .ps1 or .vbs.
    Built-in action - Restart ScreenConnect service, or Restart computer.
  Any type can have "Ask first (Yes/No)" text. Leave it blank to skip.
  Below that: label (\n = new line), colors (Pick...), height, font size,
  full/half width, and picture. Click Save; it updates right away.
  Other right-click options on a button: Move up / Move down,
  Move button to other panel, Add new button below, Delete this button.

ADD A BUTTON
  Right-click a button > "Add new button below", or right-click empty space >
  "Add new button at end". Two half-width buttons in a row sit side by side.

PICTURES ON BUTTONS
  In the edit window click "Picture..." and pick a png/jpg/ico (it's copied
  into the images folder), or "Use icon" for the program's own icon.
  "Picture spot": left (of the text), above, only (no text), or background.
  The included pictures are in images (PNG, Microsoft Fluent Emoji 3D, MIT
  licence in images\LICENSES). images\svg has only the Red Dog logo drawing.

BUTTON CLICKS
  Buttons light up when you point at them, press in when clicked, and flash
  when something launches. CLICK SOUND: right-click > "Click sound" (off by
  default). For your own sound, put a file named click.wav in this folder.

PANELS
  By default the buttons sit in one tall panel docked to the edge: Top buttons
  at the top, Bottom buttons and the Restarts at the bottom, your own icons in
  the middle. To use two separate panels instead: unlock, right-click a panel >
  Setup > Layout > Two panels, then Setup > Reload.
  In the two-panel layout there are two panels, Top and Bottom. Each one is pinned to a spot on the
  screen (an edge or corner) by percent, not pixels, so it lands in the same
  place on any screen size or scaling (100/125/150/175%). Panels get bigger or
  smaller with the screen, never sit under the taskbar (wherever it is, even
  auto-hide), and shrink to fit if they'd be taller than the screen.
  They re-adjust by themselves when you change resolution, scaling, or
  monitors, move the taskbar, or wake the PC.

  LOCK: Right-click a panel > "Lock panels" (on by default).
    Locked   = can't be dragged, no grey bar, no taskbar button, not in Alt+Tab,
               and right-click shows only "Unlock to edit..." and "Close this
               panel", so nobody can change or delete buttons by accident.
    Unlocked = drag by the grey bar or edge. When you let go it snaps to the
               nearest edge or corner and remembers it. Lock again when done.
  SIZE: right-click > Size > Small / Medium / Large.
  MONITOR: right-click > Monitor > pick one (falls back to the main monitor if
           that one is unplugged).
  Other right-click options: Always on top (per panel), Rename panel,
  Add new panel, Delete this panel (asks first), Build installer, Reload,
  Close this panel, Close all. On a button: "Move button to other panel".
  Closing one panel leaves the other open.
  CLICK SOUND: right-click > "Click sound" (off by default). To use your own
  sound, put a file named click.wav next to Launcher.ps1.

  In buttons.json each panel looks like:
    { "name": "Top", "anchor": "top-right", "offsetX": 0, "offsetY": 0, "gap": 0,
      "monitor": -1, "size": "Medium", "minWidth": 180, "maxWidth": 560,
      "alwaysOnTop": false, "buttons": [ ... ] }
  anchor: top-left, top-center, top-right, middle-left, center, middle-right,
          bottom-left, bottom-center, bottom-right.
  offsetX / offsetY: distance from that edge, in % of the screen (0 = flush).
  gap: extra space in pixels between the panel and the screen edge (0 = flush).
  monitor: -1 = main monitor, 0 = first, 1 = second...
  size: Small, Medium, Large, or a number = % of screen width.
  "locked": true/false at the top of the file controls the lock.
  The installer carries all of this, so panels land right on any PC.

MAKE AN INSTALLER FOR ANOTHER PC
  From the source folder (installed copies don't include the builder):
  right-click a panel > "Build installer..." (or right-click
  Build-Installer.ps1 > Run with PowerShell). It makes "<name> Setup.exe" in
  the installer-output folder with your current buttons and pictures inside.
  Copy that one file to the other PC and double-click it. No admin needed.
  It installs to %LOCALAPPDATA%\Programs\<name>, adds a Start menu shortcut,
  asks once about a desktop shortcut (default No), turns Start with Windows
  on, and adds an uninstaller
  (Settings > Apps, or Start menu > "Uninstall <name>").
  The name comes from "title" at the top of buttons.json.
  WARNING: the installer isn't digitally signed, so Windows SmartScreen will
  say "Windows protected your PC". Click "More info" > "Run anyway".
  Some antivirus tools may also flag it; that's normal for unsigned scripts.

START WITH WINDOWS (without the installer)
  Press Win+R, type  shell:startup  and press Enter. Right-click
  "Start Launcher.vbs" > Create shortcut, and move the shortcut into that folder.

ADVANCED: buttons.json
  (A fresh install starts from buttons.default.json. Reinstalling or upgrading
  never overwrites an existing buttons.json or pictures you added to images.)
  Everything above is saved in buttons.json. You never need to edit it, but
  you can (right-click > "Edit buttons.json in Notepad", then Reload).
  In paths, every backslash must be doubled:  C:\\Users\\Charles\\file.pdf

SET UP THIS PC
  The first time the launcher runs (right after install) a "Set up this PC"
  window lists every button whose program or file isn't on this PC yet, with
  a Pick... button for each. Run it again any time: unlock, then right-click
  a panel > "Set up this PC...".
  If a button's picture file is missing, a small amber dot shows in its corner
  (point at it to see the file name) and it's noted in launcher-error.log.

SAFETY NOTES
  - Website buttons only open http, https or mailto addresses.
  - Restart ScreenConnect always shows the Windows admin (UAC) prompt.
  - The launcher installs per-user in %LOCALAPPDATA%\Programs\<name>. Any
    program running as this Windows user can change Launcher.ps1 or
    buttons.json there, including "Run as admin" and script arguments. So if
    a launcher button ever shows an admin prompt you didn't expect, click No,
    and don't type an admin password into it on a PC you don't trust.
    (A per-machine install to Program Files is not available yet.)
  - Script buttons run with the arguments written in buttons.json, as typed.
  - If Windows shows an admin prompt when you run "<name> Setup.exe", click
    No. The installer is per-user and doesn't need admin; saying Yes would
    install it into the admin account instead.

INSTALL (per-user, no admin)
  Setup puts the launcher in %LOCALAPPDATA%\Programs\<name>, adds a Start menu
  shortcut, and lists it in Settings > Apps (Launcher) with an uninstall.
  It asks once about a desktop shortcut (default No). An update keeps your
  buttons, pictures, desktop shortcut and Start with Windows setting.
  Command line flags: ButtonLauncher-Setup-<version>.exe /DESKTOP /NOAUTOSTART
  (the "<name> Setup.ps1" fallback: -Desktop, -NoAutostart).
  FOR IT: a silent /S install run as SYSTEM or as another admin account installs
  Launcher into that account, not the user's. Run Setup as the person who will
  use it, without elevation (no "Run as administrator").
  START WITH WINDOWS is ON by default (HKCU Run value "ButtonLauncher").
  To change it: unlock, right-click a panel > "Start with Windows".
  Uninstall removes the shortcuts, the Run value, the Settings > Apps entry
  and the launcher's folder, including your buttons and any pictures you added.
  ButtonLauncher.exe and Setup.exe are not code-signed, so Windows SmartScreen
  may say "Windows protected your PC" the first time: click "More info" >
  "Run anyway" (only for copies you got from a trusted source).
