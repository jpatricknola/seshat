# AbletonOSC — Working Notes

> **The address list lives in [docs/abletonosc-api-docs.md](../../docs/abletonosc-api-docs.md).**
> That file is the canonical, complete reference derived from
> [github.com/ideoforms/AbletonOSC](https://github.com/ideoforms/AbletonOSC).
> Check it before using any address. This file holds only the conventions and
> gotchas that aren't obvious from the address tables.

## This is one bridge, not the architecture

[ableton-lom.md](ableton-lom.md) describes *what* Ableton exposes; AbletonOSC
is one way to reach it, and the deliberate choice — see
[docs/bridge-options.md](../../docs/bridge-options.md) for the trade-off
against the Max for Live WebSocket alternative. `Seshat.OSC.Transport`
isolates the wire mechanics (UDP, encoding, reply correlation); the
`/live/...` address strings themselves live inline in the handler clauses,
Registry, and Session.State — deliberately unabstracted, all sites greppable
via `"/live/`. A bridge swap would keep the tool contract in
`Seshat.Tools.Definitions` and reimplement everything below `Handlers`.

## Ports

- Seshat sends to UDP **11000**.
- AbletonOSC replies to UDP **11001**, and pushes listener updates there too.
- Replies go to the IP the message came from.

Only one process can hold 11001, so **only one Seshat can read from Ableton at a
time** — an MCP server and `mix phx.server` running together means the second
one to start is deaf. If 11001 is already bound, `Transport` falls back to an
ephemeral port, logs an error naming the conflict, and marks itself `deaf`:
sends still go out, and every query returns `{:error, :reply_port_unavailable}`
immediately rather than timing out. Session state stays at its defaults. If
reads are failing but sets seem fine, check the startup log for that error
first.

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

Any gettable property can be subscribed to:

```
/live/<object>/start_listen/<property>  [index_args...]
/live/<object>/stop_listen/<property>   [index_args...]
```

Changes are then pushed to 11001 as if they were get replies:

```
/live/<object>/get/<property>  [index_args..., new_value]
```

`Seshat.Session.State` uses this to mirror session state. Its `@listened_properties`
list drives what it subscribes to on startup, and `handle_info` clauses absorb
the pushes. Because pushes and query replies share a shape, a `handle_info`
clause will also catch replies to one-off queries — keep that in mind when
adding properties.

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

## Queries that raise instead of replying

Some queries make AbletonOSC raise internally, which on UDP looks identical to
a wrong address: **no reply at all**, then a timeout. Guard rather than diagnose
after the fact:

- **An index that doesn't exist** — a track, slot, or scene index past the end
  of the set raises `IndexError` inside the callback and nothing is sent. This is
  the single most common cause of a query timeout, so guard error messages should
  lead with "check the index", not "is Ableton running".
- **Clip queries against an empty slot** (`.clip` is `None` upstream) — check
  `/live/clip_slot/get/has_clip` first, as `get_clip_notes` and
  `Registry.ensure_clip/3` do. Notes queries against an *audio* clip likewise
  never answer — check `/live/clip/get/is_midi_clip`.
- **`/live/clip/get/notes` range args are all-or-nothing** — the handler raises
  unless it gets exactly 0 or 4 of `start_pitch, pitch_span, start_time,
  time_span`. If any is given, fill all four (`Handlers.note_range_args/1`).

Guards that exist only to turn a silent failure into an error use a **2s
timeout** (`@guard_timeout` in `Handlers`, `@slot_query_timeout` in `Registry`),
not Transport's 5s default: the branch they are protecting is the error branch,
and a typo'd index shouldn't stall a write for five seconds. Each guard catches
its own timeout — a `catch` on the calling handler clause would also cover the
work that runs *after* the guard, so a later failure would come back wearing the
guard's error message.

## Replies are correlated by address alone

`Transport` keeps **one** pending query and matches an incoming message to it by
address only — there is no request id on the wire. Two consequences:

- **A timed-out query's reply can answer the next one.** The abandoned `from`
  stays in `pending` until the next query overwrites it, so a late reply to query
  A can be handed to query B on the same address. Anything that reads a property
  per index must check the indices echoed in the reply against the ones it asked
  about (`Handlers.query_flag/3`, `Registry.ensure_clip/3`), and reissue rather
  than trust a mismatch. Compare with `==`, not a pin: a float index reaches
  Ableton fine and comes back as an integer.
- **Bulk replies can't be checked this way.** `/live/song/get/track_data` answers
  with a bare value list and no index echo, so it can't be validated against the
  request. Prefer per-index getters where the answer gates a mutation.
- **Listener pushes share the getter's address.** `/live/track/start_listen/volume`
  pushes arrive on `/live/track/get/volume`, so a push can satisfy a pending query
  for the same property. The properties `Session.State` listens to are in
  `@listened_properties` / `@listened_song_properties` — keep gating queries off
  that list where there's a choice.
