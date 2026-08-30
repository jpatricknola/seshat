# Live-native options — what Ableton already does that the generation epic shipped around

_Evaluation doc · 27 Aug 2026 · a fresh pass over this folder applying the
rule the `/evaluate` skill now enforces: check what Live itself does before
surveying external models. Decides nothing by itself; every sibling doc it
touches now points here from the passage it corrects._

**Why this doc exists.** The five sibling docs took their information from
papers, model cards and local spikes, and that information is assumed
accurate here. What none of them did was ask what the installed Live
(originally measured on 12.4.3; installed and latest 12.4.5, rechecked
2026-08-30) already does for each capability. The
answer is: quite a lot. Live ships a source separator, three audio-to-MIDI
converters, a slicer, a groove extractor and a library of ~3,000 grooves, a
set of MIDI generators and humanising transformations, a bounce-to-audio
command, an Arrangement-locator API, and a network audio protocol. Several
of those land squarely on capabilities the epic proposed importing a
dependency for.

Each rung below follows [ui-scripting-options.md](../ui-scripting-options.md)'s
ladder. **LOM** means present in Live 12.4.3's `_MxDCore/LomTypes.pyc`
(checked 2026-08-27 by string dump) — a fork handler away. **UI-only** means
not in the LOM at any spelling, reachable only through Live's menus and
therefore only through the named-AX rung, which has been validated once
(Audio Settings, 2026-08-03) and never against a Create-menu command. Edition
gates are from Ableton's own pages. Everything here is **reported unless
marked measured**; nothing below was run against Live today.

---

## 1. Inventory — what Live has, at which rung

