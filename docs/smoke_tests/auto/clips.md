# Clip properties and quantize

Every clip setter is fire-and-forget and Live's own rejection of an invalid loop
range is silent, so `mix test` proves the write-ordering logic and nothing about
whether the writes land. `/live/clip/quantize` never replies on success either,
and its two failure modes are indistinguishable from Seshat's side: a bad grid
integer is reported as a structured `/live/error`, a Remote Scripts copy
predating the fork answers nothing, and the send has returned before either
could arrive.

Drive quantize through the tool, not raw OSC: the string→int mapping, the
before/after diff and the reply wording only exist in `quantize_clip`. Write a
deliberately sloppy MIDI clip first — notes a little either side of the beat, at
least one pair of same-pitch notes close together.

## Write ordering and invalid states

*Last run: 2026-08-28 — passed, no drift. On the 8-beat clip braced 0.0–2.0 one call for 4.0–8.0 landed and echoed `loop_end` before `loop_start`; the single-sided `loop_start: 9.0` errored "loop_start 9.0 is not before the current loop_end 8.0 — pass loop_end too to move the whole range. Nothing was set." and the re-read showed 4.0–8.0. Raw past-the-guard send not repeated this run.*

*Prior run: 2026-08-03 — passed, and the open question is now answered. On an
8-beat clip braced 0.0–2.0, one call asking for 4.0–8.0 landed, and the reply
showed the reorder directly — `loop_end` echoed **before** `loop_start`. The
single-sided invalid write (`loop_start` 9.0 against the current `loop_end` 8.0)
errored "loop_start 9.0 is not before the current loop_end 8.0 — pass loop_end
too to move the whole range. Nothing was set," and a re-read confirmed the brace
still at 4.0–8.0. **Live ignores an inverted loop point; it does not clamp** —
measured by sending `/live/clip/set/loop_start 1 2 9.0` raw past the guard, after
which the brace was unchanged and `Log.txt` carried `ERROR:abletonosc:613 - Error
setting clip.loop_start: Cannot set LoopStart behind LoopEnd`. Live raises,
AbletonOSC catches and logs, and the setter moved nothing — which is what the
Elixir-side guard exists to replace. **The "nothing reaches the wire" half of
this reading is superseded**: it was measured before the fork's
dispatch-boundary rework, which now sends `/live/error ["request",
"/live/clip/set/loop_start", …]` for the same raise (`priv/AbletonOSC/API.md`,
"The loop pair rejects an inversion"). It still reaches nobody here — the
setter is a `send_message/2` that has returned by then — so the guard's job is
unchanged.*

Move a brace entirely past the old one in one call (the end-first path) and
confirm it lands. Then make a single-sided invalid write (`loop_start` beyond the
current `loop_end`) and confirm it errors naming the current value with Live
untouched.

## The loop pair with looping off

*Last run: 2026-08-28 — passed, no drift. `looping: false` alone read `Loop: off, from beat 0.0 to 8.0` with markers 0.0–8.0 (loop pair spanning the clip, not tracking a 4.0–8.0 brace set moments earlier); `looping: true, loop_start: 2, loop_end: 6` in one call produced exactly 2.0–6.0. The stale single-sided validation was not provoked this run.*

*Prior run: 2026-08-04 — passed, no drift, re-run after `get_clip_properties`'
pair-context and write-back reads moved onto the batched helper. `looping: false`
alone, then a read: `Loop: off, from beat 0.0 to 4.0 (4.0 beats)` with play
markers 0.0–4.0 — the loop pair spanning the whole clip rather than tracking the
markers, exactly as the 2026-08-03 run below recorded. `looping: true` with
`loop_start: 1.0` and `loop_end: 3.0` in one call then produced exactly 1.0–3.0,
so the batched pair-context read and the batched write-back both still order and
report correctly. Worth recording: the `looping: false` call is also the* empty
*pair-context case — it touches neither loop nor marker pair, so
`read_clip_properties/3` is handed `[]` and must not reach
`Transport.query_batch/2`, which raises on an empty batch. It did not, and the
call succeeded.*

