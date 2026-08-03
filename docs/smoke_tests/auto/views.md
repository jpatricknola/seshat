# Views and the follow cam

The three setters — `/live/view/show_view`, `/live/view/hide_view`,
`/live/view/set/detail_clip` — **never reply**, so a pane that appears and a name
Live rejects are identical on the wire. `get_view_state` is what changes that:
`/live/view/get/is_view_visible` reads each pane's real visibility back out of
Live, so most of this file is **self-checking** — Seshat confirms its own view
changes and no human has to watch the screen. The addresses only exist in the
fork, so [bridge.md](bridge.md)'s reinstall precondition still applies.

## `hide_view` hides exactly two panes

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

