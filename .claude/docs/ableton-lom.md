# Ableton Live Object Model (LOM)

The LOM is the hierarchy of objects that Ableton Live exposes for programmatic control.
Any bridge to Ableton (AbletonOSC, Max for Live, the Live API directly) ultimately
operates on this same object model.

## Hierarchy

```
Application
└── Song
    ├── tempo, time_signature, is_playing, etc.
    ├── Scenes[]
    │   └── clip slots across tracks
    ├── CuePoints[]
    ├── Tracks[]        (audio and MIDI tracks only — its own index space)
    ├── ReturnTracks[]  (a separate index space: return 0 = send A)
    ├── MasterTrack     (a single object, not a list — no index)
    │   ├── name, color, arm, mute, solo
    │   │   (return and master tracks have a subset: no arm, no clip slots)
    │   ├── MixerDevice
    │   │   ├── Volume  (0.0–1.0)
    │   │   ├── Panning (-1.0–1.0)
    │   │   └── Sends[] (0.0–1.0 each)
    │   ├── Devices[]  (instruments, effects)
    │   │   ├── name, type, class_name, is_active
    │   │   └── Parameters[]
    │   │       ├── name, value, min, max
    │   │       └── (device-specific: e.g. Cutoff, Resonance, Decay)
    │   └── ClipSlots[]
    │       └── Clip (if present)
    │           ├── name, length, looping, color
    │           └── Notes[] (MIDI note data)
    └── View
        └── selected_scene, selected_track, selected_clip, selected_device
```

## Key Concepts

### Track Types
- **Audio tracks**: record/play audio, host audio effects
- **MIDI tracks**: record/play MIDI, host instruments + effects
- **Return tracks**: receive signal from sends, host shared effects (reverb, delay)
- **Master track**: final output, hosts master effects

### MixerDevice
Every track has a MixerDevice containing volume, pan, and sends.

### Devices & Parameters
Each track can host a chain of devices (instruments/effects). Each device exposes parameters with name, value, min, and max. To control a specific knob (e.g. filter cutoff on an EQ), you need `track_id`, `device_id`, and `param_id`.

### Clips & Scenes
A clip sits in a clip slot at the intersection of a track and scene. Clips can be fired (launched), stopped, and have their properties modified. Scenes are horizontal rows — firing a scene launches all clips in that row.

### Listeners / Subscriptions
The LOM supports subscribing to property changes. When subscribed, any change to that property (from any source — our app, Ableton UI, MIDI controller) pushes an update to the client. This is how `Session.State` stays in sync. The mechanism for subscribing depends on the bridge (OSC listeners for AbletonOSC, callbacks for Max for Live, etc.).

## Track Indexing

Tracks are **0-indexed** in the LOM. The model is told ("track 1" = index 0,
"track 2" = index 1, etc.) through MCP tool descriptions.

This mapping happens in the LLM, not in application code.

**Track types do _not_ share one index space.** `Song.tracks` holds audio and
MIDI tracks only, and `num_tracks` counts just those. Return tracks are 0-indexed
within `Song.return_tracks` — a separate space, where return N is the target of
send N on every regular track (return 0 = send A). The master is
`Song.master_track`, a single object with no index at all.

The bridge follows the model: upstream AbletonOSC's `/live/track/*` addresses
reach `Song.tracks` only, so returns and the master are addressable only through
Seshat's own `/live/return_track/*` and `/live/master/*` extension — see
[docs/abletonosc-api-docs.md](../../docs/abletonosc-api-docs.md).

## Value Ranges

These are intrinsic to the LOM, not bridge-specific:

| Parameter | Range | Notes |
|-----------|-------|-------|
| Pan | -1.0 to 1.0 | Left to Right, 0.0 = center |
| Volume | 0.0 to 1.0 | Mapped to dB internally by Ableton |
| Mute | 0 or 1 | 1 = muted |
| Solo | 0 or 1 | 1 = solo on |
| Arm | 0 or 1 | 1 = armed |
| Tempo | 20.0 to 999.0 | BPM |
| Send | 0.0 to 1.0 | Send level |
| Device param | min to max | Query min/max per param |

## Controllable Actions

What we can do to the LOM (regardless of bridge):

### Song-level
- Transport: play, stop, continue, record
- Tempo, time signature, loop settings
- Create/delete/duplicate tracks and scenes
- Undo/redo
- Cue points

### Track-level
- Mixer: volume, pan, sends, mute, solo, arm
- Name, color
- Routing (input/output)
- Monitoring state
- Create/delete/duplicate

### Device-level
- Enable/disable
- Read/write any parameter by index
- Query parameter names, ranges

### Clip-level
- Fire (launch), stop
- Name, length, looping, color
- MIDI note data (read/write)
