# Plan — MIDI generation: the decision experiment

Roadmap item **"MIDI generation — the decision experiment."** Not a tool and
not a fork change: a blinded listening bake-off between complete MIDI
pipelines, rendered into the open Live set through Seshat's *existing* tool
surface and judged on the final clips only, so that the eventual feature plan
("a dusty lo-fi beat with a bassline" landing as per-part MIDI tracks) is
written against one winner. The deliverable is a dated **Result** section in
[midi-generation-options.md](evaluating/generative%20features/midi-generation-options.md)
naming a backend per part and a wiring, plus the follow-up roadmap items the
winner needs. The plan also clears the experiment's three prerequisites
(IDM spike, GMD retrieval engine, GrooVAE go/no-go), because without them the
arms cannot produce evaluable MIDI.

**Acceptance is a verdict, not a feature.** The item is done when a person
has scored every arm on every prompt without knowing which arm produced
which clip, the scores and the key are committed beside the prompts, and the
options doc's Result section says which pipeline ships, why, and what it
still has to prove — or says honestly that nothing cleared the bar and what
the next experiment is. A result that names a winner from proxy metrics, or
from clips the judge could identify, does not count.

## Context

The research is complete and deliberately undecided. Route A (local symbolic
models) failed the feel test three times on this Mac; Route B (a service)
does not exist; two finalists remain — **Route C** (Stable Audio 3 render →
transcription) and **Route D** (Groove MIDI Dataset retrieval, with GrooVAE
behind it) — and the proxy metrics that separate them have been "measured to
exhaustion" without producing an answer, because the failure that started
this (uniform velocities, grid-locked timing) is only audible. Orthogonal to
the backend is the **wiring** of a multi-part request — independent,
conditioned (drums first, bass responds to the actual kick), or joint-then-
separated — and the doc's own finding is that a beat *with* a bassline is the
main case. The product bar is in
[music-generation-user-stories.md](evaluating/generative%20features/music-generation-user-stories.md):
one request is one undo step, separate parts per track, MIDI the default, and
"related" must mean audibly related, not same-BPM.

Facts this plan rests on, measured or read on 2026-08-28 unless dated
otherwise:

- **The SA3 slate exists and is reusable.** `~/.seshat/audio-spike/` holds
  24 bar-exact renders (drums / bass / pad / texture × 90/124/170 BPM ×
  `sm-music`/`medium`, 2026-08-25) and `interlock/` holds the three
  rhythm-section files the interlock question was framed around:
  `A_stacked_independent.wav` (the 124 BPM `medium` drum and bass renders
  summed at 0.7 each by `stack.py`) and `B_joint_seed42.wav` /
  `B_joint_seed7.wav` (one prompt asking for both parts). Those three are the
  independent-vs-joint comparison's raw material and the input Stem
  Separation needs.
- **The earlier spike environments survived.** The 2026-08-26/27 measurements
  ran in a session scratchpad that has not been reclaimed:
  `/private/tmp/claude-501/-Users-patrick-seshat/c3178499-85aa-4281-bbd0-287d7cbfd0e3/scratchpad/`
  still holds `bpenv/` (Basic Pitch, 2.2 GB), `adtof-pt/` plus the three
  `*_adtof.mid` outputs, `mg312/` (`@magenta/music`, 610 MB), and the
  analysis scripts (`bp_test.py`, `adt_test.py`, `vel_demo.py`,
  `split_demo.py`, `stack.py`). Part 0 copies what is reusable into a
  durable location before that directory disappears; the ADTOF artefacts are
  copied only as the *comparison reference* the options doc already allows,
  never as an arm.
- **Live-side latency of one complete multi-part request is 6.45 s.**
  Measured today through the real HTTP MCP surface against Live 12.4.5 with
  Seshat started for the purpose (scratch set, one MIDI track, restored
  afterwards): two `search_library` calls at 0.05 s each; four
  `create_track` at 0.19–0.23 s; four `load_device` at 0.43–0.87 s (a Drum
  Machine Selector Kit ×3, Abel Bass ×1); four `write_midi_notes` (8, 8, 32
  and 16 notes, 16-beat clips) at 0.51–0.64 s each; one `get_clip_notes`
  read-back at 0.92 s. That is in-process, back-to-back — no model in the
  loop. In a real conversation each separate tool round costs ~2.1 s of model
  time on top (measured 2026-07-31, recorded in the `/smoke-write` rules), so
  the same fourteen-call chain issued conversationally is ~35 s before any
  generation compute. That number, not the ~10 s compute budget, is the
  argument the user-stories doc makes for one high-level tool; it goes into
  the Result as the product-latency baseline the feature plan must beat.
