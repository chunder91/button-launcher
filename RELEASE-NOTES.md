# Button Launcher release notes

## v1.4.12 review only: View Register status (NOT RELEASED)

Not tagged, not published, not installed. Built for review from v1.4.11 `37ea47df364fdfad29b07703fdd76fcbb925fdf4`. ClaudeCode, Lockjaw, Kern, and Squint have not reviewed this build. This note does not certify those reviews.

- The Status column (the existing 160 px column; window size, 38 px rows, and the other columns are unchanged) shows a mark plus a 16 px SemiBold label: green filled circle **Online** (`#22C55E` / `#4ADE80`), red square **Offline** (`#F87171` / `#FECACA`), gray hollow circle **Not checked** (`#B4B4BC`). The green pill on the left stays the selection mark.
- The header is **Status**, not Seen, so the word Seen is not read as Online. The last check time, and what that check found, is in the row tooltip and the row's accessible name.
- **Online** means only: within the last 60 seconds, a TCP connection to that allowed computer's host and port finished, and the peer sent exactly an RFB greeting (`RFB ddd.ddd`, 12 bytes). The launcher sent nothing. Online does not mean a password was accepted, a view-only or interact session is open, or the screen is available.
- **Offline** means that same check finished and the connection was refused, or the peer finished responding with something that was not an RFB greeting.
- **Not checked** means there is no result yet, a check is in progress, the check timed out, it was cancelled, the address cannot be checked, the check did not finish, or the last result is older than 60 seconds (or more than 5 minutes in the future). None of those are Offline. Being on the allowed list is not Online.
- The check is the existing allowed-list check: only those computers, the same 300 ms shared budget, at most 12 bytes read, nothing sent. It runs off the UI thread when the window opens and when F5 is pressed. F5 during a check cancels that check without waiting and starts another; a late result from the old check is ignored. Closing the window cancels it the same way (BeginStop, sockets closed in finally). After 60 seconds the labels repaint to Not checked. That timer does not connect.
- View only on an allowed computer is given a password file even when the row is stale or Not checked, and even when it is listed by name. The file uses the per-user DPAPI override, or the built-in default when no override is saved. A computer that is not on the allowed list is not given one. Interact still asks for the full password. View only closes View Register as soon as the viewer has started. When a password box is expected (Interact, or View only with no password file), View Register stays in front until that box is focused, or for up to 2 seconds, and then it closes. The focus handoff joins this thread to the current foreground thread, then calls BringWindowToTop and SetForegroundWindow, then asks the dialog to focus its password edit. It does not type into the box. View only with a password file is started as `-config "<temp .vnc>" -viewonly -autoscaling` with no host on the command line, because UltraVNC reads the `[connection]` password only when no host was already given. Interact and View only without a file stay `host:port` first. Shell.Application with the ProcessStartInfo fallback, and `-autoscaling`, are unchanged.
- Review fixes, still not released: the count, checking, and fault line is written after the list is rebuilt, so that rebuild cannot replace it with "Pick a computer". Moving the selection keeps the counts and adds one short line for the selected computer. When a result expires, the counts are rewritten, including while a check is still running, and the same words are not announced again. The line under the list says Online means VNC answered, not signed in or the screen, and Offline is the VNC port, not the whole computer. That line and the counts share the old footer height, so the list still has room for 4 rows at the 410 px minimum. An empty allowed list says "No computers have been allowed yet." The status announcement includes the selected computer's line, and that line keeps at least 180 px beside the counts. Cancelling a check still does not wait on the window; the read gives up within a short slice and the socket is closed.

## v1.4.11: Interact closes View Register
- Charles: "when they click interact and connect to VNC i want the View register screen to close". After Interact starts the viewer, View Register closes; the log says "View Register closed after Interact start". If the viewer can't be started (no address, viewer missing, the start fails), View Register stays open and shows the problem as before. View only is unchanged, and so are the viewer arguments and how it's started.
- The start-up diagnostics (parent chain, environment) are now gathered in the background, so they never hold up the panels; the launcher writes them itself when they're ready, and stops the lookup if it hangs or the launcher exits.
- While a viewer start is in progress, View only and Interact are briefly disabled, so a double click can't start two viewers.

