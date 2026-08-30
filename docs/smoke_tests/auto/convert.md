# Audio to MIDI — Live's own Convert

`convert_audio_to_midi` presses one of three items in Live's **Create** menu
through the macOS Accessibility helper — the second thing Seshat does that is
not OSC, after the audio-output tools, and the first that changes the Set. The
mechanism is *select over OSC, press over AX, observe over OSC*: nothing here
reads a result off the screen, so everything below is judged through ordinary
tools.

Two properties make this worth a file of its own. The press acts on **whatever
Live has selected**, so a selection that silently failed to land converts the
wrong clip — the one genuinely dangerous failure on this path. And an
`AXEnabled` of `false` is the *normal* outcome for a wrong clip type, so the
refusal path is exercised far more often than the success path.

Set-up: `mix ax.install` has run and macOS still trusts the helper (an
untrusted helper fails every test here identically, which
[audio-output.md](audio-output.md) is the place to diagnose); at least one
scene; a spare audio track.

The human-judged half is
[../manual/on-screen.md § Convert brings Live forward and gives it back](../manual/on-screen.md)
and [../manual/by-ear.md § Sing a line, hear it back as a guitar](../manual/by-ear.md).

## A converted clip lands as a new track whose notes read back

*Last run: —*

Put an audio clip in a slot with `generate_audio` (any short prompt, `bars: 2`)
— that is the cheapest audio clip an agent can make alone. Note the track count
from `get_session_state`. Then `convert_audio_to_midi` on that track and slot
with `mode: "melody"`.

The track count rises by **exactly one**, the reply names the new track's
index, and `get_clip_notes` on the new track's clip returns a non-empty note
list. The source audio clip is still in its original slot, untouched.

A count that rose by more than one, or a reply naming an index without the
count having risen, is the `create_track` failure mode this guard was copied
from: the tool must report honestly and name no index rather than steer the
view at a track that may not exist. Zero notes with a track created means Live
converted silence — check the source clip actually contains audio before
calling this a defect, and see
[generation.md § A generated clip lands, reads back, and its file is duration-exact](generation.md).

## A MIDI clip is refused before Live is ever touched

*Last run: —*

`write_midi_notes` a few notes into an empty slot, then `convert_audio_to_midi`
on it.

The refusal is **immediate**, says the clip is MIDI and not audio, and Live
never comes to the front — the whole point of guarding before the AX call.
`get_session_state` shows the track count unchanged.

Planning measured (2026-08-28) that all three Convert items read
`AXEnabled = false` with a MIDI clip selected, so the helper *would* refuse
this anyway. That is the backstop, not the guard: reaching it means Seshat
activated Live, stole focus, and pulled a menu open to learn something it could
have read over OSC in a millisecond. A refusal that takes a second and flashes
Live to the front is the failure here, even though the answer is right.

## An empty slot and a bad index refuse cleanly

*Last run: —*

`convert_audio_to_midi` on an empty slot, then on `track: 99`.

Both come back as immediate errors naming what was wrong — an empty slot, and
an index past the end. Neither hangs for a timeout, and the track count is
unchanged after both.

A ~5s pause before either error means the guard read was skipped and the
helper's own deadline supplied the answer instead.
