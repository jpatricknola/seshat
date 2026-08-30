# Harmony from a melody already in Live — how to build it

_Research & options doc · 30 Aug 2026 · answers "the user has a melody line in
MIDI and asks for harmony on another track (three-part harmony = two extra
tracks plus the original)" · decides nothing by itself; may feed
[ROADMAP.md](../../ROADMAP.md)._

Sibling docs, each still the record of its own subject:
[midi-generation-options.md](midi-generation-options.md) (models measured on
this Mac, and the rejected audio-first route),
[symbolic-midi-strategy-options.md](symbolic-midi-strategy-options.md) (which
symbolic approaches deserve prototypes),
[live-native-options.md](live-native-options.md) (what Live already ships),
[music-generation-user-stories.md](music-generation-user-stories.md) (the
acceptance bar).

---

## Verdict up front

> **Updated 2026-08-30, after PR #84.** `generate_midi` shipped the same day
> and built the write-back half of this feature as a side effect: chunked
> `add/notes_extended` writes with a windowed, float32-tolerant read-back, the
> one-undo-step multi-part workflow, and the first live proof that Live
> persists `probability`/`velocity_deviation` as sent. It built **none** of the
> harmony engine — selection resolution, chord context, candidate scoring and
> voice leading remain entirely unwritten, and `generate_midi`'s bass lane is
> not a precedent (it follows kick onsets from roots Claude supplies; it never
> chooses a pitch against a chord). The rows below are corrected in place. The
> product brief this pairs with is
> [seshat_generate_harmony_handoff.md](../seshat_generate_harmony_handoff.md);
> neither doc has a `ROADMAP.md` entry yet.


**Build it deterministically, in Elixir, with no new dependency and no model.
Every Live-side primitive it needs already ships and was measured working
today.**

This is not the same problem as the generation epic, and the epic's verdict
does not transfer. The 2026-08-25 ruling — Claude composing MIDI directly
fails on *feel* — rested on three failures: uniform velocities, grid-locked
timing, and pitch-guessing against instruments it cannot hear. **Two of the
three do not exist here.** The input is a performance that already has feel:

- **Rhythm is not composed, it is inherited.** Harmony voices in a three-part
  arrangement move with the melody. The onsets and durations are copied, not
  invented.
- **Velocity is not composed, it is inherited** (optionally scaled per voice
  so the lead stays on top).
- **Only pitch is chosen** — and pitch choice against a known scale is a small,
  bounded, correct-by-construction problem, not a matter of taste that a
  language model has to guess.

Ableton agrees, and shipped the same answer: Live 12's **Chord** MIDI effect
harmonises by *scale degree*, not by semitone, with a `Use Current Scale`
switch. Measured today, all 29 of its parameters are reachable through
AbletonOSC and settable with Seshat's existing `set_device_parameter` — so a
real-time three-part diatonic harmony is available **right now with no new
code at all**. It is not the deliverable (it makes no editable MIDI and it
lands on one track, not three), but it is the reference implementation, the
zero-cost preview lane, and the proof that scale-degree offsets are the
right primitive.

Where rules genuinely run out is *which* harmony — parallel thirds below,
sixths above, contrary motion, or voices derived from the melody's implied
chords — and whether the key Seshat thinks it is in is the key the user is
actually playing in. Those are listening and measurement questions, not model
questions. The decision experiment in §5 is a rule-set bake-off on a fixed
slate, not a model bake-off.

**One finding here contradicts a sibling doc and is corrected there, not
footnoted here:** Live's own shipped Push 2 Remote Script calls
`Conversions.audio_to_midi_clip` with a `harmony_to_midi` / `melody_to_midi` /
`drums_to_midi` enum. Convert-to-MIDI is therefore reachable from Remote
Script Python — a **fork gap, not a UI-only feature**. See §2.6 and the edits
to [ui-scripting-options.md](../ui-scripting-options.md) and
[live-native-options.md](live-native-options.md). It does not change this
feature (the input here is already MIDI) but it changes theirs.

---

## 1. The capability frame

"Harmonise this melody onto two more tracks" decomposes into nine operations.
Each row is a table row in §4.

| # | Capability | Input → output | Constraint from the ask |
|---|---|---|---|
| **C1** | Identify the source clip | "this melody" → track index + slot | Must resolve what the user is *looking at*, not guess slot 0 |
| **C2** | Read the melody | track + slot → notes | Needs the expression fields too, if harmony is to inherit feel |
| **C3** | Establish the harmonic frame | session → root, scale, whether the user actually set one | "In key" is the floor; a wrong key is worse than no harmony |
| **C4** | Choose harmony pitches | melody + frame + voice spec → pitches per voice | The composition step. Everything else is plumbing |
| **C5** | Decide the voicing plan | request → voice count, above/below, register, spacing | Three-part = melody + 2; the user may say "below", "tight", "big" |
| **C6** | Create destination tracks with a sound | source track → N−1 new tracks | Harmony should sound like the melody unless told otherwise |
| **C7** | Land each voice as a clip | notes → clip in the matching slot | Same length, same slot row, distinctly named |
| **C8** | One request, one undo step | N tool calls → 1 step | The user stories settle this. Today it is N steps |
| **C9** | Redirect | "lower", "try sixths", "drop the top one" | Must not destroy the kept melody |

