# Clip properties and quantize

Every clip setter is fire-and-forget and Live's own rejection of an invalid loop
range is silent, so `mix test` proves the write-ordering logic and nothing about
whether the writes land. `/live/clip/quantize` never replies either — success, a
bad grid integer, and a Remote Scripts copy predating the fork are all the same
silence on the wire.

Drive quantize through the tool, not raw OSC: the string→int mapping, the
before/after diff and the reply wording only exist in `quantize_clip`. Write a
deliberately sloppy MIDI clip first — notes a little either side of the beat, at
least one pair of same-pitch notes close together.

## A loop brace edit lands and reads back

*Run mode: user — requires visual and playback confirmation in Live*
*Last run: —*

Capture or write an 8-beat MIDI clip, then "loop beats 4–8": the brace visibly
moves in the note editor, playback loops that section, and the reply echoes
4.0–8.0 plus the new length.

## Write ordering and invalid states

*Run mode: agent*
*Last run: —*

Move a brace entirely past the old one in one call (the end-first path) and
confirm it lands. Then make a single-sided invalid write (`loop_start` beyond the
current `loop_end`) and confirm it errors naming the current value with Live
untouched. Note for the record whether Live clamps or ignores an inverted loop
point.

## The loop pair with looping off

*Run mode: agent*
*Last run: —*

With looping off, `get_clip_properties` should show the loop points tracking the
play markers. Then set `looping` *and* the loop points in one call and confirm the
intended brace results.

This is the known defect tracked as ROADMAP #12 — `set_clip_properties` reads the
pair before the `looping` toggle goes out, so on such a clip both the write
ordering and the single-sided validation can run against stale values. Until that
ships, a failure here is the expected result; record what you saw rather than
treating it as new.

## Audio clip properties

*Run mode: user — requires a prepared audio clip and visual confirmation in Live*
*Last run: —*

Set `gain` — the echo shows a plausible dB from `gain_display_string`. Change
`warp_mode`/`warping` and see it in clip view. Confirm `velocity_amount` and
`legato` read and write without timeouts: they are **assumed** present on audio
clips and never measured, so if a read stalls, the fix is moving them to the
MIDI-only branch of `@clip_common_reads`. On an **unwarped** audio clip, confirm
the reply says "seconds" rather than "beats".

Then the MIDI guard from the other side: `gain` on a MIDI clip errors cleanly and
nothing is sent.

## The clip reader

*Run mode: user — includes visual confirmation of selection and the note editor*
*Last run: —*

`get_clip_properties` on a freshly captured clip reports the length and brace Live
inferred; on an empty slot it errors via `ensure_clip` rather than burning
fourteen timeouts. A brace edit leaves the clip selected with the note editor
open.

## Quantize lands on 1/16ths, not 1/32nds

*Run mode: agent*
*Last run: —*

`"1/16"` at amount 1.0. Notes land on the grid in the note editor and the reply's
counts match what visibly moved. **Confirm the landing positions are 0.25-beat
multiples**; a 0.125 spacing means a 1/32 grid was sent.

That single observation caught the documented `GridQuantization` table being wrong
in *every* row; the fix is `Seshat.Tools.Handlers.grid_quantization/1`, not the
schema. The corrected table, measured 2026-07-31, is in
[../abletonosc-api-docs.md](../abletonosc-api-docs.md) under `/live/clip/quantize`
— this test guards that table and is not a second copy of it.

## Partial strength moves notes toward the grid

*Run mode: agent*
*Last run: —*

`undo`, then the same grid at amount 0.5. Notes move *toward* the grid, not onto
it, and the reply still counts them. Live interpolates linearly: a note at 1.37
with a 1.25 target lands at 1.31.

## An already-tight clip reports no change without reading as an error

*Run mode: agent*
*Last run: —*

Quantize the same clip twice at 1.0. The second call reports "no note changed" —
read that reply and confirm its stale-install hint doesn't read as a failure,
because here silence is normal.

## Triplet grids reach values the old docs wrote off

*Run mode: agent*
*Last run: —*

`"1/8T"` and `"1/16T"` on a straight part: notes land on thirds and sixths of a
beat. The old docs claimed triplet grids did not exist.

## Collisions are reported as what they were

*Run mode: agent*
*Last run: —*

A full quantize that stacks two same-pitch notes. Expect the count-change wording:
same-point collisions **merge** into one note keeping the *later* velocity, while
a post-move same-pitch overlap instead **trims** the earlier note's duration. Both
are Live's behaviour, measured — the reply should say which happened.

## Quantize refusals cost nothing

*Run mode: user — includes visual confirmation that the clip is selected*
*Last run: —*

`amount: 0` errors immediately (0% strength moves nothing), and an empty slot
errors via `ensure_clip` — neither should take a guard timeout. An audio clip is
rejected cleanly by `ensure_midi_clip`, with no warp markers touched. One `undo`
restores the take, and the quantized clip is left selected with the note editor
open — the notes snapping on screen *is* the confirmation.

## Quantize in an odd meter

*Run mode: agent*
*Last run: —*

The mapping measured identical in 4/4 and 6/8, so a quantize in an odd meter is a
cheap confirmation nothing meter-dependent crept in.