*Prior run: 2026-08-03 — **defect reproduced, but its blast radius is smaller than
this test assumed; both are recorded below.** With looping off and play markers
at 0.0–2.0, the loop pair read **0.0–8.0** — the clip extent, *not* the markers
(the earlier reading that looked like marker-tracking was a coincidence: the
markers were 0.0–8.0 then too). The test text above is corrected accordingly.
Setting `looping: true` with `loop_start: 2, loop_end: 6` in one call produced
exactly 2.0–6.0. The stale read is real: with looping off, a single-sided
`looping: true` + `loop_start: 4.0` validated against the pre-toggle `loop_end`
of 8.0 while the true post-toggle end was 6.0. Pushing that further —
`loop_start: 7.0`, which passes validation against the stale 8.0 but Live rejects
against the real 6.0 — did **not** produce a false success: the per-write re-read
caught it and reported "loop_start: Live reports 4.0, not the 7.0 that was sent
(was 0.0)".*

With looping off, `get_clip_properties` shows the loop points spanning the whole
clip (0.0 to the clip length), regardless of where the play markers sit. Then set
`looping` *and* the loop points in one call and confirm the intended brace
results.

This is the known defect tracked in [../ROADMAP.md](../ROADMAP.md) as
"`set_clip_properties` reads the loop pair before the `looping` toggle lands" —
`set_clip_properties` reads the
pair before the `looping` toggle goes out, so on such a clip both the write
ordering and the single-sided validation can run against stale values. Until that
ships, expect the *validation* to be wrong while the *report* stays honest: the
post-write re-read is what stops a stale-read pass from becoming a claimed
success. Record what you saw rather than treating it as new.

## Clip properties read in one breath, and read true

*Last run: 2026-08-28 — passed. "BatchProbe" (looping 2.0–6.0, launch quantization 1 bar, velocity amount 0.5) read back every value correctly in **0.30s** wall clock via mcp_call.py; empty slot 3 errored cleanly ("Slot 3 on track 1 is empty…") in **0.19s**. Audio arm still uncovered (manual).*

`get_clip_properties` reads a MIDI clip as an `ensure_clip` guard plus **one
batched tick** of 12 getters (`is_midi_clip` + the 11 common properties)
instead of 13+ serialized ~100ms round trips. Correctness and speed are both
the test: a batch that silently degraded to serial reads would still return
right answers, and a broken echo-prefix match would return *wrong* answers
fast.

On a MIDI clip whose properties were just set to known values through
`set_clip_properties` (a distinctive name, a brace like 1.0–3.0, looping on),
call `get_clip_properties` once and time the call (`mcp_call.py` round-trip
timing, the [devices.md](devices.md) precedent). Every reported property must
match what was just confirmed, and the whole call must land **well under a
second** — the serialized design measured ~1.5s per clip. Then call it on an
empty slot: one immediate clean error naming the slot, not a stall and not a
cascade of per-property errors.

