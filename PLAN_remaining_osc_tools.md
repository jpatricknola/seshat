# Implementation Plan: Remaining OSC Tools

Everything below is what's NOT yet implemented.

---

## Priority 1 — Device Parameter Control

"Turn up the reverb." "Set the filter cutoff to 80%." "Change the attack on the synth."

Most impactful missing feature. Path to tweaking sounds and eventually loading instruments.

### OSC Addresses

```
/live/track/get/num_devices           [track_id]              → [track_id, count]
/live/track/get/devices/name          [track_id]              → [track_id, name, ...]
/live/device/get/name                 [track_id, device_id]   → [track_id, device_id, name]
/live/device/get/type                 [track_id, device_id]   → [track_id, device_id, type]
                                                                  (1=audio_effect, 2=instrument, 4=midi_effect)
/live/device/get/num_parameters       [track_id, device_id]   → [track_id, device_id, count]
/live/device/get/parameters/name      [track_id, device_id]   → [track_id, device_id, name, ...]
/live/device/get/parameters/value     [track_id, device_id]   → [track_id, device_id, value, ...]
/live/device/get/parameters/min       [track_id, device_id]   → [track_id, device_id, min, ...]
/live/device/get/parameters/max       [track_id, device_id]   → [track_id, device_id, max, ...]
/live/device/get/parameter/value      [track_id, device_id, param_id]         → [... value]
/live/device/set/parameter/value      [track_id, device_id, param_id, value]
/live/device/get/parameter/value_string [track_id, device_id, param_id]       → [... "2500 Hz"]
```

### Implementation Approach

Two tools:
- **`get_device_parameters`** — lists all devices on a track with their parameter
  names, current values, and min/max. Agent needs this to discover what's tweakable.
- **`set_device_parameter`** — takes track, device index, param index, value.

The LLM resolves "the reverb" → device index and "decay time" → param index
using the output of `get_device_parameters`.

Parameter values are normalized 0.0–1.0 in the API. The `value_string` endpoint
gives the human-readable version ("2500 Hz", "–12 dB") which is useful for
the agent to report back.

`class_name` distinguishes Ableton-native devices (Operator, Reverb) from
third-party plugins (AuPluginDevice, PluginDevice). Racks are InstrumentGroupDevice, etc.

Listener support: `/live/device/start_listen/parameter/value [track, device, param]`

---

## Priority 1 — Send Levels

"Add some reverb to the vocals." "Turn down the delay send on the drums."

```
/live/track/get/send    [track_id, send_id]          → [track_id, send_id, value]
/live/track/set/send    [track_id, send_id, value]
```

Send IDs are 0-indexed (send A = 0, send B = 1, etc.).
Return track names needed so the agent knows which send goes where.
Return tracks come after regular tracks in the track list.

Tool: **`set_track_send`** — takes track, send index, value (0.0–1.0).

Session state improvement: include return track names so the agent can
resolve "the reverb send" → send index.

---

## Priority 2 — Nice to Have

### Clip Properties
Setting loop points, launch mode, warp mode, gain on clips.
Useful for sound design but not critical for the note-writing workflow.

### Track Color
`/live/track/set/color_index [track_id, color_index]` (0-69)
Visual organization. Low value for AI control.

### Recording Modes
Session record, arrangement overdub, punch in/out.
Important for a recording workflow but not the current focus.

### MIDI Mapping
`/live/midimap/map_cc [track_id, device_id, param_id, channel, cc]`
Power user feature.

### Beat Listener
`/live/song/start_listen/beat` → pushes beat number on each beat.
Useful for sync/visualization but not for command execution.

### Bulk Track Data
`/live/song/get/track_data [start, end, properties...]`
Performance optimization for get_session_state. Not needed until
we have enough tracks for individual queries to be slow.

---

## Session State Improvements to Support These

1. **Device list per track** — needed for device parameter control
2. **Return track names** — needed for send level references
3. **Track type** (MIDI vs audio) — useful for the agent to know what supports
   MIDI notes vs audio recording
4. **Scene count and names** — useful for the agent to resolve "the chorus" → scene index

These could be queried on-demand by the tools themselves (simpler to start)
or added to `Session.State` (better if we query them frequently).
