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

Repeat at the schema boundary, 16 bars at 60 BPM, on another new track. It must
land, the WAV must contain exactly 64 beats' requested duration at 60 BPM, and
the reported Live properties must match independent read-back. A timeout or
truncated file means the advertised boundary exceeds the runtime/import path
and must be reduced rather than left as a schema promise.

*Last run: —*

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

*Last run: —*
