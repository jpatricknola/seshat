# AbletonOSC — Working Notes

> **The address list lives in [docs/abletonosc-api-docs.md](../../docs/abletonosc-api-docs.md).**
> That file is the canonical, complete reference derived from
> [github.com/ideoforms/AbletonOSC](https://github.com/ideoforms/AbletonOSC).
> Check it before using any address. This file holds only the conventions and
> gotchas that aren't obvious from the address tables.

## This is one bridge, not the architecture

[ableton-lom.md](ableton-lom.md) describes *what* Ableton exposes; AbletonOSC
is one way to reach it, and the deliberate choice — see
[docs/evaluating/bridge-options.md](../../docs/evaluating/bridge-options.md) for the trade-off
against the Max for Live WebSocket alternative. `Seshat.OSC.Transport`
isolates the wire mechanics (UDP, encoding, reply correlation); the
`/live/...` address strings themselves live inline in the handler clauses,
Registry, and Session.State — deliberately unabstracted, all sites greppable
via `"/live/`. A bridge swap would keep the tool contract in
`Seshat.Tools.Definitions` and reimplement everything below `Handlers`.

## Ports

- Seshat sends to **`127.0.0.1:11000`**.
- AbletonOSC replies to UDP **11001**, and pushes listener updates there too.
- **The bridge is loopback-only.** The fork binds its command socket to
  `127.0.0.1`, so no address is reachable off this machine, and its default reply
  destination is fixed at `127.0.0.1:11001` — a received datagram never retargets
  it. Callback replies still answer the originating host, which after the bind can
  only be loopback. Upstream does neither (wildcard bind, reply follows the last
  sender); both are recorded as deliberate divergences in the fork's `SESHAT.md`
  and grepped by `vendored_addresses_test`. Widening either is security work
  gated in [docs/evaluating/SECURITY_BACKLOG.md](../../docs/evaluating/SECURITY_BACKLOG.md), not a
  convenience.

Only one process can hold 11001, so **only one Seshat can read from Ableton at a
time** — `mix mcp` and `mix phx.server` running together means the second
one to start is deaf. If 11001 is already bound, `Transport` falls back to an
ephemeral port, logs an error naming the conflict, and marks itself `deaf`:
sends still go out, and every query returns `{:error, :reply_port_unavailable}`
immediately rather than timing out. Session state stays at its defaults. If
reads are failing but sets seem fine, check the startup log for that error
first.

**Seshat's own reply socket is loopback-bound and source-checked too**
(shipped 2026-07-30) — `@socket_opts` in `Seshat.OSC.Transport` binds 11001 to
`127.0.0.1`, and `handle_info/2` accepts a datagram only from
`127.0.0.1:<send_port>`, the one endpoint the fork's single `OSCServer` socket
can send from; anything else is logged and dropped rather than satisfying a
pending query or reaching `Session.State`. `Seshat.OSC.Message.decode/1` is
correspondingly strict — malformed bytes return `{:error, reason}` and get
logged and dropped instead of crashing the transport. Symmetric with the
Python-side bind above, but on the Elixir side of the same datagram.

## Address naming is not fully regular

Do not derive an address by analogy. Some real examples that break the pattern:

- Track panning is `/live/track/set/panning`, not `.../pan`.
- Device parameters are `/live/device/set/parameter/value` (singular `parameter`
  for one, plural `parameters` for the bulk getters).
- Device *count* is on the track: `/live/track/get/num_devices`.
- Scene and clip-slot operations are on `/live/song/...` and
  `/live/clip_slot/...` respectively, not under a `/live/scene/` create verb.

A wrong address produces **no error** — it's UDP with no reply. The symptom is a
tool that reports success while nothing moves in Ableton.

## Listener pattern

**Scalar** properties can be subscribed to:

```
/live/<object>/start_listen/<property>  [index_args...]
/live/<object>/stop_listen/<property>   [index_args...]
```

Changes are then pushed to 11001 as if they were get replies:

```
/live/<object>/get/<property>  [index_args..., new_value]
```

Upstream registers `start_listen` only for the scalars in each handler's
hardcoded property list. A property holding a *list of LOM objects* — `tracks`,
`return_tracks` — is not in any of them, so nothing upstream fires when a track
is added, deleted or reordered. Those two are ours, added in the fork's
`abletonosc/song_structure.py`, which pushes a tuple of names via the base
class's optional `getter` argument. Don't assume a property is listenable
because it is gettable; check the handler's list first.

`Seshat.Session.State` uses this to mirror session state. `@listened_properties`
and `@listened_song_properties` drive the per-track and scalar-song
subscriptions, the two vendored structure listeners cover adds/deletes/reorders,
and `handle_info` clauses absorb the pushes. Because pushes and query replies
share a shape, a `handle_info` clause will also catch replies to one-off
queries — keep that in mind when adding properties.

Two gotchas that don't show in the address tables:

- **An index-keyed listener must be unbound from the object it was registered
  on.** Listeners are keyed by index but bound to a LOM object, and indices
  renumber on delete or reorder. Unbinding from the target you were *handed* is
  the wrong object after a renumber — it fails silently, the base swallows it as
  "likely benign", and the old listener keeps pushing under an index that now
  means someone else. Upstream did exactly that; the fork's base `_stop_listen`
  resolves through `listener_objects` instead, so every handler gets it right by
  default. Don't hand-roll a stop that passes an index-resolved object.
- **`/live/startup` invalidates every listener.** AbletonOSC sends it whenever
  its control surface initialises (Live launching, a set loading, the surface
  toggled). Every listener registered against the previous song object is dead
  by then, so `Session.State` treats it as a full refresh + re-subscribe. Without
  that the mirror would be stale permanently, not just until the next change.

## Value conventions

- Track indices, scene indices, send indices, device indices: **0-based**.
- `-1` as a creation index means "append to the end"
  (`/live/song/create_midi_track [-1]`).
- Booleans are usually `1`/`0` on the wire, but some properties arrive as real
  OSC booleans (e.g. `mute` in a notes reply, `has_clip`). Accept both —
  `Handlers.truthy?/1` and `Session.State.to_bool/1` exist for this.
- Bulk `/live/song/get/track_data` replies carry **OSC nil** (`N` type tag, no
  payload) for every `clip.*` property of an empty slot. `Seshat.OSC.Message`
  decodes it to `nil`; treat `clip_slot.has_clip` as the ground truth for
  emptiness and discard the nils, as `Handlers.parse_track_data/3` does.
- `volume` is 0.0–1.0 normalised, not dB. `panning` is -1.0 to 1.0.
- Device parameters are normalised 0.0–1.0; use
  `/live/device/get/parameter/value_string` for the human-readable value
  ("2500 Hz", "-12 dB").

## Ordering hazards

- **Deleting multiple tracks** shifts indices. Delete in reverse order —
  `Registry.clear_default_tracks/0` does this.
- **Creating then naming** a track needs the new index, which is the *old*
  `num_tracks`. Query first, then create, then set the name.
- **Adding notes** requires the clip to exist. `Registry.ensure_clip/3` checks
  `/live/clip_slot/get/has_clip` and creates one if needed.
- **A clip's loop brace / play markers** — writing a new `loop_start`/
  `loop_end` or `start_marker`/`end_marker` pair one property at a time can
  pass through an invalid intermediate state (`start >= end`), which Live may
  reject silently. Read the current values, then order the two writes so
  every intermediate state stays valid (move whichever point is heading away
  from the other first), and re-read to confirm what actually landed —
  `Handlers.clip_property_writes/2` is the precedent. Also: while a clip's
  `looping` is off, `loop_start`/`loop_end` alias `start_marker`/`end_marker`
  per the Live Object Model, so write `looping` *before* the loop points when
  both are set in the same call — get the toggle's real effect before
  computing the pair ordering above, not just before sending it (a 07/2026
  review finding on `set_clip_properties`).

## Queries that raise instead of replying

Some queries make AbletonOSC raise internally. **As of `mix abletonosc.install`
2026-08-03, that fails fast, not silently:** the fork's `osc_server.py` sends a
structured `/live/error ["request", address, message, arg_count,
...request_args]` naming the request that raised, and `Seshat.OSC.Transport`
matches it against the in-flight query and returns `{:error, {:live_error,
message}}` in roughly one AbletonOSC tick instead of waiting out
`@query_timeout` (5,000ms) — see Transport's "Failed-query correlation"
section for the matching rules and their residual collision classes. A caller
still gets *no distinguishing value back* — `describe_error/1`'s message says
Ableton rejected the request, not which guard to add — so guard rather than
diagnose after the fact:

- **An index that doesn't exist** — a track, slot, or scene index past the end
  of the set raises `IndexError` inside the callback. This is the single most
  common cause of a rejected query, so guard error messages should lead with
  "check the index", not "is Ableton running".
- **Clip queries against an empty slot** (`.clip` is `None` upstream) — check
  `/live/clip_slot/get/has_clip` first, as `get_clip_notes` and
  `Registry.ensure_clip/3` do. Notes queries against an *audio* clip likewise
  raise — check `/live/clip/get/is_midi_clip`.
- **`/live/clip/get/notes` range args are all-or-nothing** — the handler raises
  unless it gets exactly 0 or 4 of `start_pitch, pitch_span, start_time,
  time_span`. If any is given, fill all four (`Handlers.note_range_args/1`).
- **Audio-only clip properties on a MIDI clip** — `gain`, `gain_display_string`,
  `warp_mode`, `warping` raise on a MIDI clip (`Clip` has no such attribute
  upstream). Check `/live/clip/get/is_midi_clip` first, as
  `get_clip_properties`/`set_clip_properties` do.

A install still running the pre-2026-08-03 copy (no `mix abletonosc.install`
since, or a Live restart still pending) is unaffected by any of the above and
keeps the old behaviour: no reply at all, then a full timeout.

Guards that exist only to turn a silent failure into an error use a **2s
timeout** (`@guard_timeout` in `Handlers`, `@slot_query_timeout` in `Registry`),
not Transport's 5s default: the branch they are protecting is the error branch,
and a typo'd index shouldn't stall a write for five seconds. Each guard catches
its own timeout — a `catch` on the calling handler clause would also cover the
work that runs *after* the guard, so a later failure would come back wearing the
guard's error message.

## Replies are correlated by address alone

`Transport` runs **one query in flight at a time** — the rest wait in a FIFO
queue, each carrying an absolute deadline that bounds its total wait, queue time
included — and matches an incoming message against the in-flight request's
address only. There is no request id on the wire, and none is coming. Three
consequences:

- **A timed-out query's reply can still answer the next one on that address.**
  Serialization removes the old overwrite case, where mere overlap was enough:
  a reply that doesn't match the in-flight request's address is broadcast and
  answers nobody. But a straggler that *does* match it is indistinguishable
  from that request's own fresh reply, so it is delivered. Anything that reads
  a property per index must check the indices echoed in the reply against the
  ones it asked about (`Handlers.query_flag/3`, `Registry.ensure_clip/3`), and
  reissue rather than trust a mismatch. Compare with `==`, not a pin: a float
  index reaches Ableton fine and comes back as an integer.
- **Bulk replies can't be checked this way.** `/live/song/get/track_data` answers
  with a bare value list and no index echo, so it can't be validated against the
  request. Prefer per-index getters where the answer gates a mutation.
- **Scalar song properties have nothing to echo either.** `/live/song/get/can_undo`
  and `/live/song/get/can_redo` take no index, so there is no argument to compare
  against the request the way `query_flag/3` does. `Handlers.history_guard/2`
  (guarding `undo`/`redo`) is the precedent: on a `false` reply, reissue the same
  query once and only refuse on a second confirmed `false` — a stale `true`
  straggler is harmless (it only sends a mutation whose own reply already
  asserts nothing), but an uncorrelated `false` between two queries could be
  wrong, so it gets the one extra round trip an index-bearing guard gets from
  the echo check instead.
- **Listener pushes share the getter's address.** `/live/track/start_listen/volume`
  pushes arrive on `/live/track/get/volume`, so a push can satisfy a pending query
  for the same property. The properties `Session.State` listens to are in
  `@listened_properties` / `@listened_song_properties` — keep gating queries off
  that list where there's a choice.

## Measuring the Live API without building the feature first

Plenty of questions about the Live Object Model can't be answered from source —
what `browser.load_item` does with an instrument while a return is selected,
whether an assignment sticks, what a parameter's real range and display string
are. They can be *measured* in minutes, without a Live restart and without
writing any of the feature. The rig (validated 2026-07-31, Live 12.4.3):

1. **Add a temporary probe handler to the installed copy**, at
   `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC/abletonosc/return_track.py`
   — never the repo. No fork commit, no pin bump, nothing to revert in git.
   `return_track.py` is on `reload_imports`' list, which is why it's the
   convenient host.
2. **Trigger it with fire-and-forget UDP to 11000** — `/live/api/reload`
   (registered in `manager.py`, re-imports the handler modules and re-runs
   `init_api`) then your probe address. Sending only, so you never bind 11001
   and never contend with the running Seshat server for AbletonOSC's fixed
   reply port. A dozen lines of `socket.sendto` with hand-rolled OSC padding is
   enough; no reply plumbing is needed.
3. **Read the answers out of Live's own log**, not off the wire:
   `~/Library/Preferences/Ableton/Live <version>/Log.txt`, where
   `self.logger.info` lands. Prefix every line with something greppable and
   record the log's line count first so you can read only what your run added.
4. **Restore with `mix abletonosc.install`, then reload again**, and confirm
   the probe address is gone (it logs `Unknown OSC address`).

Two rules for the probe itself. **Snapshot before mutating and undo after** —
record device lists and track counts at the start, delete only what the probe
created, restore the previous selection, and delete a return track the probe
added. **Wrap every measurement in its own `try`/`except` and log the
exception**: reading `master_track.mute` raises `RuntimeError` rather than
returning falsy, so one unguarded probe line aborts the rest of the run, and
`hasattr` is not a safe feature test on LOM objects.

Ask before running one. It writes into the user's Remote Scripts and reloads
the bridge under a live session, and a probe that loads devices mutates a real
set — cheap to undo, but the user's call, and the answer may be "that session
is a scratch set, go ahead."
