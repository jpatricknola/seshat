# Ableton Live Object Model (LOM)

The LOM is what `import Live` exposes to a Remote Script. That is the surface
AbletonOSC runs on, and the one that decides what Seshat can do.

It is *mostly* a hierarchy of objects (below), but **not entirely**: some
operations are **module-level functions on a `Live` submodule**, owned by no
object in the session tree. `Live.Conversions.audio_to_midi_clip` (Live's
Convert Harmony/Melody/Drums to New MIDI Track) and `Live.MidiMap.map_midi_cc`
are both of that shape. A search that walks the object tree will not find
them.

## How to check whether the LOM has something

Four sources, in this order of authority. **A negative is only trustworthy
from tier 1 or 2** — every lower source is a filtered view and produces false
negatives.

| Tier | Source | Notes |
|---|---|---|
| **1** | `strings -n 5 "/Applications/Ableton Live 12 Suite.app/Contents/MacOS/Live"` | Ground truth — Boost.Python's own registration table, carrying **Ableton's docstrings and declared argument names**. `grep -E "^Live\.[A-Z][A-Za-z0-9]*$"` enumerates every submodule. |
| **2** | Live's shipped Python: `App-Resources/MIDI Remote Scripts`, `Helpers/Push3.app/…/live_model/Live` | `grep -rl "<term>" ".../MIDI Remote Scripts/"` — Ableton's own Remote Scripts run in **the same interpreter AbletonOSC does**, so one of them calling an operation ends the question. ⚠️ **Grep for the operation name, never for `Live.<Module>`.** `from Live import Conversions` leaves no dotted path in the compiled file, so a module-path grep misses it entirely — measured across every shipped `.pyc` on 2026-08-30, which found twelve modules and none of the ones that mattered. |
| **3** | `_MxDCore/LomTypes.pyc` | ⚠️ **Not the LOM.** The *Max for Live property registry* — what M4L is permitted to see, curated for a different host. Fine as a positive, unsafe as a negative. |
| **4** | [Cycling '74 apiref](https://docs.cycling74.com/apiref/lom/) | Third-party, known to drift (it understated `groove_amount`'s range). |

These scripts are an **existence proof for a specific operation, not a surface
to enumerate.** `_Framework`, `ableton/v2`, `ableton/v3`, `pushbase`, `Push2`,
`Push` and `Move` are Python *clients* of the Live API, not more of it —
everything they do, they do by calling `Live.*`. Walking them yields Ableton's
control-surface helpers, not Live capability (measured and recorded in the
fork's `BLIND_SPOTS.md`, 2026-08-30). Grep them for a verb you already suspect;
do not mine them for new members.

`/live/application/dump_lom` writes the reachable surface to JSON in one OSC
call and is usually the cheapest first move. It **used to record only
classes**, so module-level functions were missing from it and therefore
missing from `FORK_GAPS.md` — fixed on 2026-08-30
([fork #36](https://github.com/jpatricknola/AbletonOSC/issues/36), merged).
The walk now records module-level members under the module's qualname with
`"kind": "module"`, and the gap file reports classes it walked but could not
diff instead of dropping them against a hand-written list.

Two consequences. Absence from the gap file **is** now worth something, where
before it was worth very little — a genuine negative at tier 1 rather than a
filtered view. And it is still only tier 1: name, kind and docstring, read
from a running Live or the binary's registration table, with nothing called.
Argument order, return shapes and whether a member raises are all unmeasured
until someone calls it — `Live.Conversions.is_convertible_to_midi` raising on
a MIDI clip instead of answering `false` is the worked example, found only by
calling it. The fork's
[BLIND_SPOTS.md](../../priv/AbletonOSC/BLIND_SPOTS.md) states what that
inventory still does not claim; read it before concluding from a silence, and
use `API.md` § "Measuring the Live API without building the feature first"
before planning against anything the walk reports but nobody has called.

**Why this is spelled out.** Convert-to-MIDI was recorded as UI-only, and
`convert_audio_to_midi` shipped on an Accessibility helper, on the strength of
one `LomTypes.pyc` grep on 2026-08-27. The operation had been in the LOM the
whole time, and Live's own `Push2/convert.py` had been calling it. Found
2026-08-30; bridge half is
[fork #34](https://github.com/jpatricknola/AbletonOSC/issues/34), **merged the
same day** — `/live/clip/audio_to_midi` and four siblings now exist, and the
Seshat half is the roadmap's top item.

Note what made that a month-long error rather than a day-long one: the tier-3
grep and the tier-1 inventory were **blind in the same place**. `LomTypes.pyc`
did not list the members, and `dump_lom` could not see a module-level function
to contradict it, so a check against two independent sources returned the same
false negative twice and read as confirmation. That is the failure mode the
tier table above exists to prevent, and #36 is what removed the second half of
it.

## Seshat policy

Everything exposed by the installed LOM is 100% fair game for Seshat. The
current AbletonOSC address list is an implementation snapshot, not a product
boundary: when an address is missing, add it to Seshat's fork. That work must
be planned and verified, but it is never a capability limitation, deterrent,
or reason to reject, defer, downgrade, narrow, or rank a feature lower.
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
[priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md).

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
