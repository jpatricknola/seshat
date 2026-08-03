# Recording

`record_clip` and `stop_recording` shipped 2026-07-29 having **never executed
through the tool path** — the only verification behind them was a single raw-OSC
fire in 4/4, recorded in
[../archive/PLAN_session_record.md](../archive/PLAN_session_record.md) under
Testing: *"nothing below has executed through the tool path."* Four assumptions
are load-bearing and unreachable by `mix test`. The first three tests here are
the ones that must pass before anyone trusts the pair.

## Fixed-length take

*Run mode: agent*
*Last run: 2026-08-03 — **found broken, fixed, now passes.** First run through
the tool path since the feature shipped 2026-07-29, and `record_clip` refused
every call: `will_record_on_start` read `False` on a MIDI track with an
instrument, a bare MIDI track and an audio track, transport stopped and playing,
`session_record` off and on — while `arm`, `can_be_armed` and `has_midi_input`
all read true, monitoring was Auto, the slot was empty and the engine was
running. Firing the same slot on the same armed track **past the guard**
(`osc_send.py /live/clip_slot/fire 1 0`) recorded immediately, proving the
property is not the answer to "would firing this slot record?". The guard was
downgraded from a refusal to an advisory in the reply
(`Handlers.check_will_record/2`), with two regression tests in
`handlers_test.exs`.*

*After the fix: `record_clip bars: 2` on a disarmed track fired, Live stopped the
take itself, and `get_clip_properties` reported **exactly 8.0 beats, loop on,
0.0–8.0** — this test's assertion, met. `will_record_on_start` still reads
`False` on this machine, so the advisory sentence appears in the reply; that is
now cosmetic rather than blocking.*

Empty slot, armed MIDI track, transport stopped, `record_clip bars: 2` →
recording starts immediately, Live stops it itself, and `get_clip_properties`
shows exactly 8.0 beats, looping.

This also exercises `will_record_on_start` on the happy path: if Live gates that
property on anything beyond "armed track, empty slot", `record_clip` errors on
*every* call and it surfaces here first.

## Auto-arm

*Run mode: agent*
*Last run: 2026-08-03 — passed after the guard fix above. `record_clip bars: 2`
on a **disarmed** track armed it and the reply carried "Armed the track first."
Live's log confirms the sequence: `arm = False`, `can_be_armed = True`,
`arm (new value 1)`, re-read `arm = True`. `arm_track/1`'s re-read raised no
false error. **The exclusive-arm question is still unanswered** — this set had
no other armed track to lose, so whether Live's exclusive-arm preference
silently disarms one elsewhere remains untested, and the disclosure still
doesn't mention it.*

*The auto-arm mechanism was never at fault for the guard failure: it ran
correctly before the fix too, and the refusal that followed disclosed the side
effect ("This call armed the track on the way in…") only when the call had
actually armed something.*

The same on a **disarmed** track → the tool arms it and the reply says "Armed the
track first." Then check what Live's exclusive-arm preference did to whatever was
armed before — the disclosure currently doesn't mention it, and if exclusive arm
silently disarms another track that sentence needs to say so. If `set/arm` doesn't
land at all, the re-read in `arm_track/1` turns it into a loud error rather than a
lie.

## Audio take — the headline

*Run mode: user — requires routed audio input and judgment by ear*
*Last run: —*

An audio track with an input routed, 4 bars → audible material in the clip. This
is the capability the whole feature exists for and the one thing `capture_midi`
can never do. A silent take means the input isn't set, which Seshat cannot see or
fix.

## Open-ended take and the re-fire

*Run mode: agent*
*Last run: 2026-08-03 — passed, end to end through the tool after the guard fix.
`record_clip` with no `bars` replied "Recording into track 1, slot 3 until
stop_recording"; `stop_recording` then replied "it ends at the next quantization
boundary and keeps looping", and `get_clip_properties` showed **6.0 beats, loop
on, 0.0–6.0** — an exact 2-bar boundary in 6/8. Confirmed independently earlier
in the same session on a take started past the guard, which landed on **32.0
beats** (8 bars of 4/4). **The load-bearing assumption at the top of this test
holds:** firing a recording slot ends the take on the launch-quantization
boundary and leaves it looping. The `/live/song/set/session_record 0` fallback is
not needed.*