- **The chunking gate is soft for this experiment.** `Seshat.OSC.Message.encode/2`
  puts a `/live/clip/add/notes` datagram at 36 + 25 bytes per note: 360 notes
  encode to 9,036 bytes, 400 to 10,036, against this Mac's
  `net.inet.udp.maxdgram` of 9,216 — so the ceiling is **367 notes per
  write**. Every arm here writes *one lane per clip* (the user-stories'
  separate-parts default), and a 16th-note hat lane over 8 bars is 128 notes;
  even a transcription that doubles every hit stays under 300. The harness
  asserts `len(notes) <= 300` per write and splits a larger lane into two
  `write_midi_notes` calls (repeated adds append — the tool's own description in
  `Definitions`, "existing notes are preserved", and the chunking item's planner
  note; `API.md` does not state it), so the
  experiment does **not** wait on "`write_midi_notes` must chunk large note
  batches". The roadmap entry naming it as a gate is corrected in Part 8; the
  defect stands on its own for single-clip dense writes.
- **Which arms exist is decided by the sibling spike.**
  [PLAN_live_native_generation_spike.md](PLAN_live_native_generation_spike.md)
  measures whether `Convert Drums to New MIDI Track`, `Convert Melody`,
  `Separate Stems to New Audio Tracks` and `Extract Groove(s)` are reachable,
  observable and bounded over AX. Its planning already established the menu
  items are enumerable with `AXPress` advertised and that OSC selection flips
  their enabled state; the presses have not run. This plan takes each
  UI-only arm as **conditional on that spike's verdict line** and is written
  so every non-AX arm can run before the spike reports. The verdict is
  complete only when both are in, or when it states which arms were absent
  and why.
- **The transcriber slot is IDM or nothing.** Inverse Drum Machine
  (Apache-2.0 code and bundled weights, verified 2026-08-27) is the only
  permissive drum-transcription candidate; ADTOF-pytorch has no licence and
  upstream ADTOF is CC-BY-NC-SA. CLAUDE.md's rule makes that a selection-time
  disqualifier, so ADTOF's numbers may be *cited as a reference* in the
  Result but ADTOF may not produce a scored clip. If IDM fails its spike,
  Route C drums drop from the bake-off (or Convert Drums carries the slot, if
  the AX spike says it is a route) — the options doc names Noise-to-Notes as
  the next candidate and this plan does not spike it.
- **Session state already supplies the musical frame.** `Seshat.Session.State`
  mirrors tempo, time signature, `root_note` and `scale_name` (today's scratch
  set read `120.0 BPM, 4/4, key: C Major`); the harness reads them with
  `get_session_state` and sets tempo with `set_tempo` so every arm is
  rendered at the prompt's BPM, and seconds→beats conversion uses the tempo
  the render was asked for, not the mirror's, so a stale mirror cannot
  misplace notes.
- **Nothing here touches the wire in a new way.** Every address the harness
  reaches is behind an existing tool (`create_track`, `load_device`,
  `write_midi_notes`, `get_clip_notes`, `get_clip_slots`, `set_tempo`,
  `delete_track`, `undo`), all already documented and smoke-tested. No fork
  commit, no `Definitions` change, no Live restart.

### Architectural decisions

- **The harness renders through Seshat, not around it.** Clips reach Live via
  the HTTP MCP endpoint using the same client mechanics as
  `.claude/skills/smoke-test/scripts/mcp_call.py` (`connect` → `tools/call`),
  never via raw OSC. Two reasons: the eventual feature will place notes
  through exactly these tools, so any placement defect (velocity clamping,
  beat rounding, slot occupancy) is discovered here rather than in the
  feature; and the latency the harness logs is the product's, not a
  shortcut's.
- **The harness is committed; its outputs are not.** Scripts live at
  `experiments/midi_bakeoff/` (new top-level directory, plain Python with a
  `pyproject.toml` per lane, `uv`-managed venvs gitignored); renders, MIDI
  files, IDM/GMD downloads and the blinding key's *working copy* live under
  `~/.seshat/midi-bakeoff/`. The precedent is the sibling spike committing
  `menu_probe.m` because the 2026-08-03 probe's source was lost: an
  experiment whose harness cannot be re-run is an anecdote. Nothing under
  `experiments/` is reached by `mix`, `lib/`, or the process-start grep test.
