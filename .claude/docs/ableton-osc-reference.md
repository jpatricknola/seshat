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

If 11001 is already bound, `Transport` falls back to an ephemeral port and logs
a warning. Sends still appear to work; every query then times out. If queries
are failing but sets seem fine, check for that warning first.

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
- Booleans are `1`/`0` on the wire, not `true`/`false`.
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