**Prior evidence checked, not rediscovered.** `bridge-options.md` already
settled Max for Live (same power as a Remote Script, Suite-only, rejected as a
bridge — so it buys nothing the fork does not).
`extensions-sdk.md` already settled the Extensions SDK (no beta access,
right-click-only trigger, Suite-only → deferred, not scheduled).
`midi-generation-options.md` already settled that Route C (generate audio,
transcribe) is not the primary MIDI strategy. None of those is relitigated.

**No prior doc covers this problem.** The whole generation epic asks "who
composes the notes from a description." This asks "who *harmonises notes that
already exist*." A grep of `docs/evaluating/` for "harmon" finds only the
Convert-Harmony-to-MIDI entries (audio input) and the Notochord / ReaLchords
mentions in `live-improv-exploration.md` (real-time, live playing) — nothing
on symbolic harmonisation of a clip. The roadmap item **"MIDI generation —
the first solution, composed symbolically"** states "Melody and
harmony have no symbolic candidate today." That sentence is true of
*generating* a melody and **false of harmonising one**; §5 says what should
replace it.

---

## 2. The Live-native ladder

### 2.0 Version pin

- **Installed:** Live 12 Suite **12.4.5** (build `2026-08-19_225ce5e356`), read
  from `Info.plist` today. *Measured.*
- **Latest released:** **12.4.5**, 26 Aug 2026, per Ableton's Live 12 release
  notes — the installed build is current. *Reported.*
- 12.4.x brought Link Audio, Stem Separation on selections, and device
  refinements. **No MIDI-generation, harmony or chord feature landed in
  12.4.x.** The scale-relevant additions are older: 12.2 (Resonators scale
  awareness), 12.3 (Meld Chord oscillator). *Reported (release notes).*
- Edition gates that matter below: **Max for Live and the Extensions SDK are
  Suite-only.** The Chord and Scale MIDI effects are **Core Library** devices,
  present in Standard and Suite. The Live 12 MIDI Tools panel is in all
  editions.

### 2.1 Seshat's tool layer

| Capability | Covered today? |
|---|---|
| C1 identify the clip | **No tool.** `get_clip_slots` lists the grid but nothing tells the model which clip the user has highlighted. The address exists (§2.2) |
| C2 read the melody | **Yes** — `get_clip_notes`, five fields (pitch, start, duration, velocity, mute) |
| C3 harmonic frame | **Partly** — `get_session_state` renders `key: C Major` from `root_note` + `scale_name` only |
| C4 choose pitches | **No.** This is the feature |
| C5 voicing plan | **No** |
| C6 tracks with a sound | **Yes** — `duplicate_track` (measured below), or `create_track` + `search_library` + `load_device` |
| C7 land the clips | **Yes** — `delete_clip` + `write_midi_notes` (measured below) |
| C8 one undo step | **No.** Every tool call is its own undo step by design |
| C9 redirect | **Partly** — `edit_notes`, `delete_clip` |

Also at this rung, and worth stating plainly: **Live's Chord MIDI effect is
already fully drivable by shipped tools.** `search_library` finds it
(`query:MidiFx#Chord`), `load_device` loads it, `get_device_parameters` reads
it, `set_device_parameter` sets it.

> **Measured 2026-08-30, Live 12.4.5, this Mac, fork pin `58ac7f0`, through the
> running Seshat MCP server.** Loading `query:MidiFx#Chord` onto a MIDI track
> and reading it back gives **29 parameters**:
>
> `Device On`; then per voice 1–6 — `ShiftN` (−36…36 semitones),
> **`ShiftN Scale Degrees` (−36…36)**, `VelocityN` (0.01…2.0), `ChanceN`
> (0…1); then `Strum` (−20…20), `Strum Tension` (−100…100),
> `Strum Crescendo` (−100…100), and **`Use Current Scale` (0…1)**.
>
> The **Scale** MIDI effect (`query:MidiFx#Scale`) reads back **20
> parameters**: `Device On`, `Base` (0…11), `InternalScale` (0…35),
> `Use Current Scale`, `Transpose` (−36…36), `Fold`, `Lowest` (0…127),
> `Range` (0…128), and a full pitch-class remap `Map 0`…`Map 11` (−1…12).

So: `Use Current Scale = 1`, `Shift1 Scale Degrees = 2`, `Shift2 Scale
Degrees = 4` is a three-note diatonic stack following the session's scale,
with **zero lines of new code**. What it cannot do is put the voices on
separate tracks or leave editable MIDI behind — the Chord device always passes
the original note through and emits its copies live.

### 2.2 The fork

Every address this feature needs is already registered and documented.