⚠️ `stop_recording` assumes that firing a recording slot ends the take at the next
launch-quantization boundary and drops the clip into looped playback.
`record_clip` with no `bars`, then `stop_recording` → confirm it ends on the bar
line and keeps looping. If Live does something else, the fallback is
`/live/song/set/session_record 0` (immediate, unquantized) — a different address
and a different reply.

## Echo wording

*Run mode: agent*
*Last run: 2026-08-03 — **found broken, fixed, now passes both cases.** The
feared failure never occurred: `is_triggered` read true in the window every
time, so a healthy take was never called a hard failure. But "Recording now."
was unreachable — five takes with the transport verified stopped all replied
"Queued". Proved a defect rather than a wrong expectation by setting
`/live/song/set/clip_trigger_quantization 0` (None), leaving **no boundary to be
queued for**: the reply still said "Queued" while `get_clip_slots` showed the
slot `[recording]`.*

*Root cause measured, and it was not where it looked. Polling straight after the
fire, **`has_clip`** — `record_echo/2`'s *first* read — returned `False` at
+0ms and `True` at +99ms, with `is_recording` already true by then. The echo
raced Live materialising the clip and took the false `has_clip` as "no clip yet,
so it must be waiting". `record_echo/2` now re-reads `has_clip` once before
concluding queued; two regression tests in `handlers_test.exs` pin both arms.*

*After the fix: quantization None, transport stopped → **"Recording now."**;
quantization 1 bar, transport playing → **"Queued"**, and that take landed at
8.0 beats. Global quantization restored to `q_bar`.*

⚠️ Fire with the transport **playing** → the reply must say "Queued". That depends
on `is_triggered` reading true between the fire and the boundary; if it reads
false, `queued_or_nothing/2` mislabels a healthy take as a hard failure. Fire with
the transport **stopped** → "Recording now."

## Two bars is two bars in 6/8

*Run mode: agent*
*Last run: 2026-08-03 — passed, both halves, after the guard fix. After
`set_time_signature 6/8` a plain `get_session_state` with no `refresh: true`
already reported 6/8 via the listener push. `record_clip bars: 2` then echoed "2
bars (6.0 beats)" and produced a clip of **exactly 6.0 beats** — two bars, not
four. `record_length_beats/3` counting quarter-note song beats regardless of
signature is now confirmed against Live 12.4.3 through the tool path, not just
by arithmetic. 4/4 restored afterwards.*

Set 6/8 with `set_time_signature`, then `get_session_state` **without**
`refresh: true` should already show 6/8. Then `record_clip bars: 2` must give
**two bars**, not four: `record_length_beats/3` counts quarter-note song beats
regardless of signature (6/8 × 2 bars = 6.0 beats), confirmed against Live
2026-07-31.

## Each guard produces its own error with nothing fired

*Run mode: user — includes a group track and input-routing state no tool can create*
*Last run: —*

An occupied slot (names `delete_clip`), a group track (`can_be_armed` false), and
an armable track whose `will_record_on_start` stays false (unroute its input —
needs a routing no tool can create).

## `stop_recording` boundaries

*Run mode: agent*
*Last run: 2026-08-03 — two of three passed after the guard fix; the third was
not reached. **Early stop:** an 8-bar (24.0 beat) take stopped at 6.0 beats —
ended early, looping. **Merely playing:** `stop_recording` on a playing clip
errored "Nothing is recording in slot 0 on track 1, so nothing was fired …  Use
stop_clip to stop a clip that is merely playing," and `get_clip_slots` confirmed
the clip was **still `[playing]`** — the guard runs before any fire, so the
re-fire never restarted it. **Queued window:** not provoked; every
`stop_recording` in this run landed after recording had already begun, so the
misleading "slot is empty" message stayed unreached and its practical importance
is still unmeasured.*

On a fixed-length take it ends it early. On a slot that is merely *playing* it
errors and the clip **keeps playing** — the guard must run before any fire, or the
re-fire restarts the clip. On a slot in the queued window (fired, boundary not
reached) it currently errors with "Slot S on track T is empty… nothing was fired",
which is safe but misleading; note whether that window is long enough in practice
to be worth a better message.

## Recording follow cam

*Run mode: user — requires visual confirmation of Live's selected clip and editor*
*Last run: —*

`record_clip` lands the view on the reddening slot in Session with the detail pane
left alone; `stop_recording` opens the finished take in the note editor (or
waveform, for audio).