## v1.4.10: View Register fits the remote screen again
- The viewer gets -autoscaling again, last on the line: Interact `host:port -autoscaling`, View only `host:port -viewonly -autoscaling`, saved password `host:port -config "<temp .vnc>" -viewonly -autoscaling`. The address is still always first, and the 1.4.9 Windows shell start (which fixed Interact) is unchanged.
- View Register's computer list is easier to read: names and addresses 14 -> 16 px, Seen 13 -> 16 px (hover it for the full text), column headers 12 -> 14 px; rows 32 -> 38 px tall; the Address and Seen columns are wider (180 and 160 px) so 192.168.20.51:5900 and "Not found last scan" fit, and the headers stay over their columns when the scrollbar shows. Colours are unchanged; the window can be made 410 px tall at the smallest, still showing at least 4 rows.
- Start-up diagnostics: the parent-chain lookup is now one process query (1 s timeout) instead of one per parent.

## v1.4.9: View Register always hands the viewer its address; launch log shows the exact arguments

Pending review (build of 2026-11-04). Includes everything in v1.4.8.

- Diagnostics (no behaviour change): the start-up line in launcher-error.log now reads `Launcher 1.4.9 started (elevated=..., 64-bit=..., cwd="...", parents="...")`, with the parent processes as exe names only, and each viewer start logs `elevated=...`. A second start-up line lists TEMP, APPDATA, USERPROFILE, the number of PATH entries, __COMPAT_LAYER and the session. The viewer is now started through Windows' Shell.Application ShellExecute (the same shell call Win+R uses; normal window, the viewer's own folder, the same single argument string), falling back to a normal ShellExecute start if that fails; the log says which method was used. If Button Launcher runs as administrator, the View Register status line says "Button Launcher is running as administrator; restart it normally for VNC." and the viewer is still started as before.
- View Register buttons, option B "with icons" (Charles 10:34 AM): two equal glossy tiles, 271 x 72 px with a 16 px gap. View only is green #0C6941 with an eye, Interact is blue #095F84 with a hand (Lucide icons, ISC licence, drawn as built-in shapes). 24 px labels with a 3.2 px dark outline, 8 px from the icon; hover 10% lighter; pressed 12% darker with no gloss; the 18/14 focus ring; the panel's gloss and sparkle. With no computer selected both are dimmed (no gloss, #C4C4C8 label) and the status line says "Pick a computer to view or control it." Enter on a list row is still View only and Ctrl+Enter Interact; Tab goes list, View only, Interact; Alt+V / Alt+I. The window is 42 px taller so the list keeps its rows; on a small screen the list shrinks but always shows at least 4 rows. What the buttons do is unchanged.

