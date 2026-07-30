# AbletonOSC API Reference

> Source: https://github.com/jpatricknola/AbletonOSC — Seshat's fork of
> [ideoforms/AbletonOSC](https://github.com/ideoforms/AbletonOSC), checked out
> as a submodule at `priv/AbletonOSC` and installed by `mix abletonosc.install`.
> Addresses marked "Seshat extension" below exist only in the fork; `SESHAT.md`
> at the fork root lists every divergence, including its fixes to upstream's
> own code.
> Protocol: OSC over UDP
> Send commands to: **`127.0.0.1:11000`**
> Reply port: 11001
> The fork binds its command socket to loopback only, so nothing off this
> machine can reach any address below. Callback replies go to the originating
> host — which can therefore only be loopback — on port 11001, and listener
> pushes, `/live/startup` and `/live/error` go to a fixed `127.0.0.1:11001` that
> incoming traffic never retargets. Upstream binds `0.0.0.0` and follows the
> last sender; see `SESHAT.md` in the fork, and don't widen either without
> `docs/SECURITY_BACKLOG.md`'s deployment-gated work.
> Wildcard patterns supported (e.g., `/live/clip/get/* 0 0` queries all properties of track 0, clip 0).

---

## Application API

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/test` | | `'ok'` | Confirmation message in Live + OSC reply |
| `/live/application/get/version` | | `major_version, minor_version` | Live's version |
| `/live/api/reload` | | | Live reload of AbletonOSC server code (dev only — see the warning below) |
| `/live/api/get/log_level` | | `log_level` | Current log level (default: `info`) |
| `/live/api/set/log_level` | `log_level` | | Set log level: `debug`, `info`, `warning`, `error`, `critical` |
| `/live/api/show_message` | `message` | | Show message in Live's status bar |

⚠️ **Don't reach for `/live/api/reload`.** Two problems, both observed:

1. It reloads modules, not files on disk that Live never imported. Editing the
   Python in `priv/AbletonOSC` does nothing until `mix abletonosc.install`
   copies it across, and a reload won't pick up a *new* module either — that
   needs Live restarted, or AbletonOSC toggled off and back on under
   Preferences > Link/Tempo/MIDI > Control Surface.
2. It can take the whole API down. `clear_handlers()` runs first, then
   `clear_api()` raises `KeyError` on any listener registered against a track
   that no longer exists — leaving zero handlers registered and no way to
   re-register them over OSC, since `/live/api/reload` has unregistered itself
   too. Every address then answers "Unknown OSC address" until Live is
   restarted or the control surface is toggled.

### Status Messages (sent automatically)

| Address | Response Params | Description |
|---|---|---|
| `/live/startup` | | Sent when AbletonOSC starts |
| `/live/error` | `error_msg` | Sent on error (see `logs/abletonosc.log`) |

---

## Song API

Top-level Song object. Playback control, scene/track creation, cue points, global params (tempo, metronome).

### Song Methods

| Address | Query Params | Description |
|---|---|---|
| `/live/song/capture_midi` | | Capture MIDI |
| `/live/song/continue_playing` | | Resume session playback |
| `/live/song/create_audio_track` | `index` | Create audio track at index (-1 = end) |
| `/live/song/create_midi_track` | `index` | Create MIDI track at index (-1 = end) |
| `/live/song/create_return_track` | | Create return track |
| `/live/song/create_scene` | `index` | Create scene at index (-1 = end) |
| `/live/song/cue_point/jump` | `cue_point` | Jump to cue point (by name or index) |
| `/live/song/cue_point/add_or_delete` | | Add/delete cue point at cursor |
| `/live/song/cue_point/set/name` | `cue_point` | Rename cue point by index |
| `/live/song/delete_scene` | `scene_index` | Delete scene |
| `/live/song/delete_return_track` | `return_index` | Delete return track — indexes `song.return_tracks`, a separate space from regular track indices |
| `/live/song/delete_track` | `track_index` | Delete track |
| `/live/song/duplicate_scene` | `scene_index` | Duplicate scene |
| `/live/song/duplicate_track` | `track_index` | Duplicate track |
| `/live/song/jump_by` | `time` | Jump song position by beats |
| `/live/song/jump_to_next_cue` | | Jump to next cue marker |
| `/live/song/jump_to_prev_cue` | | Jump to previous cue marker |
| `/live/song/redo` | | Redo last undone operation |
| `/live/song/start_playing` | | Start session playback |
| `/live/song/stop_playing` | | Stop session playback |
| `/live/song/stop_all_clips` | | Stop all clips |
| `/live/song/tap_tempo` | | Tap tempo |
| `/live/song/trigger_session_record` | | Trigger session record |
| `/live/song/undo` | | Undo last operation |

### Song Getters

Listen via `/live/song/start_listen/<property>`, responses on `/live/song/get/<property>`.

| Address | Response Params | Description |
|---|---|---|
| `/live/song/get/arrangement_overdub` | `arrangement_overdub` | Arrangement overdub state |
| `/live/song/get/back_to_arranger` | `back_to_arranger` | "Back to arranger" lit state |
| `/live/song/get/can_redo` | `can_redo` | Redo available? |
| `/live/song/get/can_undo` | `can_undo` | Undo available? |
| `/live/song/get/clip_trigger_quantization` | `clip_trigger_quantization` | Clip trigger quantization level |
| `/live/song/get/current_song_time` | `current_song_time` | Current song time (beats) |
| `/live/song/get/groove_amount` | `groove_amount` | Groove amount |
| `/live/song/get/is_playing` | `is_playing` | Song playing? |
| `/live/song/get/loop` | `loop` | Looping? |
| `/live/song/get/loop_length` | `loop_length` | Loop length |
| `/live/song/get/loop_start` | `loop_start` | Loop start point |
| `/live/song/get/metronome` | `metronome_on` | Metronome on/off |
| `/live/song/get/midi_recording_quantization` | `midi_recording_quantization` | MIDI recording quantization |
| `/live/song/get/nudge_down` | `nudge_down` | Nudge down |
| `/live/song/get/nudge_up` | `nudge_up` | Nudge up |
| `/live/song/get/punch_in` | `punch_in` | Punch in |
| `/live/song/get/punch_out` | `punch_out` | Punch out |
| `/live/song/get/record_mode` | `record_mode` | Record mode |
| `/live/song/get/root_note` | `root_note` | Root note |
| `/live/song/get/scale_name` | `scale_name` | Scale name |
| `/live/song/get/session_record` | `session_record` | Session record enabled? |
| `/live/song/get/session_record_status` | `session_record_status` | Session record status |
| `/live/song/get/signature_denominator` | `denominator` | Time signature denominator |
| `/live/song/get/signature_numerator` | `numerator` | Time signature numerator |
| `/live/song/get/song_length` | `song_length` | Arrangement length (beats) |
| `/live/song/get/tempo` | `tempo_bpm` | Song tempo |

### Song Setters

| Address | Query Params | Description |
|---|---|---|
| `/live/song/set/arrangement_overdub` | `arrangement_overdub` | Set arrangement overdub (1=on, 0=off) |
| `/live/song/set/back_to_arranger` | `back_to_arranger` | Set back to arranger (1=on, 0=off) |
| `/live/song/set/clip_trigger_quantization` | `clip_trigger_quantization` | Set clip trigger quantization |
| `/live/song/set/current_song_time` | `current_song_time` | Set song time (beats) |
| `/live/song/set/groove_amount` | `groove_amount` | Set groove amount |
| `/live/song/set/loop` | `loop` | Set looping (1=on, 0=off) |
| `/live/song/set/loop_length` | `loop_length` | Set loop length |
| `/live/song/set/loop_start` | `loop_start` | Set loop start |
| `/live/song/set/metronome` | `metronome_on` | Set metronome (1=on, 0=off) |
| `/live/song/set/midi_recording_quantization` | `midi_recording_quantization` | Set MIDI recording quantization |
| `/live/song/set/nudge_down` | `nudge_down` | Set nudge down |
| `/live/song/set/nudge_up` | `nudge_up` | Set nudge up |
| `/live/song/set/punch_in` | `punch_in` | Set punch in |
| `/live/song/set/punch_out` | `punch_out` | Set punch out |
| `/live/song/set/record_mode` | `record_mode` | Set record mode |
| `/live/song/set/session_record` | `session_record` | Set session record (1=on, 0=off) |
| `/live/song/set/signature_denominator` | `signature_denominator` | Set time sig denominator |
| `/live/song/set/signature_numerator` | `signature_numerator` | Set time sig numerator |
| `/live/song/set/tempo` | `tempo_bpm` | Set tempo |

### Song: Track/Scene/Cue Queries

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/song/get/cue_points` | | `name, time, ...` | List cue points |
| `/live/song/get/num_scenes` | | `num_scenes` | Number of scenes |
| `/live/song/get/num_tracks` | | `num_tracks` | Number of regular tracks (excludes return and master tracks) |
| `/live/song/get/track_names` | `[index_min, index_max]` | `[names...]` | Regular track names, in index order (optional range) |
| `/live/song/get/track_data` | `start_track, end_track, properties...` | `[values...]` | Bulk track/clip data query (regular tracks only) |

All three iterate `song.tracks`, so return tracks and the master track are
absent from their counts and their index space. Return-track count and names
come from `/live/return_track/get/count` and `/live/return_track/get/name` —
see the Return Track & Master API below.

#### Bulk Track Data

`/live/song/get/track_data` queries multiple tracks/clips at once. Properties use format `track.property_name`, `clip.property_name`, or `clip_slot.property_name`.

Example: `/live/song/get/track_data 0 12 track.name clip.name clip.length` queries tracks 0–11.

### Beat Events

Call `/live/song/start_listen/beat` to receive beat messages on `/live/song/get/beat` with the current beat number. Stop with `/live/song/stop_listen/beat`.

---

## View API

User interface control — selecting tracks, scenes, clips, devices.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/view/get/selected_scene` | | `scene_index` | Selected scene (0-indexed) |
| `/live/view/get/selected_track` | | `track_index` | Selected track (0-indexed) |
| `/live/view/get/selected_clip` | | `track_index, scene_index` | Selected clip |
| `/live/view/get/selected_device` | | `track_index, device_index` | Selected device (0-indexed) |
| `/live/view/set/selected_scene` | `scene_index` | | Set selected scene |
| `/live/view/set/selected_track` | `track_index` | | Set selected track |
| `/live/view/set/selected_clip` | `track_index, scene_index` | | Set selected clip |
| `/live/view/set/selected_device` | `track_index, device_index` | | Set selected device |
| `/live/view/start_listen/selected_scene` | | `selected_scene` | Listen for scene selection changes |
| `/live/view/start_listen/selected_track` | | `selected_track` | Listen for track selection changes |
| `/live/view/stop_listen/selected_scene` | | | Stop listening for scene changes |
| `/live/view/stop_listen/selected_track` | | | Stop listening for track changes |
| `/live/view/show_view` | `view_name` | | ⚠️ **Seshat extension** — bring a pane into view |
| `/live/view/set/detail_clip` | `track_index, scene_index` | | ⚠️ **Seshat extension** — put a clip in the Detail view |

- `/live/view/set/selected_track` resolves its index through `song.tracks`, so
  it reaches **regular tracks only** — a return track cannot be selected on it at
  any index. Use `/live/return_track/select` (Seshat extension, see the Return
  Track & Master API below).

### View extensions (Seshat — not in upstream AbletonOSC)

⚠️ The last two rows do **not** exist in stock AbletonOSC. They are served by
`abletonosc/view.py` in Seshat's fork (`priv/AbletonOSC`), installed with
`mix abletonosc.install` (restart Live afterwards) — the only Seshat addresses
that live in an *upstream* file. Without that install both are unknown and
silently do nothing.

Upstream can *select* a track, scene, clip or device, but it cannot show the
pane those live in: `Application.View.show_view` and `song.view.detail_clip`
have no upstream address. Seshat's view steering needs both — selecting a clip
nobody can see is not confirmation that anything happened.

- `show_view` takes one of Live's own pane names: `Browser`, `Arranger`,
  `Session`, `Detail`, `Detail/Clip`, `Detail/DeviceChain`. Seshat sends
  `Session`, `Detail/Clip` and `Detail/DeviceChain`.
- `set/detail_clip` puts `song.tracks[track_index].clip_slots[scene_index]`'s
  clip into the Detail view. Pair it with `show_view Detail/Clip` to open the
  note editor on it.
- **Both are silent**, like upstream's setters — an unknown view name or an
  empty clip slot is logged to Live's `Log.txt` and nothing goes on the wire.
  They are view steering that follows an already-successful tool, and steering
  must never fail or delay the thing it follows, so the ok/error envelope the
  fork's *getters* use deliberately does not apply.

---

## Track API

**Regular (audio/MIDI) tracks only.** Every handler here resolves its index
through `song.tracks`, which holds audio and MIDI tracks and nothing else — a
return track or the master track cannot be reached on any `/live/track/*`
address, at any index. Return tracks and the master are addressable through
Seshat's return_track extension (see below); sends, being a property of a
*regular* track's mixer, live here.

Volume, panning, send, mute, solo, devices, clips.

Listen via `/live/track/start_listen/<property> <track_index>`, responses on `/live/track/get/<property>` with `<track_index> <value>`. `*` in place of the
index subscribes every track.

> ⚠️ **These listeners are fixed in the fork**, in `AbletonOSCHandler._stop_listen`
> and `TrackHandler`'s mixer-listener pair. Same addresses, same arguments, same
> pushes — nothing calling them can tell the difference, which is exactly why the
> bug is worth writing down.
>
> A listener is keyed by track index but bound to a track *object*, and upstream
> unbinds it from whatever object the index resolves to at teardown time. Delete a
> track and every later index shifts, so re-subscribing tries to unbind the old
> callback from the wrong track: the removal fails, the base class swallows it as
> "likely benign", and the old listener stays alive pushing under an index that
> now belongs to someone else. A rename afterwards writes one track's name onto
> another in `Seshat.Session.State`. The fork unbinds from the object the callback
> was actually registered on, which `_start_listen` already records in
> `listener_objects`.
>
> The mixer listeners (volume, panning) had a second bug: they never recorded
> anything in `listener_objects` at all, so `_clear_listeners` raised `KeyError`
> on script reload once either was active. They now key as
> `("value", (track_id, prop))` with the `DeviceParameter` stored, and stop
> through the fixed base class.
>
> Seshat used to fix this from outside, by re-registering the five affected
> addresses from a `track_listeners.py` that had to be instantiated after
> `TrackHandler`. That file no longer exists.

### Track Methods

| Address | Query Params | Description |
|---|---|---|
| `/live/track/delete_device` | `track_id, device_id` | Delete a device from the track's chain. **No reply, ever** — `_call_method` returns nothing, and a bad index raises inside the callback, so success and failure look identical on the wire. Callers must verify by re-reading `/live/track/get/num_devices` |
| `/live/track/stop_all_clips` | `track_id` | Stop all clips on track |

### Track Getters

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/track/get/arm` | `track_id` | `track_id, armed` | Track armed? |
| `/live/track/get/available_input_routing_channels` | `track_id` | `track_id, channel, ...` | List input channels |
| `/live/track/get/available_input_routing_types` | `track_id` | `track_id, type, ...` | List input routes |
| `/live/track/get/available_output_routing_channels` | `track_id` | `track_id, channel, ...` | List output channels |
| `/live/track/get/available_output_routing_types` | `track_id` | `track_id, type, ...` | List output routes |
| `/live/track/get/can_be_armed` | `track_id` | `track_id, can_be_armed` | Can track be armed? |
| `/live/track/get/color` | `track_id` | `track_id, color` | Track color |
| `/live/track/get/color_index` | `track_id` | `track_id, color_index` | Track color index |
| `/live/track/get/current_monitoring_state` | `track_id` | `track_id, state` | Monitoring state (1=on, 0=off) |
| `/live/track/get/fired_slot_index` | `track_id` | `track_id, index` | Currently-fired slot |
| `/live/track/get/fold_state` | `track_id` | `track_id, fold_state` | Group folded state |
| `/live/track/get/has_audio_input` | `track_id` | `track_id, has_audio_input` | Has audio input? |
| `/live/track/get/has_audio_output` | `track_id` | `track_id, has_audio_output` | Has audio output? |
| `/live/track/get/has_midi_input` | `track_id` | `track_id, has_midi_input` | Has MIDI input? |
| `/live/track/get/has_midi_output` | `track_id` | `track_id, has_midi_output` | Has MIDI output? |
| `/live/track/get/input_routing_channel` | `track_id` | `track_id, channel` | Current input routing channel |
| `/live/track/get/input_routing_type` | `track_id` | `track_id, type` | Current input routing type |
| `/live/track/get/output_routing_channel` | `track_id` | `track_id, channel` | Current output routing channel |
| `/live/track/get/output_meter_left` | `track_id` | `track_id, level` | Output level, left |
| `/live/track/get/output_meter_level` | `track_id` | `track_id, level` | Output level, both channels |
| `/live/track/get/output_meter_right` | `track_id` | `track_id, level` | Output level, right |
| `/live/track/get/output_routing_type` | `track_id` | `track_id, type` | Current output routing type |
| `/live/track/get/is_foldable` | `track_id` | `track_id, is_foldable` | Is a group? |
| `/live/track/get/is_grouped` | `track_id` | `track_id, is_grouped` | In a group? |
| `/live/track/get/is_visible` | `track_id` | `track_id, is_visible` | Visible? (1=on, 0=off) |
| `/live/track/get/mute` | `track_id` | `track_id, mute` | Muted? (1=on, 0=off) |
| `/live/track/get/name` | `track_id` | `track_id, name` | Track name |
| `/live/track/get/panning` | `track_id` | `track_id, panning` | Track panning (-1.0 to 1.0) |
| `/live/track/get/playing_slot_index` | `track_id` | `track_id, index` | Currently-playing slot |
| `/live/track/get/send` | `track_id, send_id` | `track_id, send_id, value` | Send level (0.0 to 1.0) |
| `/live/track/get/solo` | `track_id` | `track_id, solo` | Soloed? |
| `/live/track/get/volume` | `track_id` | `track_id, volume` | Track volume (0.0 to 1.0) |

### Track Setters

| Address | Query Params | Description |
|---|---|---|
| `/live/track/set/arm` | `track_id, armed` | Set arm (1=on, 0=off) |
| `/live/track/set/color` | `track_id, color` | Set color |
| `/live/track/set/color_index` | `track_id, color_index` | Set color index |
| `/live/track/set/current_monitoring_state` | `track_id, state` | Set monitoring |
| `/live/track/set/fold_state` | `track_id, fold_state` | Set group fold (1=on, 0=off) |
| `/live/track/set/input_routing_channel` | `track_id, channel` | Set input routing channel |
| `/live/track/set/input_routing_type` | `track_id, type` | Set input routing type |
| `/live/track/set/mute` | `track_id, mute` | Set mute (1=on, 0=off) |
| `/live/track/set/name` | `track_id, name` | Set track name |
| `/live/track/set/output_routing_channel` | `track_id, channel` | Set output routing channel |
| `/live/track/set/output_routing_type` | `track_id, type` | Set output routing type |
| `/live/track/set/panning` | `track_id, panning` | Set panning (-1.0 to 1.0) |
| `/live/track/set/send` | `track_id, send_id, value` | Set send level |
| `/live/track/set/solo` | `track_id, solo` | Set solo (1=on, 0=off) |
| `/live/track/set/volume` | `track_id, volume` | Set volume (0.0 to 1.0) |

### Track: Clip Queries

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/track/get/clips/name` | `track_id` | `track_id, [name, ...]` | All clip names |
| `/live/track/get/clips/length` | `track_id` | `track_id, [length, ...]` | All clip lengths |
| `/live/track/get/clips/color` | `track_id` | `track_id, [color, ...]` | All clip colors |
| `/live/track/get/arrangement_clips/name` | `track_id` | `track_id, [name, ...]` | Arrangement clip names |
| `/live/track/get/arrangement_clips/length` | `track_id` | `track_id, [length, ...]` | Arrangement clip lengths |
| `/live/track/get/arrangement_clips/start_time` | `track_id` | `track_id, [start_time, ...]` | Arrangement clip start times |

### Track: Device Queries

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/track/get/num_devices` | `track_id` | `track_id, num_devices` | Number of devices |
| `/live/track/get/devices/name` | `track_id` | `track_id, [name, ...]` | All device names |
| `/live/track/get/devices/type` | `track_id` | `track_id, [type, ...]` | All device types |
| `/live/track/get/devices/class_name` | `track_id` | `track_id, [class, ...]` | All device class names |

---

## Clip Slot API

Container for clips. Create, delete, and query clip existence.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/clip_slot/fire` | `track_index, clip_index, [record_length]` | | Fire clip slot — with `record_length` (beats), records for exactly that long (see note below) |
| `/live/clip_slot/stop` | `track_index, clip_index` | | Stop the slot's playing clip |
| `/live/clip_slot/create_clip` | `track_index, clip_index, length` | | Create clip in slot |
| `/live/clip_slot/delete_clip` | `track_index, clip_index` | | Delete clip |
| `/live/clip_slot/get/has_clip` | `track_index, clip_index` | `track_index, clip_index, has_clip` | Has clip? |
| `/live/clip_slot/get/controls_other_clips` | `track_index, clip_index` | `track_index, clip_index, controls_other_clips` | Group slot controlling the clips below it? |
| `/live/clip_slot/get/is_group_slot` | `track_index, clip_index` | `track_index, clip_index, is_group_slot` | Slot belongs to a group track? |
| `/live/clip_slot/get/is_playing` | `track_index, clip_index` | `track_index, clip_index, is_playing` | Slot's clip playing? |
| `/live/clip_slot/get/is_triggered` | `track_index, clip_index` | `track_index, clip_index, is_triggered` | Fired and waiting on quantization? |
| `/live/clip_slot/get/playing_status` | `track_index, clip_index` | `track_index, clip_index, playing_status` | Slot playing status |
| `/live/clip_slot/get/will_record_on_start` | `track_index, clip_index` | `track_index, clip_index, will_record_on_start` | Firing this slot would record (armed track, empty slot)? |
| `/live/clip_slot/get/has_stop_button` | `track_index, clip_index` | `track_index, clip_index, has_stop_button` | Has stop button? |
| `/live/clip_slot/set/has_stop_button` | `track_index, clip_index, has_stop_button` | | Set stop button (1=on, 0=off) |
| `/live/clip_slot/duplicate_clip_to` | `track_index, clip_index, target_track, target_clip` | | Duplicate clip to target slot |

Every `get/` property above also has
`/live/clip_slot/start_listen/<property>` and `stop_listen/<property>`.

> ℹ️ **`fire` takes an optional `record_length`, and that is fixed-length
> recording.** The handler passes everything after the two indices straight
> into `ClipSlot.fire()`, whose first optional positional argument is
> `record_length` in beats (then `launch_quantization`, `force_legato`). Fire
> an empty slot on an armed track with a length and Live records exactly that
> long, stops itself, and leaves a clip of that length playing — loop brace
> and play markers already set. With no length it records until something
> stops it. Verified against Live 12.4.3, 2026-07-29; it is also how Live's
> own control surfaces implement fixed-length record. This is what `record_clip`
> and `stop_recording` are built on.

> ⚠️ **`duplicate_clip_to` is a merge hazard.** Upstream PRs #182 and #185 rename
> it to `duplicate_to` with no alias, and Seshat's `duplicate_clip` tool depends
> on the old name — so merging either into the fork breaks the tool silently
> (an unknown address over UDP just does nothing). Recorded in `SESHAT.md` at the
> fork root; the `audit-osc` workflow is what catches it.

---

## Clip API

Audio or MIDI clip. Start/stop, notes, name, gain, pitch, color, playing state/position.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/clip/fire` | `track_id, clip_id` | | Start clip |
| `/live/clip/stop` | `track_id, clip_id` | | Stop clip |
| `/live/clip/duplicate_loop` | `track_id, clip_id` | | Duplicate clip loop |
| `/live/clip/quantize` | `track_id, clip_id, grid, amount` | | **Seshat extension** (fork only). Quantize the clip's notes. `grid` is Live's `GridQuantization` enum — see below. `amount` is 0.0–1.0 (Live's UI shows it as a percentage). No reply, ever |
| `/live/clip/get/notes` | `track_id, clip_id, [start_pitch, pitch_span, start_time, time_span]` | `track_id, clip_id, pitch, start_time, duration, velocity, mute, ...` | Query notes (optional range) |
| `/live/clip/add/notes` | `track_id, clip_id, pitch, start_time, duration, velocity, mute, ...` | | Add MIDI notes |
| `/live/clip/remove/notes` | `[start_pitch, pitch_span, start_time, time_span]` | | Remove notes (no params = all) |
| `/live/clip/get/color` | `track_id, clip_id` | `track_id, clip_id, color` | Clip color |
| `/live/clip/set/color` | `track_id, clip_id, color` | | Set clip color |
| `/live/clip/get/color_index` | `track_id, clip_id` | `track_id, clip_id, color_index` | Color index (0-69) |
| `/live/clip/set/color_index` | `track_id, clip_id, color_index` | | Set color index (0-69) |
| `/live/clip/get/name` | `track_id, clip_id` | `track_id, clip_id, name` | Clip name |
| `/live/clip/set/name` | `track_id, clip_id, name` | | Set clip name |
| `/live/clip/get/gain` | `track_id, clip_id` | `track_id, clip_id, gain` | Clip gain |
| `/live/clip/set/gain` | `track_id, clip_id, gain` | | Set clip gain |
| `/live/clip/get/gain_display_string` | `track_id, clip_id` | `track_id, clip_id, gain_display_string` | Human-readable gain as dB string (audio clips only, read-only) |
| `/live/clip/get/length` | `track_id, clip_id` | `track_id, clip_id, length` | Clip length |
| `/live/clip/get/sample_length` | `track_id, clip_id` | `track_id, clip_id, sample_length` | Sample length |
| `/live/clip/get/start_time` | `track_id, clip_id` | `track_id, clip_id, start_time` | Start time |
| `/live/clip/get/pitch_coarse` | `track_id, clip_id` | `track_id, clip_id, semitones` | Coarse pitch |
| `/live/clip/set/pitch_coarse` | `track_id, clip_id, semitones` | | Set coarse pitch |
| `/live/clip/get/pitch_fine` | `track_id, clip_id` | `track_id, clip_id, cents` | Fine pitch |
| `/live/clip/set/pitch_fine` | `track_id, clip_id, cents` | | Set fine pitch |
| `/live/clip/get/file_path` | `track_id, clip_id` | `track_id, clip_id, file_path` | Clip file path |
| `/live/clip/get/is_audio_clip` | `track_id, clip_id` | `track_id, clip_id, is_audio_clip` | Is audio clip? |
| `/live/clip/get/is_midi_clip` | `track_id, clip_id` | `track_id, clip_id, is_midi_clip` | Is MIDI clip? |
| `/live/clip/get/is_playing` | `track_id, clip_id` | `track_id, clip_id, is_playing` | Is playing? |
| `/live/clip/get/is_overdubbing` | `track_id, clip_id` | `track_id, clip_id, is_overdubbing` | Is overdubbing? |
| `/live/clip/get/is_recording` | `track_id, clip_id` | `track_id, clip_id, is_recording` | Is recording? |
| `/live/clip/get/will_record_on_start` | `track_id, clip_id` | `track_id, clip_id, will_record_on_start` | Will record on start? |
| `/live/clip/get/playing_position` | `track_id, clip_id` | `track_id, clip_id, playing_position` | Playing position |
| `/live/clip/start_listen/playing_position` | `track_id, clip_id` | | Listen for playing position |
| `/live/clip/stop_listen/playing_position` | `track_id, clip_id` | | Stop listening for position |
| `/live/clip/get/looping` | `track_id, clip_id` | `track_id, clip_id, looping` | Clip loop on/off (1=on, 0=off) |
| `/live/clip/set/looping` | `track_id, clip_id, looping` | | Set clip loop on/off (1=on, 0=off) |
| `/live/clip/get/loop_start` | `track_id, clip_id` | `track_id, clip_id, loop_start` | Loop start |
| `/live/clip/set/loop_start` | `track_id, clip_id, loop_start` | | Set loop start |
| `/live/clip/get/loop_end` | `track_id, clip_id` | `track_id, clip_id, loop_end` | Loop end |
| `/live/clip/set/loop_end` | `track_id, clip_id, loop_end` | | Set loop end |
| `/live/clip/get/warping` | `track_id, clip_id` | `track_id, clip_id, warping` | Warp mode |
| `/live/clip/set/warping` | `track_id, clip_id, warping` | | Set warp mode |
| `/live/clip/get/launch_mode` | `track_id, clip_id` | `track_id, clip_id, launch_mode` | Launch mode (0=Trigger, 1=Gate, 2=Toggle, 3=Repeat) |
| `/live/clip/set/launch_mode` | `track_id, clip_id, launch_mode` | | Set launch mode |
| `/live/clip/get/launch_quantization` | `track_id, clip_id` | `track_id, clip_id, launch_quantization` | Launch quantization (0=Global, 1=None, 2=8Bars, 3=4Bars, 4=2Bars, 5=1Bar, 6=1/2, 7=1/2T, 8=1/4, 9=1/4T, 10=1/8, 11=1/8T, 12=1/16, 13=1/16T, 14=1/32) |
| `/live/clip/set/launch_quantization` | `track_id, clip_id, launch_quantization` | | Set launch quantization |
| `/live/clip/get/ram_mode` | `track_id, clip_id` | `track_id, clip_id, ram_mode` | RAM mode (0=False, 1=True) |
| `/live/clip/set/ram_mode` | `track_id, clip_id, ram_mode` | | Set RAM mode |
| `/live/clip/get/warp_mode` | `track_id, clip_id` | `track_id, clip_id, warp_mode` | Warp mode (0=Beats, 1=Tones, 2=Texture, 3=Re-Pitch, 4=Complex, 6=Pro) |
| `/live/clip/set/warp_mode` | `track_id, clip_id, warp_mode` | | Set warp mode |
| `/live/clip/get/has_groove` | `track_id, clip_id` | `track_id, clip_id, has_groove` | Has groove? |
| `/live/clip/get/legato` | `track_id, clip_id` | `track_id, clip_id, legato` | Legato (0=False, 1=True) |
| `/live/clip/set/legato` | `track_id, clip_id, legato` | | Set legato |
| `/live/clip/get/position` | `track_id, clip_id` | `track_id, clip_id, position` | Position (LoopStart) |
| `/live/clip/set/position` | `track_id, clip_id, position` | | Set position |
| `/live/clip/get/muted` | `track_id, clip_id` | `track_id, clip_id, muted` | Muted? (0=False, 1=True) |
| `/live/clip/set/muted` | `track_id, clip_id, muted` | | Set muted |
| `/live/clip/get/velocity_amount` | `track_id, clip_id` | `track_id, clip_id, velocity_amount` | Velocity amount (0.0-1.0) |
| `/live/clip/set/velocity_amount` | `track_id, clip_id, velocity_amount` | | Set velocity amount |
| `/live/clip/get/start_marker` | `track_id, clip_id` | `track_id, clip_id, start_marker` | Start marker |
| `/live/clip/set/start_marker` | `track_id, clip_id, start_marker` | | Set start marker (beats) |
| `/live/clip/get/end_marker` | `track_id, clip_id` | `track_id, clip_id, end_marker` | End marker |
| `/live/clip/set/end_marker` | `track_id, clip_id, end_marker` | | Set end marker (beats) |

### Quantization grid

`/live/clip/quantize`'s `grid` argument is Live's `GridQuantization` enum, which
is **not** the `RecordingQuantization` enum used elsewhere in Live's API. Getting
the two confused quantizes sixteenths to half notes, silently.

| Value | Grid | | Value | Grid |
|---|---|---|---|---|
| 0 | none | | 5 | 1/2 |
| 1 | 8 bars | | 6 | 1/4 |
| 2 | 4 bars | | 7 | 1/8 |
| 3 | 2 bars | | 8 | 1/16 |
| 4 | 1 bar | | 9 | 1/32 |

There are no triplet grids: swing comes from the song's `swing_amount`, which
`quantize` honours.

---

## Scene API

Trigger a row of clips simultaneously. Set/query name, color, tempo, time signature.

### Scene Methods

| Address | Query Params | Description |
|---|---|---|
| `/live/scene/fire` | `scene_id` | Trigger scene |
| `/live/scene/fire_as_selected` | `scene_id` | Trigger scene, select next |
| `/live/scene/fire_selected` | | Trigger selected scene, select next |

### Scene Getters

Listen via `/live/scene/start_listen/<property> <scene_index>`, responses on `/live/scene/get/<property>`.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/scene/get/color` | `scene_id` | `scene_id, color` | Scene color |
| `/live/scene/get/color_index` | `scene_id` | `scene_id, color_index` | Color index |
| `/live/scene/get/is_empty` | `scene_id` | `scene_id, is_empty` | Is empty? |
| `/live/scene/get/is_triggered` | `scene_id` | `scene_id, is_triggered` | Is triggered? |
| `/live/scene/get/name` | `scene_id` | `scene_id, name` | Scene name |
| `/live/scene/get/tempo` | `scene_id` | `scene_id, tempo` | Scene tempo |
| `/live/scene/get/tempo_enabled` | `scene_id` | `scene_id, tempo_enabled` | Tempo enabled? |
| `/live/scene/get/time_signature_numerator` | `scene_id` | `scene_id, numerator` | Time sig numerator |
| `/live/scene/get/time_signature_denominator` | `scene_id` | `scene_id, denominator` | Time sig denominator |
| `/live/scene/get/time_signature_enabled` | `scene_id` | `scene_id, enabled` | Time sig enabled? |

### Scene Setters

| Address | Query Params | Description |
|---|---|---|
| `/live/scene/set/name` | `scene_id, name` | Set name |
| `/live/scene/set/color` | `scene_id, color` | Set color |
| `/live/scene/set/color_index` | `scene_id, color_index` | Set color index |
| `/live/scene/set/tempo` | `scene_id, tempo` | Set tempo |
| `/live/scene/set/tempo_enabled` | `scene_id, tempo_enabled` | Set tempo enabled |
| `/live/scene/set/time_signature_numerator` | `scene_id, numerator` | Set time sig numerator |
| `/live/scene/set/time_signature_denominator` | `scene_id, denominator` | Set time sig denominator |
| `/live/scene/set/time_signature_enabled` | `scene_id, enabled` | Set time sig enabled |

---

## Device API

Instruments and effects. Query/set parameters.

Every `/live/device/*` address resolves its track through `song.tracks`
(`device.py`, `create_device_callback`) — **regular tracks only**. Devices on
return tracks and the master are unreachable through this API.

Parameter 0 of every device is its "Device On" switch — the power button in the
device's corner — so `/live/device/set/parameter/value <track> <device> 0 0.0`
bypasses a device and `1.0` re-enables it. ⚠️ The parameter's identity comes
from the Live Object Model, not from a smoke test; `bypass_device` reads
parameter 0's `value_string` and refuses unless it reads On/Off rather than
trusting it blind.

Listen for parameter changes via `/live/device/start_listen/parameter/value <track_index> <device_index> <parameter_index>`.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/device/get/name` | `track_id, device_id` | `track_id, device_id, name` | Device name |
| `/live/device/get/class_name` | `track_id, device_id` | `track_id, device_id, class_name` | Device class name |
| `/live/device/get/type` | `track_id, device_id` | `track_id, device_id, type` | Device type (1=audio_effect, 2=instrument, 4=midi_effect) |
| `/live/device/get/num_parameters` | `track_id, device_id` | `track_id, device_id, num_parameters` | Number of parameters |
| `/live/device/get/parameters/name` | `track_id, device_id` | `track_id, device_id, [name, ...]` | Parameter names |
| `/live/device/get/parameters/value` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Parameter values |
| `/live/device/get/parameters/min` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Parameter min values |
| `/live/device/get/parameters/max` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Parameter max values |
| `/live/device/get/parameters/is_quantized` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Is quantized? (int/bool param) |
| `/live/device/set/parameters/value` | `track_id, device_id, value, ...` | | Set all parameter values |
| `/live/device/get/parameter/value` | `track_id, device_id, parameter_id` | `track_id, device_id, parameter_id, value` | Get single parameter |
| `/live/device/get/parameter/value_string` | `track_id, device_id, parameter_id` | `track_id, device_id, parameter_id, value` | Get parameter as string (e.g., "2500 Hz") |
| `/live/device/set/parameter/value` | `track_id, device_id, parameter_id, value` | | Set single parameter |

### Device Type Reference

- `name`: human-readable name
- `type`: 1 = audio_effect, 2 = instrument, 4 = midi_effect
- `class_name`: Live instrument/effect name (e.g., Operator, Reverb). External plugins: AuPluginDevice, PluginDevice. Racks: InstrumentGroupDevice, etc.

---

## Browser API (Seshat extension — not in upstream AbletonOSC)

⚠️ These five addresses do **not** exist in stock AbletonOSC. They are served by
`abletonosc/browser.py` in Seshat's fork (`priv/AbletonOSC`), installed with
`mix abletonosc.install` (restart Live afterwards). Without that install all
five addresses are unknown and queries time out.

Unlike the rest of AbletonOSC, these always reply — including on every error
path — so a query resolves instead of hanging.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/browser/get/items` | `category, filter, max_results` | `category, filter, 'ok', returned, total, [name, path, uri, ...]` | Search a browser category |
| `/live/browser/get/items` | | `category, filter, 'error', message` | Unknown category, or indexing failed |
| `/live/browser/load_item` | `track_id, uri` | `track_id, uri, 'ok', device_name, device_index` | Load a browser item onto a track |
| `/live/browser/load_item` | | `track_id, uri, 'error', message` | Bad track index, unknown uri, or load failed |
| `/live/browser/export` | | `export_path, 'ok', total_items` | Walk every category and write the whole index to a JSON file the handler names |
| `/live/browser/export` | | `'', 'error', message` | Arguments supplied, no category indexable, or the write failed |
| `/live/browser/preview_item` | `uri` | `uri, 'ok', name` | Audition a browser item without loading it — nothing in the set changes |
| `/live/browser/preview_item` | | `uri, 'error', message` | Missing or unknown uri, or the preview call failed |
| `/live/browser/stop_preview` | | `'ok'` | Stop the running preview |
| `/live/browser/stop_preview` | | `'error', message` | The stop call failed |

- `preview_item` plays through Live's **cue** bus, so audibility depends on the
  set's cue routing: with cue routed nowhere the preview is silent. That is a
  property of the user's set, not something the handler can detect, so a silent
  preview still replies `'ok'`. Whether a given preset carries a preview at all
  is Live's business too.
- `stop_preview` takes no argument and so has no bad-index failure to report,
  but it replies anyway — unlike the index-less getters below, nothing else
  confirms that the preview stopped.

- `category`: `instruments`, `sounds`, `drums`, `audio_effects`, `midi_effects`,
  `plugins`, `samples`, `user_library`
- `filter`: case-insensitive substring match on `"path/name"`, so it matches
  folder names too. `""` = no filter.
- `max_results`: clamped to 1–100 by the Python handler.
- `returned` is how many name/path/uri **triples** follow; `total` is how many
  matched before truncation.
- `path` is the `/`-joined chain of browser folder names above the item
  (`"Bass/808 & Sub"`), `""` for a top-level item.
- `export` takes **no arguments**. It chooses its own destination inside
  `~/.seshat/browser-exports` and returns the absolute path it wrote; an error
  reply carries `''` in that slot, so it never names a partial file.
- `uri` values come from `get/items` or `export` and are stable within a Live
  session — never construct one.
- The first walk of a large category takes seconds (it runs on Live's UI
  thread, capped at 20,000 nodes / depth 6); the result is cached per category
  for the rest of the Live session. `export` is the exception: it always drops
  the cache and re-walks, so a reindex picks up Packs and presets added since
  the last walk.
- `load_item` selects the target track and loads in one operation, then reads
  the track's device list back so `device_name` reflects what actually landed.
- `device_index` is that device's position in `track.devices` — the index
  `/live/view/set/selected_device` and every `/live/device/*` address take — so
  the caller can act on what it just loaded without re-reading the chain. It is
  **`-1`** when the device isn't on the chain to be indexed: some VST/AU plugins
  instantiate asynchronously and aren't there yet when the reply is built.
  `load_item` does not always append at the end (an instrument lands *before*
  existing audio effects), so the index is found by diffing the chain against
  what it held immediately before the load — the device that's new — falling
  back to a name match, then the last device, when diffing doesn't resolve it.
- Regular tracks only (`song.tracks`) — return and master tracks aren't
  addressable here.

### `/live/browser/export`

Backs `Seshat.Library.Catalog.reindex/1`. It walks every category except
`samples` and writes one JSON file, rather than replying over OSC — a full
index is far past what a UDP datagram (or `get/items`' 100-item cap) can carry,
and Python and Elixir share a filesystem.

**The request carries no path.** The handler creates a uniquely named file with
`tempfile.mkstemp` inside `~/.seshat/browser-exports` (created owner-only on
demand) and returns the absolute path in the reply's first slot; Elixir reads it,
then deletes it. The old `[dest_path]` form — which opened a caller-supplied path
with Live's privileges — is rejected with an error reply and an error-level log
line, and writes nothing. A request in the old form against a current install, or
a no-argument request against an install predating 2026-07-30, means
`mix abletonosc.install` and a Live restart are overdue; `reindex_library` says
so rather than reporting a browser failure.

Because only the handler knows an export's name, only the handler can clean up an
export whose reply never arrived (a query timeout, a lost datagram, a path Elixir
refused). It sweeps at startup and before each export, removing matching
**regular** direct children of the export root that are at least ten minutes old
— old enough that no in-flight caller, bounded by the 120s query timeout, can
still be reading one.

```json
{
  "sounds": [
    {"name": "808 Drifter.adg", "path": "Bass/808 & Sub", "uri": "query:Sounds#Bass:FileId_5200"}
  ],
  "instruments": [ ... ]
}
```

- Takes up to a minute on a large library, all of it on Live's UI thread — the
  UI will hitch. Query it with a generous timeout (Seshat uses 120s).
- A category that fails to index is logged and skipped; the export still
  succeeds with the rest. Only a total failure returns `'error'`.
- `samples` is excluded deliberately: it is by far the largest category and raw
  samples carry no useful tags. Reach them with `get/items`.
- The `FileId_<n>` in a preset uri is the primary key of Ableton's own browser
  database, which is where Seshat gets preset tags — see
  `Seshat.Library.AbletonDB`.

---

## Return Track & Master API (Seshat extension — not in upstream AbletonOSC)

⚠️ These fourteen addresses do **not** exist in stock AbletonOSC. They are served
by `abletonosc/return_track.py` in Seshat's fork (`priv/AbletonOSC`), installed
with `mix abletonosc.install` (restart Live afterwards). Without that install all
fourteen addresses are unknown and queries time out.

They exist because upstream reaches regular tracks only: every `/live/track/*`
handler resolves its index through `song.tracks`. Return tracks live in
`song.return_tracks` and the master in `song.master_track`, so upstream can
create and delete a return track but can neither name one nor touch its level,
and the master fader is unreachable entirely. `/live/view/set/selected_track`
indexes `song.tracks` too, which is why selecting a return needs an address of
ours as well.

Return-track indices are 0-based **within `song.return_tracks`** — a separate
index space from regular tracks. Return N is the target of send N on every
regular track: return 0 = send A, return 1 = send B, and so on. The master
track needs no index at all.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/return_track/get/count` | | `count` | Number of return tracks. Also the "is the extension installed?" probe |
| `/live/return_track/get/name` | `return_index` | `return_index, "ok", name` | Return track name |
| | | `return_index, "error", message` | Index out of range |
| `/live/return_track/set/name` | `return_index, name` | | Rename a return track |
| `/live/return_track/get/volume` | `return_index` | `return_index, "ok", volume` | Return fader, 0.0 to 1.0 |
| | | `return_index, "error", message` | Index out of range |
| `/live/return_track/set/volume` | `return_index, volume` | | Set the return fader |
| `/live/return_track/select` | `return_index` | | Select a return track in Live's UI |
| `/live/master/get/volume` | | `volume` | Master fader, 0.0 to 1.0 |
| `/live/master/set/volume` | `volume` | | Set the master fader |
| `/live/return_track/start_listen/name` | `return_index` | | Push `/live/return_track/get/name [return_index, name]` on every change |
| `/live/return_track/stop_listen/name` | `return_index` | | |
| `/live/return_track/start_listen/volume` | `return_index` | | Push `/live/return_track/get/volume [return_index, volume]` on every change |
| `/live/return_track/stop_listen/volume` | `return_index` | | |
| `/live/master/start_listen/volume` | | | Push `/live/master/get/volume [volume]` on every change |
| `/live/master/stop_listen/volume` | | | |

- **Getters always reply**, on the address they were called on, including on
  every error path — the same rule as the Browser API above, and the opposite of
  upstream's "raise inside the callback and send nothing". For an optional
  extension that silence is ambiguous: a bad index would be indistinguishable
  from an install that never happened, and would cost a full guard timeout to
  learn nothing either way. With the envelope, **an error reply means a bad
  index and silence means the extension isn't loaded.**
- `get/count` and `/live/master/get/volume` take no index, so they have no
  failure to report and reply with the bare value.
- **Setters are silent**, like upstream's. Every caller guards with the matching
  getter immediately beforehand, so a bad index has already been reported by the
  time a setter goes out, and nothing waits on one.
- `select` is silent too, for a stronger reason: it is view steering that follows
  a tool which has already succeeded, and steering must never fail — or delay —
  the thing it follows. A bad index is logged in Live and nothing happens.
- Volume is `mixer_device.volume.value` on Live's fader scale, the same property
  and scale as `/live/track/get|set/volume`.
- Creating and deleting return tracks is upstream's job:
  `/live/song/create_return_track` (no arguments, appends after the existing
  returns) and `/live/song/delete_return_track [return_index]`. A newly created
  return's index is therefore the old `get/count` — query the count, create,
  then `set/name` at that index.
- Sends belong to the *regular* track that feeds the return, so they stay on
  `/live/track/get|set/send [track_id, send_id, ...]` in the Track API above.
- **The listeners push the bare value**, not the ok/error envelope — a push has
  no failure path to report, and the differing arity is what lets
  `Seshat.Session.State` accept a push and a query reply on the same address
  without confusing them. Like upstream's listeners, each sends once immediately
  on subscribe. `start_listen`/`stop_listen` reply with nothing at all on a bad
  index (they are guarded by `get/count` and nothing waits on them).
- A `get/*` address therefore carries both query replies and listener pushes.
  Live's own track listeners upstream already work this way, and a push landing
  on a pending query is harmless: it carries a current value.
- Return-track volume is listened to on `mixer_device.volume`, a
  `DeviceParameter` with `add_value_listener` rather than a Track property — so
  that one listener is hand-rolled instead of using the base class's
  `_start_listen`, which would derive `/live/return_track/get/value`.
- **Re-subscribing an index unbinds the object it used to mean.** These
  listeners are keyed by return index but bound to a return-track object, and
  deleting a return renumbers everything after it. Upstream's `_stop_listen`
  removes the callback from whatever target it is *handed*, so re-subscribing
  index 0 after a delete would try to unbind it from the wrong object, silently
  fail, and leave the old listener pushing under an index that now belongs to
  someone else. The fork's base class unbinds from the object the callback was
  actually registered on, which is what makes any index-keyed listener safe —
  see the note under the Track API above.

---

## Song Structure API (Seshat extension — not in upstream AbletonOSC)

⚠️ These four addresses do **not** exist in stock AbletonOSC. They are served by
`abletonosc/song_structure.py` in Seshat's fork (`priv/AbletonOSC`), installed
with `mix abletonosc.install` (restart Live afterwards).

Upstream's `SongHandler` registers `start_listen` only for the *scalar* Song
properties in its hardcoded list (tempo, root_note, is_playing, …). `tracks` and
`return_tracks` are lists of LOM objects, so they aren't in it — meaning nothing
upstream fires when a track is added, deleted, duplicated or reordered, and
`Seshat.Session.State`'s mirror drifts silently.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/song/start_listen/tracks` | | | Push `/live/song/get/tracks` on every change to the track list |
| `/live/song/stop_listen/tracks` | | | |
| `/live/song/start_listen/return_tracks` | | | Push `/live/song/get/return_tracks` on every change to the return list |
| `/live/song/stop_listen/return_tracks` | | | |

The two push addresses are **push-only** — sent by the listener callback, never
registered as handlers, so querying them gets silence:

| Push address | Args |
|---|---|
| `/live/song/get/tracks` | `name0, name1, …` (regular tracks, in order) |
| `/live/song/get/return_tracks` | `name0, name1, …` (return tracks, in send order) |

- **Names only, deliberately.** The push is a change *signal*; `Session.State`
  compares it against its mirror and re-reads everything only when it differs, so
  this handler never becomes a second source of truth for track state.
- Upstream registers no handler on either push address — its equivalent is
  `/live/song/get/track_names`, a different address. No collision.
- Neither address exists on stock AbletonOSC, so a Live without the install just
  drops the `start_listen` messages: no error, and the mirror falls back to
  refresh-only staleness.

### `/live/startup` is acted on

AbletonOSC sends `/live/startup` (see the Application API above) whenever its
control surface initialises — Live launching, a different set being loaded, or
AbletonOSC toggled off and on. `Seshat.Session.State` treats it as a refresh
trigger, because by that point every listener registered against the previous
song object is dead: without it the mirror would be stale *permanently*, not
just until the next change.

---

## MidiMap API

Assign MIDI CC to Live parameters. Note: channels are 0-indexed (MIDI channel 1 = index 0).

| Address | Query Params | Description |
|---|---|---|
| `/live/midimap/map_cc` | `track_id, device_id, param_id, channel, cc` | Map CC to parameter |

---

## Quick Reference: Common POC Commands

```
# Test connection
/live/test

# Get session info
/live/song/get/tempo
/live/song/get/num_tracks
/live/song/get/track_names

# Transport
/live/song/start_playing
/live/song/stop_playing
/live/song/set/tempo 120.0

# Track control (track_id is 0-indexed)
/live/track/set/panning 0 -1.0       # Pan track 0 hard left
/live/track/set/panning 0 0.0        # Pan track 0 center
/live/track/set/panning 0 1.0        # Pan track 0 hard right
/live/track/set/volume 0 0.85        # Set track 0 volume
/live/track/set/mute 0 1             # Mute track 0
/live/track/set/mute 0 0             # Unmute track 0
/live/track/set/solo 0 1             # Solo track 0
/live/track/set/solo 0 0             # Unsolo track 0

# Create/delete tracks
/live/song/create_midi_track -1      # New MIDI track at end
/live/song/create_audio_track -1     # New audio track at end
/live/song/delete_track 3            # Delete track 3
```
