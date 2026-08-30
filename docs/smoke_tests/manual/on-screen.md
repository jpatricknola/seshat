# Judged on Live's screen

Two kinds of check, both needing a human at the machine: ones where the evidence
is what Live *displays* (a brace that moved, a dial reading, the pane the view
landed on), and ones where the action has to be performed **by hand in Live**
rather than through a tool.

The second kind is the one that must not be substituted. A tool-driven
stand-in exercises the same Live Object Model call and proves nothing about
UI-originated edits — which is exactly where the listener-rebind bug lived, and
exactly the class of bug nothing else here can find. Where a test says "by hand",
doing it with a tool is not a weaker pass, it is a different test.

**Set-up:** Live in front of you with a set you don't mind editing. Several of
these want an audio clip and a device or two already loaded; each says what it
needs.

A few carry an ear component as well (a device deleted mid-playback, the groove
dial's audible change). Those are noted in place — the screen is the primary
evidence, the sound is a secondary observation worth recording.

## The listener rebind, by hand in Live's UI

*Why manual: requires deleting and renaming tracks in Live's UI*
*Last run: —*

Delete a track, then rename a *different* one, then `get_session_state`. Every
name must be under the right index.

This guards the fork's fix to `AbletonOSCHandler._stop_listen`, which unbound a
listener from the wrong object once an index had been reused. It is the one fix
whose failure is completely silent — every address still answers — so nothing but
this test finds it. Do it by hand: a tool-driven substitute exercises the same
LOM mutation but proves nothing about UI-originated edits.

## A loop brace edit lands and reads back

*Why manual: requires visual and playback confirmation in Live*
*Last run: —*

Capture or write an 8-beat MIDI clip, then "loop beats 4–8": the brace visibly
moves in the note editor, playback loops that section, and the reply echoes
4.0–8.0 plus the new length.

## The clip reader

*Why manual: includes visual confirmation of selection and the note editor*
*Last run: —*

`get_clip_properties` on a freshly captured clip reports the length and brace Live
inferred; on an empty slot it errors via `ensure_clip` rather than burning
fourteen timeouts. A brace edit leaves the clip selected with the note editor
open.

## Audio clip properties

*Why manual: requires a prepared audio clip and visual confirmation in Live*
*Last run: —*

Set `gain` — the echo shows a plausible dB from `gain_display_string`. Change
`warp_mode`/`warping` and see it in clip view. Confirm `velocity_amount` and
`legato` read and write without timeouts: they are **assumed** present on audio
clips and never measured, so if a read stalls, the fix is moving them to the
MIDI-only branch of `@clip_common_reads`. On an **unwarped** audio clip, confirm
the reply says "seconds" rather than "beats".

Then the MIDI guard from the other side: `gain` on a MIDI clip errors cleanly and
nothing is sent.

## Quantize refusals cost nothing

*Why manual: includes visual confirmation that the clip is selected*
*Last run: —*

`amount: 0` errors immediately (0% strength moves nothing), and an empty slot
errors via `ensure_clip` — neither should take a guard timeout. An audio clip is
rejected cleanly by `ensure_midi_clip`, with no warp markers touched. One `undo`
restores the take, and the quantized clip is left selected with the note editor
open — the notes snapping on screen *is* the confirmation.

## Delete removes the right device and says what shifted

*Why manual: requires Live UI confirmation and listening for playback glitches*
*Last run: —*

`delete_device` removes the device you meant (confirm in Live's UI), its reply's
remaining chain matches a fresh `get_track_devices`, and later device indices
shift down as the reply warns.

Then delete a device while its track's clip is playing — no crash expected; note
by ear whether Live clicks or glitches (open question 2 in
[../archive/PLAN_audition_loop.md](../archive/PLAN_audition_loop.md) — if it's
ugly, the fix is a description sentence advising to stop the clip first).

## Loading onto a return, and onto the master

*Why manual: requires visual and audible confirmation in Live*
*Last run: —*

`create_track track_type: "return", name: "Room Reverb"`, then
`load_device target: "return", track:
<that index>` with a Reverb uri. The reply names *both* the return and the
device; the view lands on the return's device chain; raising the track's send is
now audible. Live renames the return as the first device lands (`A-Return` →
`A-Reverb`) — confirm the reply carries the **post-load** name, not the one it was
created with.

Then `load_device target: "master"` with an EQ Eight: the reply names the master,
the view lands on the master's device chain, and the whole mix is affected.

## The read/write surface works on both chains

*Why manual: includes audible parameter and bypass checks in Live*
*Last run: —*

With `target: "return"` and `target: "master"`:

- `get_track_devices` lists the chain and says "return track N" / "the master
  track", never "track N".
- `get_device_parameters` lists every parameter of a large device (Reverb, EQ
  Eight) in one reply — watch for truncation, this is the combined getter's only
  real test.
- `set_device_parameter` changes an audible parameter and the reply echoes Live's
  own display string.
- `bypass_device` toggles the device off and on, audibly, and repeating it replies
  "already Off" without writing.
- `delete_device` removes it, the reply's remaining chain matches a fresh
  `get_track_devices`, and the view lands sensibly (successor device, or the empty
  chain).

## A slow-loading plugin doesn't read as a failed load

*Why manual: requires a suitable third-party plugin installed in Live*
*Last run: —*

If a third-party VST3/AU **effect** is installed, load it (not an instrument) with
`target: "return"`. Some plugins instantiate asynchronously, which can leave
`_verify_landed` seeing no change yet and reporting an error for a load that in
fact succeeds a moment later — the stray-track test only exercises the synchronous
Operator case. If it happens, confirm with `get_track_devices` whether the device
actually landed; either way this is a known limitation of the guard, not a new
regression to chase.

## The return and master mixer setters move the right control

*Why manual: requires visual and audible mixer confirmation in Live*
*Last run: —*

`set_mixer target: "return"` with each of `volume`, `pan`, `mute` and `solo`,
then `set_mixer target: "master"` with `volume` and `pan`, then
`set_mixer target: "cue", volume:` — each moves the right control in Live's
mixer, and its reply names the old value as well as the new one.

`set_mixer target: "return", mute: true` silences the shared effect for every
track feeding it, and the sends themselves are untouched (check
`get_track_sends`). `target: "return", solo: true` hears the return alone. One
call carrying several of those properties must move all of them on the *same*
strip — a wrong branch here lands on a regular track of the same index and
looks like nothing happened. `get_session_state`'s return lines
carry pan and mute/solo; the master line carries pan and cue volume and names
itself "shown as Main in Live 12".

## The return and master mixer listeners push

*Why manual: requires moving controls and deleting a return in Live's UI*
*Last run: —*

Move each of those controls **by hand in Live** and confirm `get_session_state`
reflects it without `refresh: true`: return pan, mute and solo; master pan; cue
volume. This is what the listeners are for, and a missed `start_listen` looks
exactly like a working tool until you try it.

Then the rebind: delete a return track and move the pan/mute/solo of the return
that took its index. `get_session_state` must show the change on the *right*
return — a stale binding writes one return's state onto another.

## The visibility matrix

*Why manual: includes checking derived view labels against Live's screen*
*Last run: —*

For each of `Browser`, `Arranger`, `Session`, `Detail`, `Detail/Clip`,
`Detail/DeviceChain`: `show_view(name)`, then `get_view_state`, and confirm the
summary reports that pane. This covers bare `Detail`, which the 2026-07-31 run had
to leave unconfirmed because closing the detail panel needed a keystroke — now
`hide_view(Detail)` closes it and the getter proves it closed.

Two readings the summary *derives* rather than reads are worth eyeballing once
against the screen: "Main view" comes from the Session/Arranger pair, and the
detail panel's named tab comes from the `Detail/*` flags.

## Recording follow cam

*Why manual: requires visual confirmation of Live's selected clip and editor*
*Last run: —*

`record_clip` lands the view on the reddening slot in Session with the detail pane
left alone; `stop_recording` opens the finished take in the note editor (or
waveform, for audio).

## Callback replies and listener pushes both land on 11001

*Why manual: requires changing a control by hand in Live*
*Last run: —*

`get_session_state(refresh: true)`, then change tempo or a track's volume **by
hand in Live**, then `get_session_state` again and confirm it sees the change.
The first call is a direct reply; the second depends on a listener push reaching
the fixed `127.0.0.1:11001` with no incoming datagram to retarget it — both are
exactly what moved.

## The groove dial reads 130% at 1.3

*Why manual: requires assigning a groove in Live and reading its dial*
*Last run: —*

With a groove assigned to a clip **by hand in Live**, `set_groove_amount 0.0`,
then `1.0`, then `1.3` — audible change, and the Groove Pool's Amount dial reads
**100%** at 1.0 and **130%** at 1.3. Anything else means the mapping moved in this
Live version and the schema max needs revisiting.

The 0.0–1.3 bound — read out of Live's own shipped Python, correcting the LOM
apiref's understated 0.0–1.0 — is recorded on the `groove_amount` rows in
[../../../priv/AbletonOSC/API.md](../../../priv/AbletonOSC/API.md#song-getters).

## The available outputs and current selection agree with Live

*Why manual: requires comparing the tool result with Live's visible Audio Settings*
*Last run: —*

Start with Live frontmost and Settings closed. Put another application in front,
then call `get_audio_outputs` over MCP and time the call. Its current value and
available names must match the Audio Output Device popup when Settings is opened
by hand immediately afterward. The call must finish within 5 seconds, return no
generic AX tree or unrelated UI labels, restore the previously frontmost
application, and leave Settings closed because it was closed initially.

Repeat once with Settings already open on a page other than Audio. The same
device list must return, the previously selected page must be restored, and
Settings must remain open. A disagreement means the bounded selectors or menu
normalization drifted; lost foreground/page/window state means the helper's
transaction cleanup is incomplete.

## Monitoring in, auto, off move the right button

*Why manual:* the mapping is read off Live's own track header, which no tool
reports back.

*Last run: —*

Show an audio track's mixer section in Live (the **In/Auto/Off** monitoring
buttons under the track's input choosers). Then `set_mixer monitoring: "in"`,
`"auto"`, `"off"` in turn, watching the header after each.

Each call lights the button with the same name. `auto` is where a new track
starts.

The wire values are `0 = In, 1 = Auto, 2 = Off`
([API.md](../../../priv/AbletonOSC/API.md)) — derived from Live's own shipped
Push 2 script and corroborated by one wire reading, **not** from a run against
each value, which is what this test supplies. Getting it backwards is
completely silent: every value is legal, the setter never replies, and the
model would cheerfully report "monitoring off" while the track passed audio
through. If the buttons don't match the names, the enum table in
`Seshat.Tools.Handlers` is wrong, not the tool.

## The input choosers move, and the channel list follows the type

*Why manual:* the Input Type and Input Channel choosers are read on screen; the
dependency between them is the thing being judged.

*Last run: —*

With an audio track's input section visible, `set_mixer input_type: "<name>"`
using a type whose channel list differs from the current one (`Resampling` and
an external input differ on any machine with an interface). Watch both
choosers.

The Input Type chooser shows the new name, and the Input Channel chooser's
**contents** change with it — Live rebuilds the channel list per type.

This is why the tool sets type first and re-reads the available channels before
setting a channel. A channel name accepted under the old type would be silently
dropped under the new one — the fork's setter logs a warning and changes
nothing when a name isn't on the list.

## Convert leaves Live's focus and view alone

*Why manual:* the frontmost application and an unmoved view are observations no
tool can make — the point of this check is what does **not** happen on screen.

*Last run: —*

With Ableton Live **behind** another application and its Arranger view showing,
run
[../auto/convert.md § A converted clip lands as a new track whose notes read back](../auto/convert.md).
Watch the screen through the whole call.

Live never comes to the front, no menu opens, and the application that was
frontmost stays frontmost throughout. Live's view does not switch to the
Session grid — the convert runs entirely over OSC now, and the old
select-focus-press dance is gone with the mechanism that needed it. The one
thing that may move inside Live is the track selection: the follow cam selects
the new track after a success, exactly as `create_track` does, without
changing the pane.

Live coming forward, a Create menu flashing open, or the view jumping to
Session is the deleted Accessibility path still being exercised — a stale
server running pre-change code, not a new defect in this one.

## Probability shows as Chance in the clip editor

*Why manual: needs eyes on Live's clip editor lanes — no tool reads the
editor's UI, and the extended read-back proves the wire, not the display*
*Last run: —*

After `auto/generation.md § Extended note fields survive the wire` has
written a beat whose ghost hats carry `probability < 1.0`: double-click the
hat clip, show the note expression lanes, and select the Chance lane. The
ghost notes display a chance visibly below 100% and the accented notes sit at
100%. Fire the clip a few times with the metronome on — ghosts that
sometimes do not sound are the same fact heard rather than seen; either
observation passes. A Chance lane pinned at 100% everywhere while the wire
read-back reported the sent values means Live stores the field somewhere the
editor and playback do not honour — report it as a finding.
