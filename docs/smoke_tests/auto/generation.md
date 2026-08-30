# Generated material

The end-to-end layer for `generate_audio` and `generate_midi`: the local
Stable Audio runtime and managed files on the audio side, the composed
pattern-to-notes path and the fork's extended-notes family on the MIDI side,
and Live's read-back for both. `mix test` replaces the runtime and OSC peer,
so none of these guarantees exist below this file.

**Set-up:** Live and Seshat running at the same known 4/4 set. For the audio
checks: the Stable Audio runtime and required weights installed, and a bridge
at or past fork commit `fe6730e` — the one that exposes
`/live/clip_slot/create_audio_clip` — installed with `mix abletonosc.install`
and loaded by a Live restart. For the MIDI checks: a bridge at or past the
extended-notes family (fork, 2026-08-29; present at pin `3b6b9bc`) —
`/live/clip/add/notes_extended` and `/live/clip/get/notes_extended` have
never been exercised by Seshat before this feature, so a stale Remote Scripts
copy makes every MIDI result here right for the wrong reason. Start with an
empty generated-audio test track, and remove only files this run creates when
finished.

## A generated clip lands, reads back, and its file is duration-exact

Generate a four-bar `"dusty breakbeat drum loop, no melody"` at 124 BPM with a
new track named `Gen Drums`. Read the new track through `get_session_state`, its
slot through `get_clip_slots`, and the clip through `get_clip_properties`; do
not accept the generator's own reply as proof of import.

The new regular track is audio and slot 0 holds the named clip. The reply
identifies the result as audio, names the track and slot, and reports the
generated file plus Live's observed length, looping and warping values. It also
says that no rhythmic-grid or loop-seam correction was applied. The file is a
regular, non-symlink WAV under `~/.seshat/generated`; `afinfo` reports 44.1 kHz
stereo PCM and exactly the requested four-bar duration to the sample frame. A
file that exists without the independently read clip is an import failure,
never a partial pass. Do not require a particular Live beat length, looping or
warping value in this MVP; require the reply to match the independent read-back.

**The file must also contain audio.** Duration, sample rate and channel count
are all satisfied by a duration-exact file of digital silence, which is what a
half-working runtime produces — and nothing else in either suite would notice.
Measure the peak level without listening, e.g.

```
ffmpeg -i <the wav> -af volumedetect -f null - 2>&1 | grep max_volume
```

`max_volume` must be meaningfully below 0 dB and well above the noise floor;
`-91 dB` (or `-inf`) is silence and a failure, and `0.0 dB` is a clipped or
constant-valued file and also a failure. Judge *level only* — whether the
material sounds like the description is by ear and belongs to the follow-up
polish item, not here. If `ffmpeg` is not installed, say so and mark this half
skipped by environment rather than passing the check on duration alone.

Repeat at the schema boundary, 16 bars at 60 BPM, on another new track. It must
land, the WAV must contain exactly 64 beats' requested duration at 60 BPM, and
the reported Live properties must match independent read-back. A timeout or
truncated file means the advertised boundary exceeds the runtime/import path
and must be reduced rather than left as a schema promise.

*Last run: 2026-08-30 — PASS. 4 bars @ 124 BPM on a new `Gen Drums` audio track: `get_clip_slots` shows track 1 audio, slot 0 holding the named clip; `get_clip_properties` reads back audio, warp off, looping off, end marker 7.7419 s — matching the reply's own report (16.0 beats, looping off, warping off) and its "no rhythmic-grid or loop-seam correction" sentence. The file is a regular non-symlink WAV under `~/.seshat/generated`; `afinfo` gives 2 ch / 44100 Hz / Int16 and 341419 frames — exactly 16 beats at 124 BPM to the sample frame. Peak level measured with `python3 -m wave` (ffmpeg is not installed on this machine; the stdlib read is the same measurement, not a skip): peak −16.00 dBFS, RMS −28.02 dBFS — real material, not silence and not clipped. The 16-bar / 60 BPM boundary also passed on a second new track: 2822400 frames = 64.000000 s exactly, per-quarter peaks −6.93/−6.07/−7.56/−7.93 dBFS so nothing is truncated or padded with silence, render 2.396 s, nowhere near the 60 s deadline. Live chose warp *on* for that clip and *off* for the 4-bar one; not asserted, per this check. Generation was 1.578 s and 2.396 s warm.*

## An occupied slot is refused before anything is generated