| Live feature | Since | Edition | Rung | Relevant to |
|---|---|---|---|---|
| **Stem Separation** (vocals / drums / bass / other → new tracks; time-selection variant; merge option; GPU on macOS 26.3+) | 12.3 | **Suite** | UI-only (Create / context menu) | Joint-C separation ([midi §Open work](midi-generation-options.md#L860)) |
| **Convert Drums to New MIDI Track** (kick / snare / hat onto a Drum Rack, from transients) | 9 | Standard, Suite | UI-only | Route C drum transcription ([midi §C.1](midi-generation-options.md#L339)) |
| **Convert Melody to New MIDI Track** (monophonic → synth/EP Instrument Rack) | 9 | Standard, Suite | UI-only | Route C bass ([midi §C.2](midi-generation-options.md#L448)) |
| **Convert Harmony to New MIDI Track** (polyphonic → piano Instrument Rack) | 9 | Standard, Suite | UI-only | Route C pads/chords ([midi §C.2](midi-generation-options.md#L448)) |
| **Slice to New MIDI Track** (transients / beat divisions / warp markers → Drum Rack of Simplers + a MIDI clip, ≤128 slices) | 8 | Standard, Suite | UI-only for the command; **LOM** for Simpler's slice list (`slices`, `insert_slice`, `remove_slice`, `clear_slices`, `reset_slices`, `slicing_playback_mode`) plus `SimplerDevice.replace_sample` (12.2) | Drum loops as editable MIDI without transcription ([midi §C.5](midi-generation-options.md#L505)) |
| **Extract Groove(s)** (timing + velocity from any audio *or* MIDI clip → Groove Pool) | 8 | all | UI-only | Feel transfer, existing-context conditioning ([midi §E.2](midi-generation-options.md#L782), [§D](midi-generation-options.md#L582)) |
| **Groove Pool + Core Library grooves** (`Song.groove_pool.grooves`; `Groove.base / timing_amount / random_amount / velocity_amount / quantization_amount`; `Clip.groove` get/set/observe since Live 11; ~3,000 shipped `.agr` files) | 8 / 11 | all | **Fork** — the fork now exposes groove-pool reads/settings and `/live/clip/get\|set/groove` by pool index (measured on Live 12.4.5, 2026-08-29); Seshat still has no clip-groove tool | Humanising generated MIDI ([midi §D](midi-generation-options.md#L582)); now a tool-layer gap, not a fork gap |
| **MIDI Tools — Generators** (Rhythm, Seed, Shape, Stacks; Euclidean via M4L) and **Transformations** (Arpeggiate, Chop, Connect, Glissando, LFO, Ornament, Quantize, Recombine, Span, Strum, Time Warp; Velocity Shaper via M4L); custom `.amxd` tools allowed | 12.0 | Standard, Suite | UI-only (clip-view panel, parameters, Apply) | Route A/D drum and pattern generation; feel post-processing ([midi §D](midi-generation-options.md#L582)) |
| **Bounce Track in Place / Bounce to New Track / Paste Bounced Audio / Bounce Group** | 12.2–12.3 | all | UI-only | Rendering existing MIDI to audio for joint-C or audio-to-audio conditioning; improv capture ([improv §9](live-improv-exploration.md#L492)) |
| **Arrangement locators** (`Song.cue_points`, `set_or_delete_cue`, `jump_to_next_cue`, `is_cue_point_selected`) | ≤9 | all | **LOM** — fork gap | Section markers for the improv slow loop ([improv §9](live-improv-exploration.md#L511) says "not in the fork"; true, but it is in the LOM) |
| **Link Audio** (real-time audio between Link peers, latency slider, "Sync to Incoming Audio") | 12.4 | all | Outside the LOM — a network protocol; no public SDK found for the audio half | Improv routing without BlackHole ([improv §9](live-improv-exploration.md#L512)) |
| **Ableton Link** (tempo + beat phase to any peer; open-source SDK) | 9.5 | all | Outside the LOM | Improv phase: the generator learns beat one from Link, not from an OSC tick ([improv §9](live-improv-exploration.md#L534)) |
| **Extensions SDK** (JS/TS on Node inside Live: clip/track/device/MIDI access, audio import, undo transactions, `renderPreFxAudio()`, modal webviews, network) | 12.4.5 beta | Suite | Second bridge, not a rung | Import path, bounce, and possibly the UI-only rows above. **Researched 2026-08-30 — [extensions-sdk.md](../extensions-sdk.md)**: not reachable without beta access, and its trigger model (user right-clicks, extension runs once, stops) rules it out as a replacement bridge. The `render_pre_fx_audio` and `import_into_project` messages are confirmed on the Extension Host class; the wider Push-document surface (`bounce`, `audio_to_midi_clip`, `separate_stems`, the warp commands, slicing, take lanes) is measured in Live's binary but unconfirmed in the JS API |
| Drum Rack pad map (`DrumChain.in_note`, `RackDevice.insert_chain`, `Track.insert_device`) | 12.3 | all | **LOM** — fork gap | Already folded into [midi §Open work](midi-generation-options.md#L880) |

Not relevant after checking: Similar Sounds search (not in the LOM; sound
selection is the catalog's job), Capture MIDI (already a tool), Auto Shift /
Expressive Chords (devices, not generation), tuning systems.

---

## 2. Per-capability evaluation against the existing suggestion

### 2.1 Drum transcription — Convert Drums vs IDM

The epic's proposal: SA3 renders a drum loop → **Inverse Drum Machine**
(Apache-2.0, unspiked) transcribes → per-lane split → `write_midi_notes`.
The measured stand-in (ADTOF-pytorch) is unlicensed and excluded.

| | IDM (proposed) | **Convert Drums to New MIDI Track** |
|---|---|---|
| Ships with | A model + runtime Seshat installs and maintains | Nothing — Live Standard and Suite |
| Licence surface | Apache-2.0 code and bundled weights (verified) | Zero |
| Input | WAV on disk | Audio clip **already in Live, selected** — needs the import address first |
| Classes | Reported frame-level onsets + velocities; class count unverified | Kick, snare, hi-hat only (manual) — narrower than ADTOF's five, far narrower than GMD's nine |
| Velocity | Native | Unverified whether it varies |
| Output placement | A note list Seshat lands where it likes, one undo step | Live creates **its own new track with its own Drum Rack** — then Seshat must rename, possibly swap the kit, and split lanes across tracks; each is another mutation |
| Latency | Unmeasured; reported ~100× smaller than baselines | Seconds, UI-thread, unmeasured |
| Verification | Note-count sanity in-process | OSC-side: track-count push, then `get_clip_notes` |
| Mechanism risk | None | Named-AX Create-menu command — never spiked |

**Merit:** Convert Drums removes the transcriber dependency entirely, which
is the epic's most licence-fraught component. Against that, three lanes is a
hard ceiling for lo-fi (open hat, shaker and percussion are load-bearing,
[midi §C.5](midi-generation-options.md#L530)), and the output arrives as a
*track Live designed*, so the "one request, one undo step, N per-instrument
tracks" contract means a second round of mutations after the convert. It
belongs in the bake-off as an arm — cheapest possible Route C drums — not as
a replacement for spiking IDM. If IDM's lane count turns out to be three as
well, the comparison collapses to licence-free versus a dependency, and
Convert Drums wins.

### 2.2 Bass and chords — Convert Melody / Harmony vs Basic Pitch

Proposal: SA3 → **Basic Pitch** (Apache-2.0, 225 KB ONNX, measured 0.06 s)
→ notes.

| | Basic Pitch (proposed) | **Convert Melody / Harmony** |
|---|---|---|
| Measured | 0.06 s; 16 clean bass notes on the `medium` render | Nothing |
| Input | WAV | Imported, selected audio clip |
| Output | Note list with amplitude → velocity; Seshat places it | New track with Live's piano or synth Instrument Rack; Seshat re-instruments |
| Ecosystem | Stale (2024-08), SciPy pin, TensorFlow avoided via onnxruntime | Maintained by Ableton |
| Quality | Reputation: strong monophonic, weak polyphonic voicing | Unmeasured; the manual's own "works best with…" caveats match Basic Pitch's |

**Merit:** for bass, Basic Pitch is measured, instant, and returns data
Seshat controls; Convert Melody offers nothing it lacks and costs an import,
a selection, a focus-dependent menu action and a cleanup pass. **One axis this
table missed** — expression. Neither the note-writing path nor Live's Convert
carries pitch bend, but a Basic Pitch `.mid` handed to Live's own importer
does, measured 2026-08-30; see
[midi §C.2a](midi-generation-options.md#c2a-getting-a-transcription-into-live--notes-vs-the-file-measured-2026-08-30). **Keep Basic
Pitch.** Convert Harmony is worth one comparison on the pad render only
because polyphonic transcription is where Basic Pitch is weakest and Live's
converter is a different algorithm — a single afternoon's A/B, not a route.

### 2.3 Source separation — Stem Separation vs a shipped separator

Proposal: joint C (one SA3 render of drums + bass → separator → two
transcriptions) is blocked on a separator whose weights are clean; Demucs's
are unresolved.

| | Shipped separator (Demucs or other) | **Live Stem Separation** |
|---|---|---|
| Licence | Unresolved upstream for Demucs; every alternative needs its own check | Zero |
| Edition | Any | **Suite only** — Standard users lose the arm |
| Stems | Model-dependent | Fixed four: vocals / drums / bass / other; "merge to single track" option |
| Runtime | Seshat-managed, CPU/MPS | Live's, GPU on macOS 26.3+, seconds to minutes, progress bar |
| Output | Files | New tracks in the set, original muted — then transcription needs each stem as a file (bounce, or Convert directly on the stem clip) |
| Mechanism | In-process | Named-AX menu command; possibly a mode dialog (`press_current_dialog_button` exists in the LOM) |

**Merit:** this is the strongest native substitution in the folder. Joint C
was the arm with the highest interaction ceiling and the worst dependency
story; Live's separator makes it the arm with **no** dependency story, and
its four fixed stems are exactly drums + bass + other, which is what the
rhythm-section render contains. The Suite gate is acceptable for an
optional arm. **Recommendation: drop the separator survey; joint C uses
Live Stem Separation or does not run.** The open questions move to the AX
spike: menu-bar reachability, dialog, completion detection (track-count
push), and how the resulting stem clips reach a transcriber (Convert Drums
on the drum stem needs no file at all; Basic Pitch on the bass stem needs a
bounce or the Extensions SDK's `renderPreFxAudio()`).

### 2.4 Drum loops as editable MIDI — Slice to New MIDI Track vs transcription

Not in any sibling doc. The epic assumes "editable" means "transcribed to
notes on a kit." Live offers a third shape: **slice the SA3 loop itself** —
a Drum Rack of Simplers, one per transient, and a MIDI clip that plays them
in order.

| | Transcribe (IDM / Convert Drums) | **Slice to New MIDI Track** |
|---|---|---|
| Sound | Whatever kit Seshat loads — the *generated* sound is lost unless the WAV is kept | **The generated sound, exactly**, per hit |
| Editability | Notes on GM pitches; re-orderable, re-pitchable, swap the kit | Notes that trigger slices; re-orderable, re-velocity, but a slice is a sound, not a drum class — swapping "the snare" means swapping several pads |
| Per-instrument tracks | Natural after lane split | Not natural — slices are chronological, not by instrument |
| Feel | Transcriber's onset accuracy (4.3–28.2 ms measured, unattributed) | Exact — slices sit where the transients were |
| Licence / dependency | IDM or nothing | Zero |
| Rung | In-process / UI-only | UI-only command; **but** the Simpler slicing API is in the LOM, so a fork handler could load the WAV via `replace_sample`, set `playback_mode` to Slicing, and read `slices` — the *MIDI clip* Live generates would still need writing by Seshat from the slice times, which `write_midi_notes` can do |

**Merit:** for the "generate audio, keep it editable" story this is the
honest answer to "MIDI cannot represent the requested material adequately"
in [music-generation-user-stories.md](music-generation-user-stories.md#L198)
— instead of explaining the limitation, slice. It does not serve the
per-instrument-track contract and does not replace transcription for bass.
Worth an arm in the audio-output half of the bake-off, and worth noting
that the LOM half (Simpler slicing) might make it fork-only, no AX.

### 2.5 Feel — Live grooves and MIDI Tools vs GrooVAE / GMD

Proposal (Route D): retrieve GMD performances or run GrooVAE (dependency
tree with nine advisories, archived Python, hosted checkpoint of uncertain
licence) to give rule-built or Claude-built patterns human velocity and
microtiming.

Live has two native mechanisms on the same problem:

- **Groove Pool.** ~3,000 shipped grooves (MPC, SP-1200, Logic, live
  drummers, per-genre swings), each carrying timing, random, velocity and
  base amounts. `Clip.groove` is get/set in the LOM; the fork comments it
  out only because the value is an object. A handler taking a pool index —
  or a browser-loaded groove — is ordinary fork work. `Commit` bakes it into
  the notes.
- **Extract Groove** from any clip, audio or MIDI — including an SA3 drum
  render, a GMD performance, or the user's existing beat.
- **MIDI Tools.** *Time Warp* (breakpoint timing), *Velocity Shaper*,
  *Ornament* (flams, grace notes), *Recombine*, *Chop*, *Span* are
  humanising transformations; *Rhythm*, *Seed*, *Euclidean* are drum
  pattern generators with density/accent/velocity parameters. All UI-only,
  parameter-heavy panels — the hardest AX target in this list.

| | GrooVAE / GMD (proposed) | **Grooves (LOM) + Extract Groove (AX)** | **MIDI Tools (AX)** |
|---|---|---|---|
| What it gives | Learned kit orchestration + feel (GrooVAE); literal human performance (GMD) | Timing/velocity *offsets* applied to notes you already have; no orchestration, no new notes | New notes (generators) or note edits (transformations), parameterised |
| Dependency | 254 MB npm tree with advisories, or a 3 MB dataset + attribution | Zero — shipped grooves are licensed with Live | Zero |
| Rung | In-process | Fork handler for assign/commit; AX only for *extract* | AX against a clip-view panel with many controls |
| Conditioning on existing music | None | **Yes** — extract the user's beat's groove and apply it to the generated bass; the cheapest real "context use" in the folder | None |
| Ceiling | GMD's finite genre vocabulary; GrooVAE's 2-bar checkpoints | A groove is a per-position offset table — it cannot make a stiff pattern *sound* played beyond timing and velocity | Generators are random-within-parameters, not style-aware |

**Merit:** grooves do not replace Route D — they cannot invent a pattern or
orchestrate a kit — but they cover the *feel transfer* half with no
dependency and, uniquely, they answer [midi §E.2](midi-generation-options.md#L782)'s
existing-context problem for timing: extract the groove from the clips
already in the section and apply it to every generated part. That is a
fork-plus-one-AX-command path and belongs in the conditioned arms of the
bake-off. MIDI Tools' generators are a legitimate Route A alternative with
zero dependency, but driving a parameter panel over AX is unvalidated and
the output is parametric noise, not style — file them as a later spike, not
an arm.

### 2.6 Rendering existing MIDI to audio — Bounce vs nothing

Joint C and any audio-to-audio conditioning need the user's existing drums
*as audio* for SA3's `--init-audio`. No sibling doc has a route. Live has
three: **Bounce Track in Place / Bounce to New Track** (UI-only, 12.2+),
the Extensions SDK's `renderPreFxAudio()` (12.4.5, Suite, beta), and —
already in the fork — recording the track through `record_clip` onto an
audio track, which needs routing Seshat can't set. Bounce over AX is the
only one reachable without a new bridge or a manual routing step. Note it
as the prerequisite for any audio-conditioned arm; unspiked.

**Correction 2026-08-30 — the SDK route is demonstrated, by someone else.**
The Basic Pitch extension (`federico-pepe/ableton-live-extensions`, MIT)
states its own audio acquisition: Session clips are read from **their source
sample**, Arrangement clips are **rendered pre-FX from the timeline**, and
samples in Ableton's compressed format cannot be decoded directly from
Session. So the SDK offers both a sample-file route and a render route, and
the prerequisite above is solved on that bridge already. It changes nothing
today — the SDK needs beta access we don't have
([extensions-sdk.md](../extensions-sdk.md)) — but "bounce over AX is the only
reachable route" is now true only of the bridges Seshat can currently use.

### 2.7 Improvisation — locators, Link, Link Audio

Three corrections to [live-improv-exploration.md §9](live-improv-exploration.md#L492):

- **Section markers are in the LOM** (`Song.cue_points`, with a listener),
  not absent. The fork gap is one handler; scene names need not stand in.
- **Beat phase is Ableton Link's job**, not an OSC beat listener's. Link
  gives any peer tempo and beat phase with sub-frame accuracy and an
  open-source SDK; the MRT2 process (or the M4L wrapper's host) joins the
  Link session and knows where beat one is with none of the ±100 ms tick
  jitter §9 estimates. This changes Spike C's premise for the outside-Live
  topology.
- **Link Audio (12.4)** streams audio between Link peers and may replace
  BlackHole for the outside-Live topology — if a non-Live peer can offer
  audio. No public SDK for the audio half was found today; treat as a
  watch item, not a route.

---

## 3. What changes in the epic

1. **Joint C's blocker is gone** — Live Stem Separation replaces the
   separator survey (§2.3). The arm is now the *cheapest* in dependencies
   and the most expensive in AX plumbing.
2. **Convert Drums joins the drum-transcription arms** as the zero-licence
   floor; IDM's spike is now "does it beat three lanes and a Drum Rack we
   didn't choose."
3. **Slice to New MIDI Track is a new output shape** for audio requests
   that must stay editable (§2.4), possibly fork-only via Simpler's slicing
   API.
4. **Grooves become the feel-transfer and timing-context mechanism**
   (§2.5): `Clip.groove` assignment is a fork gap to close regardless of
   which backend wins; Extract Groove is one AX command; and
   [CLAUDE.md](../../CLAUDE.md)'s "cannot assign" is corrected.
5. **The improv doc's Ableton table** gains locators (LOM), Link (phase)
   and Link Audio (watch).
6. **One AX spike serves all of it**: enumerate Live's Create menu and a
   clip's context menu with `ax-probe`, then run Stem Separation and
   Convert Drums once each on an imported SA3 render, recording menu
   reachability, dialogs, duration, and what the mirror sees. Until it
   runs, every UI-only row above is a candidate, not a route.

## 4. Unmeasured

Everything. Specifically: whether any Create-menu command is reachable by
name over AX; Convert Drums' lane count and velocity behaviour on SA3
material; Stem Separation's duration on this machine and its behaviour on
a short loop; whether a `.agr` groove can be loaded into the pool through
`Browser.load_item`; the Simpler slicing API's behaviour when driven from a
Remote Script. The Extensions SDK's capability list is no longer wholly
unknown — see [extensions-sdk.md](../extensions-sdk.md) for what was measured
in Live's binary on 2026-08-30 and what remains unconfirmed in the JS API.

## Sources

[Live 12 release notes](https://www.ableton.com/en/release-notes/live-12/) ·
[Converting Audio to MIDI (manual)](https://www.ableton.com/en/live-manual/12/converting-audio-to-midi/) ·
[Using Grooves (manual)](https://www.ableton.com/en/live-manual/12/using-grooves/) ·
[MIDI Tools (manual)](https://www.ableton.com/en/live-manual/12/midi-tools/) ·
[Stem Separation](https://www.ableton.com/stem-separation-in-ableton-live/) ·
[Extensions SDK](https://ableton.github.io/extensions-sdk/) ·
LOM apiref: [Clip](https://docs.cycling74.com/apiref/lom/clip/), [Song](https://docs.cycling74.com/apiref/lom/song/), [GroovePool](https://docs.cycling74.com/apiref/lom/groovepool/) ·
installed `_MxDCore/LomTypes.pyc`, Live 12.4.3, string-dumped 2026-08-27.