A wrong value (another clip's name, a loop point that was never set) means
reply correlation broke — batching moved the echo checks into
`Seshat.OSC.Transport`, so this is the test that they still hold on a real
wire. A correct-but-slow read (≥1.3s) means the batch is not actually
pipelining. The audio arm (gain/warp, the second batch) needs an audio clip
no tool can create — that half lives in
[../manual/engineered-state.md](../manual/engineered-state.md) § An audio
clip's audio-only properties still read.

## Quantize lands on 1/16ths, not 1/32nds

*Last run: 2026-08-28 — passed. 7-note sloppy clip at "1/16"/1.0 landed on 0.0, 0.5, 1.0, 1.25, 2.0, 2.5 — 1.37 → **1.25**, all 0.25-beat multiples.*

`"1/16"` at amount 1.0. Notes land on the grid in the note editor and the reply's
counts match what visibly moved. **Confirm the landing positions are 0.25-beat
multiples**; a 0.125 spacing means a 1/32 grid was sent.

That single observation caught the documented `GridQuantization` table being wrong
in *every* row; the fix is `Seshat.Tools.Handlers.grid_quantization/1`, not the
schema. The corrected table, measured 2026-07-31, is in
[../../../priv/AbletonOSC/API.md](../../../priv/AbletonOSC/API.md) under `/live/clip/quantize`
— this test guards that table and is not a second copy of it.

## Partial strength moves notes toward the grid

*Last run: 2026-08-28 — passed. "1/16" at 0.5: 1.37 → **1.31**; others 0.03→0.015, 0.48→0.49, 1.06→1.03, 1.97→1.985, 2.52→2.51, 2.58→2.54; count stayed 7, reply "7 of 7 note(s) … at 50% strength".*

`undo`, then the same grid at amount 0.5. Notes move *toward* the grid, not onto
it, and the reply still counts them. Live interpolates linearly: a note at 1.37
with a 1.25 target lands at 1.31.

## An already-tight clip reports no change without reading as an error

*Last run: 2026-08-28 — passed. Second 1.0 quantize replied "Quantize sent, but no note changed — … may already sit on the 1/16 grid at 100% strength. If the timing audibly didn't change, the installed AbletonOSC may predate…" — benign reading leads.*

Quantize the same clip twice at 1.0. The second call reports "no note changed" —
read that reply and confirm its stale-install hint doesn't read as a failure,
because here silence is normal.

A quantize that changes nothing still costs an undo step, so a later `undo` back
past it needs one call per quantize sent, not per quantize that moved a note.

## Triplet grids reach values the old docs wrote off

*Last run: 2026-08-28 — passed. Straight clip (0.2, 0.45, 1.4, 2.1) at "1/8T" → 0.3333, 0.3333, 1.3333, 2.0; undone, "1/16T" → 0.1667, 0.5, 1.3333, 2.1667.*

`"1/8T"` and `"1/16T"` on a straight part: notes land on thirds and sixths of a
beat. The old docs claimed triplet grids did not exist.

## Collisions are reported as what they were

*Last run: 2026-08-28 — passed, both arms. Merge at 1.0: C4 2.52 (vel 70) and 2.58 (vel 110) both on 2.5, 7→6 notes, survivor vel 110, reply named the merge. Trim at 0.5: 2.51/2.54, count 7, earlier note dur 0.03, reply named the trim. Also observed: `write_midi_notes` itself trimmed the 2.52 note to 0.06 on the original write because of the same-pitch overlap.*

A full quantize that stacks two same-pitch notes. Expect the count-change wording:
same-point collisions **merge** into one note keeping the *later* velocity, while
a post-move same-pitch overlap instead **trims** the earlier note's duration. Both
are Live's behaviour, measured — the reply should say which happened.

## Quantize in an odd meter

*Last run: 2026-08-28 — passed. 6/8, same sloppy clip at "1/16"/1.0: 0.0, 0.5, 1.0, 1.25, 2.0, 2.5 with the 7→6 merge keeping vel 110 — identical to 4/4. 4/4 restored.*

The mapping measured identical in 4/4 and 6/8, so a quantize in an odd meter is a
cheap confirmation nothing meter-dependent crept in.

## Scene names ride one bulk reply

*Last run: 2026-08-28 — passed. 8-scene set, scene 1 renamed "Chorus"; `get_clip_slots` listed all 8 in order, `1 "Chorus"`, the other seven as `""`, no error and no hole.*

`get_clip_slots` reads every scene name in a single no-arg
`/live/song/get/scenes/name` query, length-checked against `num_scenes` —
the first production use of that address from `lib/` (the per-scene loop it
replaced is gone; no `/live/scene/get/name` datagram should ever appear).

In a set with at least three scenes, rename one with `set_scene_name` (e.g.
scene 1 → "Chorus"), then call `get_clip_slots`. The grid must list every
scene, in index order, with the rename showing on the right row and the
other names untouched — unnamed scenes render as Live shows them, not as
errors or holes.

A wrong name on the right row, rows out of order, or a scene count that
disagrees with Live's own grid means the bulk read's ordering or length
check is wrong in `query_scene_names`
([lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)). An
error advising a re-read on a quiet set means the length check is comparing
against the wrong count.

## `edit_notes` rewrites only the window

*Last run: 2026-08-28 — passed. Reply "Edited 2 notes in pitches 60-60, beats 0.0-9999.0 … velocity +10. Read back and confirmed."; pitch-60 notes read vel 110.0 and 47.0 with start/dur unchanged to every digit (0.0/0.3333, 1.6667/1.75), pitch 64 and 67 identical; one `undo` restored the first read exactly. Note: the reply leaks the 9999.0 time_span sentinel — see ROADMAP.*

`edit_notes` is read → `/live/clip/remove/notes` → `/live/clip/add/notes` →
read, in one undo step. The measured shape (2026-08-27) and the two
conversions it depends on — velocity re-sent as an integer, mute as `0|1` —
are in [priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md) and in the
handler; this test is that they still hold.

On a fresh MIDI track, `write_midi_notes` four notes with off-grid values:
pitch 60 at 0.0 (duration 0.3333, velocity 100), pitch 60 at 1.6667 (1.75,
37), pitch 64 at 0.25 (0.5, 100), pitch 67 at 2.125 (0.125, 127).
`get_clip_notes`, then `edit_notes start_pitch: 60, pitch_span: 1,
velocity_delta: 10`, then `get_clip_notes` again.

The reply says 2 notes matched and 2 read back. The two pitch-60 notes show
velocity 110 and 47 with their start and duration **unchanged to every printed
digit**; the pitch-64 and pitch-67 notes are identical to the first read. One
`undo` restores the first read exactly.

A note count that dropped means the `add` datagram was rejected — check the
velocity/mute types on the wire. Starts or durations that moved means the
handler rounded what it read. An untouched note that changed means the remove
window was wider than the read window.

## A window edit that would leave the range is refused

*Last run: 2026-08-28 — passed once the test was corrected: `transpose: 60` on G4 landed on 127 (G9, legal) and was **not** refused — the test's own arithmetic was wrong, fixed to 61 above. `transpose: 61` refused "would push 1 note above G9 (MIDI 127) … nothing was changed"; `shift: -1.0` refused "would start 2 notes before the clip's beat 0 … nothing was changed"; clip identical after both; `transpose: -12` read back as G3 (55).*

Same clip. `edit_notes start_pitch: 67, pitch_span: 1, transpose: 61` (G4 →
one past G9; 127 *is* G9, so +60 lands exactly on the ceiling and is legal —
this test originally said 60 and passed the wrong way) and `edit_notes shift:
-1.0` on the whole clip (the 0.0 note would go negative).

Both refuse before sending, each naming what would have left the range and
how many notes; `get_clip_notes` is identical to before. A `transpose: -12`
on the same window succeeds and reads back as pitch 55.

Notes piled onto pitch 127 or 0, or a note at a negative start, means the
refusal is happening after the rewrite.

## `delete: true` empties the window and nothing else

*Last run: 2026-08-28 — passed on semantics, wording defect found. Three notes remained including the 1.6667 note; one `undo` brought the fourth back. But the reply read "Deleted 1 note in the whole clip of the clip in slot 1" — `window_phrase/1` in handlers.ex says "the whole clip" whenever the pitch window is default, ignoring the beats 2.0–3.0 window that was given. See ROADMAP.*

Same clip. `edit_notes start_time: 2.0, time_span: 1.0, delete: true`. The
window is beats 2–3; the pitch-60 note starting at 1.6667 sounds into it but
does not *start* in it.

The reply says 1 note matched (pitch 67 at 2.125) and 0 remain in the window;
`get_clip_notes` shows three notes, the 1.6667 note among them. One `undo`
brings the fourth back.

The 1.6667 note gone means the window was matched by overlap rather than by
start — the measured semantics of `remove/notes` — and the description's
promise is wrong.

## Renaming rides `set_clip_properties`

*Last run: 2026-08-28 — passed. One call `name: "Verse A", looping: true` echoed both (`looping: on`, `name: 'Verse A'`); `get_clip_slots` showed "Verse A" on slot 1; `get_clip_properties` showed loop on.*

`set_clip_properties name: "Verse A", looping: true` on an existing clip, one
call. The reply echoes both read back; `get_clip_slots` shows the new name on
the right slot; `get_clip_properties` shows looping on.

A reply that lists `looping` but not `name`, or a name reported with a number
formatter's output, means the string property missed the write list or the
formatter.
