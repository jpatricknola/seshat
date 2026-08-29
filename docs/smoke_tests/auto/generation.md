# Generated audio

The end-to-end layer for `generate_audio`: the local Stable Audio runtime,
Seshat's managed files, the fork's clip-slot import address, and Live's
read-back. `mix test` replaces the runtime and OSC peer, so none of these
guarantees exist below this file.

**Set-up:** Live and Seshat running at the same known 4/4 set, the Stable Audio
runtime and required weights installed, and a bridge at or past fork commit
`fe6730e` — the one that exposes `/live/clip_slot/create_audio_clip` — installed
with `mix abletonosc.install` and loaded by a Live restart. Start with an
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
