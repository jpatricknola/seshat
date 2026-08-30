# Audio to MIDI — Live's own Convert, over OSC

`convert_audio_to_midi` runs Live's *Convert … to New MIDI Track* through the
fork address `/live/clip/audio_to_midi`, guarded by Live's own predicate on
`/live/clip/get/is_convertible_to_midi`. Everything here is OSC — no
Accessibility, no menu, no focus. Two properties shape these checks: the
conversion is **asynchronous** (the reply's `"ok"` means accepted, and the new
track appears up to a few seconds later — `priv/AbletonOSC/API.md`
§ "Conversions"), and the predicate answers `false` for every unconvertible
case alike, so the tool's diagnosis reads (empty slot vs. MIDI clip) are what
turn one bit into a useful refusal.

Set-up: the installed AbletonOSC matches the repo pin (`conversions.py`
present) **and Live has been restarted since `mix abletonosc.install` ran** —
an installed handler is not a loaded one, and against a stale load every check
below fails as a timeout that looks like "Ableton isn't running". At least one
scene; a spare audio track.

The human-judged half is
[../manual/on-screen.md § Convert leaves Live's focus and view alone](../manual/on-screen.md)
and [../manual/by-ear.md § Sing a line, hear it back as a guitar](../manual/by-ear.md).

## A converted clip lands as a new track whose notes read back

*Last run: 2026-08-30 — passed. 2-bar generate_audio source on track 1; count 2 → 3, reply named track 2 "3-Melody to MIDI" only after it existed, get_clip_notes returned 11 unquantized notes (G5–C6, starts 0.0348–5.2709) in the source's own slot 0, source clip untouched. Placement: with the source last, index 2 is ambiguous, so a second convert was run with a marker track below it — the new track landed at index 2, **directly after the source**, pushing the marker to 3. Not appended last; API.md's three "appended last" samples all had the source on the last track and cannot discriminate. Resolve-by-diff read it right; an appended-last assumption would have named the marker track. Filed as [fork #38](https://github.com/jpatricknola/AbletonOSC/issues/38).*

Put an audio clip in a slot with `generate_audio` (any short prompt, `bars: 2`)
— that is the cheapest audio clip an agent can make alone. Note the track count
from `get_session_state`. Then `convert_audio_to_midi` on that track and slot
with `mode: "melody"`.

The track count rises by **exactly one**, the reply names the new track's
index and Live's own name for it (e.g. `"… to MIDI"`), and `get_clip_notes` on
the named track and the source's slot returns a non-empty note list. The
source audio clip is still in its original slot, untouched.

Because the conversion is asynchronous, the reply must arrive only after the
track actually exists — a reply naming an index while `get_session_state`
still shows the old count is the dishonesty this design exists to prevent.
Record **where** the new track landed relative to the source (directly after
it, or appended last): `API.md` has one measurement of each and no promise,
and the tool resolves the index by reading rather than assuming — this run is
what confirms the read got it right. Zero notes with a track created means
Live converted silence — check the source clip actually contains audio before
calling this a defect, and see
[generation.md § A generated clip lands, reads back, and its file is duration-exact](generation.md).

## One undo accounts for the converted track

*Last run: 2026-08-30 — passed, the clean answer, twice. One undo took the track count back to its pre-convert value with the source clip untouched, both for a converted track appended after the last track and for one inserted mid-list. Live folds the asynchronous conversion into the single undo step the tool call brackets; no second undo needed and nothing extra removed.*

Immediately after the previous check's successful convert, call `undo` once,
then `get_session_state`.

Record what one undo removed: the track count back to its pre-convert value
with the source clip untouched is the clean answer. The conversion runs
asynchronously on Live's side while the tool call's undo-step bracket is
still open, so whether Live folds the whole convert into that one step is a
measurement, not a promise — if it takes two undos (or one undo removes more
than the converted track), record that here and check the tool's reply and
description say nothing that contradicts it. Redo (or re-convert) to leave
the set as the run found it.

## A refusal names why, before anything is converted

*Last run: 2026-08-30 — passed. MIDI clip refused in 0.46s: "holds a MIDI clip, and Convert turns *audio* into MIDI — nothing was converted", routing to get_clip_notes/edit_notes. Empty slot refused in 0.34s: "is empty… Convert needs an audio clip to work from", routing to record_clip/generate_audio. Distinct wordings from one predicate bit, so the diagnosis reads are working. Track count unchanged after both.*

`write_midi_notes` a few notes into an empty slot, then `convert_audio_to_midi`
on it. Then the same on a genuinely empty slot.

Both refusals are **immediate** — the predicate plus one or two diagnosis
reads, no mutation, no multi-second wait. The MIDI-clip refusal says the clip
is already MIDI and routes to
`get_clip_notes` / `edit_notes`; the empty-slot refusal routes to
`record_clip` / `generate_audio`. `get_session_state` shows the track count
unchanged after both.

Live's predicate answers `false` for both cases without saying which, so the
distinction in the wording is Seshat's diagnosis reads working — a generic
"can't convert" for either case means the diagnosis half regressed even
though the guard held.

## A bad index refuses cleanly and fast

*Last run: 2026-08-30 — passed. track: 99 refused in 0.22s with Live's own "Index out of range. Nothing further was sent — check get_session_state for the indices that actually exist." No hang. Live's Log.txt shows the IndexError raised on /live/clip/get/is_convertible_to_midi — the guard address, so the refusal really did land before any conversion was requested. Track count unchanged.*

`convert_audio_to_midi` on `track: 99`.

An immediate error naming what was wrong — not a ~5s hang. The guard address
always answers for in-range indices, so an out-of-range one surfaces as the
structured `/live/error` fast-fail; a timeout here means either a stale
bridge install or the error correlation regressed. Track count unchanged.
