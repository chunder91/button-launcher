# Combined UX + UI review: View Register picker v1.3.0 (vnc-picker @ da5117b)
Squint (UX) + Kern (UI). Full detail in squint.md and kern.md. 2026-10-29, ET.

**Verdict: SHIP WITH FIXES.** No Blockers. Both halves agree. Mock is HTML, so we both recheck on a real Windows build.

## Majors
1. (Kern) Button row wraps. One row: **View only, Interact | Rescan, Add..., ⋯**. Grid, 32 px buttons, don't widen the window.
2. (Kern) Selected row uses the Interact blue. Use the Win11 list style (#2E2E2E fill, #22C55E left pill).
3. (Kern) No D2 styling yet. See kern.md checklist.
4. (Squint) Unnamed rows are bare IPs and naming is hidden behind Rename / pin. Show `Unnamed (F2 to name)`, F2 renames, the star column toggles pin, naming no longer pins.
5. (Squint) Empty and no-network states. Centred list message with the copy in squint.md finding 2, Add... reachable first.

## Minors
- (Kern) Secondary buttons and list border have no edge; dead space under the status line; pin star should be the amber Fluent glyph; column header and 32 px rows.
- (Squint) Replace the Greeting column (RFB version) with a Seen column, banner in the tooltip; grey out rows not found in the last scan.
- (Squint) Remove only for saved rows ("Remove from favourites"), disabled for scanned-only rows.
- (Squint) Interact tooltip plus Ctrl+Enter; no extra confirm.
- (Squint) Wrong saved view-only password: status-line message pointing to Setup.
- (Both) Title shown twice. Keep one; if the standard chrome stays, swap the H1 for a one-line hint.

## Decisions on the open questions
- **⋯ menu contents:** Rename... (F2), Pin / Unpin, separator, Remove from favourites. Rows get a right-click menu with the same items plus View only and Interact.
- **View-only password:** Squint's call (flow): remove it from the picker, including the ⋯ menu. It stays at Setup > View-only register password... and the first-use ask-once prompt. This replaces Kern's "⋯ menu" placement; the ⋯ menu then has no separator before it. Update ultravnc-viewonly-note.md to match.
- **Enter = View only:** yes. View only is IsDefault, Ctrl+Enter = Interact, double-click = View only.

## Proposals needing Charles's OK (through Groot)
- The full D2 restyle (custom chrome, gradients, shadow) is look/feel and stays a proposal until Charles OKs it. The wrap fix, selection colour and states are fixes.