- **One judge, blind, final MIDI only.** Every arm's output is written onto
  the *same* fixed instruments (one Drum Rack chosen in Part 4, one bass
  preset) as a MIDI clip; the judge hears clips labelled with opaque codes in
  a shuffled slot order and never the source WAVs in the primary round. The
  key (`code → arm`) is written by the harness and opened only after all
  score sheets are committed. Sound selection per lane ("dusty" changing
  which kick loads) is explicitly not judged.
- **Prompts are fixed before anything is generated, and committed first.**
  Ten prompts (Part 3) in four groups — drum-only, bass-only, combined,
  bass-against-existing-MIDI — with bar count, tempo, key and instrument
  frozen. A prompt added after a first listen is a new experiment.
- **Arms are complete pipelines; subtests isolate one factor.** The product
  bake-off ranks pipelines (what to ship); two one-factor subtests
  (independent bass vs. the same bass post-hoc conditioned; GMD skeleton vs.
  SA3→IDM skeleton under the same derived-bass rule) say *why*. Both are
  cheap because they reuse the bake-off's MIDI, and the Result reports them
  separately rather than inferring a wiring winner from the pipeline ranking.
- **The derived-bass engine is bounded and rule-based, and the rule is
  written down.** Claude proposes root motion per bar inside the mirrored
  key/scale (validated: scale degrees only, one root per bar, register
  E1–G2) and picks one relationship (`lock`, `answer`, `sustain`); the engine
  derives onsets from the drum lane's kick positions and applies a bass
  phrase rule for duration and velocity that never copies the drummer's
  velocity contour. It is one Python module with unit tests, because it is
  the thing most likely to survive into the feature if conditioned/D wins.
- **GrooVAE is dropped by default.** Nine production advisories in
  `@magenta/music`, an archived Python repo, and a hosted checkpoint with no
  explicit licence are three shipping blockers on one arm; Part 2 gives
  settling the checkpoint terms one hour, and absent an explicit grant the
  arm is recorded as "excluded on licence, not on quality," like ADTOF. GMD
  retrieval (CC-BY-4.0) carries Route D.
