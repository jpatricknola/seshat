# Roadmap

The single living list of what to do next — features, defects, and security
work in one ranked queue. The top item is the biggest win, work top to
bottom. 

**Adding an issue to the roadmap**
An issue must state its goal and why it's worth building. Where the value is user-visible, include user stories — concrete moments that show the feature earning its place. Internal plumbing items wont usually have a user story. An issue must also include context for the plan author — a roadmap entry is **not** an implementation plan. Plans get written per issue (the `/plan` skill) when the work is picked up.  

Ranking criteria is **impact-per-effort**, mission impact weighed against cost. A medium-impact quick win outranks a high-impact slog.  Place the new issue in the appropriate order for its priority.  

Every issue carries its scores on the line under its heading — **impact** (1-10,
user-visible value: how much better the producer's experience gets) and **lift**
(1-10, work required: 1 is a quick PR), with the quotient. The whole queue was
scored and reordered on 2026-08-27. Score a new issue the same way and insert it
at its quotient.

**Dependencies outrank the quotient.** The quotient orders work that is *ready*;
it never places an issue above something that has to land first. Where an issue
is gated, it says so under its scores and its gate sits above it — which is why
"Search eval harness" sits near the top at a quotient of 0.67, ahead of six
catalog levers that score better and cannot start until it exists. Sort
prerequisites first, then rank the ready work by quotient inside that. A related
trap: impact scores *user-visible* value, so pure plumbing scores low however
necessary it is. Read a low quotient near the top as "cheap thing that unblocks
expensive things," not as a mis-rank.

**Removing an issue from the roadmap**
Issue numbers are ranks, not stable identifiers - when something ships, delete all trace of it from the roadmap and let the rest renumber (the `/ship` skill handles this). If a shipped issue had a detailed plan doc, move that doc to [archive/](archive/) with a status banner. Nothing else about a ship stays here — this file documents future work only, and ship history lives in git, CLAUDE.md's Current focus, and [archive/](archive/). A shipped issue is mentioned below only where an *open* item needs it as context.  **Cite an issue by its title, never by its rank**
A rank is correct only until the next ship, and a stale one doesn't look stale — it silently points at a different item. Any cross-reference written by rank will quickly become wrong, trust me, its happened a lot.

**[Deliberately not planned](#deliberately-not-planned)**
The section at the end of this file records ideas that were weighed and
declined, each with the condition that would reopen it. Check it before
proposing or re-proposing work. Add to the list when rejecting a proposed issue.  


---

## #1 · Generate audio onto a track — Stable Audio 3, imported as a clip

**Impact 9 · Lift 7 · 1.29 impact-per-effort**

**Ranked at the top by decision on 2026-08-28** — the first of three
generation items placed together after the
[generative features](evaluating/generative%20features/) research closed
its evaluation phase. This one has a settled direction; the two below it
are the spike and the decision experiment that the MIDI half still needs.

Plan: [PLAN_generate_audio_clip.md](PLAN_generate_audio_clip.md) — one
`generate_audio` tool over a `Seshat.Generation` behaviour, consuming the fork
address `/live/clip_slot/create_audio_clip` and its import-root guard, **both
of which are already merged on the fork's `origin/master`** (`fe6730e`): this PR
bumps the gitlink and runs `mix abletonosc.install`, and writes no Python.

**The audio story is two PRs** (decision, 2026-08-29). This one generates the
material and puts it in the right place: safe duration-exact generation, import
into the named slot, and honest Live read-back. Everything about how it *sits*
on the grid — alignment, warping, loop seams, a second quality lane — is
"Generated-audio alignment, warping and quality polish", which is deliberately
sequenced **after** "MIDI generation — the decision experiment".

**Goal:** a producer describes material for one track — "a dusty four-bar
drum part", "a slow pad bed in this key" — and a duration-exact generated WAV
lands as an audio clip in the named Session slot on a new or existing audio
track, with every take kept in a folder Seshat manages. The reply reports
Live's observed length, looping and warping rather than claiming the raw render
is grid-aligned or seamlessly loopable. Explicitly *not* full songs; 1–16 bars
of one part.

**Why:** direction is settled by two docs and one measured spike. Read
[audio-generation-options.md](evaluating/generative%20features/audio-generation-options.md)
and [one-model-or-two.md](evaluating/generative%20features/one-model-or-two.md)
before planning. Stable Audio 3 small via the MLX runtime is already
installed at `~/.seshat/stable-audio-3` and measured 2026-08-25 at 1.0–1.1 s
per four-bar clip after cache warm-up (`medium` 2.6–3.8 s), with durations
bar-exact to one sample frame, so no client-side trim exists. The local
runtime carries `--negative-prompt`, `--init-audio`/`--init-noise-level`
(variation of an existing clip) and inpainting, so "again, but darker" needs
no cloud. Cloud providers are contingencies, not dependencies. Magenta
RealTime 2 is deliberately *not* used for clips — its bar-exactness and
offline speed are unmeasured and it would trade a measured 1 s path for a
trim-and-guess one (one-model-or-two §5).

**User stories:**
- As a producer with a blank set, I say "give me a four-bar dusty lo-fi drum
  part on a new track" and a named audio track appears with a duration-exact
  clip, selected and shown, ready to audition.
- As a producer who liked the loop, I say "another take, darker" and a
  variation lands in the next empty slot on the same track without
  overwriting the one I kept.
- As a producer who is unsure what was created, the reply names the form
  (audio), the file, the slot, and any constraint it could not verify —
  never "done" for a clip that did not import.

**Context for the plan author:**
- **The import path exists now — the fork work is done.**
  `/live/clip_slot/create_audio_clip` (wrapping the Live Object Model method
  Stable Audio 3's own experimental Ableton integration uses) is merged on the
  fork's `origin/master` at `fe6730e`, with its always-reply `"ok"`/`"error"`
  contract and the shared `path_safety.resolve_import_path` rule documented in
  `API.md`. The wire carries a *name relative to* the fixed import root
  `~/.seshat/generated`, never a path, so Seshat's side is: create that root,
  write takes into it, send basenames. All that is left here is bumping the
  submodule pin, `mix abletonosc.install`, and a Live restart. Generated WAVs
  stay in that managed folder outside the User Library, so no browser indexing
  or URI lookup is involved. The address is model-agnostic plumbing that "MIDI
  generation — the decision experiment" and any future improv capture also
  need; it is part of why this item leads.
- Tool contract stays small and names the producer action, not the stack:
  `description`, `bars`, target track/scene, optional material or model
  hint. The handler injects mirrored tempo, time signature and key/scale
  from `Session.State` and computes the requested duration. Key is a soft
  prior in every provider — report best-effort, do not contract it.
- Invoke the CLI per generation; a persistent sidecar has no measured
  justification. This will be the second process-starting door out of
  `lib/seshat/` after `Seshat.AX.Client`, so the grep test in
  `test/seshat/ax/client_test.exs` must be widened deliberately, not
  worked around.
- **Audio polish is intentionally the second PR** ("Generated-audio alignment,
  warping and quality polish"): BPM adherence on Live's grid, downbeat/phase
  choice, loop-seam cleanliness, explicit warp/loop state, behaviour after tempo
  changes, and whether `medium` audibly earns its escalation surface. The MVP
  must report these limitations rather than hide them or expand to solve them,
  and must keep the fixtures the follow-up measures.
- Occupied-slot policy, managed-folder lifecycle while a set still
  references a file, and behaviour on a generation that exits non-zero all
  need explicit decisions — house rule: report what was observed.
- Distribution: code is MIT, weights are under the Stability AI Community
  License (commercial below a $1M revenue threshold, Enterprise above) plus
  Gemma terms for the T5Gemma text encoder. The plan must say what Seshat
  ships, what the user installs, and what happens above the threshold —
  a selection-time criterion per CLAUDE.md, not a pre-release checklist.
- Optional, do not let it grow the scope: *Slice to New MIDI Track* would
  make an audio result editable per hit (a Drum Rack of Simplers plus a
  MIDI clip). The command is UI-only but Simpler's slicing API is in the
  LOM ([live-native-options.md §2.4](evaluating/generative%20features/live-native-options.md)).
  Its own item if the AX spike below finds the command reachable.

## #2 · Live-native generation spike — can AX drive the Create menu?

**Impact 4 · Lift 3 · 1.33 impact-per-effort**

**Ranked above its quotient on 2026-08-28** as the gate for "MIDI
generation — decision experiment": until it runs, five of Live's own
features are candidates, not routes, and the experiment's arms cannot be
fixed.

Plan: [PLAN_live_native_generation_spike.md](PLAN_live_native_generation_spike.md)
— a committed read-mostly probe (`native/seshat_ax/probe/menu_probe.m`,
allowlisted press only), the dialog members read through the temporary
probe-handler rig, one press per command bracketed by track counts and an
undo step, and the result written as §4 "Measured" of
`live-native-options.md`. Planning already measured (2026-08-28, Live 12.4.5
Suite) that every target command sits in the menu bar with `AXPress`, that
`AXEnabled` reads while Live is inactive, and that a clip selected over OSC
flips that state — so the mechanism is select-over-OSC, press-over-AX,
observe-over-OSC, and the context menu is out unless a menu-bar press fails.

**Goal:** one measured answer to whether Seshat can invoke Live's Create-menu
and clip-context-menu commands through the named-AX rung, recorded in
[live-native-options.md](evaluating/generative%20features/live-native-options.md)
§4 "Unmeasured". Not a tool. A spike with a written result.

**Why:** the 2026-08-27 native pass found Live already ships the pieces the
generation research had been surveying dependencies for — **Stem
Separation** (12.3, Suite), **Convert Drums / Melody / Harmony to New MIDI
Track**, **Slice to New MIDI Track**, **Extract Groove**, and **Bounce**.
Every one is UI-only (absent from `_MxDCore/LomTypes.pyc` at any spelling)
and reachable, if at all, only through the Accessibility helper. That rung
has been validated exactly once (the Settings window, 2026-08-03) and never
against a menu command. Live's separator would make joint Route C the
arm with *zero* dependency and licence surface — the doc's verdict is
"joint C uses Live Stem Separation or does not run" — and Convert Drums is
the zero-licence floor for drum transcription. Whether any of that is real
is a one-afternoon question that has not been asked.

**Context for the plan author:**
- Read [ui-scripting-options.md](evaluating/ui-scripting-options.md) for
  the mechanism ladder and safety model, and its 2026-08-27 production-
  helper measurement. `native/seshat_ax/main.m` is deliberately a closed
  four-command protocol with no generic press command; the spike may use a
  scratch build or `ax-probe`, but the result should say what a *bounded*
  new command would look like, not add a generic one.
- Procedure the doc already names: enumerate Live's Create menu and a
  clip's context menu; import one SA3 render from `~/.seshat/audio-spike/`
  by hand; run Stem Separation and Convert Drums once each; record menu
  reachability, any mode dialog (`press_current_dialog_button` exists in the
  LOM), duration, and what `Session.State` sees — the track-count push is
  the natural completion signal.
- Also worth one check each while there: Convert Drums' lane count and
  whether its velocities vary on SA3 material; whether a `.agr` groove loads
  into the pool through `Browser.load_item`; Stem Separation's behaviour on
  a short loop.
- Output is a result section in `live-native-options.md` plus, for each
  command, a verdict of route / not-a-route / needs-its-own-item. If the
  menu is unreachable, say so and the MIDI experiment drops those arms;
  that is a valid outcome.
- Suite gate: Stem Separation is Suite-only. Acceptable for an optional
  arm; the result must record which edition it ran on.

## #3 · MIDI generation — the decision experiment

**Impact 9 · Lift 8 · 1.12 impact-per-effort**

Plan: [PLAN_midi_generation_decision_experiment.md](PLAN_midi_generation_decision_experiment.md)
— clears the three prerequisites (IDM spike, GMD retrieval, GrooVAE
go/no-go), fixes ten prompts and a bounded derived-bass rule, renders every
arm through the existing tool surface onto fixed instruments, and scores
blind; the AX-gated arms run as a second session once the spike reports.
Planning measured the full Live-side cost of one four-part request (6.45 s
in-process) and the `/live/clip/add/notes` ceiling (367 notes), which the
per-lane writes stay under — so the chunking item is no longer a gate.

**Gated on "Live-native generation spike"** (which arms exist) and, for
dense rendered clips, on "`write_midi_notes` must chunk large note batches".

**Goal:** choose the backend and the wiring for MIDI generation by a blinded
listening bake-off of complete pipelines, so that a feature plan can be
written against a winner instead of a shortlist. The deliverable is a
verdict recorded in
[midi-generation-options.md](evaluating/generative%20features/midi-generation-options.md),
not a tool. The feature itself — "make me a dusty lo-fi beat with a
bassline" landing as per-part MIDI tracks — gets its own item once this
one has a result.

**Why:** the research is done and honest: "no route has earned a product
recommendation yet." Route A (local symbolic models) is dead today — three
ran here and reproduced the uniform-velocity failure at 1–48 s, the best
new papers have no weights, and MIDI-GPT's weights are CC-BY-NC. Route B
(a service) does not exist. Two finalists remain and the evidence cannot
separate them without ears: **Route C** (Stable Audio 3 → transcription;
Basic Pitch measured at 0.06 s and clean on bass, drums needing a
transcriber that is still unspiked) and **Route D** (Groove MIDI Dataset
retrieval, 3 MB, CC-BY-4.0, nine lanes of real human performance; GrooVAE
behind it with an unresolved checkpoint licence). Orthogonal to backend is
*wiring* — independent, conditioned (drums first, bass responds to the
actual kick), or joint-then-separated — and the doc's own finding is that
"a beat with a bassline" is the main case, so wiring is not optional.
Proxy metrics (note counts, onset offsets) have been measured to
exhaustion; the only remaining instrument is a person listening to final
MIDI rendered through the same Live instruments. Read
[music-generation-user-stories.md](evaluating/generative%20features/music-generation-user-stories.md)
for the acceptance bar the winner must clear; it settles that one request
is one undo step, separate parts per track, MIDI the default.

**Context for the plan author:**
- The doc's "Recommendation: run the decision experiment" is the protocol:
  fix 8–12 prompts first (drum-only, bass-only, combined, and bass against
  existing Session-view MIDI); clear prerequisites; run controlled
  one-factor subtests; then the product bake-off between **independent C**,
  **conditioned/D** (GMD drums + bounded rule-derived bass),
  **conditioned/C** (SA3→IDM drums + the same bass engine) and **joint C**
  (one render → Live Stem Separation → two transcriptions); judge blind on
  final MIDI only; choose by quality, break ties toward the simpler,
  licence-clean pipeline.
- **Prerequisites are their own work and should be listed as such:** spike
  Inverse Drum Machine (Apache-2.0, the only permissive drum-transcription
  candidate — ADTOF and its port are excluded on licence, and must not be
  substituted silently) on the existing SA3 drum WAVs for latency, install
  weight, class vocabulary and GM mapping; settle GrooVAE's hosted-checkpoint
  terms and its nine npm advisories, or drop it; verify the downbeat and
  loop boundary on the existing WAV slate.
- The context-aware prompts get a fifth arm, **MRT2 offline render →
  transcription**, because Magenta RealTime 2's pianoroll channel is the
  only local symbolic conditioning that exists. It is gated on Spike A1's
  offline real-time factor in
  [live-improv-exploration.md §12](evaluating/generative%20features/live-improv-exploration.md),
  and a Route C / D result must not wait on it.
- Two Live-side prerequisites the experiment can dodge but the eventual
  feature cannot, worth measuring here since the harness will exist:
  `Clip.groove` assignment by pool index (a fork gap — the cheapest real
  "follow this section's timing" mechanism) and reading the selected scene
  (`/live/view/get/selected_scene` has no tool or mirror, so "this section"
  cannot be resolved today).
- Full Live-side latency has never been measured: track creation, catalog
  lookup, `load_device`, clip write, verification. The compute budget is
  ~10 s; the product budget is unset. Time one complete multi-part request.
- The listening slate needs fixed comparison instruments; sound selection
  per lane ("dusty" affecting which kick loads) is judged separately from
  note quality and is not this experiment's question.
- Rendered results may be written to Live through `write_midi_notes`;
  eight-bar dense drums can exceed one datagram, hence the chunking gate.

## #4 · Generated-audio alignment, warping and quality polish

**Impact 7 · Lift 5 · 1.40 impact-per-effort**

**Gated on "Generate audio onto a track — Stable Audio 3, imported as a clip"**,
which produces the real imported fixtures this item measures. **Deliberately
sequenced after "MIDI generation — the decision experiment" by decision on
2026-08-29** — the audio story was split into two PRs, and the MIDI half is
worth more than polishing audio that already lands in the right slot.

Plan: [PLAN_generate_audio_polish.md](PLAN_generate_audio_polish.md) — written
as the deferred half of the generation plan, and finalised against the MVP's
measurements rather than ahead of them.

**Goal:** turn the raw, duration-exact clips established by `generate_audio`
into performance-ready loop material where the evidence supports it, without
holding the first generation/import PR hostage to DSP and listening details.

**Why:** the spike already shows that exact file duration is not the same as a
musical loop: several drum renders begin between grid lines and many fade near
the file end. Live may also choose looping and warping defaults that vary with
content or preferences. The MVP produces real imported fixtures and reports
those observations; this follow-up then solves the measured failures instead of
guessing at them in the initial tool contract.

**User stories:**
- As a producer who asked for a four-bar loop, the pattern's intended phase
  lands on the grid — including a requested pickup or rest — and the clip loops
  without a click or gap at the seam.
- As a producer who changes the set tempo after generating, the clip follows
  it — or Seshat says plainly that it will not.
- As a producer chasing a better take, a higher-quality lane exists only
  because it audibly beat the default, not because the model has one.

**Scope:**
- Measure raw and imported clips against the metronome, including Live's
  looping/warping defaults and behaviour after the set tempo changes.
- Evaluate over-generation, sub-beat grid-phase detection, exact cropping,
  silence/fade handling and seam repair while preserving pickups and rests.
- Set and read back warping, looping and loop markers only where the resulting
  playback contract is demonstrably reliable.
- Compare `medium` against `sm-music` by ear and expose a `best` lane only if it
  audibly earns the extra model weight, latency and contract surface.
- Add durable by-ear smoke coverage for grid placement, seam quality, pickup/
  rest preservation, tempo changes and close-versus-loose variations.

Keep any model/runtime or OSC additions in this PR proportionate to the
specific failing measurements.

## #5 · Generated material lands one instrument per track

**Impact 9 · Lift 8 · 1.12 impact-per-effort**

**Gated on "Generate audio onto a track"** (the render and the import it
splits), on "Live-native generation spike" (whether Live's own *Separate
Stems* and *Convert Drums* are pressable, which decides two of the routes
below), and on "MIDI generation — the decision experiment" (which
transcriber, if any, supplies the lanes). **Ranked directly under those three
by decision on 2026-08-29**: a generated file with more than one instrument
in it is not finished until each instrument has its own track, so this is
the second half of the generation feature, not an enhancement to it.

**Goal:** when a generated result contains more than one instrument — a
drum kit is the main case: kick, snare, hats, toms, percussion — each
instrument lands on its own track, the way a producer lays out a kit
(an eight-track drum kit, not one stereo loop on one track). One request,
one undo step, tracks named by instrument, playing together exactly as the
joint render did. "Instrument" means a musical role the producer would mix
separately, which is the user-stories doc's **part**.

**Why:** a single stereo loop is a sketch; a kit split across tracks is
material — the kick can be swapped, the hats sidechained, the snare sent to
a reverb, one hit nudged, and all of that is what the producer does next.
Everything downstream of generation (mixer, sends, devices, `edit_notes`)
works per track, so a joint render on one track leaves the rest of Seshat's
surface unable to touch the parts. The user-stories doc already settles
"separate parts per track, MIDI the default"; this item is where that
promise meets an audio render.

**User stories:**
- As a producer who asked for "a dusty lo-fi beat", I get a Kick, Snare,
  Hats and Perc track, not a "Beat" track, and can say "swap the kick for
  something rounder" without touching the rest.
- As a producer who asked for "a beat with a bassline", the bass is its own
  track from the start, and "undo that" removes the whole set of tracks in
  one step.
- As a producer who wanted the loop as-is, I can ask for it kept as one audio
  track and get exactly that — splitting is the default for a kit, never a
  surprise.

**Context for the plan author:**
- **Per-drum audio separation exists; the repo's survey never covered it,
  and licence is the selection criterion.** Live's own *Separate Stems to
  New Audio Tracks* is four stems (vocals / drums / bass / other) with the
  whole kit as one, and the separators surveyed in
  [live-native-options.md](evaluating/generative%20features/live-native-options.md)
  are the same four — but a second tier splits a *drum stem* into kit
  pieces (checked 2026-08-29):
  - **LarsNet** (polimi-ispl, five stems kick / snare / toms / hi-hat /
    cymbals, faster than real time, parallel U-Nets): weights **CC BY-NC
    4.0** — disqualified as shipped, the same NC wall that excluded ADTOF.
    Its training set **StemGMD is CC-BY 4.0**, so a permissively licensed
    retrain is possible; that is a spike with a GPU bill, not a dependency.
  - **inagoy "drumsep"** (Hybrid-Demucs fine-tune, kick / snare / toms /
    cymbals): licence **unknown** on every mirror — disqualified until the
    author states one.
  - **jarredou / MDX23C drum separator** (six stems incl. crash and ride
    separately): trained on a private dataset, licence unstated — same.
  - **Side Brain "DrumSep" Live extension** (Extensions SDK, June 2025
    beta, wraps MDX23C, local CPU, pay-what-you-want): a *user-installed*
    product that lands stems on tracks Live's own way. Reachable, if at
    all, only as the AX spike reaches Live's own commands — and it keeps
    the model outside Seshat, the SA3 precedent for restricted weights.
  - **cukas/drumsep** (MIT, no model: HPSS + frequency masking + transient
    gating; numpy/librosa/soundfile, ~50 MB): zero licence surface, honest
    caveats (adjacent-stem bleed, designed for isolated drum stems — which a
    generated drum loop *is*). The only candidate selectable today; quality
    on SA3 material unmeasured.
  Generated loops are a friendlier input than records: no room, no bleed,
  no vocals to strip first. So a separation arm belongs in the plan, and
  the by-ear gate decides whether a masked split is material or mud.
- The routes that do exist, each with a known ceiling on lane count:
  *Convert Drums to New MIDI Track* — kick / snare / hat, three lanes, onto
  one Drum Rack on one track, so Seshat still has to split lanes across
  tracks afterwards (extra mutations, and the Drum Rack pad map is a fork
  gap — `DrumChain.in_note`, `RackDevice.insert_chain`); a transcriber over
  the render — Inverse Drum Machine (Apache-2.0, class count unverified) or
  whatever the decision experiment picks; GMD retrieval — nine lanes, but it
  replaces the render rather than splitting it. Per-lane MIDI then lands
  through `write_midi_notes` onto per-track instruments chosen from the
  catalog — sound selection per lane is its own question and should be
  scored separately from the split.
- The other shape is *generate per part*: one render per instrument with
  the joint render as `variation_of` at low strength, or the decision
  experiment's conditioned wiring (drums first, the next part responds to
  the actual kick). Independent renders are measured not to interlock; the
  conditioned form is unmeasured. This is the only route to per-instrument
  *audio* tracks that needs no separator, and it should be an arm of the
  plan beside the separation arm, not assumed away.
- Deciding *how many* instruments a render holds is itself unsolved: the
  request text ("kick, snare, hats") is the cheapest signal and the one the
  model already has; a transcriber's non-empty lanes are the second.
- One request is one undo step across N created tracks — the undo-step
  bracketing exists, but `create_track` per lane inside one `Handlers` call
  needs the multi-step `Registry` path, and a partial failure (three tracks
  made, transcription failed) must be reported as such, never as done.
- Bass and melodic parts through Basic Pitch (measured 0.06 s, clean on
  bass) are the same shape with a different transcriber; the plan should
  say whether v1 is drums-only.

## #6 · Catalog vocabulary — read tag axes, teach the menu proactively

**Impact 8 · Lift 4 · 2.00 impact-per-effort**

**Goal:** read the tag *axes* (Character, Genres, Type, …) and the
preset→device relation out of Ableton's database, and surface the real
vocabulary proactively in tool replies — so the model sees the menu before
ordering, instead of guessing tags and learning only from failures.

**Why:** this is levers №1+№2 of
[sound-search-options.md](evaluating/sound-search-options.md) — read that doc before
planning; it grounds every claim in measurements. The top of the search
funnel leaks first-attempt vocabulary misses ("warm" isn't a tag here, `Soft`
is), and the axes fix real traps the flat tag list creates (`Distortion` the
device tag vs. `Distorted` the character tag). Highest certain win left in
the catalog area, at Low/Low-Med effort. №2 also enables future levers, which
is why they ship together.

**User stories:**
- As a producer asking for "a warm pad," the first slate is right because
  Seshat already knows this library's word for it is `Soft` — it sees the
  menu before ordering instead of guessing and learning from misses.
- As a producer asking for "something distorted," I get presets with a
  distorted *character*, not everything touched by the Distortion *device* —
  the axes keep those apart.

**Planner notes:**
- The axis lives in `files.parent_id`, which
  `Seshat.Library.AbletonDB.read_tags/1` currently discards; the
  preset→device map is the `file_devices` table (4,535 rows on the dev
  machine).
- Vocabulary is per-machine (depends on installed Packs) — it must flow
  through replies/catalog data, never be hardcoded in a tool description.
  That rule already governs `search_library`'s design.
- Requires a catalog rebuild (`reindex_library`) — fine, just say so; no
  migration shims (see CLAUDE.md).

## #7 · Search eval harness — numbers before opinions

**Impact 2 · Lift 3 · 0.67 impact-per-effort**

**Goal:** a repeatable harness that scores `search_library` relevance against
a fixed set of realistic "describe a sound" queries, so every further catalog
lever gets measured instead of argued.

**Why:** lever №9 of [sound-search-options.md](evaluating/sound-search-options.md),
estimated at a morning's work. It exists to **gate the six catalog levers**:
"Widen the search slate at tied score bands", "Browser preview audition",
"Opt-in `samples` index", "Accepted-search memory", "User XMP tags" and "LLM
enrichment at reindex". After "Catalog vocabulary" lands, the eval decides
whether any of them is still worth buying. "Catalog vocabulary" itself is not
gated — it is a certain win with or without numbers.

**Its quotient understates it, and its rank corrects for that.** Impact 2 scores
the *user-visible* value, which is zero — nobody hears a harness. All six gated
levers score better, so on quotient alone this would sit near the bottom of the
queue with every item that depends on it above it. It ranks second instead
because the dependency wins: this and "Catalog vocabulary" are the only two
issues in the catalog block that can be started today.

**Planner notes:** the result-quality work already used a six-query/77-slot
benchmark informally (see
[archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md));
formalize that rather than inventing a new one. Runs offline against the
catalog — no Ableton needed.

## #8 · Widen the search slate at tied score bands

**Impact 5 · Lift 2 · 2.50 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** when the score band straddling the result cut is large (the ~46
identical-tag `E-Piano *` presets), show more of the band rather than
pretending rank means something inside it.

**Why:** lever №4 — a presentation fix for ranking headroom that scoring
provably can't close (a graded per-term variant measured +1 slot across six
queries and was rejected). Hours of work, honest fix.

**User stories:**
- As a producer choosing an e-piano, when dozens of presets score
  identically, I see the honest breadth of the tie — not an arbitrary top
  five pretending rank means something inside it.

## #9 · A rejected index says which index, and what to call next

**Impact 5 · Lift 2 · 2.50 impact-per-effort**

**Goal:** a tool call Live rejects for a bad index tells the model which index
was bad and which `get_*` tool resolves it, instead of the bare "Ableton
rejected the request: Index out of range".

**Partly solved already, by accident — re-scope before planning this.** Measured
2026-08-05 (`/smoke-test bridge`): `get_track_devices` on track 99 now replies
"Index out of range. Nothing further was sent — check get_session_state for the
indices that actually exist." The batched-reads work of 2026-08-04 routed the
converted reads through `Handlers.remote_error/1` instead of
`Transport.describe_error/1`, and `remote_error/1` already carries the
what-to-call-next half of this item's goal. So the goal now holds on the four
batched read sites and not on the rest, which still render the bare
`describe_error/1` string — and on the regular-track `set_device_parameter`
read-back, whose own item shipped 2026-08-27 with a bespoke what-to-call-next
sentence rather than `remote_error/1`'s, so the surface is now three renderings
wide, not two. The inconsistency is arguably worse than the
uniform gap this item was written against. What is still missing everywhere,
including the batched paths, is the *which index* half: the reply says to check
`get_session_state` but never names 99. Both are in the `/live/error` payload
already (`address`, `arg_count`, the args), so this is still only rendering.

**Why:** found running the never-run agent smoke tests on 2026-08-03
([smoke_tests/auto/devices.md](smoke_tests/auto/devices.md) § Device error paths are
errors, not stalls). The guidance was never deleted — it was stranded. The
helpful wording ("Check both indices with `get_track_devices` first") lives on
`do_call`'s `catch :exit` timeout branch
([handlers.ex:2886](../lib/seshat/tools/handlers.ex#L2886) and siblings), and
the `/live/error` correlation shipped the same day made that branch unreachable
for a bad index: Live's rejection now arrives in ~0.19s and renders through
`Transport.describe_error/1`, which knows only the message Python sent. The
fast-fail is the right behaviour and is not in question; the regression is that
the model went from a slow, actionable message to a fast, generic one, on
exactly the path a model is most likely to hit by guessing an index.

**User stories:**
- As a producer, when I name a track that isn't there, Seshat re-checks and
  corrects itself in the same breath instead of telling me Ableton rejected
  something and stopping.

**Planner notes:**
- The information is present at the rejection site — `/live/error`'s structured
  payload carries `address`, `arg_count` and the request args (see
  `Seshat.OSC.Transport`'s "Failed-query correlation"), so the offending index is
  in hand; only the rendering drops it.
- Decide where the hint belongs. `describe_error/1` is deliberately the one
  place a caller renders the message, but it is tool-agnostic — a per-tool hint
  probably wants to travel with the `{:error, reason}` the handler clause
  already matches, not be pattern-matched onto message strings inside Transport.
- Audit the other `catch :exit` hints for the same stranding while in there;
  this is unlikely to be the only one the fast-fail bypassed.
- Settle the rendering *once* while here. There are three shapes in the tree
  now — `describe_error/1` bare, `remote_error/1`'s "check get_session_state",
  and `set_device_parameter`'s regular-track sentence — and the last was added
  knowing this item would unify them, not to pre-empt it.
- Small effort. The pure layer can cover it: `transport_test.exs` already
  constructs `/live/error` payloads, so the rendering is testable without Live.

## #10 · Browser preview audition

**Impact 7 · Lift 3 · 2.33 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** play a preset's browser preview instead of loading it, so the agent
can flip through ten candidates in the time one heavy preset takes to
instantiate.

**Why:** lever №6 — the lighter cousin of the shipped audition loop
(`delete_device`/`bypass_device`). Metadata will never distinguish two `Soft`
pads as well as ten seconds of audio. Gated on the eval above rather than
sequenced after it: better search may make this unnecessary, and the eval is
what decides.

**User stories:**
- As a producer torn between two `Soft` pads the tags can't tell apart, we
  flip through their browser previews and pick by ear — ten candidates
  auditioned in the time one heavy preset takes to load.

**Planner notes:** the fork already ships `/live/browser/preview_item` and
`/live/browser/stop_preview`; what remains here is the Elixir tool. The
preview plays through Live's cue channel — the tool description must
surface that audibility depends on cue routing.

## #11 · `start_new_project` — the setup wizard, and prompt budget back

**Impact 6 · Lift 3 · 2.00 impact-per-effort**

**Goal:** a tool that catches "let's start a new project" / "start fresh" and
runs the opening of a session: report what's in the open set, name any empty
leftover track, and gather the one-line brief (genre, tempo, mood, reference)
its reply asks for. It **reads and guides; it does not mutate** — the actual
work stays with `create_track` / `delete_track`, with the model in the loop.

**Why:** two wins at once. It fixes finding #1 of the 2026-07-28 validation
run ("start a new project" only appended tracks, leaving the default set's
leftovers behind), and it moves that rule off the *instructions* budget,
which is hard-capped — see below. A tool description routes a user utterance
far more reliably than a bullet in a block that gets truncated from the
bottom, and a reply can name the empty track it actually found instead of
asserting a cleanup unconditionally and hoping the model checks.

**User stories:**
- As a producer saying "let's start something fresh," I get a quick read of
  what's in the open set and one question — genre, tempo, mood, reference —
  so the session starts from my idea, not from leftovers.
- As a producer, the default set's empty leftover track gets noticed and put
  to use, instead of new tracks silently piling up beside it.

**Planner notes:**
- **The 2,048-character ceiling is the point.** Claude Desktop truncates
  server `instructions` mid-sentence at 2,048 characters and says nothing
  (measured 2026-07-29; see the comment above `@text` in
  [lib/seshat/instructions.ex](../lib/seshat/instructions.ex)). Tool schemas
  have no such cap — ~36KB ships every request. So moving a rule from the
  instructions into a tool description or reply costs nothing in total
  context and buys room on the one budget that silently drops content.
- **The "New project" bullet is already gone from `Seshat.Instructions`**
  (removed 2026-07-29, ~230 characters back). Nothing states replace-not-append
  until this ships — the model will append tracks, as it did before that rule
  was written. That gap is deliberate: the rule was bought back as budget on
  the assumption this tool follows.
- **No file operations, ever.** Opening or saving a set is a human step —
  Live's save dialog swallows keystrokes and no code should discard a user's
  work. That is settled; see
  [archive/create-project-removal.md](archive/create-project-removal.md).
- **Read-only is what keeps it from repeating history.** Every failure of the
  removed `create_project` came from fire-and-forget mutation through Live's
  post-load settling window. A tool that only reads `Session.State` and
  returns guidance cannot reproduce any of it.
- The default set is now a single blank MIDI track, so "leftovers" is at most
  one track — the reply should say what it found, not describe a mess.
- Trigger phrasing carries the whole routing job now, so the description has
  to cover the ways the intent is actually spoken. Standard `/add-tool`
  discipline, load-bearing here.
- **Nothing is broken while this is missing.** The cost is one awkward
  session opening the model can be steered through by hand — that is what
  holds its impact score to 6 rather than higher. It earns its rank on being
  small and on freeing instructions budget that "Producer personas" will
  want, so prefer building it before that item even though ratio separates
  them.

## #12 · `write_midi_notes` must chunk large note batches

**Impact 6 · Lift 3 · 2.00 impact-per-effort**

**Goal:** dense and long MIDI clips are written in bounded OSC messages instead
of one unbounded UDP datagram.

**Why:** `Seshat.Commands.Registry.add_notes/3` currently flattens every note
into one `/live/clip/add/notes` message, while the public schema places no
maximum on the notes array. This machine's `net.inet.udp.maxdgram` is 9,216
bytes, so a sufficiently dense request can exceed the transport ceiling even
though it passed validation. This is an existing `write_midi_notes` defect,
not work that should remain buried inside the prospective music-generation
plan; generated 8–16 bar drums merely make it easier to hit. The generation
work in [docs/evaluating/generative features/midi-generation-options.md](evaluating/generative%20features/midi-generation-options.md)
depends on this fix for dense or long clips. "MIDI generation — the
decision experiment" now sits above this item by decision (2026-08-28) and
names this as one of its gates; when that experiment is picked up, land this
first.

**User stories:**
- As a producer writing a dense or long MIDI clip, all requested notes land in
  Live instead of the whole write disappearing because its UDP packet was too
  large.

**Planner notes:**
- Keep clip creation and all note chunks inside the existing single
  `write_midi_notes` command and undo step. Repeated
  `/live/clip/add/notes` calls append, so create once and batch only the add.
- Derive a conservative chunk size from encoded OSC payload size, not an
  undocumented note-count guess. Each wire note adds pitch, start, duration,
  velocity, and mute arguments; track and slot are message-level arguments.
- Add pure tests at, below, and above the chosen boundary, including a long
  dense clip and preservation of note order. The OS limit is the failure
  mechanism, but the test should not send to Live or depend on this Mac's
  current sysctl value.
- Do not “fix” this only with schema `maxItems`: the public 1–16 bar feature
  surface needs valid dense clips to work, not become validation errors.

## #13 · `set_clip_properties` reads the loop pair before the `looping` toggle lands

**Impact 4 · Lift 2 · 2.00 impact-per-effort**

**Goal:** setting `looping` *and* the loop points in one call produces the
intended brace on a clip whose stored loop points differ from its play markers.

**Why:** recorded as a known wart by the 07/2026 review of the clip property
tools, and carried since then as a caveat inside the smoke-test checklist —
which is the wrong home for a defect, since a checklist item that says "if it
misbehaves, the fix is…" is a bug report nobody triaged. With looping off,
Live aliases the loop points onto the play markers. `set_clip_properties`
reads that pair *before* the `looping` toggle goes out, so on such a clip both
the write ordering and the single-sided validation can run against stale
values, and the resulting brace is not the one asked for.

**Planner notes:**
- The fix is stated in the original review: send `looping` first, then read the
  pair context, then order the loop-point writes. Confirm the read really is
  ordered before the toggle in `Seshat.Tools.Handlers` before assuming it.
- Ordering logic is pure-testable — the existing write-ordering tests in
  `handlers_test.exs` are the place. What is not pure-testable is whether Live
  aliases as described; that is a measurement, and it belongs in
  [../priv/AbletonOSC/API.md](../priv/AbletonOSC/API.md) once made.
- The live check already exists as
  `smoke_tests/auto/clips.md § The loop pair with looping off`, where a failure is
  currently the *expected* result. Cite it from the plan, and when this ships,
  rewrite that test so a failure means a regression again.

## #14 · Routing evals — general corpus and client-realism lane

**Impact 5 · Lift 3 · 1.67 impact-per-effort**

**Goal:** widen the routing-eval corpus past the two decision-experiment
cases to the ~20-case general corpus (paraphrases, cue/return/master
coverage) the first slice deferred, and decide whether to add a
client-realism lane (Claude Code's default system prompt) plus a direct-API
model adapter. The harness itself — `mix routing.eval`, `Seshat.Eval.*`,
committed base/head surface snapshots — already exists; this item is corpus
and lane work on top of it, not new plumbing.

**Why:** the first slice's decision run (`mix routing.eval`, 2026-08-28, 40
trials, zero void) found both the pre- and post-consolidation tool surfaces
routed *correctly* in every trial on both seed cases — full detail in
CLAUDE.md's Current focus and the archived
[PLAN_routing_evals.md](archive/PLAN_routing_evals.md). That result is honest
but narrow: both seed cases are exactly the ones consolidation was designed
for, and five trials per cell cannot separate 100% from 95%. The general
corpus — paraphrased requests, cue/return/master targets the seed cases
never touch — is where the same-verb-different-target base surface would be
expected to struggle if it struggles anywhere; only running it turns "we
didn't observe a difference" into "there isn't one, on this evidence."

**Planner notes:**
- The archived plan's `Out of scope` section is the authoritative list of
  what this covers: the general corpus, the client-realism lane, and a
  direct-API model adapter (options doc B in
  [automated-conversation-routing-evals.md](evaluating/automated-conversation-routing-evals.md)).
  A prose/LLM judge for "replies speak music" was declined outright, not
  deferred — the manual conversation-check residue stays as the check for
  that; don't rebuild it here.
- Reuse `Seshat.Eval.Case`'s JSON shape and `Seshat.Eval.Judge`'s predicate
  vocabulary; new cases are data, not code, per the harness's own design goal.
- Two open nits from the first slice's review bear on any new cases: "Routing
  eval report should self-identify which case expectations it scored
  against" and "Routing eval: an exploratory read on a fixture with no data
  for it should not fail `no_tool_errors`" — the second is likely to
  actually bite once cue/return/master reads widen the discovery surface,
  unlike in the two-case corpus where it never fired.
- `mix routing.eval` is on-demand only, never in `mix precommit` — keep it
  that way; it is externally metered and stochastic.

## #15 · Read-only audio input display — warn before a silent take

**Impact 5 · Lift 3 · 1.67 impact-per-effort**

**Goal:** surface a track's audio input routing, read-only, so `record_clip`
can warn when an audio take is about to record nothing.

**Why:** `record_clip`'s description admits Seshat "cannot choose or check
the input," so an audio take is a coin flip on whether anything was routed —
a silent take discovered after the fact. Upstream already has every address
needed (`/live/track/get/input_routing_type` / `_channel` and the
`available_*` lists — no fork change). Raised as a Medium gap by the
2026-07-31 external tool audit; ranked
here rather than higher because audio recording is a side path in a
MIDI-first workflow and the failure it prevents is recoverable and already
documented in `record_clip`'s description.

**User stories:**
- As a producer setting up a guitar take, Seshat tells me "that track is
  listening to Ext. In 3/4" — or that no input is routed — before recording,
  instead of us finding a silent clip after.

**Planner notes:**
- Read side only. The write side (`/live/track/set/input_routing_*`) stays in
  the grab bag — that's where the sharp edges are.
- Smallest version: `record_clip` reads the routing before firing on an audio
  track and names it in the reply. Decide whether it's also worth a line in
  `get_session_state` before building more surface than the warning needs.
- Routing values are strings from Live's own menus; report them verbatim,
  don't interpret.

## #16 · `screenshot_live` — let Seshat see the screen

**Impact 6 · Lift 4 · 1.50 impact-per-effort**

**Goal:** capture Live's window (macOS `screencapture` targeted by window
ID) and return the image in the MCP tool result, so the client model —
already vision-capable — can look at the actual UI when the user asks about
it.

**Why:** 2026-07-28 validation run: "why can't I see the notes?" — OSC is
blind to presentation. The mirror knows session *state*, never what's on
screen (focused view, open dialogs, browser panes), so UI questions today
get guesses. Trigger is user UI questions, not routine post-action use —
the follow cam (shipped 2026-07-29) covers that.

**User stories:**
- As a producer asking "why can't I see the notes?", Seshat looks at my
  actual screen and answers — instead of guessing from mirrored state that
  can't see a dialog, a collapsed pane, or where focus went.

**Planner notes:**
- Verify Anubis supports image content in tool results (the MCP spec does).
- Downscale before returning — full-res screenshots are token-expensive.
- One-time macOS Screen Recording permission for the BEAM process; capture
  works occluded but not minimized.

## #17 · Opt-in `samples` index

**Impact 6 · Lift 4 · 1.50 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** index the `samples` category (3,567 items) into the catalog,
returned **only** when `category: samples` is explicitly requested.

**Why:** lever №7, the only category still invisible — "a vinyl crackle" is
unfindable while `Crackle Vinyl Pop.wav` sits in the browser. Sample uris
carry FileIds, so tag-awareness comes free.

**User stories:**
- As a producer asking for "a vinyl crackle," the sample that's sitting
  right there in Live's browser is actually findable — today no search can
  reach it.

**Planner notes:** samples is why `EXPORT_CATEGORIES` excludes it and the
20k-node scan cap exists — measure the walk cost first. Keeping samples out
of default results is a hard requirement so the preset slate stays clean.

## #18 · Accepted-search memory

**Impact 6 · Lift 5 · 1.20 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** remember what a description resolved to — "this request led to this
accepted preset" — and let it bias future rankings.

**Why:** lever №8. `use_count`/recency already bias rankings, but the
description→preset association is thrown away today. Compounds over time; a
personal tool can afford a personal memory.

**User stories:**
- As a producer who settled on a particular preset for "dusty keys" last
  week, the same request surfaces it first this week — my accepted picks
  teach the search what my words mean.

**Planner notes:** this is the one catalog feature that wants a write-side
store. Keep it out of the read-only catalog file — a separate small file
under `~/.seshat/` — and it is still not a database (see CLAUDE.md).

## #19 · Producer personas — switchable musical taste

**Impact 7 · Lift 6 · 1.17 impact-per-effort**

**Goal:** layer a *persona* onto the base session instructions. 
Personas live one per file in [priv/producers/](../priv/producers/)
(five placeholder stubs exist; `mona_dust.md` is the default); a `load_producer` tool (plus
`list_producers`) loads one into the conversation mid-session:
"load me Volt Kessler" changes the session's whole aesthetic.

**Why:** The feel of colloborating with different styles of producer is valuable to the user.
Also different songs might benefit from a different producer. Personas should carry aesthetic taste: sonic palette, genre instincts. Maybe other fun details like stylistic language differences in the responses.

**User stories:**
- As a producer, "load me Volt Kessler" changes what every following pick
  reaches for — a different palette, same tools, no re-explaining a whole
  aesthetic in every prompt.
- As a producer with a direction of my own, my stated taste still leads; the
  persona only fills in where I haven't said anything yet.

**Planner notes:**
- the base text([lib/seshat/instructions.ex](../lib/seshat/instructions.ex) 
  is delivered via the instrucions.  We could put the persona here but there are 2 VERY BAD limitations. 
  Its only loaded at the start of the session, which precedes the first user command, so a user has no way to select the producer being loaded. 
  Also there is a strict 2048 character limit on this field, and the base text needs to use most of it, not much room for the producer persona. 
- Because of these limitations, the planner should explore out of the box creative solutions to loading a producer. 
  Even resorting to asking a user to manual input a file or text somewhere in the desktop client. 
  Consider all possible avenues and angles for getting the mcp consumer to respond with a desired persona. 
  so we are unfortunately quite limited with the space that can be given to a persona if using this delivery method. 
- **The taste hierarchy:  the user's communicated taste
  always leads; the persona is the *default* — the prior that fills in when
  the user hasn't said yet.** 
- The stubbed out personas are placeholders and need to be edited manually,
  continuous iteration is expected as we can only guess and check while using.

## #20 · Verify destructive mutations before reporting success

**Impact 8 · Lift 7 · 1.14 impact-per-effort**

**Goal:** destructive and structural operations check their target before
mutating and confirm the result afterward, instead of returning success as soon
as `:gen_udp.send/4` returns.

**Why:** a rejected delete and a dropped packet are indistinguishable from a
successful one, because nothing waits on a setter — and the follow cam then
steers to a destination that may not exist. The reachable trigger is a stale
model-held index. (The original framing, "Python catches Live API exceptions
and only logs them," is half obsolete: the fork now sends a correlated error
for a rejected setter. Seshat still discards it — see the third planner note
below — so the symptom is unchanged, but the fix has a cheaper option than it
did.)

**User stories:**
- As a producer, when a delete never actually happened in Live, Seshat says
  so — instead of confirming success and steering my view toward a track
  that doesn't exist.

**Planner notes:**
- **Keep ordinary parameter setters fire-and-forget.** The review's headline
  recommendation — structured acknowledgements from every mutation endpoint —
  is rejected: it reverses the settled rule in
  [.claude/rules/osc.md](../.claude/rules/osc.md) ("Setters stay silent — each
  is guarded by its getter first, and nothing waits on one"), and adds a
  round-trip to every mutation, adding load to the query queue that now
  serializes every OSC request.
- The pattern already exists: `delete_device` bounds-checks then verifies by
  re-count, `set_clip_properties` verifies each write by re-read. Extend that to
  the remaining destructive operations and stop.
- Ranked here rather than higher because the surface is broad — this is the
  slog of the correctness items.
- From the 2026-07-29 external review; the verify-before-mutate half accepted,
  structured setter acknowledgements rejected above.
- **Fold in the `remove_notes` footgun fix** (2026-07-31 external tool
  audit): with no range given it silently deletes every note in the clip. Require an explicit range or `all: true`
  before a full wipe — the same principle (destructive intent must be
  explicit), a few lines in `Definitions` + `Handlers`, and small enough to
  ride along here (or as a drive-by before this item is picked up) rather
  than rank on its own.
- **A third option exists now, cheaper than a read-back: the correlated
  setter failure.** The fork's dispatch-boundary rework stopped
  `_call_method`/`_set_property` swallowing exceptions, so a rejected setter
  or generic method now sends `/live/error ["request", <its own address>,
  message, argc, *args]` — the same envelope a failing *query* gets, naming
  the request and its arguments. Today Seshat throws that away:
  `Transport.send_message/2` has already returned `:ok`, and the error is
  broadcast on `"osc:in"` and answers nobody. The lever is a short grace
  window after a silent setter — hold the tool step open for roughly one
  AbletonOSC tick (~100ms, and 212ms was the measured client-call-to-result
  figure for a rejection) and report the rejection if one arrives, rather
  than paying a full read-back round trip. That is not the round-trip-per-
  mutation design rejected above: nothing is *queried*, the wait is bounded
  by a tick rather than by `@query_timeout`, and a clean setter costs
  nothing extra. Weigh it against the read-back on a per-setter basis —
  read-back proves the value landed, the envelope only proves it wasn't
  refused — and note it needs a Transport-side subscription to unmatched
  `"request"` errors, which does not exist yet. Requires the fork's
  `_dispatch` commit installed; verify with `mix abletonosc.install` first.
- **Two more Tier-A setters named by the 2026-08-03 integration review**
  ([abletonosc-integration-review.md](evaluating/abletonosc-integration-review.md),
  §4 item 6): `set_track_arm` returns "Armed track N" unverified while
  `record_clip`'s internal `arm_track/1` exists precisely because Live can
  refuse to arm, and `set_time_signature` fires two independent messages and
  can report a plain error with the signature half-applied. Both belong to
  this item's surface. (`set_track_send` from the same review shipped
  separately, with a read-back rather than a wording hedge — see
  [CLAUDE.md](../CLAUDE.md)'s Current focus.)

## #21 · User XMP tags

**Impact 3 · Lift 3 · 1.00 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

**User stories:**
- As a producer who has tagged parts of my own library, those tags count in
  search — they're the most precise signal about my sounds that exists.

## #22 · Small OSC breadth — grab bag

**Impact 3 · Lift 3 · 1.00 impact-per-effort**

Individually tiny, none blocking a workflow; pick up opportunistically:

- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low
  value for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groups · routing/IO · automation** — grouping tracks, input/output
  routing & monitoring, automation envelopes. (The read-only input *display*
  graduated to its own item, "Read-only audio input display"; the write side
  stays here.)
- **Sends on return tracks** (return→return routing, feedback sends) —
  niche, needs Live's "sends only" awareness, no named workflow yet.
- **Groove Pool assignment by index** — `Clip.groove` is unserializable over
  the wire, but a fork handler could assign it Python-side from
  `song.groove_pool.grooves[i]`, which would make `set_groove_amount` live in
  Seshat-only sessions. Niche until a user actually has grooves in their
  pool; recorded so the "groove amount is inert" audit finding doesn't get
  re-litigated.

## #23 · Pin the wording of `edit_notes`' partial-failure message

**Impact 2 · Lift 2 · 1.00 impact-per-effort**

**Goal:** get test coverage on the message `add_edited_notes/3`
(`lib/seshat/tools/handlers.ex`) returns when the remove half of an
`edit_notes` call succeeds but the add half fails — "The matched notes were
removed but the edited replacements could not be sent … Call undo
immediately to put them back." Nothing in the suite pins its wording today.

**Why:** flagged in the 2026-08-28 review of "Consolidate the tool surface"
as the single most consequential error path in the note-editing feature —
notes already gone, replacements never sent, and the only way back is an
immediate `undo` — with no test protecting the sentence a model would act on
in that moment. It was left as a non-blocking nit rather than fixed inline
because the failure can't be provoked through the existing harness:
`Transport.send_message/2` goes out over loopback UDP via `:gen_udp.send/4`,
which does not return `{:error, _}` in practice, so `Seshat.Test.OSCSink`
has nothing to hook to drive this branch through the full call path — the
same constraint that leaves every other bare error-message helper in
`Handlers` (`extension_missing_error/2`, `mixer_partial_error/5`,
`stale_reply_error/2`, and siblings) untested directly today, by consistent
convention across the module.

**Planner notes:**
- Fixing this for real means solving it for the whole family, not just this
  one message — either give `Transport.send_message/2` a way to be
  injected with a failure in tests (a behaviour/mock swap, or a test-only
  send path), or accept breaking the module's current privacy convention by
  exporting one pure formatting function and decide whether that's worth
  the inconsistency it introduces.
- Low lift once the mocking question is settled — the message itself is
  already correct and doesn't need to change, only get pinned.

## #24 · Routing eval report should self-identify which case expectations it scored against

**Impact 2 · Lift 2 · 1.00 impact-per-effort**

**Goal:** `Seshat.Eval.Report`'s header pins the CLI version, the lane-prompt
hash and each surface's contract digest, but nothing about the case
expectations a run was scored against. Add a digest of each case's `expect`
block (per surface, since head and base can be held to different bars) to
the header or per-case section, so `report.md` is self-contained.

**Why:** flagged in the review of "Automate conversation-routing evaluations"
(`docs/archive/PLAN_routing_evals.md`). The decision run deliberately scores
`note_third_quieter` against different bars per surface — head gets
`max_mutations: 1` plus `must_not_call: ["write_midi_notes"]`, base gets
`max_mutations: 2` with nothing forbidden — and a reader of `report.md` alone
sees "semantic success 100% / 100%" with no signal the two columns measured
different criteria. The plan says so in prose, but `/ship` archives the plan;
`priv/routing_eval/runs/` is gitignored, so the report is the only thing that
travels with a PR. Left as a non-blocking nit rather than fixed inline
because it is a small feature addition (new digest plumbed from the case
loader through the run map `mix routing.eval` assembles, through
`Seshat.Eval.Report`, with new test coverage), not a one-line correction.

**Planner notes:**
- The digest should probably be sha256 of the case's `expect` map for the
  surface actually used, following the pattern `Seshat.Eval.Surface` already
  uses for the contract digest.
- Consider whether the per-case Markdown section should also spell out the
  gate differences in prose (`max_mutations`, `must_not_call`) rather than
  only a hash, since a hash alone still sends a PR reader back to the case
  JSON to see what changed.

## #25 · Routing eval: an exploratory read on a fixture with no data for it should not fail `no_tool_errors`

**Impact 3 · Lift 3 · 1.00 impact-per-effort**

**Goal:** `Seshat.Eval.Fixture`'s "a read the fixture has no data for answers
`isError: true`" behavior currently makes any such read count as a tool
error, and both seed cases set `no_tool_errors: true` in their expectation —
so a model that probes `get_clip_properties`, `get_track_devices`, or
`get_clip_notes` on the wrong track before finding the right one fails
`semantic_success` even when everything it does afterward is correct.
Give the judge a way to tell "the model invented state" apart from
"the model looked in the wrong place and recovered," or exclude exploratory
reads from `no_tool_errors` specifically.

**Why:** flagged in the review of "Automate conversation-routing evaluations"
(`docs/archive/PLAN_routing_evals.md`). It did not bite in the decision run — zero
tool errors across all 40 trials on both seed cases — but the plan's own
Out-of-scope section defers "the general corpus (paraphrases, cue/return/master
coverage, ~20 cases)" to a second slice, and that is exactly the corpus that
would widen the discovery surface and start exploratory reads landing. Left
as a non-blocking nit rather than fixed inline because the second slice
doesn't exist yet — there is no case in this repo the change would currently
affect, and picking the right judge semantics (a new verdict field? a
"forgivable error" allowlist keyed by tool?) is a design call better made
against real second-slice cases than speculatively.

**Planner notes:**
- Revisit this before or alongside building the second-slice corpus
  (`docs/archive/PLAN_routing_evals.md`'s "Out of scope" section), not before.
- The plan's own justification for the `isError: true` reply itself still
  holds ("the model must not proceed on invented state") — this item is only
  about whether that reply should count against `no_tool_errors`.

## #26 · `variation_of` refuses a managed take when `~/.seshat` is a symlink

**Impact 3 · Lift 3 · 1.00 impact-per-effort**

**Goal:** `Seshat.Generation.AudioClip.under_root?/1` compares
`Path.expand/1` output on both the reported clip path and `generated_root()`
— neither of which resolves symlinks. The fork realpaths the path it hands
to Live before replying on `/live/clip/get/file_path`, so on any
installation where `~/.seshat` is itself a symlink (an external volume, a
dotfile manager), every take Seshat generated reads back under the
link-target path and `variation_of` refuses it as "outside Seshat's
generated-audio folder" — permanently, and incorrectly, for a file Seshat
just wrote.

**Why:** flagged as non-blocking in the PR review of "Generate audio onto a
track" (`docs/PLAN_generate_audio_clip.md`) because it needs a real symlinked
`~/.seshat` to reproduce and is unreachable on this reviewer's plain
installation, not because the bug is in doubt. The module already solved the
identical shape twenty lines below `under_root?/1`: `same_file?/2` compares
inode and device rather than path strings specifically because "a symlinked
`~/.seshat` would make Live report a different string for the very file just
written" (its own comment). `under_root?/1` needs the same treatment — a
containment check that survives a resolved root, not a second string
comparison that repeats the mistake `same_file?/2` was written to avoid.

**Planner notes:**
- `same_file?/2` works because it compares one file against another known
  file. `under_root?/1` is a containment check (is this path *inside* a
  directory), which inode/device comparison alone doesn't answer — the fix
  needs either a realpath equivalent for the root and the reported path (no
  built-in in `File`; would mean resolving each path segment's symlinks
  manually) or an ancestor walk from the reported path's directory upward,
  comparing `{inode, device}` against the root's at each step until it
  matches or the walk exhausts.
- Test against an actual symlinked temp directory, not just a string
  comparison — the whole bug is that string comparison looks correct until
  the filesystem enters the picture.

## #27 · Bounded generation diagnostics can drop the newest chunk entirely on overflow

**Impact 2 · Lift 2 · 1.00 impact-per-effort**

**Goal:** `Seshat.Generation.StableAudio`'s `retain/3` holds the Stable Audio
runtime's stdout newest-first and trims from the oldest end once
`max_output_bytes()` is exceeded, so a failing run's diagnostics show its
last output rather than its startup banner. `trim/3`'s base case doesn't
handle a single chunk that is itself larger than the cap: it pops that chunk
as "oldest" (there being nothing else left) and returns `{[], 0}`, discarding
the newest — and only — output instead of keeping the tail of it. A failure
under a configured cap smaller than the runtime's per-message chunk size
(measured at up to 16,384 bytes for a `:binary` spawn port with no `:packet`
option) reports "The runtime printed nothing" on a run that printed
plenty.

**Why:** flagged as non-blocking in the PR review of "Generate audio onto a
track" because the shipped default `max_output_bytes` (32 KB) is safe — the
bug only reaches production behavior if `:generation_max_output_bytes` is
configured below the port's per-message chunk size, which nothing in the
codebase does today. It is currently masked by its own test
(`stable_audio_test.exs`, the cap-at-1,000-bytes case), which asserts only
`byte_size(message) < 4_000` — true whether the tail is retained or dropped
entirely — so the bug shipped through review with a test that exercises the
exact path without noticing.

**Planner notes:**
- Fix belongs in `trim/3`'s base case: when the list is down to one
  oversized chunk, truncate the binary to its last `cap` bytes instead of
  discarding it.
- While there, strengthen the masking test to assert the retained diagnostic
  actually contains recognizable content (e.g. `assert message =~ "x"`
  against known input), not just a byte-size ceiling — that assertion is
  what let this ship unnoticed the first time.

## #28 · Tighten the process-start grep so it does not shape prose in unrelated modules

**Impact 1 · Lift 1 · 1.00 impact-per-effort**

**Goal:** `test/seshat/ax/client_test.exs`'s grep for `Port.open`,
`:spawn_executable`, `System.cmd`, `System.shell`, `:os.cmd` and
`:erlang.open_port` (the invariant that nothing under `lib/` outside
`Seshat.AX.Client` and `lib/mix/tasks/` starts a process) matches inside
comments and `@moduledoc` bodies, not just executable code. Narrow it to
skip comment lines and doc attributes.

**Why:** flagged in the review of "Automate conversation-routing evaluations"
(`docs/archive/PLAN_routing_evals.md`). `Seshat.Eval.Client`'s moduledoc has to avoid
writing the literal string `Port.open` even in prose, so the grep does not
false-positive on a docstring — the invariant itself is intact, but a test
tripwire is now shaping documentation in an unrelated module. Left as a
non-blocking nit rather than fixed inline because it touches a shared
invariant test outside the routing-evals change's own files, not something
that plan's implementation owns.

## #29 · LLM enrichment at reindex

**Impact 7 · Lift 9 · 0.78 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** generate tags/descriptions for untagged and third-party items at
reindex time, using an external model service or an MCP-client-driven tagging
turn.

**Why:** lever №5 — highest ceiling (it attacks the thin-signal problem
directly: ~200 of 5,795 entries say anything real about their sound) and
highest cost. Last resort of the catalog levers: buy only if the search eval
still shows first-slate misses on thin-tagged entries after every other lever
has landed. Concrete evidence from
the 2026-07-28 validation run: for "warm, slightly out-of-tune electric
piano," the character lived only in preset *names* — E-Piano Rusty, Old
School, MKII Old, Cheap were invisible to tag scoring because no warm/aged/
detuned vocabulary exists to carry them.

**User stories:**
- As a producer asking for "a warm, slightly out-of-tune electric piano,"
  the presets whose character lives only in their names — E-Piano Rusty,
  MKII Old — finally rank on their sound instead of their tag luck.

## #30 · Monitored refresh worker for `Session.State`

**Impact 3 · Lift 6 · 0.50 impact-per-effort**

**Goal:** move the mirror rebuild off the GenServer's synchronous path and give
it an overall deadline plus freshness / connection / last-error metadata, so a
slow or unreachable Ableton cannot block every mirror read behind it.

**Why:** this lived in "Deliberately not planned" — the larger half of the
2026-07-29 review's session-refresh finding, deferred rather than declined, with
one stated reopen condition: *"the blocking window is short and has never been
observed. Reconsider if the blocking window is ever actually seen."* **It was
observed on 2026-08-02.** An ordinary undo burst raced a rebuild, and one
rejected index blocked `do_refresh/1` inside the GenServer for a full five
seconds — see "Correlate `/live/error` so a failed query fails fast" for the
measurement. The condition has fired, so this belongs in the queue rather than
in the declined list.

**The gating fix has now shipped.** "Correlate `/live/error` so a failed query
fails fast" cut that same window from ~5,000ms to roughly one AbletonOSC tick
(≤100ms) without restructuring anything, which may have removed this item's
entire motivation. Buy it only if blocking is still observed after
re-measuring against the shipped fix — the same discipline the catalog levers
get from "Search eval harness". Ranked here for that reason: conditional, and
the shipped fix may retire it outright.

**Planner notes:**
- Only the fabricated-defaults half of the original finding shipped (2026-07-30);
  refresh still runs sequential synchronous OSC calls inside the GenServer.
- The OSC query queue changed the contention picture after that review was
  written — re-establish the real blocking behaviour by measurement before
  designing against the review's description of it.
- `@refresh_sync_timeout` already bounds what the *caller* waits, not what the
  refresh costs. That asymmetry is what this item is actually about.
- **If this is ever picked up, reach for `Seshat.OSC.Transport.query_batch/2`
  first**, not a new fork bulk-snapshot endpoint. "Batch the N+1 reads into
  one AbletonOSC tick" (shipped 2026-08-04, archived at
  [archive/PLAN_batched_queries.md](archive/PLAN_batched_queries.md))
  measured the mirror rebuild's own ~73-query cost as the same disease this
  item targets, at ~4.6s; a batched rebuild would cost roughly 3 ticks
  instead, which may shrink the blocking window enough on its own to retire
  this item without a worker. Re-measure against a batched rebuild before
  designing the worker.

## #31 · Device list per track in session state

**Impact 2 · Lift 5 · 0.40 impact-per-effort**

**Goal:** mirror each track's device chain in `Seshat.Session.State`, so the
agent sees loaded devices without a `get_track_devices` round-trip.

**Why:** device-chain reads are frequent (every load/delete/bypass verifies
by re-read), and the session-state mirror is push-fresh for everything else.
Quality-of-life multiplier for the now-complete device workflow — but the
gain is latency and tokens, not user-visible experience, hence the rank.

**Planner notes:** needs device add/remove listeners per track — check what
upstream offers before assuming a new handler is required. The clip-grid
precedent applies (see the "Clip grid in session state" note): query-on-demand
shipped first, promotion to
push state only once usage justified the subscription surface. Usage now
plausibly does; confirm before building. These listeners are index-keyed —
the fork already fixes the wrong-object unbind in the handler base class, so
any listener work here is an ordinary fork commit, no override gymnastics.

## #32 · Adopt MCP `2026-07-28` when Anubis supports it

**Impact 2 · Lift 5 · 0.40 impact-per-effort**

**Goal:** serve MCP's stateless `2026-07-28` protocol over both Streamable HTTP
and stdio while retaining legacy compatibility for as long as clients need it.

**Why:** `2026-07-28` removes the `initialize` / `notifications/initialized`
handshake and `Mcp-Session-Id`, moves version and client capabilities into
per-request `_meta`, adds mandatory `server/discover`, requires
`Mcp-Method` / `Mcp-Name` HTTP headers and `resultType` on results, and makes
list responses cacheable. Claude support began rolling out on 2026-07-28.
Seshat is currently pinned to `anubis_mcp` 1.10.0, whose newest supported
protocol is `2025-11-25`; current dual-era clients can fall back to that legacy
flow, so this is not an active break.

**Planner notes:**
- Wait for an Anubis release with native `2026-07-28` support; do not implement
  the wire protocol inside Seshat. The existing `~> 1.10` constraint may admit
  a later 1.x release, leaving only a lock update plus any new transport option.
- Prefer dual-era operation initially. A modern-only client cannot use the
  current server, while a dual-era client probes `server/discover` and falls
  back to legacy initialization.
- Seshat's application state already lives outside MCP transport sessions:
  tools delegate to `Seshat.Tools.Handlers` and do not use the per-client Anubis
  frame. No tool or OSC redesign should be needed.
- Verify that `Seshat.MCP.Server.server_instructions/0` reaches the
  `server/discover` result. The new protocol retains `instructions`, but today
  Anubis emits them from the legacy initialize response and this guidance is
  load-bearing.
- The SDK should own per-request `_meta`, standard HTTP headers, `resultType`,
  cache fields, version errors and discovery dispatch. Seshat's static tool
  list is already deterministic and does not vary by connection.
- Keep the current GET/SSE path while supporting legacy clients; modern
  `2026-07-28` replaces the standalone GET stream with
  `subscriptions/listen`. Revisit the router comments and
  `Seshat.MCP.LogFilter` after the Anubis upgrade.
- Authorization changes do not apply while Seshat remains unauthenticated and
  loopback-only. Tasks, roots, sampling, elicitation and MCP logging are not
  used here.
- Add wire-level tests for `server/discover`, a direct stateless `tools/list`
  and `tools/call`, required response fields, HTTP headers, instructions, and
  legacy fallback. Existing MCP tests cover component parity and the
  instructions callback, not transport negotiation.
- Primary references:
  [release overview](https://blog.modelcontextprotocol.io/posts/2026-07-28/),
  [key changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
  [discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
  and
  [version compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).

## #33 · Clip grid in session state — only if usage demands it

**Impact 2 · Lift 6 · 0.33 impact-per-effort**

**Goal:** promote the clip grid from on-demand (`get_clip_slots`, shipped)
into push-fresh `Session.State`.

**Why (conditional):** clip-slot listeners are a large subscription surface
(tracks × scenes × properties). The standing decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) is to
wait for evidence the grid is read constantly. Session record has now shipped
alongside `capture_midi`, so the trigger this item was waiting on has
happened — worth checking whether grid-read frequency actually justifies the
subscription surface before building it. Index-keyed listeners, like the
device-chain mirror's — these are ordinary fork commits on the fixed base class.

---

## Deliberately not planned

- **Deployment-gated security work** — HTTP authentication on `/mcp`,
  production binding, rate limiting, and the multi-user design
  question. Not in this queue by design; see
  [SECURITY_BACKLOG.md](evaluating/SECURITY_BACKLOG.md) for the two triggers that activate
  them. Note that authentication alone does not make Seshat multi-user — one
  transport, one mirror, one Ableton.
- **A PubSub restart would leave `Session.State` permanently unsubscribed.**
  State subscribes only in `init/1`, and it is a `:one_for_one` sibling of
  `Phoenix.PubSub`, so a PubSub restart leaves it registered in a dead registry
  and deaf to OSC broadcasts. The mechanism is real. Declined 2026-07-30 because
  the offered fix is worse than the disease: `:rest_for_one` at
  [application.ex:39](../lib/seshat/application.ex#L39) would, given the current
  child order, restart Transport, Session.State, Catalog, the MCP supervisor
  **and the Phoenix endpoint** on any PubSub blip — a guaranteed heavy failure
  traded for a hypothetical one. `Phoenix.PubSub` crashing is close to unheard
  of. **Reconsider if it is ever actually observed**, and then take the targeted
  option: monitor PubSub and re-subscribe after replacement.
  `get_session_state`'s `refresh: true` is already a manual backstop for a
  mirror that has gone stale for any reason.
- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Device *reordering* (removal & bypass
  shipped — see `delete_device`/`bypass_device`), rack inner chains, parameter
  listeners (live meters/automation following) — revisit if a real workflow
  needs them.
- Embeddings or a semantic index for the catalog — the LLM is already the
  semantic layer and has the musical context.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](evaluating/bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
- **Machinery around the fork's two known soft spots** (recorded 2026-07-28
  with the fork itself): a pre-push guard for an unpushed `priv/AbletonOSC`
  commit behind a bumped pin (today it surfaces only as a confusing CI
  checkout failure), and a mechanical check that the fork's `SESHAT.md` stays
  current (a missing divergence entry is invisible until the next upstream
  merge). Both are covered by prose in `/implement` and `/pr-review`; neither
  is worth automating while upstream is dormant and there is one committer.
  Reopen if a merge actually goes wrong because of one.
- Anything related to Windows. It would be nice for this to work on a windows machine,
  but currently we are not focused on this.