- View Register: `-autoscaling` is no longer sent. Charles's log on 1.4.8 showed `192.168.20.51:5900 -autoscaling` still left VNC Server blank, while Win+R `vncviewer.exe 192.168.20.51:5900` works. Interact now sends exactly `<host>:<port>`, View only `<host>:<port> -viewonly` (`-config "<temp .vnc>"` after host:port only with a saved view-only password; that form is not yet proven on his viewer).
- Interact and View only build ONE argument string (`<host>:<port> [-config "<temp .vnc>"] [-viewonly]`) and pass exactly that string to the viewer, instead of a list Windows PowerShell re-joins. The launcher refuses to start the viewer, with a plain message, if the computer's address is empty or not valid, or if the arguments don't start with `<host>:`.
- Review follow-ups: if Windows returns no process for the viewer, that is logged and the temp .vnc is deleted at the fixed 8 s (no false "viewer closed"); a viewer in a drive root starts in `C:\`; a vncviewer.exe you pick by hand must pass the same check as a found one (exactly vncviewer.exe, a plain file on this PC's own drive), or it is refused with a message (LJ M42-I1).
- The host and port are read the same way whether the picker row is an object or a table (`Get-VncRowHost` / `Get-VncRowPort`).
- v1.4.8 follow-ups: the email badge for 42 or 99+ sits 4 px higher so more of the envelope shows; every shipped button name is tested to fit whole at 105 and 244 px; any name that still doesn't fit (for example on a panel scaled down) ends in "..." with the full name in a tooltip; label width allows for the 1 px edge on every button (2 px border on restart buttons).
- The viewer is started like a Win+R or manual start: ProcessStartInfo with UseShellExecute, the viewer's own folder as working directory, one exact argument string, never elevated, no environment changes.
- launcher-error.log gets one more line per launch, read back from the ProcessStartInfo just before Start(): `VNC viewer start: exe="<path to vncviewer.exe>" args="<exact argument string>" dir="<viewer folder>" shell=True`. A saved-password file shows as `<temp .vnc>`; no password is ever on the command line or in the log.


Review follow-ups (Kern, ClaudeCode, Lockjaw):
- View only and Interact icons now sit visibly 8 px from their labels, and both tiles' gloss band ends 4.5 px above the top of the icon (20 px).
- View Register can't be made narrower than 616 px, so the tiles never clip; its height floor matches the 402 px minimum.
- The tiles' pressed-state watcher is removed when View Register closes.
- The start-up diagnostics (parent chain, environment) are written just after the panels show, and the parent-chain lookup stops after about 2 s.
- launcher-error.log is moved to launcher-error.log.old at start-up once it's past 1 MB.
- Known trade-off: because the viewer is now started through the Windows shell, the launcher no longer gets a process for it, so the hint after a saved view-only password fails can't show.

## v1.4.8: glossy buttons (style C, "rounder candy gloss")

Review status (build of 2026-11-04): 164bf87 passed ClaudeCode (code) and Lockjaw (security: C0 H0 M0 L0); Kern and Squint said ship with fixes, applied in 2871b6b. The first real Windows captures of 2871b6b (100%, and a 144 DPI render) showed the glossy style is right but found two bugs, fixed in this build: "Restart ScreenConnect" split mid-word, and the "99+" email badge covered the Email label. This build goes back to ClaudeCode, Lockjaw, Kern and Squint and needs a fresh Windows look-check (a true 150% capture is still outstanding). Includes everything in v1.4.7.

- Windows capture fixes: button text never breaks in the middle of a word any more (long words shrink to fit, or end in "..." with the full name in the tooltip), and the restart buttons' red border is counted when fitting their text, so "Restart ScreenConnect" fits whole. The email count badge grows to the left over the envelope instead of onto the word "Email"; it keeps the same sizes and colours.
- Follow-up fixes: the small grey second lines (such as "Version 11") are now full strength with a thin dark outline so they are easy to read; the outline thickness and gloss are worked out after the text has its final size; buttons in the same row get the same gloss height; margins no longer depend on the PC's language settings; the sparkle check knows about centred labels.

- Charles picked style C (8:44 AM Nov 4). Every button keeps its own colours, size, gaps, fonts, auto-fit and layout. Only the finish changes:
  - 18 px corners (never more than half the button's height)
  - a soft white gloss band at the top that stops at least 2 px above the text
  - a soft inner glow
  - light labels get a dark outline (2.4 px under 16 px, 3.2 px at 16 px and up); dark labels such as Department of Revenue stay as they are
  - one small static sparkle near the top-right corner
- Hover is 10% lighter. Pressed is 12% darker with no gloss. Keyboard focus shows a 2 px white and 2 px dark ring inside the button.
- Pictures, edit mode, the email count and the restart buttons work as before. No new files, no effects and no animation on the gloss.

## v1.4.7: viewer started with a bare host:port (no -connect)

Pending review (build of 2026-11-04). Includes everything in v1.4.6.

- View Register: the viewer is started as `<host>:<port> [-config "<temp .vnc>"] [-viewonly] -autoscaling`, address first and no `-connect`. Charles (8:22 AM Nov 4): Win+R `"C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe" 192.168.20.51:5900` connects and accepts his password, while `-connect 192.168.20.51:5900 -autoscaling` left VNC Server blank and the password got "auth failed". Ports below 100 are still refused.
- The not-found re-search throttle treats a clock that moved backwards as expired (CC D1).
- The chip drag-and-drop handler uses `[0-9]` (CC I1). A viewer version number too large to read is treated as unknown instead of stopping the viewer from being found (CC I2).

## v1.4.6: View only says why it asks; viewer found after install; password dialog tidy-up

Pending review (build of 2026-11-04). Includes everything in v1.4.5.

- View only: when the viewer is going to ask for the password, the picker's status line (and the log) says why: no view-only password is saved, the computer is listed by name (list it by IP address in Allowed computers), or it didn't answer the quick check (press F5). Never the password itself (Squint 1).
- UltraVNC Viewer installed while the launcher is open is now found: a "not found" result is searched again when View Register opens and on every View only / Interact click (Squint 2). The not-found message asks a plain yes/no question.
- Setup > View-only password (Charles, 7:55 AM Nov 4): short intro, a visible "Password" label, a 12 px note "Only used for computers listed by IP address. UltraVNC uses only the first 8 characters.", status text in #B4B4BC announced to screen readers, and "Remove password" (was "No password") shown only when one is saved; it keeps the dialog open and says "Saved password removed. View only will ask for one." (Squint 5, Kern).
- Allowed computers intro: "Use IP addresses if you want View only to use the saved password."
- Setup menu shows "Button Launcher 1.4.6" as a disabled first item.
- Remove password checks that the password is really gone and says so if it is still saved (LJ M47-I1). A not-found viewer is searched again (and logged) at most once every 30 s (LJ M47-I2, CC N2). Prefix, viewer-version and mail-count parsing use [0-9] (CC N3).
- Port parsing uses `[0-9]` and `\A...\z` (LJ M46-I2).

## v1.4.5: allowed computers save again

Pending review (build of 2026-11-03). Includes everything in v1.4.4.

- Allowed computers: saving a second time failed with "Not saved (code 27)". The elevated writer passed `$null` as File.Replace's backup path; PowerShell turns that into an empty string, which .NET refuses. It now passes [NullString]::Value like the rest of the launcher.
- The allowed-list editor says plainly when a port is below 100.
- Address, name and banner checks use `[0-9]` and `\A...\z` throughout (a trailing newline is refused).

## v1.4.4: View Register starts UltraVNC with -connect

Pending review (build of 2026-11-03). Includes everything in v1.4.3.

- View only supplies the view-only password again (Charles, 3:49 PM): enter it once per Windows user in Setup > View-only password (for viewing computers)... It is stored with DPAPI (this user only) in %LOCALAPPDATA%\ButtonLauncher\vnc-viewonly-v2.dat with an owner-only ACL, and handed to UltraVNC in a short-lived owner-only .vnc (`-connect <host>:<port> -config "<temp .vnc>" -viewonly -autoscaling`) that is deleted a few seconds after the viewer opens. Leftovers are deleted at start-up. Never on the command line or in the log (the log says only saved/none). With no password saved, View only behaves as before (the viewer asks). Interact is unchanged and asks.
- The saved view-only password is only used for computers listed by IP address; for a computer listed by name the viewer asks (LJ M44-L1). Ports below 100 are also refused in the allowed list and saved computers (LJ M44-I2).

- View Register: the viewer is now started as `-connect <host>:<port> [-viewonly] -autoscaling`. Charles's UltraVNC Viewer 1.5.0.0-dev left VNC Server blank for the bare `<host>::<port>` form; his Win+R test of `-connect 192.168.20.51:5900 -viewonly` filled it in (3:36 PM, Nov 3).
- Allowed computers: the elevated save now reports which step failed (codes 21-27 with a plain message) instead of a bare "code 2"; the old list is kept.
- Custom VNC ports below 100 are refused (with one colon UltraVNC reads them as display numbers).

## v1.4.3: finds UltraVNC Viewer in Program Files

Pending review (build of 2026-11-03). Includes everything in v1.4.2.

- **Finds the viewer by itself.** At start-up Launcher looks for `vncviewer.exe` once in Program Files and Program Files (x86): first `uvnc bvba\UltraVNC` and `UltraVNC`, then only folders named like `uvnc` / `UltraVNC` (one or two levels down, never a full search). A viewer path you picked yourself still wins when it is valid. If several are found, the newest version is used.
- **Clear message when it's missing.** If no viewer is found, View only and Interact say "UltraVNC Viewer wasn't found in Program Files" and offer to pick `vncviewer.exe`.
- **Better log.** launcher-error.log now notes the launcher version at start-up, which viewer was used and how it was found (your pick, a known folder, the search, or the Windows App Paths entry), its version, and the exact viewer arguments for every View only / Interact (never a password; none is sent).
- The computer is still passed as `address::port`, as in v1.4.2.
- Review fixes: a saved viewer path is used only if it is a real `vncviewer.exe` on this PC (a saved shortcut or other file is ignored and logged, and the search is used instead); "Set up this PC" no longer saves a shortcut for View Register; the search stops after 5000 folders or 2 seconds (logged).

## v1.4.2: email address placeholder fix

Pending review (build of 2026-11-03). Includes everything in v1.4.1.

- **Setup > Unread email count: the grey `name@jartrek.net` placeholder now hides** whenever the Email address box has text (typed, pasted, the `@jartrek.net` start, or a saved address). In v1.4.1 it stayed on top of the address because the Pulse hint reused its variable.
- **View Register now hands UltraVNC the computer you picked** (`address::port`) for both View only and Interact. In v1.4.1 View only could start the viewer with only a temporary settings file, and on Charles's PC the viewer showed a blank VNC Server and asked for a password for `:5900`. No password is ever sent (the registers have none). If the viewer still shows its own Password box, that computer's UltraVNC server is set to require one.
- **Bigger button text.** Labels on the main panel start larger (16 / 20 / 26 px) and each one shrinks only as much as it must to fit its tile. Half tiles in one row share the same size, a label wraps to up to 3 lines before it shrinks (never below 12 px, or 13 px on 3 lines); a row can lower a label by at most 2 px, and "(needs admin)" stays together. Only a label that still does not fit at 12 px ends in "...", with the full name in its tooltip; Narrator always reads the full label.
- **Setup > View-only password... is gone.** It is no longer used, and Launcher deletes any old saved view-only password file at start-up without reading it.

## v1.4.1: View Register shows only allowed computers

Pending review (build of 2026-10-30). Includes everything in v1.4.0.

- **Only the computers you allow.** View Register now lists only the computers an administrator puts in Setup > Allowed computers (admin)... (one per line: Name, address, for example `Register 1, 192.168.1.21`). Saving asks Windows for an administrator, and the list applies to every Windows user on the PC; users can't add, remove or rename computers. There is no network scan any more: each listed computer shows Online or Offline from a quick check (F5 checks again). Until a list is saved, View Register says "No computers have been allowed yet. Ask your administrator."
- **View only no longer pops up the launcher's own password box** the first time; it connects with -viewonly and no password, as the registers have none. A saved view-only password (Setup, optional) is still sent only to a computer that answered the quick online check in the same View Register window.
- **Interact still uses UltraVNC's own password box** (nothing is filled in for you, and the launcher has no password box of its own for it). To help find why Interact was refused, launcher-error.log now notes the exact viewer program and arguments used for each View only / Interact (never a password).

## v1.4.0: unread email count on the Email button

Pending review (build of 2026-10-29). Includes everything in v1.3.0. Waiting on the ClaudeCode and Lockjaw reviews, Charles's OK and a test on a real Windows PC. **v1.4.0 replaces v1.3.0, which was pulled.**

- **Off unless you turn it on.** Setup > Unread email count... (or right-click the Email button > Unread email count... once it's on). Nothing checks email, and nothing is sent anywhere, until someone turns it on for their own Windows login.
- **Your own Jartrek email.** Type your full email address (the box starts with @jartrek.net; type your name in front of it, or change it) and the same password you use for webmail, press Test, then Save. Save only works after a good Test. The password is saved for this Windows user only, encrypted by Windows, and never in buttons.json or the log.
- **Shared PCs.** The setup window warns that everyone who uses this Windows login on this PC will see how many unread emails the account has. The address shows only in the setup window, never on the button.
- **The count.** A small black badge with a yellow number on the Email button shows how many unread emails are in your Inbox (99+ for 100 or more). It checks every 3 minutes by default (pick 2, 3, 5, 10, 15 or 30 minutes in the same window; it changes as soon as you Save), again 1 and 3 minutes after you click Email, once after the PC wakes up, and whenever you pick Check email now.
- **While there are unread emails:** Pulse the Email button (the default) or Just show the number. With "Pulse the Email button" chosen, the button slowly fades to red and back (about every 3.5 seconds) the whole time your Inbox has unread email, and stops as soon as there's none. The number shows either way. It doesn't move while you're editing the panel or when the panel is hidden, and with Windows animation effects off it just shows the number (Setup says so, and your choice is kept for when they're back on; it notices the change right away). If you had already set this up, any moving choice is now Pulse, and Just show the number stays as it was.
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
