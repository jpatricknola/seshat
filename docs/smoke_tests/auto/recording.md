# Recording

`record_clip` and `stop_recording` shipped 2026-07-29 having **never executed
through the tool path** — the only verification behind them was a single raw-OSC
fire in 4/4, recorded in
[../archive/PLAN_session_record.md](../archive/PLAN_session_record.md) under
Testing: *"nothing below has executed through the tool path."* Four assumptions
are load-bearing and unreachable by `mix test`. The first three tests here are
the ones that must pass before anyone trusts the pair.

## Fixed-length take

*Last run: 2026-11-08 — passed. `record_clip bars: 2` on a disarmed MIDI track, transport stopped, replied "Recording now." and get_clip_properties read exactly 8.0 beats, loop on. The `will_record_on_start` advisory sentence still appears on Live 12.4.6, cosmetic as before.*

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

*Last run: 2026-11-08 — passed. The same call armed the track and the reply carried "Armed the track first." The exclusive-arm question remains unmeasured: track 1 was armed beforehand, but `set_mixer arm: false` on it afterwards replies only "disarmed." without a was-value, so whether exclusive arm had already disarmed it could not be read through the tools.*

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

## Open-ended take and the re-fire

*Last run: 2026-11-08 — passed. `record_clip` with no bars replied "Recording into track 2, slot 2 until stop_recording … Queued" (the previous take had left the transport running); `stop_recording` 3s later replied "it ends at the next quantization boundary and keeps looping" and get_clip_properties read 8.0 beats, loop on — an exact 2-bar boundary in 4/4.*

⚠️ `stop_recording` assumes that firing a recording slot ends the take at the next
launch-quantization boundary and drops the clip into looped playback.
`record_clip` with no `bars`, then `stop_recording` → confirm it ends on the bar
line and keeps looping. If Live does something else, the fallback is
`/live/song/set/session_record 0` (immediate, unquantized) — a different address
and a different reply.

## Echo wording

*Last run: 2026-11-08 — passed both cases. `clip_trigger_quantization 0` (None) → "Recording now.", 4.0-beat take; quantization restored to 4 (`q_bar`), transport playing → "Queued", 8.0-beat take. Caveat: the None case ran with the transport possibly still running from the previous take, so it proves the None path, not stopped-transport specifically.*

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

*Last run: 2026-11-08 — passed, both halves. After `set_time_signature 6/8` a plain get_session_state already read 6/8; `record_clip bars: 2` echoed "2 bars (6.0 beats)" and produced exactly 6.0 beats, loop on. 4/4 restored.*

Set 6/8 with `set_time_signature`, then `get_session_state` **without**
`refresh: true` should already show 6/8. Then `record_clip bars: 2` must give
**two bars**, not four: `record_length_beats/3` counts quarter-note song beats
regardless of signature (6/8 × 2 bars = 6.0 beats), confirmed against Live
2026-07-31.

## `stop_recording` boundaries

*Last run: 2026-11-08 — passed, all three reached for the first time. **Early stop:** a 32.0-beat take stopped at 8.0 beats, looping. **Merely playing:** `stop_recording` on a fired clip errored "Nothing is recording in slot 1 on track 2 … Use stop_clip to stop a clip that is merely playing" and get_clip_slots still showed `[playing]`. **Queued window:** transport playing, `record_clip` (no bars) then `stop_recording` 0.9s later, inside the queued window — it did **not** hit the "slot is empty" message; the slot already had its clip (`has_clip` goes true at fire time), so the re-fire was sent and the take ran one bar, landing as a 4.0-beat clip. The misleading message looks unreachable in practice on Live 12.4.6; the window it guarded closes at fire time, not at the boundary.*

On a fixed-length take it ends it early. On a slot that is merely *playing* it
errors and the clip **keeps playing** — the guard must run before any fire, or the
re-fire restarts the clip. On a slot in the queued window (fired, boundary not
reached) it currently errors with "Slot S on track T is empty… nothing was fired",
which is safe but misleading; note whether that window is long enough in practice
to be worth a better message.


## An audio take names its input, or refuses before recording

*Last run: 2026-11-08 — passed. A fresh audio track set to `input_type: "No Input"` was refused before recording: "Track 3 is an audio track with nothing routed into its input, so nothing was recorded … Set one with set_mixer (input_type, plus input_channel …) … It offers: 'Ext. In', 'Resampling', 'A-A-Smoke Return', 'Main', 'No Input'."; slot still empty. After `input_type: "Ext. In"`, `record_clip bars: 1` recorded and replied `Listening to "Ext. In" on "1/2"`, verbatim. Live 12.4.6.*

Create an audio track and route it to nothing — `set_mixer input_type:
"No Input"`. Call `record_clip` on an empty slot with `bars: 1`. Then set a real
input with `set_mixer`'s `input_type` (any name from the list its error or
`get_session_state` reports), and call `record_clip` again on another empty slot.

Setting `"No Input"` explicitly is the whole method, and substituting "just
don't set the input" is what makes this test unable to fail: a freshly created
audio track does **not** start unrouted — measured 2026-08-30 on Live 12.4.5, a
new one came up on `Ext. In` / `1`, so the first call records and the guard is
never exercised.

The first call is **refused before any recording starts** — the reply says the
track has no input routed, names the `set_mixer` properties that fix it, and
`get_clip_slots` shows the slot still empty. The second call records, and its
reply names the input verbatim, exactly as Live spells it.

A silent take that had to be discovered afterwards is the whole failure this
prevents, and it is unrecoverable in the sense that matters: the performance is
gone. A first call that records anyway means the pre-read was skipped or its
result ignored; a reply that paraphrases or normalises the input name means
someone interpreted a string that belongs to the user's interface, not to us.

Live's name for an unrouted audio input is `"No Input"` — a routing type like
any other, listed on `available_input_routing_types` beside `Ext. In` and
`Resampling` (measured 2026-08-30 against Live 12.4.5, closing what
[PLAN_sing_it_back_as_midi.md](../../archive/PLAN_sing_it_back_as_midi.md)
carried as open question 2). It is not the empty string the first
implementation matched on, and this test is where that would have been caught.
⚠️ Not yet recorded in [API.md](../../../priv/AbletonOSC/API.md) — that is
fork-owned and needs a fork commit, not an edit here.

⚠️ On a machine with no audio input device, Live also reads `can_be_armed` as
false under `"No Input"`. So a refusal alone does not prove the input guard
fired: check the wording. "nothing routed into its input" naming `set_mixer` is
this guard; anything about arming or group tracks means the later
`can_be_armed` read stopped the take instead, which is the regression this
check exists to catch.

## Monitoring set to off warns but still records

*Last run: 2026-11-08 — passed. With `Ext. In` routed and `monitoring: "off"`, `record_clip bars: 1` ran and the reply carried "Monitoring is off, so the input won't be heard through Live while it records; that is normal … set_mixer monitoring: 'in' changes it." get_clip_slots showed the 4.0-beat clip. Also observed: the fresh audio track already read monitoring off on the first take, before this step set it. Monitoring restored to auto.*

On an audio track with a real input routed, `set_mixer monitoring: "off"`, then
`record_clip bars: 1` on an empty slot.

The take **runs** — the reply warns that monitoring is off and records anyway.
`get_clip_slots` shows the clip.

Monitoring off is legal and normal when the player hears themselves through
their interface rather than through Live. A refusal here would block a correct
setup; a silent record would hide a genuinely likely mistake. The reply saying
both things is the whole behaviour.
