---
paths:
  - "lib/**"
  - "priv/AbletonOSC/**"
---

# OSC safety rules

Wrong OSC addresses **fail silently** — it's UDP with no reply. These rules
exist because a typo'd address looks exactly like success.

- **Before using any OSC address**, check
  [docs/abletonosc-api-docs.md](../../docs/abletonosc-api-docs.md) — the
  canonical list of addresses and their arguments. Never guess an address or
  infer one from a similar-looking pattern; AbletonOSC's naming is not fully
  regular. If the capability isn't in that file, say so instead of inventing
  an address. Conventions and gotchas (ports, listener pattern, ordering
  hazards) are in
  [.claude/docs/ableton-osc-reference.md](../docs/ableton-osc-reference.md).
- **The bridge is our fork, and editing it is two commits.**
  [priv/AbletonOSC](../../priv/AbletonOSC) is a git submodule
  ([jpatricknola/AbletonOSC](https://github.com/jpatricknola/AbletonOSC)), so an
  address upstream lacks is ours to add rather than ours to work around. The
  sequence, in order, with the trap in each step:

  1. `git -C priv/AbletonOSC checkout master` **first**. `git submodule update
     --init` leaves a *detached HEAD*, and a commit made there belongs to no
     branch and pushes nowhere.
  2. Edit the Python, then `commit` and `push` **inside** `priv/AbletonOSC`.
  3. `git add priv/AbletonOSC` from the Seshat root — that stages the new SHA,
     not the files. Put it in the same Seshat commit as the Elixir side, so the
     pin and the code depending on it move together.
  4. `mix abletonosc.install` and **restart Live**. The tests grep the submodule
     in this repo; Live runs the *copy* in Remote Scripts. Skip this and a green
     suite is telling you about Python that Live has never loaded. That failure
     mode is new with the fork — treat a passing test on unreinstalled Python as
     no evidence at all.

  A fresh git worktree (`/lifecycle`, worktree-isolated agents) has an empty
  `priv/AbletonOSC` until step 0, `git submodule update --init`; the
  Python-grepping tests fail with that hint until it runs.
- **Never widen the UDP boundary.** The fork binds AbletonOSC's command socket to
  `127.0.0.1:11000` and pins its default reply destination to
  `127.0.0.1:11001`, permanently — a received datagram must never retarget it.
  Every OSC address can control Live and none of them authenticate anything, so
  restoring upstream's `0.0.0.0` bind or its follow-the-last-sender reply hands
  full control of the user's session to anything the machine's network boundary
  allows through. The same applies to Seshat's own 11001 listener. A networked
  controller (TouchOSC and friends) is not a config tweak: it needs an explicit
  opt-in bind *and* the deployment-gated security work in
  [docs/SECURITY_BACKLOG.md](../../docs/SECURITY_BACKLOG.md) activated and
  finished first. A regression here is silent — loopback keeps working
  identically — so `vendored_addresses_test` greps the Python for both.
- **A vendored handler never opens a path a caller sent it.** It runs with Live's
  privileges. `/live/browser/export` is the pattern: the request carries no path,
  Python creates the file with `tempfile.mkstemp` inside a fixed root, returns the
  absolute path, and Elixir validates that reply (root, name shape, `File.lstat/1`
  regular file) before reading — and especially before deleting — anything.
- **`/live/browser/*`, `/live/return_track/*`, and `/live/master/*` are ours,
  not upstream's** — those handlers live in
  [priv/AbletonOSC/abletonosc/browser.py](../../priv/AbletonOSC/abletonosc/browser.py)
  and
  [priv/AbletonOSC/abletonosc/return_track.py](../../priv/AbletonOSC/abletonosc/return_track.py)
  respectively. Upstream's track addresses only reach `song.tracks` (regular
  tracks) — returns and the master come from the second file, including
  `/live/return_track/select`, because `/live/view/set/selected_track` indexes
  `song.tracks` too. Any new address upstream doesn't provide goes there the
  same way.
- **Two view addresses of ours live inside upstream's own `view.py`**:
  `/live/view/show_view` and `/live/view/set/detail_clip`, in
  [priv/AbletonOSC/abletonosc/view.py](../../priv/AbletonOSC/abletonosc/view.py).
  Upstream can *select* a track, scene, clip or device but cannot show the pane
  it lives in — `Application.View.show_view` and `song.view.detail_clip` have no
  upstream address — which is what `Seshat.Tools.FollowCam` needs. Both are
  silent: a bad view name or an empty clip slot is logged in Live and nothing
  goes on the wire. Steering must never fail or delay the tool it follows, so
  the "a vendored getter always replies" rule below deliberately does not reach
  them.
- **Two addresses of ours live under a prefix upstream owns**:
  `/live/song/start_listen/tracks` and `/live/song/start_listen/return_tracks`,
  from
  [priv/AbletonOSC/abletonosc/song_structure.py](../../priv/AbletonOSC/abletonosc/song_structure.py).
  Upstream can only listen to *scalar* song properties, so nothing of its own
  fires when tracks are added, deleted or reordered. They push on
  `/live/song/get/tracks` and `/live/song/get/return_tracks` — push-only
  addresses, sent by the listener and never registered, so querying them gets
  silence. `Seshat.Session.State` treats the pushed name list as a change signal
  and re-reads everything only when it differs from the mirror.
- **Vendored addresses must appear as string literals in `lib/`, never
  interpolated.** `vendored_addresses_test` greps for `"/live/…"` literals and
  checks each against what the Python actually registers; an address built with
  `#{}` is invisible to that tripwire, which is the only thing standing between a
  typo and a silent no-op.
- **A vendored getter always replies, including on its error paths** — an
  `[..., "ok", value]` / `[..., "error", message]` envelope, echoing whatever
  index it was asked about. The exception is a getter that takes no index
  (`/live/return_track/get/count`, `/live/master/get/volume`): with nothing to
  look up there is no failure to report, so those reply with the bare value and
  no envelope. Upstream's habit of raising inside the callback and
  sending nothing is wrong for an *optional* extension: silence would mean both
  "bad index" and "the user never ran `mix abletonosc.install`", and cost a full
  guard timeout to distinguish neither. With the envelope, an error reply is a
  bad index and silence is a missing install. Setters stay silent — each is
  guarded by its getter first, and nothing waits on one.
- **An index-keyed listener must be unbound from the object it was registered
  on.** Listeners are keyed by track/return index but bound to a LOM object, and
  indices renumber when something is deleted or reordered. Unbinding from the
  target you were *handed* is the wrong object after a renumber — it fails
  silently and leaves the old listener pushing under an index that now means
  someone else, so a later rename writes one track's name onto another. The
  fork's `AbletonOSCHandler._stop_listen` resolves through `listener_objects`
  instead, which makes this correct for every handler by default. Don't
  reintroduce a hand-rolled stop that passes an index-resolved object.
  `vendored_addresses_test` greps for that fix: it is the one change whose loss
  is completely invisible, since every address still answers without it.
- **All OSC goes through `Seshat.OSC.Transport`** — nothing sends UDP
  directly. Address strings deliberately live inline in `Handlers`,
  `Registry`, and `Session.State` (greppable via `"/live/`) — do not add an
  abstraction layer over them.
- **Track indices are 0-based everywhere.** "Track 1" in user speech =
  index 0. Send IDs likewise (send A = 0).
- **Ranges**: pan is -1.0 (left) to 1.0 (right); volume and send levels are
  0.0–1.0 (Ableton maps to dB internally).
- **Handler params are string-keyed.** `Handlers.call/2` normalises
  (Anthropic sends strings, MCP sends atoms); `do_call/2` clauses only ever
  see string keys.
- **`%Command{}` structs are for multi-step sequences only** (via
  `Seshat.Commands.Registry`). Single-message tools call `Transport` directly
  from their handler clause.
- **Never hand-write a module under `lib/seshat/mcp/` for a tool** — MCP
  components are generated from `Seshat.Tools.Definitions` at compile time.
- **No database, no Ecto.** `:exqlite` exists only so
  `Seshat.Library.AbletonDB` can read *Ableton's* browser database read-only.
