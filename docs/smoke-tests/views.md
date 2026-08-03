# Views and the follow cam

The three setters — `/live/view/show_view`, `/live/view/hide_view`,
`/live/view/set/detail_clip` — **never reply**, so a pane that appears and a name
Live rejects are identical on the wire. `get_view_state` is what changes that:
`/live/view/get/is_view_visible` reads each pane's real visibility back out of
Live, so most of this file is **self-checking** — Seshat confirms its own view
changes and no human has to watch the screen. The addresses only exist in the
fork, so [bridge.md](bridge.md)'s reinstall precondition still applies.

## The visibility matrix

*Run mode: user — includes checking derived view labels against Live's screen*
*Last run: —*

For each of `Browser`, `Arranger`, `Session`, `Detail`, `Detail/Clip`,
`Detail/DeviceChain`: `show_view(name)`, then `get_view_state`, and confirm the
summary reports that pane. This covers bare `Detail`, which the 2026-07-31 run had
to leave unconfirmed because closing the detail panel needed a keystroke — now
`hide_view(Detail)` closes it and the getter proves it closed.

Two readings the summary *derives* rather than reads are worth eyeballing once
against the screen: "Main view" comes from the Session/Arranger pair, and the
detail panel's named tab comes from the `Detail/*` flags.

## `hide_view` hides exactly two panes

*Run mode: agent*
*Last run: 2026-08-03 — passed, both names. From "Main view: Session. Live's
browser: open. Detail panel: open, showing the clip editor":
`hide_view(Browser)` → "Live's browser: **closed**", detail panel untouched; then
`hide_view(Detail)` → "Detail panel: **closed**". Each pane went present →
absent, and `hide_view`'s own read-back reported success rather than a stuck-pane
error, so Live's hide set has not moved on 12.4.3. Both panes restored
afterwards.*

For each name in `hide_view`'s enum (`Browser`, `Detail`): `get_view_state`,
`hide_view(name)`, `get_view_state` again. The pane must go from present to
absent.

`Session` and `Arranger` are a pair with no closed state, and hiding either
`Detail/*` only flips the detail panel's tab — which is why the enum is smaller
than `show_view`'s six. A name whose visibility doesn't flip means Live's hide set
moved in this version and the enum needs revisiting. `hide_view` reads itself
back, so a stuck pane comes out as an honest error rather than a false success; if
it reports one, that *is* the finding.

## Show-first sequencing

*Run mode: user — requires a fresh conversational request and manual starting view*
*Last run: —*

Start in Arrangement, ask naturally to launch a named Session clip. Expect
`show_view(Session)` before `fire_clip` — the grid appears, then the launch happens
on screen — and expect it sent *directly*, with no `get_view_state` pre-check: six
serialized reads to avoid one harmless idempotent send would only delay the
action.

Then the Arrangement case: start in Session, ask to set the song loop brace.
Expect `show_view(Arranger)` before `set_loop`.

## No redundant pre-show

*Run mode: user — requires a fresh conversational request and manual starting view*
*Last run: —*

Start in Session, ask to change a clip's loop brace or notes. Expect no
`show_view(Detail/Clip)` beforehand — the existing follow cam already leaves the
edited clip on screen right after the write.

## The selected-track pane

*Run mode: user — requires manual selection and an unprompted conversation*
*Last run: —*

With a *different* track selected, ask to change a device parameter on a named
track. Expect `select_track` then `show_view(Detail/DeviceChain)` before the
mutation — `set_device_parameter` is the one mutation with no follow cam behind
it, so a skipped pre-show here shows the wrong track's chain.

## Pure navigation and hiding in words

*Run mode: user — requires an unprompted conversation to judge model behaviour*
*Last run: —*

Ask only "show me the timeline" and "show me the notes again." Expect `show_view`
alone — no invented follow-up mutation, no keyboard instructions.

Then ask "hide the browser, I need the room" and, in a separate turn, "close the
detail panel." Expect `hide_view(Browser)` and `hide_view(Detail)` respectively —
not a keystroke instruction, and not `show_view` of something else. Then "what am
I looking at?" should call `get_view_state` and answer in the user's vocabulary
("Session view, browser closed"), never tool names or raw flags.
