# AbletonOSC Protocol Reference

> **This is one bridge implementation.** The app may use other methods to talk to
> Ableton in the future (Max for Live WebSocket device, direct Live API, etc.).
> The LOM doc describes what we can control; this doc describes how AbletonOSC
> specifically exposes it.
>
> Source: [github.com/ideoforms/AbletonOSC](https://github.com/ideoforms/AbletonOSC)
> AbletonOSC listens on UDP **port 11000**, replies to **port 11001**.

## Listener Pattern

Any gettable property supports listeners:
```
/live/<object>/start_listen/<property>  [index_args...]
/live/<object>/stop_listen/<property>   [index_args...]
```
When a listened property changes, AbletonOSC pushes a message to port 11001:
```
/live/<object>/get/<property>  [index_args..., new_value]
```

---

## Application

| Address | Args | Description |
|---------|------|-------------|
| `/live/test` | — | Confirmation ping; replies with a message |
| `/live/application/get/version` | — | Returns `[major, minor]` |
| `/live/api/reload` | — | Hot-reload server code (dev) |
| `/live/api/get/log_level` | — | Current log level |
| `/live/api/set/log_level` | `level` | `debug`, `info`, `warning`, `error`, `critical` |
| `/live/api/show_message` | `message` | Display in Live's status bar |

### Automatic Events

| Address | Description |
|---------|-------------|
| `/live/startup` | Sent when AbletonOSC initializes |
| `/live/error` | Sent on errors, with error string |

---

## Song — Methods

| Address | Args | Description |
|---------|------|-------------|
| `/live/song/start_playing` | — | Start playback |
| `/live/song/stop_playing` | — | Stop playback |
| `/live/song/continue_playing` | — | Resume playback |
| `/live/song/stop_all_clips` | — | Stop all clips |
| `/live/song/capture_midi` | — | Capture MIDI input |
| `/live/song/create_audio_track` | `index` | Create audio track (-1 = end) |
| `/live/song/create_midi_track` | `index` | Create MIDI track (-1 = end) |
| `/live/song/create_return_track` | — | Create return track |
| `/live/song/create_scene` | `index` | Create scene (-1 = end) |
| `/live/song/delete_scene` | `scene_index` | Delete scene |
| `/live/song/delete_track` | `track_index` | Delete track |
| `/live/song/delete_return_track` | `track_index` | Delete return track |
| `/live/song/duplicate_scene` | `scene_index` | Duplicate scene |
| `/live/song/duplicate_track` | `track_index` | Duplicate track |
| `/live/song/jump_by` | `beats` | Jump by N beats |
| `/live/song/jump_to_next_cue` | — | Jump to next cue |
| `/live/song/jump_to_prev_cue` | — | Jump to previous cue |
| `/live/song/tap_tempo` | — | Tap tempo |
| `/live/song/trigger_session_record` | — | Toggle session record |
| `/live/song/undo` | — | Undo |
| `/live/song/redo` | — | Redo |
| `/live/song/cue_point/jump` | `cue_point` | Jump to cue (name or index) |
| `/live/song/cue_point/add_or_delete` | — | Add/delete cue at cursor |
| `/live/song/cue_point/set/name` | `index, name` | Rename cue point |

## Song — Properties (get/set/start_listen/stop_listen)

| Property | Type | Notes |
|----------|------|-------|
| `tempo` | float | BPM |
| `current_song_time` | float | Beats |
| `is_playing` | bool | Read-only for listener |
| `loop` | bool | 1=on, 0=off |
| `loop_start` | float | Beats |
| `loop_length` | float | Beats |
| `metronome` | bool | 1=on, 0=off |
| `record_mode` | int | |
| `session_record` | bool | |
| `session_record_status` | int | |
| `arrangement_overdub` | bool | |
| `back_to_arranger` | bool | |
| `clip_trigger_quantization` | int | |
| `groove_amount` | float | |
| `midi_recording_quantization` | int | |
| `nudge_down` | bool | |
| `nudge_up` | bool | |
| `punch_in` | bool | |
| `punch_out` | bool | |
| `root_note` | int | |
| `scale_name` | string | |
| `signature_denominator` | int | |
| `signature_numerator` | int | |
| `song_length` | float | Arrangement length in beats |
| `can_redo` | bool | Read-only |
| `can_undo` | bool | Read-only |

Address pattern: `/live/song/get/<property>`, `/live/song/set/<property> [value]`

### Song — Bulk Queries

| Address | Args | Description |
|---------|------|-------------|
| `/live/song/get/num_tracks` | — | Total track count |
| `/live/song/get/num_scenes` | — | Total scene count |
| `/live/song/get/cue_points` | — | List of cue points |
| `/live/song/get/track_names` | `[min, max]` (opt) | Track names in range |
| `/live/song/get/track_data` | `min, max, props...` | Bulk property query |

### Song — Beat Listener

| Address | Args | Description |
|---------|------|-------------|
| `/live/song/start_listen/beat` | — | Subscribe to beat events |
| `/live/song/get/beat` | `beat_number` | Pushed on each beat |
| `/live/song/stop_listen/beat` | — | Unsubscribe |

---

## View

| Address | Args | Description |
|---------|------|-------------|
| `/live/view/get/selected_scene` | — | Selected scene index |
| `/live/view/get/selected_track` | — | Selected track index |
| `/live/view/get/selected_clip` | — | Returns `[track, scene]` |
| `/live/view/get/selected_device` | — | Returns `[track, device]` |
| `/live/view/set/selected_scene` | `scene` | |
| `/live/view/set/selected_track` | `track` | |
| `/live/view/set/selected_clip` | `track, scene` | |
| `/live/view/set/selected_device` | `track, device` | |

Supports `start_listen`/`stop_listen` for `selected_scene` and `selected_track`.

---

## Track — Methods

| Address | Args | Description |
|---------|------|-------------|
| `/live/track/stop_all_clips` | `track_id` | Stop all clips on track |

## Track — Properties (get/set/start_listen/stop_listen)

Address pattern: `/live/track/get/<property> [track_id]`, `/live/track/set/<property> [track_id, value]`

| Property | Type | Notes |
|----------|------|-------|
| `volume` | float | 0.0–1.0 (mapped to dB by Ableton) |
| `panning` | float | -1.0 (L) to 1.0 (R) |
| `mute` | bool | 1=muted, 0=unmuted |
| `solo` | bool | 1=solo, 0=off |
| `arm` | bool | 1=armed, 0=off |
| `name` | string | |
| `color` | int | |
| `color_index` | int | |
| `current_monitoring_state` | int | |
| `fold_state` | int | For group tracks |
| `send` | float | Extra arg: `send_id`. `/live/track/get/send [track_id, send_id]` |
| `input_routing_channel` | string | |
| `input_routing_type` | string | |
| `output_routing_channel` | string | |
| `output_routing_type` | string | |

### Track — Read-Only Properties

| Address | Args | Returns |
|---------|------|---------|
| `/live/track/get/can_be_armed` | `track_id` | bool |
| `/live/track/get/fired_slot_index` | `track_id` | int |
| `/live/track/get/has_audio_input` | `track_id` | bool |
| `/live/track/get/has_audio_output` | `track_id` | bool |
| `/live/track/get/has_midi_input` | `track_id` | bool |
| `/live/track/get/has_midi_output` | `track_id` | bool |
| `/live/track/get/is_foldable` | `track_id` | bool |
| `/live/track/get/is_grouped` | `track_id` | bool |
| `/live/track/get/is_visible` | `track_id` | bool |
| `/live/track/get/output_meter_left` | `track_id` | float |
| `/live/track/get/output_meter_right` | `track_id` | float |
| `/live/track/get/output_meter_level` | `track_id` | float |
| `/live/track/get/playing_slot_index` | `track_id` | int |
| `/live/track/get/available_input_routing_channels` | `track_id` | list |
| `/live/track/get/available_input_routing_types` | `track_id` | list |
| `/live/track/get/available_output_routing_channels` | `track_id` | list |
| `/live/track/get/available_output_routing_types` | `track_id` | list |

---

## Clip Slot

Address pattern: `/live/clip_slot/<action> [track_id, scene_id, ...]`

| Address | Args | Description |
|---------|------|-------------|
| `/live/clip_slot/create_clip` | `track_id, scene_id, length` | Create empty clip |
| `/live/clip_slot/delete_clip` | `track_id, scene_id` | Delete clip from slot |
| `/live/clip_slot/get/has_clip` | `track_id, scene_id` | Returns 1/0 |
| `/live/clip_slot/get/color` | `track_id, scene_id` | Slot color |

---

## Clip

Address pattern: `/live/clip/get/<property> [track_id, scene_id]`, `/live/clip/set/<property> [track_id, scene_id, value]`

### Clip — Methods

| Address | Args | Description |
|---------|------|-------------|
| `/live/clip/fire` | `track_id, scene_id` | Fire (launch) clip |
| `/live/clip/stop` | `track_id, scene_id` | Stop clip |

### Clip — Properties

| Property | Type | Notes |
|----------|------|-------|
| `name` | string | |
| `length` | float | In beats |
| `looping` | bool | |
| `color` | int | |

Wildcard: `/live/clip/get/* [track_id, scene_id]` queries all properties.

### Clip — Notes

| Address | Args | Description |
|---------|------|-------------|
| `/live/clip/get/notes` | `track_id, scene_id` | Get MIDI notes in clip |
| `/live/clip/set/notes` | `track_id, scene_id, notes...` | Set MIDI notes |

---

## Device

Address pattern: `/live/device/get/<property> [track_id, device_id]`

| Address | Args | Description |
|---------|------|-------------|
| `/live/device/get/name` | `track_id, device_id` | Device name |
| `/live/device/get/type` | `track_id, device_id` | Device type |
| `/live/device/get/class_name` | `track_id, device_id` | Device class |
| `/live/device/get/num_parameters` | `track_id, device_id` | Parameter count |
| `/live/device/get/parameters/name` | `track_id, device_id` | All param names |
| `/live/device/get/parameters/value` | `track_id, device_id` | All param values |
| `/live/device/get/parameters/min` | `track_id, device_id` | All param mins |
| `/live/device/get/parameters/max` | `track_id, device_id` | All param maxes |
| `/live/device/get/parameter/value` | `track_id, device_id, param_id` | Single param value |
| `/live/device/set/parameter/value` | `track_id, device_id, param_id, value` | Set param value |
| `/live/device/get/is_active` | `track_id, device_id` | Enabled state |
| `/live/device/set/is_active` | `track_id, device_id, active` | Enable/disable |
| `/live/track/get/num_devices` | `track_id` | Number of devices on track |
