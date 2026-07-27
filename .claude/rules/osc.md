---
paths:
  - "lib/**"
  - "priv/abletonosc/**"
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
- **`/live/browser/*`, `/live/return_track/*`, and `/live/master/*` are ours,
  not upstream's** — those handlers live in
  [priv/abletonosc/browser.py](../../priv/abletonosc/browser.py) and
  [priv/abletonosc/return_track.py](../../priv/abletonosc/return_track.py)
  respectively, and both are installed by `mix abletonosc.install`. Upstream's
  track addresses only reach `song.tracks` (regular tracks) — returns and the
  master come from the second file. Any new address upstream doesn't provide
  goes there the same way.
- **Two addresses of ours live under a prefix upstream owns**:
  `/live/song/start_listen/tracks` and `/live/song/start_listen/return_tracks`,
  from
  [priv/abletonosc/song_structure.py](../../priv/abletonosc/song_structure.py).
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
