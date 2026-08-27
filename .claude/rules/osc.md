---
paths:
  - "lib/**"
  - "priv/AbletonOSC/**"
---

# OSC safety rules

Wrong OSC addresses **fail silently** — it's UDP with no reply. These rules
exist because a typo'd address looks exactly like success.

- **Before using any OSC address**, check
  [priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md) — the
  canonical list of addresses and their arguments. Never guess an address or
  infer one from a similar-looking pattern; AbletonOSC's naming is not fully
  regular. If the capability isn't in that file, say so instead of inventing
  an address. Wire conventions (naming irregularities, listener pattern,
  what raises, the probe rig) are in that file too; Seshat's own side
  (ports, value conventions, ordering hazards, reply correlation) is in
  [.claude/docs/ableton-osc-reference.md](../docs/ableton-osc-reference.md).
- **The bridge is our fork, but this submodule is never its development
  checkout.** [priv/AbletonOSC](../../priv/AbletonOSC) is Seshat's pinned,
  disposable consumer checkout of
  [jpatricknola/AbletonOSC](https://github.com/jpatricknola/AbletonOSC). **Never
  edit or commit fork files here, and never create a development/topic branch
  here.** Local commits in a submodule create an unnecessary second line of
  development and diverge as soon as the canonical fork moves. Do all fork
  development in the standalone clone (on this machine,
  `/Users/patrick/ableton-osc`) or another standalone clone of that repository.

  An address upstream lacks is ours to add rather than ours to work around.
  The sequence, in order:

  1. In the standalone fork clone, start a topic branch from the current
     `origin/master`. Edit, test, commit and push there, then merge through the
     fork's required pull request workflow. Documentation-only changes follow
     exactly the same fork workflow.
  2. Only after the fork change is on canonical `origin/master`, update
     `priv/AbletonOSC` to that merged commit. Do not pin Seshat to an unpushed
     commit or a topic-branch-only commit.
  3. `git add priv/AbletonOSC` from the Seshat root — that stages only the new
     gitlink SHA. Put it in the same Seshat commit as the Elixir side when the
     two depend on each other, so the pin and its consumer move together.
  4. When runtime files changed, run `mix abletonosc.install` and **restart
     Live**. The tests grep the submodule in this repo; Live runs the *copy* in
     Remote Scripts. Skip this after a Python change and a green suite is
     telling you about Python that Live has never loaded. That failure mode is
     new with the fork — treat a passing test on unreinstalled Python as no
     evidence at all. Documentation-only changes still require steps 1–3, but
     not installation or restart because Live does not consume them.

  A dirty or locally committed `priv/AbletonOSC` is a recovery situation, not a
  development workflow. Reproduce or cherry-pick the work into a standalone
  fork branch, merge it there, then return the submodule to the merged
  `origin/master` commit before advancing Seshat's pin.

  The task **fetches and fast-forwards the submodule to `origin/master` before
  copying**, and prints the commit it installed. That is the fix for the
  2026-08-05 failure where a merged fork PR was installed, restarted around and
  smoke-tested against — as two-day-old Python, because merging on GitHub moves
  the remote and nothing in this repo moves the checkout. Use `--no-pull` to
  install the checkout exactly as it stands: offline work, or deliberately
  bisecting an older bridge against Live.

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
  [docs/evaluating/SECURITY_BACKLOG.md](../../docs/evaluating/SECURITY_BACKLOG.md) activated and
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
- **Four view addresses of ours live inside upstream's own `view.py`**:
  `/live/view/show_view`, `/live/view/hide_view`,
  `/live/view/get/is_view_visible` and `/live/view/set/detail_clip`, in
  [priv/AbletonOSC/abletonosc/view.py](../../priv/AbletonOSC/abletonosc/view.py).
  Upstream can *select* a track, scene, clip or device but cannot show the pane
  it lives in, put a pane away, or report which panes are open —
  `Application.View.show_view`, `.hide_view`, `.is_view_visible` and
  `song.view.detail_clip` have no upstream address. The first is what
  `Seshat.Tools.FollowCam` needs; the rest are what the `hide_view` and
  `get_view_state` tools need. The three **setters are silent**: a bad view name
  or an empty clip slot is logged in Live and nothing goes on the wire. Steering
  must never fail or delay the tool it follows, so the "a vendored getter always
  replies" rule below deliberately does not reach them — but it *does* govern
  `get/is_view_visible`, which answers every query in the ok/error envelope,
  echoing the view name where other getters echo an index. `hide_view` is
  verified from the Elixir side instead, by reading that getter back after the
  send; its tool enum is only `Browser` and `Detail`, the two names measured to
  truly hide (the others swap to a sibling view).
- **Two more of ours live inside upstream's own `song.py`**:
  `/live/song/begin_undo_step` and `/live/song/end_undo_step`, two entries in
  that file's generic methods list. Upstream has no way to demarcate an undo
  step, so Live groups script-driven mutations by its own activity-sensitive
  rules — measured on 12.4.3, a `create_track` plus a `write_midi_notes`
  collapsed into a single step whose undo deleted the whole track.
  `Seshat.Tools.Handlers.call/2` wraps **every** tool dispatch in a
  `begin`/`end` pair so one tool call is one undo step, sending `end` from an
  `after` block so an error or a raise still closes it, and serializing the
  whole thing under `:global.trans` because `begin` does not refcount. `undo`
  and `redo` are never wrapped; they send a lone defensive `end` first. Both
  addresses are send-only and registered by a loop, so — like `swing_amount` —
  `vendored_addresses_test` greps `song.py` for the literal names instead of
  seeing the registration.
- **A tool may opt out of the undo step only if its mechanism cannot reach
  Live's undo history.** `undo_step: false` in a `Definitions` entry makes
  `Handlers` dispatch it with no lock and no begin/end datagrams; the set is
  derived by `Definitions.unstepped_names/0`, never hand-listed. Today it is
  exactly `get_audio_outputs` and `set_audio_output`, which reach Live through
  macOS Accessibility (`Seshat.AX.Client`) and change an Ableton *preference*
  rather than the Set — sending OSC for them would put datagrams on the wire for
  a tool that never touches it. **It is not an optimisation for read-only OSC
  tools**: those stay wrapped by deliberate policy, per the bullet above. A tool
  that opts out owes the model a sentence saying the change is outside Live's
  undo history and how to reverse it, since `undo` cannot.
- **Nothing under `lib/` (outside `lib/mix/tasks/`) starts a process except
  `Seshat.AX.Client`.** It is the single door to the native Accessibility
  helper, and `client_test.exs` greps `lib/**/*.ex` — minus `lib/mix/tasks/`,
  where a human-invoked task like `mix ax.install` is expected to run a
  subprocess — for `Port.open`, `:spawn_executable`, `System.cmd`,
  `System.shell`, `:os.cmd` and `:erlang.open_port` to keep it that way. The
  LOM-first rule — UI scripting only for a concrete operation absent from the
  current LOM, everything else goes in the fork — is only durable if it is
  mechanical. A new capability that genuinely needs the helper adds a command
  to its closed protocol, with its own LOM-gap, safety, semantic-target and
  read-back case argued first; it does not spawn something of its own.
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
- **`Transport.query_batch/2` is reads only.** It pipelines several getters
  into one AbletonOSC tick — one FIFO slot, one deadline, every datagram sent
  back-to-back at dequeue, each reply matched to its entry by address plus
  echoed-argument prefix. A batch can time out with datagrams already on the
  wire, which is harmless only when nothing in it mutates: never put a
  setter in one. An ordered sequence around a mutation (a pre-write guard, a
  confirming read-back) stays individual `query/3` calls — the sequencing is
  the point, and batching it would blur "sent" with "confirmed." See the
  moduledoc's "Query serialization" section in
  [lib/seshat/osc/transport.ex](../../lib/seshat/osc/transport.ex) and the
  archived [PLAN_batched_queries.md](../../docs/archive/PLAN_batched_queries.md)
  for the measured tick model behind it.
- **Track indices are 0-based everywhere.** "Track 1" in user speech =
  index 0. Send IDs likewise (send A = 0).
- **Ranges**: pan is -1.0 (left) to 1.0 (right); volume and send levels are
  0.0–1.0 (Ableton maps to dB internally).
- **Handler params are string-keyed.** `Handlers.call/2` normalises MCP's atom
  keys and any string-keyed direct calls; `do_call/2` clauses only ever see
  string keys.
- **`%Command{}` structs are for multi-step sequences only** (via
  `Seshat.Commands.Registry`). Single-message tools call `Transport` directly
  from their handler clause.
- **Never hand-write a module under `lib/seshat/mcp/` for a tool** — MCP
  components are generated from `Seshat.Tools.Definitions` at compile time.
- **No database, no Ecto.** `:exqlite` exists only so
  `Seshat.Library.AbletonDB` can read *Ableton's* browser database read-only.
