# Views and the follow cam

The three setters — `/live/view/show_view`, `/live/view/hide_view`,
`/live/view/set/detail_clip` — **never reply**, so a pane that appears and a name
Live rejects are identical on the wire. `get_view_state` is what changes that:
`/live/view/get/is_view_visible` reads each pane's real visibility back out of
Live, so most of this file is **self-checking** — Seshat confirms its own view
changes and no human has to watch the screen. The addresses only exist in the
fork, so [bridge.md](bridge.md)'s reinstall precondition still applies.

## `hide_view` hides exactly two panes

*Last run: 2026-11-08 — passed, both names, Live 12.4.6 (screen locked throughout, so this is the LOM's own visibility reading). From "Main view: Session. Live's browser: open. Detail panel: open, showing the clip editor": hide_view(Browser) → "Live's browser: closed", detail untouched; hide_view(Detail) → "Detail panel: closed". Each hide's own read-back reported success. Both restored with show_view and read back open.*

For each name in `hide_view`'s enum (`Browser`, `Detail`): `get_view_state`,
`hide_view(name)`, `get_view_state` again. The pane must go from present to
absent.

`Session` and `Arranger` are a pair with no closed state, and hiding either
`Detail/*` only flips the detail panel's tab — which is why the enum is smaller
than `show_view`'s six. A name whose visibility doesn't flip means Live's hide set
moved in this version and the enum needs revisiting. `hide_view` reads itself
back, so a stuck pane comes out as an honest error rather than a false success; if
it reports one, that *is* the finding.


## The selected scene reads back

`get_view_state` reports the selected scene by index, read from
`/live/view/get/selected_scene` — the upstream address Seshat never consumed
before this. `select_scene` is the setter half and already exists, so the pair
is self-checking: `select_scene 0`, then `get_view_state` — the reply names
scene 0. `select_scene` to the set's **last** scene index (from
`get_session_state`), read again — it names that index. The two reads
disagreeing with what was just selected means the getter is reading a
different notion of selection than the setter writes, which is the finding.

*Last run: 2026-11-08 — passed, first run. get_view_state initially read "Selected scene: 2"; select_scene 0 → "Selected scene: 0"; select_scene 7 (the last of 8) → "Selected scene: 7". Restored to 0.*
