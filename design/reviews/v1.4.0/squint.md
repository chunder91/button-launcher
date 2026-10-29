# Squint UX notes: v1.4.0 unread-mail badge on the Email tile (spec stage)
Source: mail-badge-spec.md (Kern, visual), src/buttons.json (the Email tile opens `mailto:`). 2026-10-29 ET. There's no build yet, so this covers flow and copy only.

**Verdict: GO WITH FIXES.** (Switchboard has adopted both Majors and all the Minors into the v1.4.0 build spec. Smudge's mockups aren't in mockups/ yet; I'll check them when they land.) Opt-in, count-only, and quiet by default is the right shape. The two Majors are about a shared PC and a bad sign-in. Fix them before it's built.

## Mail source (answered by Switchboard, 1:20 PM ET)
IMAP STATUS INBOX UNSEEN on mail.jartrek.net:993, using the Windows user's own @jartrek.net login, which is stored per Windows user. In the shop, the Email tile opens Roundcube (webmail.jartrek.net). That means the login is typed into the launcher, and "unread" matches the bold count in webmail's Inbox. The final copy is below. Lockjaw owns how the password is stored.

## Findings
1. **Major: on a shared shop PC, everyone sees one person's unread count.** The launcher runs on staff PCs. If Charles turns the count on with his mailbox, the next person at that PC sees his count and the tooltip.
   Fix: the setup dialog shows the account in plain words and warns before Turn on: `Everyone who uses this PC will see how many unread emails this account has.` Show the account (for example `cc...@keystonebingo.com`) only in the setup dialog, not in the tile tooltip.
2. **Major: a failed sign-in keeps retrying every 3 minutes.** That's 20 bad attempts an hour. It can lock the mail account, and the user only sees a small grey ring.
   Fix: on a sign-in failure (not a network failure), stop polling right away and show the marker. Restart polling only after setup succeeds again, or after **Check mail now** succeeds.
3. **Minor: the count lingers after you've read your mail.** Staff click Email, read everything, come back, and the badge still says 3 for up to 3 minutes. It looks broken.
   Fix: after the Email tile is clicked, check again at 60 s and at 3 min, then go back to the normal schedule. Also add **Check mail now** to the Email tile's right-click menu.
4. **Minor: the setting label is jargon.** "New mail alert: Pulse / Flash / Badge only" assumes people know what's being pulsed.
   Fix: a two-part setting.
   - Checkbox (off by default): `Show unread email count on the Email button`
   - `When new mail arrives:` with **Pulse the number** (default), **Flash the button 3 times**, **Just show the number**.
   Default Pulse is right. It moves only the small badge, it stops after 3.6 s, and it fires only when the count goes up.
5. **Minor: the error marker needs a meaning without hover.** An 8 px grey ring means nothing to someone on a touch screen, which has no tooltip.
   Fix: keep the ring, and make the right-click menu's first line a status line (disabled item): `Mail count: can't sign in` / `Mail count: offline since 9:41 AM` / `Mail count: 3 unread, checked 9:41 AM`. Put **Check mail now** and **Mail count settings...** under it.
6. **Minor: sleep and wake shouldn't count as offline.** A PC that wakes up after an hour would otherwise show "offline" when it's only been awake a few seconds.
   Fix: check once on wake (after the network is up, about 10 s) and don't count missed polls during sleep. The "2 failed polls" rule counts only polls the PC actually tried. Clear the marker on the first good poll.

## Final copy for Jartrek mail (replaces the generic wording above where they differ)
Setup dialog, titled **Unread email count**:
- Checkbox: `Show unread email count on the Email button`
- Intro: `Uses your Jartrek email, the same login as webmail.`
- Fields: **Email address** (prefilled `@jartrek.net`, so they type only the name part) and **Password** (a PasswordBox).
- Warning, shown before Save: `Everyone who uses this Windows login on this PC will see how many unread emails this account has.` (It's per Windows user, so shared shop logins are where this bites.)
- `When new mail arrives:` with Pulse the number (default) / Flash the button 3 times / Just show the number
- **Test** results:
  - `Signed in. 3 unread emails in Inbox.`
  - `Couldn't sign in. Check the email address and password, the same ones you use for webmail.`
  - `Can't reach the mail server. Check this PC is online, then press Test again.`
- Save is enabled only after a good Test. Turning it off asks `Turn off the email count and forget this login on this PC?` Default No.

The tooltip and status lines are final with these two wording changes:
- Sign-in failed: `Email count stopped: can't sign in. If you changed your webmail password, update it in Setup > Unread email count...`
- Menu status line: `Email count: can't sign in` / `Email count: offline since 9:41 AM` / `Email count: 3 unread, checked 9:41 AM`
Use "email" everywhere (not "mail") to match the button's label.

## Setup flow (opt-in)
1. **Setup > Unread mail count...** opens one D2 dialog (Kern styles it). No first-run prompt, no tip, and nothing on staff PCs unless someone turns it on. This is the same rule as the earlier ask-once Major.
2. The dialog has the checkbox `Show unread email count on the Email button`. Ticking it shows **Sign in...** (or the account picker for Outlook).
3. After sign-in, it shows the account and the shared-PC warning (finding 1), plus the `When new mail arrives:` choice.
4. **Test** checks right away and shows the result in the dialog: `Signed in. 3 unread in Inbox.` or `Couldn't sign in. Try Sign in... again.` The Turn on / Save button is enabled only after a good test.
5. Turning it off clears the badge right away and forgets the sign-in, after a confirm: `Turn off the mail count and sign out of this account on this PC?` Default No.

## Tooltip copy (replaces section 6)
Use full stops, not " - ". The time is h:mm AM/PM for today, and adds the date (`Oct 28, 4:10 PM`) when it isn't today.
| State | Text |
|---|---|
| 1 unread | `1 unread email in Inbox. Checked 9:41 AM.` |
| N unread (2-99) | `3 unread emails in Inbox. Checked 9:41 AM.` |
| 99+ | `128 unread emails in Inbox. Checked 9:41 AM.` |
| 0 | `No unread email. Checked 9:41 AM.` |
| Checking (first poll) | `Checking email...` |
| One failed poll (no marker yet, last count kept) | `3 unread emails in Inbox. Couldn't check at 9:44 AM, trying again.` |
| Sign-in failed (marker) | `Mail count stopped: can't sign in. Fix it in Setup > Unread mail count...` |
| Offline (marker, 2 failed polls) | `Can't reach email since 9:41 AM. The count is hidden until it reconnects.` |
| Off / not set up | `Open email` (the normal tile tooltip) |
Line 1 of the tooltip stays the tile's own tooltip (`Open email`), and the mail line goes under it, so the tile's job never disappears from the tooltip.

## When the error marker shows
- **Sign-in failed:** right away, on the first failure that is clearly a sign-in error (bad or expired credentials, revoked access). Polling stops (finding 2).
- **Offline or poll error:** after 2 tried polls in a row fail (about 6 min). The first failure keeps the last count and changes only the tooltip.
- **Never:** when the count is off or not set up, while the first check is running, or during sleep.
- **Clears:** on the first good poll, or when the count is turned off.

## Accessibility (non-contrast)
- The Email tile's accessible name includes the count: `Email, 3 unread`. Changes are announced politely only when the count goes up, not on every poll.
- The error states are in the accessible name too: `Email, mail count can't sign in`.
- Motion: reduced motion and Windows "Animation effects off" map to Just show the number, as in the spec. Flash at 1 Hz, 3 times, then stopping is fine for photosensitivity.
- Text size: the 11 px numeral badge is an acceptable exception, and the tooltip and menu carry the real count.

## Mockup check - UX (Squint, 2026-10-29 1:25 PM ET)

**Verdict: GO WITH FIXES. No Blockers.** The motion and the badge work for users. The fixes are copy and missing states, not changes to the look.

- **Good.** Pulse is calm and is the right default. Flash stays at 1 Hz for 3 flashes, well under the 3-per-second seizure limit, and it stops by itself. Badge only is quiet. 12, 27 and 99+ all read at a glance, and the badge leaves the "Email" label clear. The hover state still shows the count.
- **Minor 1 - The tooltip copy is stale.** still-tooltip-3 says "3 unread in Inbox - last checked 9:41 AM". The final copy is "3 unread emails. Checked 9:41 AM." (with the singular form for 1). Build from the copy table in this file, not from the mockup.
- **Minor 2 - The error ring alone doesn't say what's wrong.** In still-error, the small hollow ring sits in the same corner as the orange status dot on View Register, so staff will read it as another status light, or miss it. That's fine as long as the words do the work. Please add an error still with its tooltip showing ("Email count stopped: can't sign in. If you changed your webmail password, update it in Setup > Unread email count...") and an offline still ("Can't reach email since 9:41 AM..."). Then check that the count is hidden in both states, as the spec says. Ring size and contrast are Kern's call.
- **Minor 3 - The setup screens haven't been mocked yet.** The "Unread email count" dialog (intro, @jartrek.net prefill, shared-PC warning, Test results) and the "Email count: ..." first line of the right-click menu are where users will trip. A quick still of each before build would let me check them. This doesn't hold anything up.
- Can't check from pictures: the accessible name ("Email, 3 unread"), the keyboard path to Setup, and Reduce motion. I'll check those on the Windows build.
