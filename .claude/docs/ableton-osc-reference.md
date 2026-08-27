# AbletonOSC — Seshat's consumer notes

> **Everything about the wire itself lives in the fork.** The address list,
> reply shapes, listener pattern, the addresses that raise, and every
> behaviour measured against real Live are in
> [priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md); divergences from
> upstream in [SESHAT.md](../../priv/AbletonOSC/SESHAT.md); LOM members with
> no address yet in [FORK_GAPS.md](../../priv/AbletonOSC/FORK_GAPS.md); fork
> defects in [issues.md](../../priv/AbletonOSC/issues.md). Check `API.md`
> before using any address. This file holds only what is true of *Seshat's
> side* of the datagram — how `Transport`, `Handlers`, `Registry` and
> `Session.State` consume the wire — and never restates a wire fact.

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

## Listeners, as Seshat uses them

`Seshat.Session.State` mirrors session state through the listener pattern
documented in the fork's `API.md` ("Listener pattern"). `@listened_properties`
and `@listened_song_properties` drive the per-track and scalar-song
subscriptions, the two fork structure listeners (`tracks`, `return_tracks`)
cover adds/deletes/reorders, and `handle_info` clauses absorb the pushes.
Because pushes and query replies share a shape, a `handle_info` clause will
also catch replies to one-off queries — keep that in mind when adding
properties. `/live/startup` invalidates every listener, so `State` treats it
as a full refresh + re-subscribe.

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

## Guarding a query that would raise

The fork's `API.md` ("Queries that raise instead of replying") lists which
requests raise and how the structured `/live/error` reaches the client.
`Seshat.OSC.Transport` matches that envelope against the in-flight query and
returns `{:error, {:live_error, message}}` in roughly one AbletonOSC tick
instead of waiting out `@query_timeout` (5,000ms) — see Transport's
"Failed-query correlation" section for the matching rules and their residual
collision classes. A caller still gets *no distinguishing value back* —
`describe_error/1`'s message says Ableton rejected the request, not which
guard to add — so guard rather than diagnose after the fact: check
`/live/clip_slot/get/has_clip` before a clip query (`get_clip_notes`,
`Registry.ensure_clip/3`), `/live/clip/get/is_midi_clip` before notes or the
audio-only properties (`get_clip_properties`/`set_clip_properties`), and fill
all four of `/live/clip/get/notes`' range args or none
(`Handlers.note_range_args/1`).

Setters and generic methods raise with the same envelope, and it buys Seshat
nothing for delivery: `Transport.send_message/2` returns as soon as UDP
transmission succeeds, so the tool step is already complete and reported by
the time the error lands — it is broadcast on `"osc:in"` and answers nobody.
A setter that must be *known* to have landed still needs a guard before it or
a read-back after it (`set_track_send` and `set_device_parameter` are the
patterns).

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

`query_batch/2` (added 2026-08-04, see
[docs/archive/PLAN_batched_queries.md](../../docs/archive/PLAN_batched_queries.md))
occupies one FIFO slot for several reads at once rather than sidestepping this
section — it just matches more precisely: address *plus* echoed-argument
prefix, so same-address entries (twelve `/live/track/get/send` reads in one
batch) resolve to the right one instead of arriving in any old order. The two
hazard classes below are unchanged by batching, not new risks it introduces —
a wrong-args straggler now matches no entry at all (strictly better than the
single-query path, which would have consumed the slot), and a listener push on
a batched address can still satisfy an entry exactly as it can a lone query.

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
