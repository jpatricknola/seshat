# Live Object Model → AbletonOSC fork gap audit

_Research and inventory · 31 Jul 2026 · no implementation or roadmap priority
is decided here._

## Why this audit exists

Seshat has three distinct capability layers:

1. **Live's installed Live Object Model (LOM)** — what Live permits a Remote
   Script to read or call.
2. **Seshat's AbletonOSC fork** — which LOM members have OSC addresses.
3. **Seshat's tool layer** — which OSC addresses the model can actually use.

Those layers are easy to collapse into one. "Seshat cannot do X" may mean a
tool is missing, an OSC handler is missing, or Live exposes no API at all. Only
the last case justifies considering UI scripting.

This document audits layer 1 against layer 2. It also names clear layer-3-only
gaps so they are not mistakenly planned as Python work.

## Snapshot and method

Audited against:

- Ableton Live **12.4.3**, build `2026-07-07_e3d8be4d07`, installed at
  `/Applications/Ableton Live 12 Suite.app`.
- Live's shipped allowlist at
  `Contents/App-Resources/MIDI Remote Scripts/_MxDCore/LomTypes.pyc`. This is
  the strongest local evidence: it is the table the installed Live build uses
  to decide which types and members are available to Max/Remote Script code.
- Seshat's AbletonOSC submodule at
  `58c1dd8dc01434802bf6c52de5ba38347bcc9000`, especially the registration code
  in `abletonosc/*.py`.
- Seshat's canonical wire reference,
  [abletonosc-api-docs.md](../abletonosc-api-docs.md).
