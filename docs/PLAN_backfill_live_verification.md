# Backfill: live checks whose feature shipped before they ran

**This plan never ships and is never archived.** It is the standing home for
acceptance checks that were written for a feature, went unrun, and would
otherwise have been archived alongside a plan marked done — which would
silently convert *never verified* into *verified*.

An acceptance test's job is done when it **passes**, not when the feature ships.
`/ship`'s promote-or-retire step carries unrun checks here instead of retiring
them; `/smoke-test` runs them like any other plan's `## Live verification`
section. When a check passes, **delete it from this file** and record the pass
in the run report. When the file empties, leave it empty — an empty backfill is
the good state, and the file's existence is what keeps the next one from being
lost.

Checks here are **not** invariants. They do not belong in
[live-invariants.md](live-invariants.md), which admits only standing properties,
measurement tripwires, and model-behaviour probes. A check that turns out to
qualify on those grounds gets promoted there and removed from here.

`/full-smoke` does not sweep this file — most of what lands here needs the ears,
hands or hardware routing that a zero-touch sweep excludes by definition — but
its report **names this file's contents in the Uncovered list**, with the count.
A sweep that reads as complete while `record_clip` has still never run is
exactly the failure the list exists to prevent.

---

## Live verification

### `record_clip` / `stop_recording`

**Why it is here:** shipped 2026-07-29 having never executed through the tool
path — the verification behind it was a single raw-OSC fire in 4/4. Recorded
in [archive/PLAN_session_record.md](archive/PLAN_session_record.md) under
Testing: *"nothing below has executed through the tool path."* Four assumptions
are load-bearing and unreachable by `mix test`. Items 1, 2 and 5 must pass
before anyone trusts the pair.

1. **Fixed-length take.** Empty slot, armed MIDI track, transport stopped,
   `record_clip bars: 2` → recording starts immediately, Live stops it itself,
   and `get_clip_properties` shows exactly 8.0 beats, looping. This also
   exercises `will_record_on_start` on the happy path: if Live gates that
   property on anything beyond "armed track, empty slot", `record_clip` errors
   on *every* call and it surfaces here first.
2. **Auto-arm.** Same on a **disarmed** track → the tool arms it and the reply
   says "Armed the track first." Then check what Live's exclusive-arm preference
   did to whatever was armed before — the disclosure currently doesn't mention
   it, and if exclusive arm silently disarms another track that sentence needs
   to say so. If `set/arm` doesn't land at all, the re-read in `arm_track/1`
   turns it into a loud error rather than a lie.
3. **Open-ended take and the re-fire.** ⚠️ `stop_recording` assumes that firing
   a recording slot ends the take at the next launch-quantization boundary and
   drops the clip into looped playback. `record_clip` with no `bars`, then
   `stop_recording` → confirm it ends on the bar line and keeps looping. If Live
   does something else, the fallback is `/live/song/set/session_record 0`
   (immediate, unquantized) — a different address and a different reply.
4. **Echo wording.** ⚠️ Fire with the transport **playing** → the reply must say
   "Queued". That depends on `is_triggered` reading true between the fire and
   the boundary; if it reads false, `queued_or_nothing/2` mislabels a healthy
   take as a hard failure. Fire with the transport **stopped** → "Recording
   now."
5. **Audio take — the headline.** An audio track with an input routed, 4 bars →
   audible material in the clip. This is the capability the whole feature exists
   for and the one thing `capture_midi` can never do. A silent take means the
   input isn't set, which Seshat cannot see or fix.
6. **Non-4/4.** Set 6/8 with `set_time_signature`, then `get_session_state`
   **without** `refresh: true` should already show 6/8. Then `record_clip
   bars: 2` must give **two bars**, not four: `record_length_beats/3` counts
   quarter-note song beats regardless of signature (6/8 × 2 bars = 6.0 beats),
   confirmed against Live 2026-07-31.
7. **Guards, each producing its own error with nothing fired:** an occupied slot
   (names `delete_clip`), a group track (`can_be_armed` false), and an armable
   track whose `will_record_on_start` stays false (unroute its input).
8. **`stop_recording` boundaries.** On a fixed-length take it ends it early. On
   a slot that is merely *playing* it errors and the clip **keeps playing** —
   the guard must run before any fire, or the re-fire restarts the clip. On a
   slot in the queued window (fired, boundary not reached) it currently errors
   with "Slot S on track T is empty… nothing was fired", which is safe but
   misleading; note whether that window is long enough in practice to be worth a
   better message.
9. **Follow cam.** `record_clip` lands the view on the reddening slot in Session
   with the detail pane left alone; `stop_recording` opens the finished take in
   the note editor (or waveform, for audio).

**Uncovered even when run:** whether a take *sounds* right, and the
`will_record_on_start`-false guard in item 7, which needs an input routing no
tool can create. Both need hands on Live.
