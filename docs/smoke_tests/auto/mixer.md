# The mixer

`set_mixer` — one tool for volume, pan, mute, solo, arm and name on a regular
track, a return track, the master, or the cue output. It replaced thirteen
single-property tools on 2026-08-27; the addresses are the ones those tools
sent, so nothing here is a new wire fact. What *is* new is the dispatch: one
call fans out to several silent setters, chosen by `target`, and a wrong
branch fails silently — a datagram to `/live/track/set/volume` when the model
asked for a return is indistinguishable from success on the wire. The
regular-track setters never reply and are mirrored by push; the return, master
and cue paths guard-read through vendored addresses first (a set where those
never answer points at [bridge.md](bridge.md)).

Set-up: at least two regular tracks and one return track (create one with
`create_track track_type: "return"` if needed, and delete it at the end).

## One `set_mixer` call moves several controls

*Last run: 2026-08-28 — volume 0.6/pan −0.5/mute true in one call all read back from the mirror (volume=0.6, pan=-0.5, [muted]); a single `undo` restored all three (0.85, 0.0, unmuted).*

On track 1 (index 0), in **one** call: `volume: 0.6, pan: -0.5, mute: true`.
Then `get_session_state` without `refresh: true`.

The reply lists all three on one strip, and the session state's line for the
track reads the pushed values: volume about −10 dB, pan `25L`, muted. One
`undo` reverts all three together — the mirror shows the previous volume, pan
centred, unmuted — because the whole call is one undo step.

One property missing from the mirror while the others arrived means that
property's branch sent the wrong address or none. Three undos needed means the
call escaped the undo-step wrap.

## A property the target lacks is refused with nothing sent

*Last run: 2026-08-28 — both refused before sending: "A return track has no arm — it has volume, pan, mute, solo, name. Nothing in this call was sent." / "The master has no mute — it has volume, pan."; return 0 volume still 0.85 in the mirror and Log.txt has zero `Setting property for return_track` lines.*

`set_mixer target: "return", track: 0, arm: true, volume: 0.7`, then
`set_mixer target: "master", mute: true`.

Both are refused immediately, each error naming the property the target lacks
(`arm` on a return; `mute` on the master). `get_session_state` shows return 0's
volume unchanged — the valid property in the same call was **not** sent either.
Live's Log.txt shows no `/live/return_track/set/volume` for the first call.

A changed return volume means the handler applied the supported half before
refusing; the rule is all-or-nothing, so that is a defect in the
pre-send check.

## Master and cue ignore `track`, and read back their old value

*Last run: 2026-08-28 — `track: 7` on master raised no error; replies read "volume 0.85 (≈ 0 dB) — was 0.85" and "Cue: volume 0.5 (≈ -14 dB) — was 0.7 (≈ -6 dB)"; cue restored to 0.7 afterwards.*

Read the master fader in Live, then `set_mixer target: "master", track: 7,
volume: 0.85` (an index far past the track count) and
`set_mixer target: "cue", volume: 0.5`.

Both succeed; each reply names the previous value as well as the new one, and
Live's Main fader sits at 0.0 dB. Nothing happened to track 7 (which does not
exist — no error about it either, because the index is ignored for these
targets). Restore the original values afterwards.

An "Index out of range" error means `track` leaked into the master/cue branch.

## Boundaries and a bad return index

*Last run: 2026-08-28 — last track read back volume=1.0 (+6 dB) pan=1.0 (50R), track 0 volume=0.0; return 99 refused in 0.37s wall-clock via mcp_call.py: "Return track 99 does not exist — this set has 1 return track(s)", mirror unchanged.*

`set_mixer track: <last index>, volume: 1.0, pan: 1.0` — the last regular
track — reads back at +6 dB and `50R`. `set_mixer track: 0, volume: 0.0` reads
back as −inf dB. `set_mixer target: "return", track: 99, volume: 0.5` errors
**immediately** (well under a second), naming the real return count; nothing
in the mirror changes.

A ~2s stall on the bad return index means the guard read is not going through
the vendored getter that always replies.