- Cycling '74's [public LOM reference](https://docs.cycling74.com/apiref/lom/),
  currently labelled Live 12.3.5, for descriptions and access modes. The
  installed 12.4.3 allowlist wins if the two differ.

"Missing from the fork" below means that the installed LOM allowlists the
member but the fork registers no OSC route that reaches it. It does **not** mean
the member has been exercised successfully against a running set. Object-valued
properties also need a deliberate serialization or index scheme before they
are usable over OSC.

This is a capability audit, not an argument to expose the whole LOM. The fork
is intentionally selective; many omissions are good omissions.

## Executive findings

The important gaps are not a long tail of scalar properties. They fall into
four groups:

1. **Small, valuable omissions on objects the fork already handles.** Dialog
   observation, richer device-parameter metadata, count-in/automation state,
   and the rest of `Application.View` are examples.
2. **Objects reached only in one location.** Track and device handlers resolve
   through `song.tracks`, so the same LOM `Track` and `Device` capabilities are
   missing on return tracks, the master, nested Rack chains, and take lanes.
3. **Object-valued capabilities that need an OSC representation.** Grooves,
   selected parameters, warp-marker dictionaries, routing objects, note
   dictionaries, and nested chains cannot be exposed safely by adding a name
   to a generic property list.
4. **Capabilities already in the fork but not in Seshat.** Input/output
   routing is the clearest example. These need Elixir/tool work, not a fork
   commit.

Three high-value bridge gaps are already on the roadmap:

- `Application.View.is_view_visible` and `hide_view` under
  **Read and hide Live's panes**.
- Return/master mixer and device coverage under
  **Devices on return and master tracks**.
- Stable note IDs and `apply_note_modifications` under
  **Modify a note in place**.

The strongest newly identified small addition is **read-only dialog
observation**. The strongest newly identified quality addition is **device
parameter choices and state**, especially `value_items` for quantized
parameters.

## Recommended disposition

This ranking is impact and architectural fit, not a request to insert every
row into the roadmap now.

| Priority | Missing bridge surface | Why it matters | Disposition |
|---|---|---|---|
| High | `Application.open_dialog_count`, `current_dialog_message`, `current_dialog_button_count` | Lets Seshat detect and describe a blocking Live dialog without AX or pixels | New candidate: a small read-only fork extension; keep `press_current_dialog_button` out of the tool surface unless a separately reviewed, non-file use case proves safe |
| High | Return/master mixer and device addressing | An empty return cannot become a usable reverb/delay path without human device loading | Already roadmap item **Devices on return and master tracks** |
| High | `Application.View.is_view_visible` and `hide_view` | Closes `show_view`'s blind loop and makes view smoke tests self-verifying | Already roadmap item **Read and hide Live's panes**; consider `focused_document_view` in the same evidence pass |
| Medium–high | `DeviceParameter.value_items`, `is_enabled`, `automation_state`, `default_value`, `original_name` | Current tools expose raw min/max numbers but cannot name enum choices, tell whether a parameter is disabled, or warn that automation owns it | New candidate: extend the parameter read surface before adding more device-specific APIs |
| Medium–high | Extended note identity and modification (`note_id`, `apply_note_modifications`, selection/by-ID methods) | Enables safe single-note edits and preserves probability, deviation, and release velocity that the current flattened reply discards | Already roadmap item **Modify a note in place** |
| Medium | Count-in and automation state (`count_in_duration`, `is_counting_in`, `session_automation_record`, `re_enable_automation_enabled`) | Recording readiness and automation ownership are musically meaningful, exact, and currently invisible | Evaluate as one focused transport/automation feature; the `re_enable_automation` action is already bridged but undocumented |
| Medium | `Song.View.draw_mode` and `follow_song` | Replaces focus-routed toggle shortcuts with readable absolute state | Fold into a concrete view/automation workflow; not valuable as isolated knobs |
| Medium–low | Groove Pool enumeration and clip assignment | Makes `set_groove_amount` useful without a groove first being assigned by hand | Already recorded in roadmap **Small OSC breadth**; needs index-based serialization in Python |
| Conditional | Arrangement clips and take lanes | LOM support is substantial, but Seshat is deliberately Session-first | Keep declined until an Arrangement/comping workflow is chosen |
| Conditional | Rack chains, Drum Pads, macros and variations | Opens deep sound design, but requires recursive addressing and a much larger tool contract | Keep declined until a named workflow needs inside-the-Rack control |
| Conditional | Device-specific APIs (Simpler, Wavetable, Looper, Drift, Roar, etc.) | Large surface with uneven value; generic parameters already cover much of it | Add only from a concrete feature, never as blanket parity work |

## Core object audit

### `Application` — partial

The fork registers only:

- a two-number version reply (`get_major_version`, `get_minor_version`); and
- `average_process_usage`.

The installed LOM also exposes:

- `open_dialog_count`, `current_dialog_message`, and
  `current_dialog_button_count` — the read-only dialog candidate;
- `press_current_dialog_button` — technically reachable, but unsafe as a
  general model action because a current dialog may guard unsaved work;
- `peak_process_usage`;
- `get_version_string` and `get_bugfix_version`; and
- `control_surfaces`, an object list with little value to Seshat today.

Reference: [LOM Application](https://docs.cycling74.com/apiref/lom/application/).

**Finding:** the claim that dialog presence requires AX is false. The fork is
missing the read, not Live.

### `Application.View` — only `show_view`

The fork's Seshat addition registers `show_view`. It does not register:

- `is_view_visible`;
- `hide_view`;
- `focused_document_view`;
- `browse_mode`;
- `focus_view`;
- `scroll_view`;
- `toggle_browse`;
- `zoom_view`; or
- `available_main_views` where exposed by the installed build.

Reference:
[LOM Application.View](https://docs.cycling74.com/apiref/lom/application_view/).

`is_view_visible` and `hide_view` have clear value and are already planned.
`focused_document_view` may be worth adding in the same handler because it
answers Session versus Arrangement exactly. `focus_view` overlaps
`show_view`; `toggle_browse` is inferior to absolute show/hide; scroll and zoom
need a user story before they earn tool surface.

### `Song` — broad but incomplete

AbletonOSC covers the main transport, loop, tempo, signature, record, track and
scene creation/deletion, undo/redo, groove/swing amount, root note and scale
name. Important installed LOM omissions include:

- **record readiness:** `can_capture_midi`, `count_in_duration`,
  `is_counting_in`;
- **automation:** `session_automation_record`,
  `re_enable_automation_enabled` (the `re_enable_automation` method itself is
  already registered but absent from the canonical address docs);
- **scale/tuning:** `scale_mode`, `scale_intervals`, and the `tuning_system`
  child;
- **Link/tempo:** `is_ableton_link_start_stop_sync_enabled` and
  `tempo_follower_enabled`;
- **Arrangement control:** `play_selection`, `scrub_by`, `start_time`,
  `last_event_time`, and `move_device`;
- **state/guards:** `can_jump_to_next_cue`, `can_jump_to_prev_cue`,
  `is_cue_point_selected`, `select_on_launch`, `exclusive_arm`, and
  `exclusive_solo`; and
- **object children:** `groove_pool`, `tuning_system`, and `visible_tracks`.

Reference: [LOM Song](https://docs.cycling74.com/apiref/lom/song/).

Several are poor direct OSC values: `appointed_device`, `groove_pool`,
`tuning_system`, tracks, scenes and cue points are LOM objects or collections
and need indices or purpose-built replies. Do not put them into the generic
property loop.

### `Song.View` — selection subset only

The fork exposes selected track and scene, custom selected-clip/device helpers,
and Seshat's `detail_clip` setter. Missing installed members include:

- `draw_mode` and `follow_song`;
- `highlighted_clip_slot`;
- `selected_parameter`;
- `selected_chain`;
- modulation-mapping device/parameter where present; and
- the general `select_device` method.

Reference: [LOM Song.View](https://docs.cycling74.com/apiref/lom/song_view/).

The object-valued reads need paths such as `(track, device, parameter)`, not
raw Python objects. `draw_mode` and `follow_song` are the clean scalar wins.

### `Track` — regular tracks only, substantial scalar coverage

For regular tracks, the fork already covers names, color, arm, mute, solo,
monitoring state, meters, volume/pan/sends, device summaries, Session clips,
and input/output routing. It also exposes a small read-only Arrangement clip
summary.

Missing installed capabilities include:

- **Arrangement creation and movement:** `create_audio_clip`,
  `create_midi_clip`, `duplicate_clip_to_arrangement`, `delete_clip` by object,
  and `jump_in_running_session_clip`;
- **take lanes:** `create_take_lane` and the `take_lanes` child;
- **device insertion/reordering:** `insert_device` and `Song.move_device`;
- **track state:** `back_to_arranger`, `can_be_frozen`, `is_frozen`,
  `implicit_arm`, `is_part_of_selection`, `performance_impact`, and
  `is_showing_chains`; and
- **Track.View:** `is_collapsed`, `device_insert_mode`, `selected_device`, and
  `select_instrument`.

Reference: [LOM Track](https://docs.cycling74.com/apiref/lom/track/).

The larger limitation is addressing. `/live/track/*` always resolves through
`song.tracks`, even though the LOM `Track` class also represents return tracks
and the master. The fork's custom return/master handler restores only return
count/name/volume/selection and master volume. It does not restore the rest of
the common Track/Device surface. The roadmap's return/master item is therefore
closing a structural addressing gap, not inventing new Live functionality.

### `Scene` — nearly complete

The fork covers fire, name/color, scene tempo, time signature, empty/triggered
state, and the corresponding listeners. Installed members not directly
registered are mainly:

- `set_fire_button_state`; and
- the `clip_slots` object collection.

No roadmap item is justified by those alone.

### `ClipSlot` — useful core, newer audio/state gaps

The fork covers fire/stop, MIDI clip creation, delete/duplicate, stop-button
state, and the main playback flags. Missing installed members include:

- `create_audio_clip`;
- `is_recording`;
- `color` and `color_index`;
- `set_fire_button_state`; and
- the object-valued `clip` child.

`create_audio_clip` takes an absolute file path. Any Seshat extension must
follow the fork's existing path-safety rule: the model must not be allowed to
hand arbitrary paths to code running with Live's privileges.

### `Clip` — wide property coverage, session-only addressing

The fork exposes many playback, loop, launch, audio and MIDI properties. It
also calls `get_notes_extended`, but flattens each note down to pitch, start,
duration, velocity and mute. It therefore discards stable note IDs and newer
expressive fields such as probability, velocity deviation and release
velocity.

Missing groups include:

- **stable MIDI editing:** full extended-note reads,
  `apply_note_modifications`, `duplicate_notes_by_id`, `select_notes_by_id`,
  selected-note reads, and `remove_notes_extended`;
- **audio warping:** `warp_markers`, `available_warp_modes`,
  `add_warp_marker`, `move_warp_marker`, and `remove_warp_marker`;
- **clip automation:** `has_envelopes`, `clear_all_envelopes`,
  `clear_envelope`, and the Clip.View envelope methods;
- **editing/transport:** `crop`, `duplicate_region`, `quantize_pitch`,
  `move_playing_pos`, `scrub`, and `stop_scrub`;
- **groove assignment:** the object-valued `groove` property; and
- **time signature:** `signature_numerator` and `signature_denominator`.

Reference: [LOM Clip](https://docs.cycling74.com/apiref/lom/clip/).

There is also an addressing gap: `ClipHandler` resolves only
`song.tracks[t].clip_slots[s].clip`. The same LOM `Clip` class represents
Arrangement clips, but the fork cannot apply its Clip API to
`track.arrangement_clips[n]` or take-lane clips.

### `Device` and `DeviceParameter` — top-level regular-track devices only

The fork exposes a device's `name`, `class_name`, `type`, and parameter
names/values/min/max/quantization, plus parameter writes and value listeners.

Missing generic Device metadata includes:

- `class_display_name`;
- `can_have_drum_pads`;
- `is_active`;
- latency in samples/milliseconds; and
- Live 12.3's compare-A/B state and save method.

Missing DeviceParameter metadata includes:

- `value_items` — the human choices for a quantized enum;
- `default_value`;
- `display_value` and `original_name`;
- `is_enabled`;
- `automation_state` and `re_enable_automation`; and
- the remaining state metadata.

Reference: [LOM Device](https://docs.cycling74.com/apiref/lom/device/).

`value_items` is the most useful omission. Today `get_device_parameters`
provides only a numeric range. For a quantized chooser, the model can know that
values are discrete but not what each value means. This is a quality problem
inside an already important workflow, not speculative device breadth.

The same address resolver limitation applies here: all `/live/device/*`
addresses assume `song.tracks[track].devices[device]`. Devices on returns,
master, Rack chains and Rack return chains are unreachable even though the
generic LOM Device/DeviceParameter APIs apply to them.

## Entire object families absent from the bridge

These installed LOM families have no general OSC addressing scheme in the
fork:

| Family | What Live exposes | Why it is not a simple property-list addition |
|---|---|---|
| `Chain`, `ChainMixerDevice`, `DrumChain`, `DrumPad` | Nested devices, chain mixer, pad note/mute/solo, chain insertion/deletion | Needs a recursive path `(track, rack, chain, nested device...)` and must survive structural index changes |
| `RackDevice` and `RackDevice.View` | Chains, Drum Pads, macro count/mappings, macro variations, selected chain/pad | Mixes collections, destructive methods and view state; needs a focused Rack contract |
| `GroovePool`, `Groove` | Indexed pool, groove name/base/timing/random/velocity/quantization | `Clip.groove` is an object reference; Python must resolve a caller-facing index to the object |
| `TakeLane` | Lane names, Arrangement clips, audio/MIDI clip creation | Requires Arrangement-first clip addressing and safe file-path handling |
| `TuningSystem` | Name, reference pitch, note range and tuning table | Structured musical data; useful only with a microtonal workflow |
| `Sample`, `SimplerDevice` | Slices, warp data, playback modes, sample replacement | Large mutable surface and path-bearing replacement method |
| Device-specific classes | Looper, Wavetable, Drift, Meld, Roar, Hybrid Reverb, Eq8, Shifter, Compressor, Plugin, Max devices | High cardinality and version churn; generic parameters already cover common control |
| `DeviceIO` | Max-device audio/MIDI routing ports | Structured routing objects and a narrow Max for Live use case |

References: [LOM RackDevice](https://docs.cycling74.com/apiref/lom/rackdevice/),
[LOM GroovePool](https://docs.cycling74.com/apiref/lom/groovepool/),
[LOM TakeLane](https://docs.cycling74.com/apiref/lom/takelane/).

The correct conclusion is not "implement all of these." It is that future
proposals must check these families before claiming Live cannot perform an
operation.

## Already in the fork: no Python change required

The following are common sources of false bridge-gap claims:

| Capability | Existing fork surface | Actual missing layer |
|---|---|---|
| Read/set regular-track audio input | `/live/track/get/input_routing_type`, `/live/track/set/input_routing_type`, and the corresponding channel/available-list addresses | Seshat tool/handler; roadmap **Read-only audio input display** already says no fork change |
| Read/set regular-track output | Matching `output_routing_*` addresses | Tool layer only |
| Set monitoring mode | `/live/track/get/current_monitoring_state` and `/live/track/set/current_monitoring_state` | Tool layer only |
| Track color | `/live/track/get/color`, `/live/track/set/color`, and the corresponding `color_index` addresses | Tool layer only; already in **Small OSC breadth** |
| Read Arrangement clip summary | `/live/track/get/arrangement_clips/{name,length,start_time}` | A full Arrangement workflow and richer addressing, not the three reads |
| Scene tempo/time signature | Existing `/live/scene/get|set/*` properties | Tool layer only |
| Link enable | Generated get/set/listen addresses for `is_ableton_link_enabled` | Tool/docs layer, not Python |
| Scale root/name | Existing get/set/listen addresses for `root_note` and `scale_name` | Tool choices; `scale_mode`, intervals and tuning remain true fork gaps |

## Canonical address documentation drift found during the audit

The fork source registers several addresses absent from
[abletonosc-api-docs.md](../abletonosc-api-docs.md), even though that file is
described as the canonical address list:

- `/live/application/get/average_process_usage`;
- `/live/song/capture_and_insert_scene`;
- `/live/song/force_link_beat_time`;
- `/live/song/re_enable_automation`;
- `/live/song/get|set|start_listen|stop_listen/is_ableton_link_enabled`;
- `/live/song/set/root_note` and `/live/song/set/scale_name`;
- `/live/song/get/scenes/name`;
- `/live/song/export/structure`.

This list records source-confirmed examples, not a claim that no other
documentation drift exists. The vendored-address test protects Seshat's custom
extensions and strings used from Elixir; it does not prove that every upstream
registration is documented.

Before implementing any finding from this audit, reconcile the relevant
address rows with the Python source and update the canonical docs in the same
change. Do not infer a missing address name from AbletonOSC naming patterns.

## Bottom line

The fork is strong on Session-view tracks, clips, scenes and generic device
parameters. Its meaningful blind spots are:

- application/dialog and view observation;
- return/master and nested-device addressing;
- automation/readiness state;
- stable, expressive note editing;
- object-valued musical structures such as grooves, Rack chains and tuning;
  and
- Arrangement/take-lane objects, deliberately outside Seshat's current focus.

The next time a capability appears "out of reach," use this order:

1. Check the installed `LomTypes.pyc` and public LOM reference.
2. Check the fork's Python registrations, not only the API markdown.
3. Check whether Seshat already has a handler/tool for the address.
4. Only then classify it as a fork gap or a genuine LOM gap.
