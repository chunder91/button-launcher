# One-panel launcher mockup: UX pass (Squint), Oct 29 2026, 10:08 AM ET
Reviewed compare.png, the one-panel normal, edit and small frames, and notes.md (box mockups, not Windows captures).

**Verdict: good idea, OK to build behind `"layout": "single"` with the two-panel layout as the default, with 1 Major and 4 Minors.** Whether to switch to it is Charles's call after he tries it on a real PC.

## Your 4 questions
- **Is it clear what's clickable?** Mostly yes. The chips have a solid fill, so they read as buttons, and empty gaps passing clicks through to the desktop is the right call. One risk: chips floating over the wallpaper look a lot like real desktop icons, so staff may try Explorer things like right-click > Delete or dragging them to the Recycle Bin. That's covered by Minor 3 below.
- **Is the edit flow obvious?** Add and remove are obvious. Reordering is less so, because the ⠿ handle is tiny. See Minors 1 and 2.
- **Small-screen "N more":** the behaviour should be a button, not a scroll. See Minor 4.
- **Not always-on-top by default:** I agree, because a tall topmost strip would cover the scrollbars and close buttons of maximized apps. But that makes the Major below necessary.

## Findings
1. **Major: with an app maximized, there's no way to get the launcher back.** It isn't topmost, and while locked it has no taskbar button and doesn't show in Alt+Tab. Once Red Dog or a browser is maximized, staff have to minimize everything to reach it, and a single tall window makes that happen all the time. Fix: give it one way to come forward, and ideally both. (a) A tray icon whose click brings the launcher to the front until the next launch. (b) A hotkey, for example Ctrl+Alt+L. Also test that Win+D (show desktop) leaves the launcher visible, so "show desktop" always lands on it.
2. **Minor: the Editing bar text gets cut off before the important part.** It shows "Editing: right-click a button to change it. L..." with "Lock when done" hidden. Fix: put the key message first, "Editing. Lock when done.", and move the right-click hint into the middle hint line or a tooltip.
3. **Minor: there are two edit models on one panel.** The groups edit by right-click, while the middle edits with ⠿ and ×. Fix: also give middle chips the same right-click menu (Edit, Remove, Move), so one habit works everywhere. In edit mode, make the whole chip draggable, not only the 8px ⠿ handle.
4. **Minor: × removes instantly, and there's an × on every chip.** In edit mode a slip of the mouse deletes a shortcut. Fix: when you remove a chip, show a toast like "Removed Notepad. Undo" for 5 seconds instead of asking to confirm. Also keep the same column count in locked and edit modes. Switching from 2 to 3 columns rearranges the icons the moment you start editing, which defeats reordering.
5. **Minor: "▾ 4 more (scroll)" mixes a button and an instruction.** Scrolling over a click-through area is also unreliable, because the wheel over a gap goes to the desktop. Fix: make it a real button, "4 more", that opens the same flyout as the ⋯ fallback. Then there's one behaviour on every screen size, and the middle never scrolls.

## Fine as is
- The window height comes from the work area and never covers the taskbar, and it falls back to two panels when the groups don't fit.
- The approved order and the Restarts group at the bottom carry over. The amber Editing bar, the missing-program dot with its tooltip, and the Add icon slot that opens the existing Edit window are all good.
- Using each target's own Windows icon helps staff recognise their shortcuts.