- **The MRT2 arm is not waited on.** It is gated on Spike A1 in
  [live-improv-exploration.md §12](evaluating/generative%20features/live-improv-exploration.md),
  which has not run. The context-aware prompts get a conditioned arm (derived
  bass against the *existing* drum clip's notes, read with `get_clip_notes`)
  instead; if A1 has reported by run day, MRT2 joins for those prompts only,
  and the Result says whether it did.
- **Undo is the cleanup.** Every arm's placement runs as a bracketed sequence
  the harness can revert with `delete_track` (and the set is a scratch set),
  but the harness also records how many `undo` calls one arm's placement
  costs — that is the number the feature's "one request = one undo step"
  promise has to collapse to, and it is measured for free here.

## OSC contract

No new address, no fork change. Every row below is reached through an
existing tool and is already in
[priv/AbletonOSC/API.md](../priv/AbletonOSC/API.md) at pin `bc171b7`; the
harness never sends raw OSC. Listed so `/plan-review` can check that the
harness stays inside the published surface.

| Tool the harness calls | Address(es) underneath | Why the experiment needs it |
|---|---|---|
| `get_session_state` | mirror (`/live/song/get/tempo`, `signature_*`, `root_note`, `scale_name`, `/live/song/get/tracks`) | tempo/key frame; track indices after each create |
| `set_tempo` | `/live/song/set/tempo` `[tempo]` | every arm rendered at the prompt's BPM |
| `create_track track_type: "midi"` | `/live/song/create_midi_track` `[index]`, count guard `num_tracks` before/after | one track per part per arm |
| `search_library` / `load_device` | catalog (no OSC) / `/live/browser/load_item` `[track, uri]` → reply `[track, uri, 'ok', device_name]` or `[track, uri, 'error', message]` (the regular-track clause does no separate `devices/name` read-back; the reply carries the name) | the fixed comparison instruments |
| `write_midi_notes` | `/live/clip_slot/get/has_clip` `[t, s]` → `/live/clip_slot/create_clip` `[t, s, length]` → `/live/clip/add/notes` `[t, s, pitch, start, dur, vel, mute …]`, then `/live/clip/set/name` `[t, s, name]` when `name` is given (`Handlers.maybe_name_clip`) | placement; ≤ 300 notes per call by harness assertion (367 is the datagram ceiling); the opaque code goes in as `name` |
| `get_clip_notes` | `/live/clip/get/notes` `[t, s]` → `[t, s, pitch, start, dur, vel, mute …]` (echoed indices checked) | read-back proves the write landed; also the *input* for context-aware arms |
| `get_clip_slots` | `/live/song/get/track_data` (bulk: `track.name`, `track.has_midi_input`, `track.is_foldable`, `clip_slot.has_clip`, `clip.name`, `clip.length`, `clip.is_playing`, `clip.is_recording` — one query, not per-slot reads) | pick empty slots for the shuffled layout |
| `create_scene` | `/live/song/create_scene` `[index]` (-1 = end) | the layout needs one scene per prompt; a fresh set has eight, the slate has ten |
| `delete_track` / `undo` | `/live/song/delete_track` `[index]` / `can_undo` guard → `/live/song/undo` | cleanup; undo-count measurement |

Wire facts the harness depends on and does not re-measure: repeated
`/live/clip/add/notes` calls append (API.md); `get/notes` echoes track and
slot, which `Handlers` verifies; `create_track` reports an index only after
`num_tracks` rose by exactly one.

## Numbered parts

### 0. Preserve the spike material — `~/.seshat/midi-bakeoff/`, `experiments/midi_bakeoff/`

- Create `~/.seshat/midi-bakeoff/{reference,renders,midi,scores}`. Copy from
  the surviving scratchpad (path in Context) into `reference/`: the three
  `*_adtof.mid` files and `bp_test.py`, `adt_test.py`, `vel_demo.py`,
  `split_demo.py`, `stack.py`. Do not copy `adtof-pt/` itself — it is not a
  candidate and must not be runnable from the harness tree.
- Create `experiments/midi_bakeoff/` with a `README.md` (what this is, how to
  run, the licence table from Part 2) and a `.gitignore` for `.venv*/`,
  `*.wav`, `*.mid`, `key.json`. Add `experiments/` to the repo's top-level
  `.gitignore` *exceptions* only if a rule there would swallow it (checked at
  plan review: nothing does — the root file ignores `/tmp/`, `*.ez`,
  `catalog.json`, `priv/routing_eval/runs/` and build artefacts, none of which
  match `experiments/`).
- Checkable: the directory exists with the README and the five scripts'
  provenance noted; `mix precommit` is untouched by it.

### 1. Spike Inverse Drum Machine — `experiments/midi_bakeoff/idm/`

The prerequisite the options doc calls out first. Install IDM from its
repository into a `uv` venv (record the commit, the weight file's size and
its licence text verbatim in the README), then run it on the three drum WAVs
the ADTOF numbers came from — `drums_124bpm_medium.wav`,
`drums_90bpm_medium.wav`, `drums_124bpm_sm-music.wav` — plus the two joint
renders. Record per file: wall time (cold and warm), note count, class
vocabulary as emitted and the GM map applied, velocity min/max/distinct,
onset deviation from the 16th grid (the same statistic `adt_test.py`
computed, so the numbers are comparable), and whether `sm-music` still
transcribes to nothing. Write `idm_transcribe.py` exposing
`transcribe(wav, bpm) -> [Note(pitch_gm, start_beat, duration_beats,
velocity)]`, the one interface every drum arm produces.

**Kill rule:** if IDM produces < 8 notes on the 124 BPM `medium` clip that
ADTOF transcribed to 60, or takes > 10 s warm, or its weights turn out not
to be under the Apache-2.0 grant the repository claims, Route C drums are
out of the bake-off and the Result says so. The arm is not replaced by
ADTOF under any circumstance.

### 2. Route D materials — `experiments/midi_bakeoff/gmd/`

- Download the Groove MIDI Dataset MIDI-only archive (3.11 MB, CC-BY-4.0) to
  `~/.seshat/midi-bakeoff/gmd/`; commit its `info.csv` schema notes and the
  attribution text the licence requires to the README. Write
  `gmd_retrieve.py`: index every 2- and 4-bar 4/4 segment by genre, tempo,
  beat/fill, note density and swing ratio; `retrieve(style_tags, bpm, bars,
  density, seed) -> [Note]` returns a segment time-scaled to `bpm`, tiled or
  recombined to `bars`, with a seed that changes *which* candidate wins so
  "another take" is real. Remap Roland TD-11 pitches → GM using the mapping
  table published with the dataset (the doc's warning: "already GM" is
  wrong) and write the map as data, not code.
- **GrooVAE, one hour, then a decision.** Locate an explicit licence for the
  hosted Tap2Drum / Humanize checkpoints (the `magentadata` bucket's
  checkpoint index, the magenta-js repository's checkpoint README). An
  explicit Apache-2.0 or CC-BY grant on the *checkpoints* admits the arm,
  subject to running it from the surviving `mg312/` venv with the dependency
  tree pinned and `npm audit` recorded. Anything less — silence, or only the
  code licence — records "excluded on licence" in the README's licence table
  and the arm does not run. *Plan assumes* excluded.

### 3. The slate, the derived-bass engine, and the harness — `experiments/midi_bakeoff/`

**`prompts.json` — committed before any render.** Ten prompts, every field
frozen:

| # | Group | Prompt (the text every arm receives) | BPM | Key | Bars |
|---|---|---|---|---|---|
| 1 | drums | "dusty lo-fi hip hop drums, lazy, kick snare and hats" | 90 | — | 4 |
| 2 | drums | "tight four-on-the-floor house drums, open hat on the offbeat" | 124 | — | 4 |
| 3 | drums | "broken beat, syncopated, sparse kick, busy hats" | 110 | — | 4 |
| 4 | drums | "half-time trap drums, rolling hats, heavy snare on 3" | 140 | — | 8 |
| 5 | bass | "dark garage bassline, sparse, sub register" | 130 | F minor | 4 |
| 6 | bass | "walking funk bassline, eighth notes, some ghost notes" | 100 | A minor | 4 |
| 7 | combined | "dusty lo-fi beat with a bassline" | 90 | D minor | 4 |
| 8 | combined | "driving techno kick and hats with a pulsing bass" | 128 | C minor | 4 |
| 9 | combined | "laid-back boom bap with a deep bass, 8 bars" | 92 | G minor | 8 |
| 10 | context | "add a sparse dub bassline to this section" — existing drums (a GMD reggae bar placed on track 0) and an existing two-chord pad clip (i–VI, written by hand) already in prompt 10's own scene (the layout below gives every prompt one scene) | 75 | A minor | 4 |

Prompt 10's existing material is written by the harness before any arm runs
and is identical for every arm. Per prompt the harness stores the SA3 seed
list (three seeds; the arm's *first* successful render is scored, the others
are kept for the "another take" question) so every Route C arm reuses the
same render where its pipeline is the only difference.

**`bass_rules.py` — the bounded derived-bass engine.** Input: a drum lane
(`[Note]`), a harmonic plan (`[{bar, degree}]` validated against the
mirrored key/scale — degrees only, one per bar, register E1–G2), and one
relationship in `{lock, answer, sustain}`. `lock` places a bass onset on
every kick and rests elsewhere; `answer` places onsets on the 8th after each
kick that is not followed by another kick within a beat; `sustain` holds the
root from the first kick of the bar to the last. Duration and velocity come
from a bass phrase rule (accent bar-1 downbeat, decay across the bar, ghost
the last 16th before a kick at velocity 45) — **never** from the drum notes'
velocities. Claude's part of the input (plan + relationship) is produced once
per prompt by asking a fresh Claude Code session with the prompt text and
the key, and the answer is committed with the prompt so every run derives
the same bass. Unit tests: a `lock` bass over a known kick pattern lands on
exactly those beats; `answer` never coincides with a kick; degrees outside
the scale are refused; the register bound holds.

**`render.py` — the placement harness.** For a given `(prompt, arm)`:
`set_tempo` → `create_track` per part → `load_device` the fixed instruments
(URIs pinned in `instruments.json`, Part 4) → `write_midi_notes` per part
(≤ 300 notes, split otherwise) with the clip named by the opaque code →
`get_clip_notes` read-back compared note-for-note (pitch, start to 3 dp,
velocity) → log every call's wall time. Writes `key.json` (`code → {prompt,
arm, seed, files}`) under `~/.seshat/midi-bakeoff/` and prints only the codes.
Layout: one scene per prompt (`create_scene` until the set has ten), one track group per arm, arm order shuffled per
prompt from a seed the judge never sees. `clean.py` deletes the harness's
tracks by name prefix and reports the undo count it observed.

**`transcribe_bass.py`** wraps Basic Pitch (the surviving `bpenv/` recipe:
`nmp.onnx`, `predict()` note events) with amplitude → velocity mapping
(linear 40–120 over the file's amplitude range, the same curve `vel_demo.py`
used) and a note-count sanity check that flags < 4 notes as a failed
transcription rather than writing an empty clip.

### 4. Fixed instruments and the drum map — `instruments.json`

Pick one Drum Rack whose pads 36/38/42/46 are kick/snare/closed hat/open hat
(a Core Library kit; today's timing run used *Drum Machine Selector Kit*,
`query:Drums#FileId_5318`) and one bass preset (*Abel Bass* loaded in 0.51 s
today). Verify the pad map **by ear once**, writing a four-note clip and
listening — there is no pad-read address (`FORK_GAPS.md` § "`DrumChain.in_note` and rack chain
insertion — read the Drum Rack pad map"), so this is the only way to know GM 36 is the kick on that kit. Record
the URIs and the verified map in `instruments.json`; every arm's drum output
is GM and is remapped through this one table.

### 5. Controlled subtests — reuse, do not regenerate

- **Wiring, one factor:** for prompts 7–9, take independent C's transcribed
  bass and produce a second version through a post-hoc snap (`bass_rules.py`
  `lock` applied to the *existing* bass onsets within a 16th of a kick, all
  else untouched). Two clips, same notes but placement.
- **Skeleton source, one factor:** for the same prompts, run `bass_rules.py`
  once over the GMD lane and once over the SA3→IDM lane with the identical
  plan and relationship. Two basses, same rule, different kick truth.

These are scored in the same blind session as the bake-off — the judge
cannot tell a subtest clip from an arm clip — and reported in their own
table.

### 6. The bake-off run

Arms per group, each conditional only where stated:

| Group | Arms |
|---|---|
| drums (1–4) | **D-retrieval** (GMD) · **C/IDM** (SA3 → IDM) · **Convert Drums** *(if the AX spike's verdict is "route")* · GrooVAE *(only if Part 2 admitted it)* |
| bass (5–6) | **C/Basic Pitch** · **Convert Melody** *(if "route")* · **derived** (`bass_rules.py` over prompt-matched GMD drums, so the group has a non-transcription baseline) |
| combined (7–9) | **independent C** · **conditioned/D** (GMD + derived bass) · **conditioned/C** (SA3→IDM + derived bass) · **joint C** (one SA3 rhythm-section render → Stem Separation → IDM on the drum stem, Basic Pitch on the bass stem) *(if Separate Stems is "route" and the machine is Suite — record the edition from `Log.txt`'s `Licensing:` line)* |
| context (10) | **conditioned/existing** (derived bass over the existing drum clip's `get_clip_notes`) · **independent C** (SA3 bass prompted with key and tempo only) · **MRT2 offline** *(only if Spike A1 has reported an offline real-time factor)* |

Run order: all non-AX arms first (they need only Seshat and the venvs); the
AX arms as a second session once the spike has run, with the same prompts,
seeds and key file appended. For every arm log: model compute, transcription
time, harness placement time, read-back agreement, undo count. A generation
or transcription that yields no notes is recorded as a **void** for that arm
and prompt (like the routing eval's void trials), not re-rolled silently; one
re-roll with the next seed is allowed and logged.

**Judging.** Metronome on, Live looping the scene, judge hears each code in
the shuffled order, twice, and fills `scores/<prompt>.csv`: five 1–5 ratings
(prompt match, groove/feel, cohesion between parts — combined and context
groups only, part correctness — does the kick sound like a kick lane, no
octave errors in the bass, editability — would you keep these notes or
delete them), one free-text line, and a forced ranking of the codes. Nothing
is scored from the source WAVs in this round. A second, *unblinded*
diagnostic round listens to WAV vs. transcribed MIDI only for arms that lost,
to locate the loss (generation, separation, transcription) — that is a note
in the Result, never a score change.

### 7. The Result — `docs/evaluating/generative features/midi-generation-options.md`

Add a dated **"Result — the decision experiment, 2026-MM-DD"** section after
"Recommendation" containing: the arm table with which arms ran and which were
absent and why; the per-group score tables (medians and rankings) and the two
subtest tables; the latency table (compute + transcription + placement, and
the 6.45 s / ~35 s baseline from Context); the verdict — backend per part,
wiring, and the licence and dependency surface of the winning pipeline — or
the honest "nothing cleared the bar, here is the next experiment"; and the
tie-break rule applied verbatim (quality first; on a material tie, the
simpler, licence-clean pipeline). Update "Verdict up front" to point at it.
Link `experiments/midi_bakeoff/README.md`, the committed `prompts.json`,
`scores/` and (after judging) `key.json`.

### 8. Bookkeeping

- `ROADMAP.md`: remove this item via `/ship`; add the feature item the Result
  earns ("MIDI generation — <winner>") with the follow-ups the winning
  pipeline needs as its gates, choosing from: "Read the selected scene"
  (`/live/view/get/selected_scene` has a fork address and no tool — needed
  before "this section" resolves), "Groove Pool assignment by index"
  (promoted from the grab bag if grooves won the feel-transfer question), a
  Drum Rack pad-map read (`DrumChain.in_note`, a fork handler), and the IDM
  or GMD packaging item. Correct "`write_midi_notes` must chunk large note
  batches"' paragraph that names this experiment as its dependant: the
  experiment measured the ceiling (367 notes) and stayed under it per lane.
- `CLAUDE.md` "Current focus": one paragraph — the experiment ran, the
  verdict, where the harness and scores live.
- `experiments/midi_bakeoff/README.md` licence table: SA3 (Community License
  + Gemma terms, user-installed, per
  [PLAN_generate_audio_clip.md](archive/PLAN_generate_audio_clip.md)), IDM
  (Apache-2.0, verified text), GMD (CC-BY-4.0, attribution string), Basic
  Pitch (Apache-2.0), GrooVAE (excluded/admitted with the evidence), ADTOF
  (excluded, reference only).

## Testing

The experiment produces no change under `lib/`, so `mix test` is unaffected;
the pure coverage lives in the harness:

- `experiments/midi_bakeoff/tests/test_bass_rules.py` — the four rule
  properties in Part 3, plus: an empty drum lane yields an empty bass (no
  crash), the `answer` rule on a four-on-the-floor kick yields exactly four
  offbeat onsets per bar, velocities never equal the input drum velocities
  even when the phrase rule would coincide (the "never copies" guarantee is a
  test, not a comment).
- `tests/test_gmd_retrieve.py` — TD-11 → GM map is total over every pitch in
  the dataset (a pitch with no mapping fails the test); time-scaling a 120
  BPM segment to 90 keeps note count and relative order; two seeds on the
  same query return different segments when more than one candidate exists.
- `tests/test_render_plan.py` — the write splitter never emits a call with
  more than 300 notes and preserves order; seconds→beats uses the requested
  BPM; the shuffled layout is a permutation (every arm exactly once per
  prompt) and is reproducible from its seed.
- `tests/test_transcribe_bass.py` — the amplitude→velocity map hits 40 and
  120 at the extremes and the < 4-note void is flagged, using a synthetic
  note-event list (Basic Pitch itself is not invoked in tests).

Nothing tests through Live: the harness's Live half is exercised by the run
itself and by the smoke tests below.

## Live verification

Nothing in `mix test` reaches any of this. The plumbing the harness relies on
is already covered; the experiment adds one manual test and cites the rest.
Run the automated half with `/smoke-test` before the first render session so
a placement defect is not mistaken for a musical one.

- `smoke_tests/auto/clips.md § Write ordering and invalid states` — the
  harness's `write_midi_notes` → `get_clip_notes` loop is this test's
  contract; a note-for-note read-back mismatch during the run means this
  test, not an arm, is what failed.
- `smoke_tests/auto/clips.md § Clip properties read in one breath, and read
  true` — the length the harness sets (`bars × 4` beats) must read back
  exact, or every arm's loop point is wrong together.
- `smoke_tests/auto/devices.md § Chain and parameter reads pair the right
  values` — `load_device`'s read-back of the fixed instruments; the pinned
  URIs in `instruments.json` are only as stable as this.
- `smoke_tests/manual/by-ear.md § A generated loop sits on the grid and seams
  cleanly` — **written by archive/PLAN_generate_audio_clip.md, not yet in the file;
  it is this experiment's prerequisite too** (the roadmap's "verify the
  downbeat and loop boundary on the existing WAV slate"). Run it on the
  spike slate before Part 6: a late first hit in the WAV would put every
  Route C onset late by the same amount, which the judge would hear as bad
  feel. If it has not been written by then, write it there first.
- `smoke_tests/manual/by-ear.md § The bake-off's fixed kit triggers the right
  lanes` — **new.** *Why manual: the assertion is a sound.* With the kit from
  `instruments.json` on a MIDI track, write one note each at GM 36, 38, 42,
  46 and listen: kick, snare, closed hat, open hat, in that order. Failure
  meaning: the drum map is wrong for this kit and every drum arm is being
  judged on the wrong sounds — fix `instruments.json` before scoring anything.
- `smoke_tests/manual/on-screen.md § The clip reader` — the context arm's
  input is `get_clip_notes` on the existing drum clip; this is the check that
  the reader returns what is on screen.

**Uncovered:** the judging itself (one person's ears — the Result must say
so, as the routing eval says five trials cannot separate 100% from 95%);
the AX-gated arms until the sibling spike runs; Stem Separation on a
Standard-edition machine (none here); the "another take" seed behaviour by
ear (the seeds are kept, not scored).

## Out of scope

- **Any tool, handler, `Definitions` or fork change.** The winner's feature
  plan is the next item; this one only decides. In particular no
  `generate_midi` tool, no `Seshat.Generation.MIDI` module, no attribute-layer
  schema — the derived-bass engine is experiment code that a feature plan may
  adopt, not a library.
- **The AX presses** (Convert Drums, Convert Melody, Separate Stems, Extract
  Groove) — owned by
  [PLAN_live_native_generation_spike.md](PLAN_live_native_generation_spike.md);
  this plan consumes its verdict lines.
- **Audio import over OSC** (`/live/clip_slot/create_audio_clip`) — owned by
  [PLAN_generate_audio_clip.md](archive/PLAN_generate_audio_clip.md) Part 1. The joint
  C arm imports its render by drag-and-drop if that has not landed, as the
  spike plan does.
- **Reading the selected scene, `Clip.groove` assignment, a Drum Rack pad-map
  read** — feature prerequisites, filed from Part 8; the harness passes scene
  indices explicitly and needs none of them.
- **`write_midi_notes` chunking** — stays its own roadmap defect; the harness
  routes around it per lane.
- **Melody, chords and pads as generated parts** — weakest evidence on both
  generator and transcriber sides (options doc §8); the pad clip in prompt 10
  is hand-written context, not a generated part.
- **Existing-audio conditioning** and **Arrangement placement** — outside the
  first release per the user-stories doc.
- **Spike A1 / MRT2** — not run here; the MRT2 arm joins only if A1 has
  reported.
- **Noise-to-Notes** or any second drum transcriber — only if IDM fails, and
  then as its own spike.

## Open questions

Live 12.4.5 was running during planning and was used for the two
measurements above; the remaining questions need either the venvs Part 1–2
build, a press the sibling spike owns, or ears.

1. ⚠️ **Does IDM transcribe SA3's degraded drums at all?** Its README warns
   that out-of-distribution loops transcribe poorly, and `sm-music` already
   defeated ADTOF once. Unanswerable until Part 1 installs it (no IDM venv
   survives from the earlier session; the spike ran ADTOF). *Plan assumes*
   it passes on the `medium` renders and voids on `sm-music`, and carries the
   kill rule either way.
2. ⚠️ **Which AX arms exist?** Convert Drums, Convert Melody and Separate
   Stems are each a press the sibling spike has not made. *Plan assumes* all
   three are routes and schedules them as the second run session; a
   "not-a-route" removes the arm and the Result records the absence.
3. **Do the GrooVAE checkpoints carry an explicit licence? — Answered
   2026-08-28: no.** `magenta-js/music/checkpoints/checkpoints.json` (the
   index that names `groovae/tap2drum_1–4bar` and
   `music_vae/groovae_2bar_humanize`) carries no licence or attribution field,
   and `music/checkpoints/README.md` states none for the hosted files; only
   the repository code is Apache-2.0. Under the selection-time rule the arm
   stays excluded. Part 2's licence check collapses to recording this; the
   only thing that would reopen it is an explicit statement from Magenta.
4. **Does the SA3 slate's first hit land on the downbeat? — Measured
   2026-08-28: not reliably.** librosa onset detection on the six drum WAVs
   (no ears): first onset at 23 ms for `drums_124bpm_sm-music` and
   `drums_170bpm_medium`, but 221 ms (`124 medium`), 209 ms (`90 medium`),
   174 ms (`170 sm-music`) and 488 ms (`90 sm-music`). Bass files all start
   at 23 ms. Median |deviation from the 16th grid| across onsets ranges
   9.7–32.2 ms per file — nothing separates groove from error there, as
   §C.1 already said. So the offset rider is **on by default** for every
   Route C drum arm: subtract the measured first-onset offset per file
   before seconds→beats, record it, and say so in the Result. The by-ear
   test still decides whether the first hit *is* the one or a pickup.
5. **Is one judge enough?** The routing eval's caveat applies twice over:
   five trials cannot separate 100% from 95%, and one listener cannot
   separate taste from quality. *Plan assumes* one judge (Patrick) is the
   available instrument and the Result presents rankings, not significance;
   a second listener on the same blind sheets is the cheapest upgrade and
   is offered, not required.
6. **Has Spike A1 run by the time Part 6 runs?** Decides whether the MRT2 arm
   appears for prompt 10. As of 2026-08-28 it has not — `live-improv-
   exploration.md` still opens with "Nothing in this document is measured".
   *Plan assumes* not; the conditioned/existing arm carries the context group
   regardless.

Closed during planning: full Live-side latency (6.45 s in-process, ~35 s
conversationally — Context); whether the chunking defect gates the run (no —
367-note ceiling, per-lane writes stay under it); whether the spike material
and environments still exist (yes — Part 0 preserves them).
