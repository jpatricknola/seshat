# AbletonOSC API Reference

> Source: https://github.com/ideoforms/AbletonOSC
> Protocol: OSC over UDP
> Send port: 11000
> Reply port: 11001
> Replies are sent to the same IP as the originating message.
> Wildcard patterns supported (e.g., `/live/clip/get/* 0 0` queries all properties of track 0, clip 0).

---

## Application API

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/test` | | `'ok'` | Confirmation message in Live + OSC reply |
| `/live/application/get/version` | | `major_version, minor_version` | Live's version |
| `/live/api/reload` | | | Live reload of AbletonOSC server code (dev only) |
| `/live/api/get/log_level` | | `log_level` | Current log level (default: `info`) |
| `/live/api/set/log_level` | `log_level` | | Set log level: `debug`, `info`, `warning`, `error`, `critical` |
| `/live/api/show_message` | `message` | | Show message in Live's status bar |

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
| `/live/song/delete_return_track` | `track_index` | Delete return track |
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
| `/live/song/get/num_tracks` | | `num_tracks` | Number of tracks |
| `/live/song/get/track_names` | `[index_min, index_max]` | `[names...]` | Track names (optional range) |
| `/live/song/get/track_data` | `start_track, end_track, properties...` | `[values...]` | Bulk track/clip data query |

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

---

## Track API

Audio, MIDI, return, or master track. Volume, panning, send, mute, solo, devices, clips.

Listen via `/live/track/start_listen/<property> <track_index>`, responses on `/live/track/get/<property>` with `<track_index> <value>`.

### Track Methods

| Address | Query Params | Description |
|---|---|---|
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
| `/live/track/get/send` | `track_id, send_id` | `track_id, send_id, value` | Send level |
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
| `/live/clip_slot/fire` | `track_index, clip_index` | | Fire clip slot |
| `/live/clip_slot/create_clip` | `track_index, clip_index, length` | | Create clip in slot |
| `/live/clip_slot/delete_clip` | `track_index, clip_index` | | Delete clip |
| `/live/clip_slot/get/has_clip` | `track_index, clip_index` | `track_index, clip_index, has_clip` | Has clip? |
| `/live/clip_slot/get/has_stop_button` | `track_index, clip_index` | `track_index, clip_index, has_stop_button` | Has stop button? |
| `/live/clip_slot/set/has_stop_button` | `track_index, clip_index, has_stop_button` | | Set stop button (1=on, 0=off) |
| `/live/clip_slot/duplicate_clip_to` | `track_index, clip_index, target_track, target_clip` | | Duplicate clip to target slot |

---

## Clip API

Audio or MIDI clip. Start/stop, notes, name, gain, pitch, color, playing state/position.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/clip/fire` | `track_id, clip_id` | | Start clip |
| `/live/clip/stop` | `track_id, clip_id` | | Stop clip |
| `/live/clip/duplicate_loop` | `track_id, clip_id` | | Duplicate clip loop |
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
