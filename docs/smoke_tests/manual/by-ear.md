# Judged by ear

Checks where the assertion is a sound (the count here has drifted before —
trust the section list, not a number). No read-back proves any of them: a
bypassed device, a preview at the wrong cue level, and a take that recorded
silence all look identical in every value Seshat can read.

**Set-up, once, for the whole file:** audio output routed somewhere you can hear
it, cue output routed too (the preview and cue-volume tests need it and are
silent without it — expected, not a bug), and at least one audio input routed if
you are doing the recording take.

Worth doing in one sitting for that reason — the routing is the expensive part,
and it is the same routing for all six.

**A silent result is only a failure once you have confirmed the routing.** Every
test here can fail for a reason that has nothing to do with Seshat, so rule that
out before recording a finding.

## Bypass is audible and idempotent

*Why manual: requires visual and audible confirmation in Live*
*Last run: —*

`bypass_device enabled: false` on an effect is audible and the device's power
button visibly dims in Live; `enabled: true` restores it with settings intact;
bypassing an instrument silences its track; repeating a bypass replies "already
Off" without writing.

## Cue volume is audible

*Why manual: requires cue routing and judgment by ear*
*Last run: —*

Preview a preset (see [catalog.md](catalog.md)), change
`set_mixer target: "cue"`, preview
again — the preview level follows. The scales are already measured (master pan
−1.0…1.0 shown as `50L`/`C`/`50R`, cue 0.0…1.0 on track volume's dB curve with
`0.85` = `0.0 dB`), so this is about audibility, not range.

## Browser preview sounds without touching the set

*Why manual: requires audible cue routing and judgment by ear*
*Last run: —*

`/live/browser/preview_item` and `/live/browser/stop_preview` are served by the
fork but have no Seshat tool (ROADMAP: browser preview audition), so the MCP
surface can't reach them. Drive them with
`.claude/skills/smoke-test/scripts/osc_send.py`, passing a `uri` from
`search_library`, with Live's cue output routed somewhere audible and the cue
level up.

Confirm it sounds *without* anything being added to the set (`get_session_state`,
`get_track_devices`), and that `stop_preview` silences it. A silent preview with
cue routed nowhere is expected, not a bug — which is exactly why the cue caveat
has to reach the eventual tool's description.

## Swing plus quantize actually swings

*Why manual: includes judging the amount of swing by ear*
*Last run: —*

Set swing, then `quantize_clip` at `"1/8"` on a straight clip — notes land *off*
the straight grid, on swung positions. This is the end-to-end "make it swing".
Judge by ear whether 0.10–0.20 reads as "subtle"; if not, the fix is
`set_swing_amount`'s description, not the code.

## Audio take — the headline

*Why manual: requires routed audio input and judgment by ear*
*Last run: —*

An audio track with an input routed, 4 bars → audible material in the clip. This
is the capability the whole feature exists for and the one thing `capture_midi`
can never do. A silent take means the input isn't set, which Seshat cannot see or
fix.

## A named output changes, verifies, and restores

*Why manual: requires safe routed hardware and hearing the output transition*
*Last run: —*

Call `get_audio_outputs`, note the current choice, and choose one other safe
connected output by its exact returned name. With Settings closed and another
application frontmost, call `set_audio_output` with that exact name over MCP and
time the call. It must return within 5 seconds, report the observed previous and
new Live values, move the audible output to the requested hardware, restore the
previously frontmost application, and leave Settings closed without a second
cleanup tool call.

Read `get_audio_outputs` again: its current value must name the requested
device. Then set the original choice back and repeat the read-back so the test
leaves routing as it found it. A success reply without both audible movement and
the independent second read means native post-action verification or handler
reporting is false; a Settings window left behind means one helper invocation no
longer owns the complete transaction.

## Sing a line, hear it back as a guitar

*Why manual:* it needs a microphone, a voice, and a judgement about whether the
result is musically usable — none of which an agent has.

*Last run: —*

The headline arc, run as one conversation: ask Seshat to set up a track to
record your voice, sing or hum a short single-note line over whatever is
already in the set, let the take finish, then ask for it as MIDI on a guitar
sound.

What you should get: a routed and armed track before you sing, a take that
contains your voice rather than silence, a new MIDI track whose clip plays your
line back, and a guitar patch on it. Play the two together and judge whether
the MIDI actually follows what you sang — the contour, the rhythm, roughly the
right octave.

This is the only check that can fail the *feature* rather than the code. Live's
Convert Melody is monophonic pitch tracking, so slides, bends and breathy
attacks come back as extra notes; a clean hummed line comes back usable. If the
result is unusable on a clean line, that is a finding about the route, not a
bug — record it and raise it in [../../ROADMAP.md](../../ROADMAP.md). If the
result is usable but messy, confirm that asking for it to be tidied reaches
`quantize_clip` and `edit_notes` rather than a re-record; the tool description
is what has to teach that.

Note also whether the whole arc happened without you being told to do anything
in Live's UI by hand. Being sent to the Input Type chooser is the failure this
feature exists to remove.

## The fixed slate — composed beats judged blind

*Why manual: this is the feature's acceptance test and it is entirely ears —
keep/delete preference, groove and prompt match cannot be judged from a trace*
*Last run: —*

The by-ear verdict the roadmap item promises, run once per
`docs/archive/PLAN_midi_generation_symbolic.md` and recorded as a dated Result in
`docs/evaluating/generative features/midi-generation-options.md` — this entry
exists so the run is never skipped as "covered by the auto checks", which
prove placement and feel *mechanics*, not musical worth.

Eight prompts fixed before any generation, across four styles, at 4 and 8
bars, one requiring a fill and one a dropout; three takes each (different
seeds); fixed instruments per lane, chosen once and reused. Clips carry
opaque codes; a second person (or a shuffled key the judge never sees)
decides the order. Score keep/delete, groove/feel, prompt match, and — for
the combined prompts — whether bass and kick audibly interlock.

The controlled A/B on one skeleton: the same pattern rendered (a) raw grid,
no performance layer, (b) with the harvested performance layer, (c) with (b)
plus an assigned Live groove from the pool. This is the measurement that says
whether feel comes from composition, post-processing, or both — and it is the
result that would overturn the symbolic-first verdict if (b) does not beat
(a) audibly.

## A synthesized NKS preset sounds like its own preview

*Why manual: the assertion is a sound — Massive X exposes one readable host
parameter, so no value Seshat can read distinguishes the preset's state from
an init patch that instantiated cleanly*
*Last run: — (not reachable yet: as of 2026-09-01 no synthesized `.adv` has
cleared Live's browser metadata extractor, so nothing loads to listen to.
The one-minute human action that would unblock the whole spike is described
under "What would settle it" in
[../../evaluating/semantic-sound-selection-options.md](../../evaluating/semantic-sound-selection-options.md)
§ "Spike L result" — drag a loaded Massive X device into the User Library so
there is a Live-written plugin preset to diff against.)*

Run after (and only after)
[../auto/nks-load.md](../auto/nks-load.md) § "A synthesized NKS `.adv` lands
Massive X carrying the preset's state" is green. With the synthesized Agonic
Drone loaded, hold a note for a few seconds, then play the preset's own
preview — `/Library/Application Support/Native Instruments/Massive X/Presets/.previews/Agonic Drone.nksf.ogg`
— and compare. The preset's character (a slow, synthetic, evolving drone)
against a plain init saw is not a subtle difference; same character = the
state chunk landed, and this is the spike's actual acceptance. Record the
verdict in the options doc per the plan, not only here.
