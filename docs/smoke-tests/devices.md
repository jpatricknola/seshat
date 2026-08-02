# Device tools

`load_device`, `get_track_devices`, `get_device_parameters`,
`set_device_parameter`, `delete_device` and `bypass_device`, on regular tracks and
— via `target: "return" | "master"` — on the return and master chains. Every
address behind `target` is vendored, so [bridge.md](bridge.md)'s reinstall
precondition applies to all of it.

Set-up for the return/master tests: one MIDI track with an audible clip playing,
one return track, and a send from the track into it.

## Parameter 0 is the `Device On` switch, displaying `On`/`Off`

*Last run: —*

Both `delete_device` and `bypass_device` stand on this, and it comes from the
Live Object Model rather than from a verified run. Check on a stock Live device,
an Instrument Rack preset, and (if installed) an AU/VST plugin:
`get_device_parameters` shows parameter 0 named "Device On", and `bypass_device`
toggles it.

If Live spells the display differently, `bypass_device` refuses on *every* device
and its error prints the actual string; the fix is widening the accepted set in
`ensure_on_off_switch` ([lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)).

## Bypass is audible and idempotent

*Last run: —*

`bypass_device enabled: false` on an effect is audible and the device's power
button visibly dims in Live; `enabled: true` restores it with settings intact;
bypassing an instrument silences its track; repeating a bypass replies "already
Off" without writing.

## Delete removes the right device and says what shifted

*Last run: —*

`delete_device` removes the device you meant (confirm in Live's UI), its reply's
remaining chain matches a fresh `get_track_devices`, and later device indices
shift down as the reply warns.

Then delete a device while its track's clip is playing — no crash expected; note
by ear whether Live clicks or glitches (open question 2 in
[../archive/PLAN_audition_loop.md](../archive/PLAN_audition_loop.md) — if it's
ugly, the fix is a description sentence advising to stop the clip first).

## Device error paths are errors, not stalls

*Last run: —*

An out-of-range device index errors immediately (Elixir-side bounds check — no 2s
stall); a bad track index errors in ≈2s with the `get_track_devices` hint;
deleting from an empty chain errors cleanly.

## The audition loop works as a conversation

*Last run: —*

`search_library` for electric pianos → load one on a MIDI track with a clip →
fire → "next" (delete + load) → "keep that one" — the set ends holding only the
winner. Then an effect A/B via `bypass_device`.

## Loading onto a return, and onto the master

*Last run: —*

`create_return_track "Room Reverb"`, then `load_device target: "return", track:
<that index>` with a Reverb uri. The reply names *both* the return and the
device; the view lands on the return's device chain; raising the track's send is
now audible. Live renames the return as the first device lands (`A-Return` →
`A-Reverb`) — confirm the reply carries the **post-load** name, not the one it was
created with.

Then `load_device target: "master"` with an EQ Eight: the reply names the master,
the view lands on the master's device chain, and the whole mix is affected.

## The stray-track guard fires

*Last run: —*

Load an *instrument* (Operator) with `target: "return"`, then again with
`target: "master"`. Both must **error**, naming the stray MIDI track Live created;
nothing may be claimed as loaded; and the stray track must still be there
afterwards — the tool never deletes it, the model should offer `delete_track`. If
either reports success, `browser.py`'s `_verify_landed` is not running.

## The read/write surface works on both chains

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

*Last run: —*

If a third-party VST3/AU **effect** is installed, load it (not an instrument) with
`target: "return"`. Some plugins instantiate asynchronously, which can leave
`_verify_landed` seeing no change yet and reporting an error for a load that in
fact succeeds a moment later — the stray-track test only exercises the synchronous
Operator case. If it happens, confirm with `get_track_devices` whether the device
actually landed; either way this is a known limitation of the guard, not a new
regression to chase.

## The return and master mixer setters move the right control

*Last run: —*

Each of `set_return_track_volume`, `set_return_track_pan`, `set_return_track_mute`,
`set_return_track_solo`, `set_master_volume`, `set_master_pan` and
`set_cue_volume` moves the right control in Live's mixer, and its reply names the
old value as well as the new one.

`set_return_track_mute` silences the shared effect for every track feeding it, and
the sends themselves are untouched (check `get_track_sends`).
`set_return_track_solo` hears the return alone. `get_session_state`'s return lines
carry pan and mute/solo; the master line carries pan and cue volume and names
itself "shown as Main in Live 12".

## The return and master mixer listeners push

*Last run: —*

Move each of those controls **by hand in Live** and confirm `get_session_state`
reflects it without `refresh: true`: return pan, mute and solo; master pan; cue
volume. This is what the listeners are for, and a missed `start_listen` looks
exactly like a working tool until you try it.

Then the rebind: delete a return track and move the pan/mute/solo of the return
that took its index. `get_session_state` must show the change on the *right*
return — a stale binding writes one return's state onto another.

## Cue volume is audible

*Last run: —*

Preview a preset (see [catalog.md](catalog.md)), change `set_cue_volume`, preview
again — the preview level follows. The scales are already measured (master pan
−1.0…1.0 shown as `50L`/`C`/`50R`, cue 0.0…1.0 on track volume's dB curve with
`0.85` = `0.0 dB`), so this is about audibility, not range.