Record the generated folder's file set and the current name/path of `Gen
Drums` slot 0. Ask `generate_audio` to write explicitly to that occupied slot.
It must refuse immediately, name the occupied slot and an available slot when
one exists, end with the consequence that nothing was generated, leave the
folder unchanged, and leave slot 0's independently read name/path unchanged.

Now omit `clip_slot` on the same track. One new file is created, the new clip
lands in the first empty slot, and slot 0 remains untouched. Finally create a
MIDI track, record the folder contents, and target its empty slot explicitly;
the call refuses it as non-audio before rendering and the folder remains
unchanged. A generated file in either refusal case means the guard ran after
the expensive side effect and the workflow ordering is wrong.

*Last run: 2026-08-30 — PASS. With `Gen Drums` slot 0 occupied, an explicit `clip_slot: 0` was refused with "Slot 0 on track 1 already holds a clip, and generated audio never overwrites one. Slot 1 on that track is empty. Nothing was generated." — the folder listing was byte-identical before and after, and slot 0's independently read name and markers were unchanged. Omitting `clip_slot` on the same track then produced exactly one new file and landed "another breakbeat" in slot 1, slot 0 untouched. A new MIDI track targeted explicitly was refused with "Track 3 is a MIDI track, so an audio clip cannot be imported onto it… Nothing was generated.", folder again identical before and after. Both guards ran before the render.*

## A composed beat lands as per-part tracks and one undo removes it

Snapshot `get_session_state` (track count and names). Call `generate_midi`
with a four-bar brief at the set's tempo: three drum parts (kick on pitch 36,
snare on 38, closed hat on 42, explicit one-bar patterns with at least one
accent and one ghost each) and a rule-derived bass part (`relationship:
"lock"`, one root per bar inside E1–G2), a style profile, and a fixed `seed`.
Do not pass instrument URIs — bare tracks are acceptable for this check and
keep it independent of the catalog.

Verify through independent reads, never the tool's own reply: `get_session_state`
shows exactly four new MIDI tracks named by part role; `get_clip_slots` shows a
clip in the target slot of each; `get_clip_notes` per clip shows only that
part's pitch(es), every note inside the four bars, and — the feel half —
**velocities that vary** (the accent above the base, the ghost well below,
non-identical values across ordinary hits) and **at least some starts off the
16th grid** (the harvested microtiming; a fully grid-locked read means the
performance layer never ran). The bass clip's onsets must coincide with the
kick pattern's onsets (`lock`), roots as requested.

The reply must name every track and slot it created, say the result is MIDI,
and report its read-back through the extended getter (see the next check).
Then call `undo` **once**: `get_session_state` must show the original track
count and names — all four tracks gone in one step. A residue (some tracks
removed, some left) fails the one-undo-step promise, not just this check.

Repeat once at the boundary: 16 bars, hats at 1/16 resolution (a dense lane —
past one datagram's worth of notes), same independent reads. Every note lands;
a truncated lane means the chunked write dropped a datagram.

*Last run: —*

## Extended note fields survive the wire

The write goes out on `/live/clip/add/notes_extended` and the read-back
returns on `/live/clip/get/notes_extended` — a different address, so the
tool's own read-back report *is* a genuine measurement here, and it is the
only extended reader Seshat has (`get_clip_notes` is the five-field view).
`API.md` carries a ⚠️ that these fields were measured *accepted* but never
read back; this check is what closes it.

Generate a one-bar beat whose hat part carries `probability` below 1.0 and a
non-zero `velocity_deviation` (the style profile supplies both; pick a
profile the plan documents as carrying them, or pass explicit overrides).
The reply's read-back section must report probability and velocity-deviation
values **matching what was sent** (float32 tolerance), not Live's defaults
(1.0 / 0.0). Defaults coming back means Live accepted and discarded the
fields — report it as a finding against the feature's Live-side feel claim,
and the fork's ⚠️ stays.

Cross-check placement independently with `get_clip_notes`: the same notes, at
the same starts and velocities, in the five-field view.

*Last run: —*

## An occupied MIDI target slot is refused before anything is created

Record the session's track count and the name of an occupied clip slot (use a
clip from the check above, before its undo). Ask `generate_midi` to write a
part explicitly onto that occupied slot (`track` + `clip_slot` of an existing
clip). It must refuse immediately, name the occupied slot, state that nothing
was created, and leave the track count and the slot's independently read clip
name unchanged. Then target an audio track's empty slot with a drum part: the
call refuses it as non-MIDI before creating anything. New tracks appearing in
either refusal case means a guard ran after a side effect and the workflow
ordering is wrong.

*Last run: —*
