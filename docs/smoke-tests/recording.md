# Recording

`record_clip` and `stop_recording` shipped 2026-07-29 having **never executed
through the tool path** — the only verification behind them was a single raw-OSC
fire in 4/4, recorded in
[../archive/PLAN_session_record.md](../archive/PLAN_session_record.md) under
Testing: *"nothing below has executed through the tool path."* Four assumptions
are load-bearing and unreachable by `mix test`. The first three tests here are
the ones that must pass before anyone trusts the pair.

## Fixed-length take

*Last run: —*

Empty slot, armed MIDI track, transport stopped, `record_clip bars: 2` →
recording starts immediately, Live stops it itself, and `get_clip_properties`
shows exactly 8.0 beats, looping.

This also exercises `will_record_on_start` on the happy path: if Live gates that
property on anything beyond "armed track, empty slot", `record_clip` errors on
*every* call and it surfaces here first.

## Auto-arm

*Last run: —*

The same on a **disarmed** track → the tool arms it and the reply says "Armed the
track first." Then check what Live's exclusive-arm preference did to whatever was
armed before — the disclosure currently doesn't mention it, and if exclusive arm
silently disarms another track that sentence needs to say so. If `set/arm` doesn't
land at all, the re-read in `arm_track/1` turns it into a loud error rather than a
lie.

## Audio take — the headline

*Last run: —*

An audio track with an input routed, 4 bars → audible material in the clip. This
is the capability the whole feature exists for and the one thing `capture_midi`
can never do. A silent take means the input isn't set, which Seshat cannot see or
fix.

## Open-ended take and the re-fire

*Last run: —*

⚠️ `stop_recording` assumes that firing a recording slot ends the take at the next
launch-quantization boundary and drops the clip into looped playback.
`record_clip` with no `bars`, then `stop_recording` → confirm it ends on the bar
line and keeps looping. If Live does something else, the fallback is
`/live/song/set/session_record 0` (immediate, unquantized) — a different address
and a different reply.

## Echo wording

*Last run: —*

⚠️ Fire with the transport **playing** → the reply must say "Queued". That depends
on `is_triggered` reading true between the fire and the boundary; if it reads
false, `queued_or_nothing/2` mislabels a healthy take as a hard failure. Fire with
the transport **stopped** → "Recording now."

## Two bars is two bars in 6/8

*Last run: —*

Set 6/8 with `set_time_signature`, then `get_session_state` **without**
`refresh: true` should already show 6/8. Then `record_clip bars: 2` must give
**two bars**, not four: `record_length_beats/3` counts quarter-note song beats
regardless of signature (6/8 × 2 bars = 6.0 beats), confirmed against Live
2026-07-31.

## Each guard produces its own error with nothing fired

*Last run: —*

An occupied slot (names `delete_clip`), a group track (`can_be_armed` false), and
an armable track whose `will_record_on_start` stays false (unroute its input —
needs a routing no tool can create).

## `stop_recording` boundaries

*Last run: —*

On a fixed-length take it ends it early. On a slot that is merely *playing* it
errors and the clip **keeps playing** — the guard must run before any fire, or the
re-fire restarts the clip. On a slot in the queued window (fired, boundary not
reached) it currently errors with "Slot S on track T is empty… nothing was fired",
which is safe but misleading; note whether that window is long enough in practice
to be worth a better message.

## Recording follow cam

*Last run: —*

`record_clip` lands the view on the reddening slot in Session with the detail pane
left alone; `stop_recording` opens the finished take in the note editor (or
waveform, for audio).