| Need | Address | Status |
|---|---|---|
| Which clip is highlighted | `/live/view/get/highlighted_clip_slot` | **Registered — unused by `lib/`.** `convert_audio_to_midi` read it while it drove Live's menu through the Accessibility helper; moving that tool onto `/live/clip/audio_to_midi` deleted the read, and no tool exposes it |
| Selected scene | `/live/view/get/selected_scene` (+ listen pair) | **Now read by a tool** — `get_view_state` reports it since PR #84 (2026-08-30) |
| Melody notes, five fields | `/live/clip/get/notes` | In use |
| Melody notes, **nine fields** | `/live/clip/get/notes_extended` | **Now in use** — `Seshat.Generation.MidiParts` reads it back in windows since PR #84; no tool exposes it to the model yet |
| Write with expression | `/live/clip/add/notes_extended` | **Now in use and live-verified** — `MidiParts` writes through it in 200-note chunks, and Live 12.4.5 was measured persisting `probability` and `velocity_deviation` as sent (2026-08-30, PR #84) |
| Edit without disturbing expression | `/live/clip/apply_note_modifications` | Same |
| Scale intervals | `/live/song/get/scale_intervals` → `0 2 4 5 7 9 11` for Major, observable | **Registered — unused by `lib/`** |
| Every scale Live knows, name → intervals | `Live.Song.get_all_scales_ordered()` — *"Get an ordered tuple of tuples of all available scale names to intervals"* | **In the LOM, no address.** Surfaced 2026-08-30 by [fork #37](https://github.com/jpatricknola/AbletonOSC/pull/37); confirmed independently in the Live 12.4.5 binary |
| Whether the user set a key | `/live/song/get/scale_mode`, observable | **Registered — unused by `lib/`** |
| Root, scale name | `/live/song/get/root_note`, `/live/song/get/scale_name` | Mirrored in `Session.State` |

**There is essentially no fork work in this feature.** That is unusual and
worth saying out loud: the gap is almost entirely at rung 2.1, in Seshat's own
tool layer, reading addresses the fork already answers.

The one exception is optional and arrived after this section was written.
`Live.Song.get_all_scales_ordered()` — one of the 33 previously invisible
free functions surfaced by [fork
#37](https://github.com/jpatricknola/AbletonOSC/pull/37) — returns **every
scale Live knows, as name → intervals, in a single call**. It is not required:
`scale_intervals` already answers for the *current* scale, which is what a
harmoniser needs at the moment it runs. It matters for the two things
`scale_intervals` cannot do — validating a scale the user *names* ("harmonise
it in Dorian") without Seshat hardcoding a table of Live's 36-plus scales, and
telling the user which scales are available at all. Worth an address if
someone is in `song.py` anyway; not worth blocking on.

One relevant fork gap already on record and *not* re-recorded here:
[`FORK_GAPS.md` § "`Clip.notes` has no listener"](../../../priv/AbletonOSC/FORK_GAPS.md)
— no `/live/clip/start_listen/notes`. That is the reason "the harmony follows
the melody as you edit it" is not a story this feature can offer; harmony is
generated on request and goes stale silently if the melody is edited
afterwards.

### 2.3 The LOM

Three sources checked today, in the skill's order of authority.

**`_MxDCore/LomTypes.pyc` (12.4.5).** *Inspected.* `Song` carries `root_note`,
`scale_name`, `scale_intervals`, `scale_mode`. Full note API on `Clip`:
`add_new_notes`, `apply_note_modifications`, `get_notes_extended`,
`get_notes_by_id`, `duplicate_notes_by_id`, `remove_notes_extended`,
`select_notes_by_id`. **Nothing matching `chord`, `harmon`, `transform` or
`generator`.**

**Live's own shipped Python.** *Inspected.* `Push3.app`'s `live_model/Live/`
carries one `.pyc` per LOM class. `Live.Clip.Clip` has **no scale or
`root_note` member at all** — checked directly. `Live.Song.Song` has
`root_note` and `scale_name`. There is a `MidiChordDevice` class (the Chord
effect, as a typed device) and a `MidiPitcherDevice`, but no harmonisation
service.

**Consequence, stated precisely:** Live 12's **per-clip** scale (the Scale
chooser in the transport bar that clips can follow or override) is **absent
from the LOM at both tiers**. That is a *Live limit*, not a fork gap — there
is no member for the fork to expose. Seshat can read and set the **song**
scale and nothing finer. This is load-bearing: the Chord device's `Use Current
Scale` follows the clip's scale where one is set, and Seshat cannot see or set
that.

**Verdict for C4:** **there is no harmonisation member in the LOM at any
spelling.** The LOM supplies the *frame* (scale) and the *plumbing* (notes in,
notes out) and nothing in between. This is the honest "none at any rung"
answer for the composition step, and it is why §3 goes outside — and why §5
comes back in.

### 2.4 Extensions SDK

A harmoniser is a natural Extensions SDK program: clip note access, undo
transactions, JavaScript. But per
[extensions-sdk.md](../extensions-sdk.md), Seshat has no beta access, the
trigger model is a user right-clicking (runs once, then stops — no listeners,
no programmatic invocation), and it is Suite-only. A capability landing here
is **deferred, not scheduled**. Nothing in this feature needs to land here,
because rung 2.1 already reaches everything.

### 2.5 UI-only

**Live 12 MIDI Tools — checked, and they do not do this.** *Inspected + reported.*

Five Generators: **Rhythm, Seed, Shape, Stacks, Euclidean**. Twelve
Transformations: Arpeggiate, Chop, Connect, Glissando, LFO, Ornament,
Quantize, Recombine, Span, Strum, Time Warp, Velocity Shaper. (`Stacks`,
`Chance` and `Quantize` are visible as strings in the Live binary; the full
list is Ableton's manual. *Reported.*)

- **`Stacks` is the near miss.** It builds chords *within a selected scale* —
  and Live ships its ruleset as readable data:
  `App-Resources/Misc/Default Chord Bank.stacks` is JSON of `chord_rulesets`
  keyed by `scale_cardinality`, each rule a list of **scale degrees**
  (`[0,2,4]`, `[0,2,4,6]`, `[0,3,7,9]`, …). *Inspected.* But per Ableton's
  manual it **generates new chords rather than harmonising existing notes**,
  and it is a Generator, so it does not read the melody.
- **No MIDI Tool harmonises an existing melody.** *Reported (Ableton manual,
  fetched today).*
- MIDI Tools are **clip-scoped** — they apply to the time or note selection of
  the clip being edited, and have **no output routing to another track**. So
  even a hypothetical harmonising Transformation could not satisfy the ask
  without a second mechanism to split voices onto tracks.
- **No API.** Nothing in `LomTypes.pyc` or Push's `live_model` exposes
  Transformations or Generators.

So the UI-only rung offers nothing for this feature. That is a clean negative,
not a deferral.

### 2.6 A finding at this rung that belongs to other docs

While walking §2.3 for a harmonisation member, the Convert-to-MIDI question
resolved differently from how `ui-scripting-options.md` records it.

- `_MxDCore/LomTypes.pyc` (12.4.5) **imports `Conversions`** from `Live`.
  *Inspected.*
- `Push3.app`'s `live_model/Live/Conversions.pyc` declares
  `ConversionsServicesAudioToMidiTypeEnum` with **`harmony_to_midi`,
  `melody_to_midi`, `drums_to_midi`**, plus `audio_to_midi_clip`,
  `is_convertible_to_midi`, `create_drum_rack_from_audio_clip`,
  `create_midi_track_with_simpler`. *Inspected.*
- **Live's own shipped Remote Script** `MIDI Remote Scripts/Push2/convert.pyc`
  imports `Conversions`, calls `is_convertible_to_midi`, and names
  `ConvertAudioClipToHarmonyMidi`, `ConvertAudioClipToMelodyMidi`,
  `ConvertAudioClipToDrumsMidi`. *Inspected.*

AbletonOSC is a Remote Script and runs in that same embed. So Convert-to-MIDI
is **a fork gap — a missing address — not a UI-only feature**, which is the
opposite of the disposition that put `convert_audio_to_midi` on the
Accessibility helper.

**Settled 2026-08-30, after this section was first written.** The Live 12.4.5
binary's Boost.Python registration for `Live.Conversions` was read directly,
with Ableton's own docstrings: `audio_to_midi_clip` — *"Creates a MIDI clip in
a new MIDI track with the notes extracted from the given `audio_clip`. The
`audio_to_midi_type` decides which algorithm is used"* — plus
`is_convertible_to_midi` and six siblings, all **module-level free functions**,
with the enum `AudioToMidiType` confirmed live in the running Remote Script
interpreter via the fork's own `/live/application/dump_lom`. Filed as
[fork issue #34](https://github.com/jpatricknola/AbletonOSC/issues/34);
Seshat's half is the roadmap item "`convert_audio_to_midi` drops the
Accessibility helper" — the top item as of 2026-08-30, cited by title because
ranks move.

**Executed 2026-08-30, and both open questions are answered** — see the
correction below and the fork's `API.md` § "Conversions", which owns the
measurements. The paragraph that follows was written before the call was made
and is kept as the record of what was unknown at the time:

**Still not executed** — nobody has called `audio_to_midi_clip` and watched a
track appear, so whether it is synchronous, and whether
`is_convertible_to_midi` raises on a MIDI clip or answers `false`, are open.
Both are named in #34 as things to confirm before the Elixir is written.

Two fork defects surfaced while establishing this, both filed and **both
merged on 2026-08-30**:
[#35](https://github.com/jpatricknola/AbletonOSC/issues/35) — `/live/api/reload`
aborted on a fresh session while still logging "Reloaded code", which is why
`API.md`'s documented probe rig did not work as written; it now names the
module it stopped at and reports a partial reload at `error` level — and
[#36](https://github.com/jpatricknola/AbletonOSC/issues/36) — `walk_live()`
dropped module-level members, which is exactly why `Live.Conversions` was
invisible to `FORK_GAPS.md`; the walk now records them under the module's
qualname.

Sibling docs are edited, per the cross-link rule:
[ui-scripting-options.md](../ui-scripting-options.md) §2 and
[live-native-options.md](live-native-options.md) §1.

---

## 3. External survey

Only now, and the shortlist is short — because §1 established that the hard
part is choosing pitches against a known scale, and almost nothing in the
literature is shaped like that. The field is shaped around *chord* prediction
from a melody, or *four-part chorale* realisation. Neither is "give me two
more singers."

| Candidate | What it does | Code licence | Weights / data | Local? | Conditioning interface | Fit |
|---|---|---|---|---|---|---|
| **Deterministic rules, in Elixir** | Scale-degree offsets from the mirrored scale; optional chord-tone snap, contrary motion, range clamp, voice-crossing guard | n/a — ours | n/a | Yes, in-process | Total: any rule Claude can name in words | **Recommended** |
| **Live's Chord device** | Real-time diatonic stack, `Use Current Scale` | Ableton, in Live | n/a | Yes, in Live | 6 voices × (scale degree, semitone, velocity, chance) + strum | **Preview / fallback lane** — no editable MIDI, one track |
| **music21** | Analysis toolkit; roman-numeral analysis, `chordify`, figured-bass *realisation* | **BSD-3** *(reported)* | Corpus licensed separately — not needed | Yes, Python | Symbolic | Useful *analysis* if implied-chord detection is wanted. Costs a **third native-process door** ([CLAUDE.md](../../../CLAUDE.md)) — has to be argued, not assumed |
| **Composer's Assistant 2** | Multi-track measure infill: fill track B given track A | **MIT** *(reported)* | "trained only on public domain and permissively-licensed MIDI" *(reported)* | Yes, but needs a **persistent** Python + PyTorch server process | Rhythmic/density/pitch controls | Wrong shape *and* wrong cost. Generates an *independent* part, not a voice locked to the melody's rhythm; a resident server is a heavier door than either existing one. Already a roadmap candidate for **bass**, where its shape does fit |
| **DeepBach / Coconet** | Four-part **Bach chorale** harmonisation of a melody | Research code | Bach Doodle assets CC-BY-4.0; **model-weight commercial terms not established** *(reported)* | Yes | Melody in, four voices out — style fixed | Imposes Bach voice-leading on a pop melody. Unresolved weight terms disqualify under the distribution rule unless kept out of the product |
| **MIDI-GPT** | General symbolic infill | — | **Non-commercial weights** | — | — | Disqualified at selection (already recorded in `midi-generation-options.md`) |
| **Hosted chord/harmony APIs** | Chord suggestion from melody | — | — | **No** | — | No API key exists anywhere in Seshat. A service must beat local by a clear margin; here local is *better*, not merely cheaper |

**Nothing was spiked.** No candidate was installed or run for this doc — every
external row above is **reported**, from repository READMEs, papers and
manuals. That is a deliberate call rather than an omission: the deterministic
route needs no spike to be judged (§5 judges rule sets, not installs), and the
two candidates worth a spike are gated on questions cheaper to answer first —
CA2 on whether a resident server is acceptable at all, music21 on whether
implied-chord detection is even wanted in v1.

**Ecosystem health, briefly.** music21 is actively maintained and the most
alive thing on the list. CA2 is a 2024 research release with a working REAPER
integration. DeepBach and Coconet are 2016–2019 research code; Coconet's
living artifact is a browser demo, not a library. Apple Silicon: music21 is
pure Python and fine; CA2 rides PyTorch CPU; the other two are unverified.

---

## 4. Comparison, per capability

Live-native is a column throughout, per the rule this skill enforces.

| Capability | Live-native rung + cost | Deterministic rules (recommended) | External model |
|---|---|---|---|
| **C1** identify the clip | **2.2** — `/live/view/get/highlighted_clip_slot` registered, read by `lib/` already, **no tool**. Small tool-layer job | Same address; add a tool or fold into `get_session_state` | n/a |
| **C2** read the melody | **2.1 partial** — `get_clip_notes` still gives 5 of 9 fields to the model, but `notes_extended` is **no longer unused**: `MidiParts` reads it since PR #84 | Reuse that read so harmony can inherit probability, velocity deviation and release velocity — measured surviving the round trip on 2026-08-30 | Same input either way |
| **C3** harmonic frame | **2.2** — `scale_intervals` and `scale_mode` registered and **unused**; `root_note`/`scale_name` mirrored. **Clip-level scale is absent from the LOM (a Live limit)** | Read intervals rather than mapping a name to a table — Live has 36+ internal scales plus user scales | Same |
| **C4** choose pitches | **None at any rung.** Chord device does it *live* only; no LOM member; no MIDI Tool; Stacks generates rather than harmonises | **Scale-degree offsets from `scale_intervals`, plus range clamp, voice-crossing guard, optional chord-tone snap and contrary motion.** Pure Elixir, deterministic, testable without Ableton | Bach-fixed (DeepBach/Coconet) or wrong-shape (CA2). None expresses "a sixth below, but stay above D3" |
| **C5** voicing plan | **None** | Claude's job — this is exactly the "LLM does the resolving" seam already in [CLAUDE.md](../../../CLAUDE.md) | Poorly steerable: free text or nothing |
| **C6** tracks with a sound | **2.1 — shipped and measured.** `duplicate_track` copies **instrument and clip together in one call** | Same | Same |
| **C7** land the clips | **2.1 — shipped, measured, and now half-built.** PR #84's `MidiParts` already chunks `add/notes_extended` at 200 notes/datagram and reads each clip back in windows, tolerant of float32 truncation | Reuse that writer rather than `write_midi_notes`, so the harmony carries the melody's expression | Same |
| **C8** one undo step | **None.** Each tool call is one step by design | A single `harmonize_melody` tool is one call and therefore one step. Composing it from six existing calls is six steps and fails the stories | Same either way |
| **C9** redirect | **2.1 partial** — `edit_notes`, `delete_clip` | Re-run the rule with new parameters and rewrite only the harmony clips; the melody is never touched | Non-deterministic: "a bit lower" re-rolls the whole part |

### What was measured today, end to end

> **Measured 2026-08-30, Live 12.4.5 (build `2026-08-19`), this Mac, fork pin
> `58ac7f0`, through the running Seshat MCP server, on an empty scratch set.**
> The set was restored to its starting state afterwards.
>
> 1. Wrote an 8-note C-major melody (varied velocities 84–118) to track 0 with
>    `write_midi_notes`.
> 2. `duplicate_track 0` → **the copy carried both the clip and the
>    instrument.** With a `Grand Piano` rack loaded on the source, the copy's
>    chain read back `Device 0 "Grand Piano" — instrument
>    (InstrumentGroupDevice)`, and the copied clip's notes read back with
>    **pitch, start, duration and velocity identical** to the source.
> 3. `edit_notes` with `start_pitch: 72, pitch_span: 1, transpose: 4` moved
>    exactly that one note and self-confirmed on read-back.
> 4. `delete_clip` + `write_midi_notes` rebuilt the slot as a named,
>    length-specified harmony clip in **two calls**, with per-note pitch
>    control.
>
> **Two hazards surfaced.** The duplicate lands at `source_index + 1` and
> **shifts every later track index up** — a three-voice build must re-resolve
> indices between calls, or duplicate in an order that avoids it. And Live
> auto-names from the instrument, so two duplicates read `1-Grand Piano` /
> `2-Grand Piano`: the feature must rename each voice or the user cannot tell
> them apart.

### The wiring question

Two shapes compose the capabilities, and they differ sharply.

**Shape A — duplicate, then replace the notes.** Per harmony voice:
`duplicate_track` → `delete_clip` → `write_midi_notes`. Three calls, and the
voice inherits the melody's instrument, mixer settings and clip length for
free. **Measured working today.** Cost: three undo steps per voice, index
shifting between calls, and a rename still owed.

**Shape B — one tool.** A single `harmonize_melody` call does the whole thing
below `Handlers`. One undo step, no index race, correct by construction. This
is what [tool-surface-scaling.md](../tool-surface-scaling.md) already
prescribes: a genuinely different producer intention (not a property of an
existing one), with a substantial algorithm living in a focused module behind
`Handlers` — the same shape as `Seshat.Tools.NoteEdit` and
`Seshat.Generation.AudioClip`.

**Shape A fails C8 and Shape B passes it.** That is decisive, and it is the
only place the two differ on the criteria. Shape A remains valuable as the
*implementation* inside Shape B, and as the thing to prototype first, since it
is already proven on the wire.

**A third shape worth naming:** put the Chord device on the melody track and
tell the user what you did. One `load_device` and two `set_device_parameter`
calls, working today, no editable MIDI, one track. Not the deliverable — but
the right answer to "just let me hear what a third above sounds like," and the
right fallback when the key is unknown (§5's kill measurement).

---

## 5. Verdict expanded, and the experiment

### The recommendation

**Ship a single `harmonize_melody` tool implementing deterministic
scale-degree harmonisation, with the arithmetic in a pure module behind
`Handlers`.** The evidence supports this without further research:

1. **C4 has no candidate at any Live rung** (§2.3), so something must be
   built — the only question is what.
2. **The epic's objection does not apply** (§0). Rhythm and velocity are
   inherited; only pitch is chosen; pitch against a known scale is
   deterministic.
3. **Ableton solved it the same way.** The Chord device harmonises by scale
   degree with `Use Current Scale`, and Live ships a diatonic scale-degree
   chord ruleset as data (`Default Chord Bank.stacks`). Building scale-degree
   offsets is following Live's own model, not inventing one.
4. **Every primitive is shipped and was measured working today** (§4).
5. **No external candidate is the right shape**, and the two nearest cost more
   than they return: CA2 wants a resident server for a part that would not be
   locked to the melody anyway; DeepBach and Coconet impose Bach.
6. **Deterministic wins the criteria that rank highest here** — expressiveness
   of control (Claude can say "a sixth below, above D3, contrary motion at the
   phrase end" and have it obeyed), local-first fit (in-process, no door),
   licence (none needed), latency (arithmetic), verification path (the result
   is read back with `get_clip_notes` and can be asserted in `mix test`
   without Ableton), and undo atomicity.

The pure-module split matters for a reason this project has already paid for:
`NoteEdit` proved that note arithmetic tests exhaustively with no OSC and no
Live. A harmoniser is the same kind of code, and its correctness — in key, in
range, no crossing, no doubled unisons — is exactly what a test suite can pin.

### What the evidence does *not* settle, and the smallest experiment that would

It settles the mechanism. It does not settle **which harmony sounds right**,
and it must not pretend to.

> **Experiment H1 — the rule-set bake-off.** Fixed slate of **five melodies**
> chosen to break different rules: a stepwise diatonic line, a line with
> chromatic passing notes, a wide-leaping line, a line that sits low in the
> register, and a syncopated line with rests. All in Live, all rendered
> **through the same instrument** on every arm, judged **by ear and blinded**.
>
> Arms, all deterministic, all cheap:
> **(a)** parallel third above; **(b)** parallel sixth below; **(c)** third
> below + sixth below (the two-voice-under default);
> **(d)** chord-tone-snapped — degrees chosen against an implied chord per bar
> rather than a fixed interval; **(e)** contrary motion at phrase ends.
> **Control:** Live's Chord device, `Use Current Scale`, same offsets — which
> tells us whether our arithmetic matches Ableton's.
>
> **What it decides:** the default `harmonize_melody` produces without being
> asked, and whether (d) earns its extra machinery. **What it can kill:** if
> (d) beats every fixed-interval arm on the chromatic and leaping melodies,
> implied-chord detection is v1 scope, not v2 — and music21 as a third door
> becomes a real question rather than a hypothetical one.

> **Measurement K1 — run this *before* H1; it can invalidate the frame.**
> Does Seshat know the key? `get_session_state` reports `key: C Major` on a
> set where nothing was ever set — its own tool description admits this.
> Read `/live/song/get/scale_mode` and check whether it distinguishes "the
> user set a key" from "Live's default." Then check whether a **clip**-level
> scale override (Live 12, absent from the LOM per §2.3) leaves the song-level
> reading *wrong* rather than merely unset.
>
> **What it can kill:** if the song scale cannot be trusted, harmonising to it
> silently is worse than not harmonising. The feature would then have to infer
> the scale from the melody's own pitch content, or ask — and "ask" is a
> product decision, not an implementation detail.

> **Measurement K2 — answered 2026-08-30, and it did kill that case.**
> `Live.Conversions` is a registered module of free functions in the Live
> binary, and its enum is live in the Remote Script interpreter. Convert-to-MIDI
> is a fork gap, not a UI-only feature, so `convert_audio_to_midi` need not use
> the Accessibility helper at all. Bridge half:
> [fork #34](https://github.com/jpatricknola/AbletonOSC/issues/34) — **merged
> the same day**. Seshat half: the roadmap item "`convert_audio_to_midi` drops
> the Accessibility helper", now the top item.
>
> **The call has since been executed, and both open questions are answered.**
> `audio_to_midi_clip` is **asynchronous**, and `is_convertible_to_midi`
> **raises on a MIDI clip** rather than answering false — the fork wraps it so
> the address always answers. Neither was predictable from the registration
> table, which is the point of K2 as a measurement. The fork's `API.md`
> § "Conversions" holds the contract; do not restate it here. None of this
> touches the harmony feature, whose input is already MIDI.

Run **K1 → H1**. K2 is **done**; its result belongs to whoever picks up
`convert_audio_to_midi`, which is now planned.

### Roadmap shape, if this is picked up

Not inserted into [ROADMAP.md](../../ROADMAP.md) — that is a ranked
commitment, and this doc's job is to make the commitment informed. If it is
added, the honest framing is:

- **Impact 8** — it is a complete musical intention with a clean answer, it
  needs no fork work and no dependency, and it makes the existing melody the
  user already cares about immediately more useful.
- **Lift 3** — one tool, one pure module, three unused-but-registered
  addresses to start reading, no Python, no install, no Live restart.
- **≈2.7 impact-per-effort**, which would place it **above the current #1**.

It should also **correct the sentence in "MIDI generation — the first
solution, composed symbolically"** reading "Melody and harmony have no
symbolic candidate today." That is true of generating a melody from a
description and false of harmonising one that exists. The two should not share
a lane: this needs no model, no listening bake-off against models, and none of
#1's licence work.

---

## 6. Open work — what is not measured

Nothing below is settled; a doc that reads as complete retires the checks
nobody wrote.

**Blocking the design:**
1. **K1** — whether `scale_mode` distinguishes a set key from Live's default,
   and what a clip-level scale override does to the song-level reading.
1b. Whether `get_all_scales_ordered()`'s interval tuples agree with
   `scale_intervals` for the same scale, and what it does with a user-defined
   scale. Only matters if the "harmonise it in <named scale>" path is built.
2. Whether the Chord device's `Use Current Scale` follows the **song** scale
   (which Seshat can set) or the **clip** scale (which it cannot see). Decides
   whether the Chord-device fallback lane works at all.

**Blocking the quality answer:**
3. **H1** — which rule set is the default. Unrun.
4. Whether inheriting the melody's velocities verbatim sounds right, or
   whether harmony voices need a fixed scale-down to keep the lead on top.
   Ears only.
5. Whether harmony should inherit micro-timing verbatim. Homorhythmic harmony
   usually does; a plucked or strummed voice may want `Strum`-like spread.

**Measured nowhere, cheap to measure:**
6. Round-trip fidelity of `/live/clip/get/notes_extended` →
   `/live/clip/add/notes_extended`. `API.md` records that Live *accepts* the
   eight-field construction (confirmed 2026-08-29) but that **the values were
   never read back**. A harmony voice inheriting probability and velocity
   deviation depends on that round trip.
7. Whether `duplicate_track` copies mixer sends and track colour, not just
   instrument and clips. Only the instrument and the clip were measured.
8. Timing of a full three-voice build. Individual calls were fast; the total
   was not timed.

**Not attempted:**
9. No external candidate was installed or run (§3). Every external figure is
   reported.
10. **K2 is answered but not executed** — the registration and the live enum
    are established; `audio_to_midi_clip` has still never been called, so its
    synchronicity and `is_convertible_to_midi`'s behaviour on a MIDI clip are
    open. Tracked on [fork #34](https://github.com/jpatricknola/AbletonOSC/issues/34).

**Defects this research exposed in existing code and docs** — independently
real, recorded here, not yet filed:
- **`edit_notes`' description states a false reason.** It tells the model that
  probability, velocity deviation and release velocity are reset "(the wire
  cannot carry them)". Since 2026-08-29 the wire carries all three, and
  `/live/clip/apply_note_modifications` edits notes without disturbing them.
  The *behaviour* is still accurate — `edit_notes` uses the five-field
  addresses — but the stated reason is wrong, in model-facing text.
- **`lib/` reads none of the extended-note addresses**, so every Seshat note
  edit silently flattens Live's expression fields. Directly load-bearing here:
  harmony inheriting the melody's feel is the whole premise.
- **`ui-scripting-options.md` and `live-native-options.md` recorded Convert-to-
  MIDI as UI-only** on the strength of a `LomTypes.pyc` grep. It is not:
  `Live.Conversions` is a registered module of free functions. Both docs are
  corrected, and the bridge half is
  [fork #34](https://github.com/jpatricknola/AbletonOSC/issues/34) with
  Seshat's half is the roadmap item **"`convert_audio_to_midi` drops the
  Accessibility helper"** (cited by title: it was written here as "#14" and is
  now the top item, which is why ranks are not identifiers).
- **`/live/api/reload` has been silently broken on every fresh Live session** —
  [fork #35](https://github.com/jpatricknola/AbletonOSC/issues/35). It aborts
  on `abletonosc.introspection` (imported lazily inside a callback, so the
  attribute does not exist) and then logs "Reloaded code" anyway. `API.md`'s
  probe rig depends on it.
- **`FORK_GAPS.md` could not see module-level LOM members at all** —
  [fork #36](https://github.com/jpatricknola/AbletonOSC/issues/36), **merged
  2026-08-30**. `walk_live()` recursed into modules and types and dropped
  everything else, so absence from the gap file was not evidence of absence
  from the LOM. It now records module-level members and reports the classes it
  walks but cannot diff, so that absence is worth something. The "unknown how
  much else this hides" question was answered by the regeneration: seven Live
  modules, and a *Walked but not diffed* section carrying 198 members across
  38 entries that the old hand-written filter dropped without a note.

---

## 7. Source index

**Measured on this Mac, 2026-08-30, Live 12.4.5 (build `2026-08-19_225ce5e356`),
fork pin `58ac7f0`, via the running Seshat MCP server:** Chord device 29-parameter
readout; Scale device 20-parameter readout; `duplicate_track` copying instrument
and clip; note round-trip through `write_midi_notes` / `get_clip_notes`;
`edit_notes` single-pitch window; `delete_clip` + `write_midi_notes` rebuild;
track-index shift and auto-naming on duplicate; `get_session_state` key rendering.

**Inspected on this Mac (read, not executed):**
`/Applications/Ableton Live 12 Suite.app/Contents/Info.plist`;
`App-Resources/MIDI Remote Scripts/_MxDCore/LomTypes.pyc`;
`App-Resources/MIDI Remote Scripts/Push2/convert.pyc`;
`Helpers/Push3.app/.../live_model/Live/{Clip,Song,Conversions,MidiChordDevice,MidiServices}.pyc`;
`App-Resources/Misc/Default Chord Bank.stacks`;
`App-Resources/Core Library/Devices/MIDI Effects/{Chord,Scale}/*.adv`;
`App-Resources/Builtin/Devices/MIDI Tools/`;
`MacOS/Live` (string table);
`priv/AbletonOSC/API.md`, `priv/AbletonOSC/abletonosc/clip.py`,
`priv/AbletonOSC/FORK_GAPS.md`;
`lib/seshat/tools/definitions.ex`, `lib/seshat/tools/handlers.ex`,
`lib/seshat/session/state.ex`;
`catalog.json` (5,796 entries).

**Reported (not reproduced):**
[Live 12 release notes](https://www.ableton.com/en/release-notes/live-12/) ·
[MIDI Tools, Live 12 manual](https://www.ableton.com/en/live-manual/12/midi-tools/) ·
[Live MIDI Effect Reference](https://www.ableton.com/en/manual/live-midi-effect-reference/) ·
[Keys and Scales in Live 12 FAQ](https://help.ableton.com/hc/en-us/articles/11425083250972-Keys-and-Scales-in-Live-12-FAQ) ·
[Live 12.4 announcement](https://www.ableton.com/en/blog/live-12-4-is-out-now/) ·
[music21](https://github.com/cuthbertLab/music21) (BSD-3) ·
[Composer's Assistant for REAPER](https://github.com/m-malandro/composers-assistant-REAPER) (MIT) ·
[Composer's Assistant 2 paper](https://arxiv.org/abs/2407.14700) ·
[DeepBach](https://arxiv.org/pdf/1612.01010) ·
[Coconet / Bach Doodle](https://coconets.github.io/)

**Seshat docs consulted:** [midi-generation-options.md](midi-generation-options.md) ·
[symbolic-midi-strategy-options.md](symbolic-midi-strategy-options.md) ·
[live-native-options.md](live-native-options.md) ·
[music-generation-user-stories.md](music-generation-user-stories.md) ·
[live-improv-exploration.md](live-improv-exploration.md) ·
[ui-scripting-options.md](../ui-scripting-options.md) ·
[extensions-sdk.md](../extensions-sdk.md) ·
[bridge-options.md](../bridge-options.md) ·
[tool-surface-scaling.md](../tool-surface-scaling.md) ·
[ROADMAP.md](../../ROADMAP.md)
