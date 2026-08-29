# Symbolic MIDI generation — which ideas deserve competing prototypes

_Research & options doc · 30 Aug 2026, updated after licence and quality
follow-up · reconciles
[midi-generation-strategies](1%20-%20midi-generation-strategies) and
[competing-midi-strategies.md](2%20-%20competing-midi-strategies.md) against
Seshat's measured MIDI research · decides no product backend by itself; may
feed the re-plan of “MIDI generation — the first solution, composed
symbolically” after the listening experiment._

The earlier [MIDI options survey](midi-generation-options.md) remains the
evidence record for models already run on this Mac and for the rejected
audio-first route. This document answers the narrower question raised by the
two new consultant reports: which **symbolic** approaches are now promising
enough to implement as competing experiments?

## Verdict up front

The consultants agree on the durable architecture and are right about it:

> Claude should translate intent into a small musical plan; a joint symbolic
> engine should author the notes; a deterministic layer should enforce hard
> constraints and land separate editable parts in Live.

That architecture is not one experiment arm. It is the common seam every arm
must share: a minimal `BeatPlan`, a DAW-independent `SymbolicScore` (HVO for
drums), a validator, and one renderer/listening harness.

Three experiments deserve branches, but they are not three equivalent drum
backends:

1. **Minimal pattern DSL + procedural compiler.** This is the most promising
   product architecture: best control, easiest conversational editing, no
   model licence or runtime, and it directly attacks the abstraction failure
   seen with raw note calls. Its unknown is musical vocabulary, not plumbing.
2. **GMD retrieval + structural mutation.** This is the strongest aesthetic
   baseline and probably the quickest route to drums that feel played. It
   starts from real human performances with velocity and microtiming intact.
   Its unknown is prompt range and whether mutation produces enough genuine,
   controllable variation.
3. **Composer's Assistant 2 contextual infill.** This is the neural prototype
   worth trying before MIDI-GPT, but primarily as a bass/accompaniment,
   mutation, and surgical-revision backend. Its interface matches targeted
   track/measure edits, the repository is MIT, its author explicitly permits
   any use of outputs subject to ordinary infringement responsibility, and
   the released models are reported trained only on public-domain or
   permissively licensed MIDI. Blank-project modern drums, Apple Silicon
   latency, and separation from REAPER remain unmeasured.

A fourth, narrower branch should test **Anticipatory Music Transformer for
bass/accompaniment after drums exist**. It is not a competing drum generator
and should not be scored as one. The likely eventual product is a hybrid:
retrieval supplies a strong seed, the DSL makes it editable and promptable,
and a specialist infiller is used only where it audibly improves the result.

Do **not** spend a product branch on MIDI-GPT, MIDI-LLM, MIDILM, GrooVAE, or a
custom trained model now. A bounded MIDI-GPT benchmark remains defensible only
to decide whether to seek commercial rights or retrain its MIT architecture on
clean data. MIDI-LLM is already slow and poorly shaped for surgical edits;
MIDILM has no runnable checkpoint; GrooVAE's hosted checkpoint has no explicit
licence; and training a new model before the baselines are heard would answer
the wrong question.

## Capability frame

The first experiment should cover drums first, then a conditioned bass lane.
The required capabilities are:

| Capability | Input | Output / constraint |
|---|---|---|
| Interpret intent | Free text + tempo/key/length + target roles | Small plan separating hard constraints from soft style intent |
| Read context | Existing Session-view MIDI clips | Bounded rhythmic, harmonic, density, and phrase context; existing notes untouched |
| Compose jointly | One plan + optional existing score | One coordinated multivoice score, not independently generated lanes |
| Perform | Quantized skeleton + feel controls | Intentional velocity and microtiming; composition can be preserved while feel changes |
| Validate | Candidate score + locked ranges/roles | Exact bars, legal notes, requested roles only, preservation and density bounds |
| Revise | Prior plan/score + local instruction | Change hats/bar 8/feel without collateral changes |
| Land and hear | Valid score + target scene + sounds | Separate aligned clips on sounding tracks, verified by read-back |
| Reverse atomically | Whole multi-part request | One high-level operation and one Live undo step |

This framing rules out “sounds good in a full-song demo” as sufficient. A
Seshat backend must also preserve explicit material and support surgical
iteration.

## Live-native ladder

**Version pin.** Measured locally: installed Live is **12.4.5**
(`CFBundleShortVersionString`, 2026-08-30). Reported by Ableton: 12.4.5 is the
latest released build (26 Aug 2026). Its release notes add no new symbolic
generation API relative to the 12.4.3 investigation.

| Capability | Lowest useful rung | Finding and cost |
|---|---|---|
| Read existing MIDI | **Seshat tool layer** | `get_clip_notes` already supplies notes. The fork now has `/live/view/get/selected_scene`, but no model-facing getter resolves “this scene” yet. |
| Compose new material | **UI-only** | Live's Rhythm/Seed/Shape/Stacks MIDI Tools can generate, but they are clip-editor UI operations, not LOM calls. They are a useful listening baseline, not a dependable headless backend. |
| Apply feel | **Fork / LOM** | Quantization and the song groove amount are tools. The fork now exposes groove-pool reads and `/live/clip/set/groove`; Seshat lacks the clip-groove tool. Live can therefore supply performance templates cheaply after one tool gap is filled. |
| Validate/edit notes | **Seshat tool layer** | `get_clip_notes`, `edit_notes`, and `quantize_clip` exist. Generator-specific hard constraints still need a pure validator before the write. |
| Land MIDI and sounds | **Seshat tool layer** | `create_track`, catalog search, `load_device`, and `write_midi_notes` already cover the path. Per-lane dense writes must respect the measured OSC datagram ceiling. |
| One undo step | **Fork + new high-level tool** | The fork exposes `begin_undo_step` / `end_undo_step`, and each current mutation is bracketed. A multi-track generation workflow still needs one handler-owned transaction rather than a conversation-time chain. |

The native result is important but not surprising: Live already owns most of
the execution and feel machinery; it does not expose a symbolic composition
engine Seshat can invoke programmatically. No external dependency is needed
for the DSL or retrieval branches. A neural backend would require a justified
third native-process door under the architecture rule in `CLAUDE.md`.

## What the consultant documents get right

Both reports correctly diagnose four failures in Claude-to-raw-notes:

- the representation is too low-level;
- musical relationships are hierarchical and cross-track;
- feel is systematic timing and velocity, not random jitter;
- natural-language style knowledge needs compiling into musical operations or
  a learned symbolic representation.

The longer report's `BeatPlan` / joint HVO / composition-versus-performance
split is the right internal shape. The shorter report adds the strongest
near-term idea: let Claude emit a compact pattern program and make invalid
timing, range, preservation, and grid states unrepresentable.

Two refinements matter:

1. **The plan and the pattern are different artifacts.** `BeatPlan` should
   hold intent and constraints; the pattern DSL should express executable
   musical structure. Do not make one growing JSON schema carry both jobs.
2. **Persist both plan and source pattern beside the rendered score.** The
   MIDI remains the product output, while these smaller artifacts make “keep
   the snare, change the hats” deterministic and diffable.

Decomposer supports the value of executable, readable symbolic programs, but
not the consultant's stronger claim that it validates text-to-Strudel
composition. The paper performs the opposite transformation—MIDI to Strudel.
It is evidence for the representation, not for adopting Strudel or for
Claude's generation quality.

## Focused follow-up — MIDI-GPT and Composer's Assistant 2

### MIDI-GPT: right interface, wrong current artifact

MIDI-GPT remains architecturally relevant: multitrack generation, bar infill,
drum typing, attributes, and expressive checkpoints are close to Seshat's
editing workflow. The public artifact still fails the two questions a product
branch must answer together: “does it sound good?” and “can the tested system
ship?”

- **Measured on this Mac, 2026-08-26:** current checkpoints produced zeroed
  velocities, ignored density controls in a full-AR run, implausible or
  non-GM drum pitches, implausible bass registers, and nearly empty infills.
  Those are not all necessarily model-taste failures—the velocity round-trip
  points to pipeline defects—but a branch would first debug the research
  stack rather than compare musical quality.
- **Reported, rechecked 2026-08-30:** the code is MIT, while the published
  weights are CC-BY-NC-4.0 and trained on GigaMIDI, whose access terms restrict
  the dataset to non-commercial research or education. User-supplied local
  installation avoids Seshat redistributing the weights; it does not turn
  inference intended to create monetised music into non-commercial use.
- The CC licence does not automatically label every generated MIDI file
  CC-BY-NC, but neither the model card nor the licence gives a commercially
  dependable output-use grant. A personal user deliberately generating music
  for commercial release should obtain separate permission rather than rely
  on “I installed it myself.”

Therefore the only proportionate MIDI-GPT work now is a fixed-prompt,
non-commercial **benchmark**, not a Seshat backend branch. If its final MIDI
clearly beats the clean candidates, that result justifies asking Metacreation
Lab for a commercial licence or training compatible weights on commissioned,
owned, public-domain, or commercially permissive material. If it does not,
licensing and retraining are moot.

### Composer's Assistant 2: clean rights, narrower quality claim

Composer's Assistant 2 is materially cleaner. **Reported by its official
repository:** the software is MIT; the author claims no rights in model
outputs and says users may do with them as they wish, subject to not
infringing another party; and the training material is documented as public
domain, CC0, CC-BY, freely usable, or contributor-authorised. Before Seshat
redistributes anything, inspect the exact v2.1.0 archive and preserve its
licence, disclaimer, and acknowledgments, but commercial output is not blocked
the way MIDI-GPT output is.

Its quality evidence needs a narrower reading:

- **Reported in the CA2 paper:** it supports arbitrary track-measure masking,
  leaves unmasked context unchanged, and controls explicit rhythm, horizontal
  and vertical onset density, pitch range, step/leap propensity, rhythmic
  interest, and whether a new part duplicates an existing part. This is an
  unusually good match for “keep the snare,” “only bar 8,” and “write bass
  against these drums.”
- **Reported:** the model is grid-quantised to 24 ticks per quarter note, with
  32nd-note and 16th-triplet onset locations. The paper describes no velocity
  or microtiming model and no free-text, genre, mood, swing, or style
  conditioning. Claude can translate “sparse” and “low bass” into its knobs;
  those knobs cannot directly express the cultural vocabulary of “dark,
  glitchy hip-hop” or supply a dragging snare and intentional hat feel.
- **Reported listening result, with an important caveat:** listeners did not
  find a statistically significant difference between real music and twelve
  roughly 16-bar co-created examples. Those examples began from six real
  compositions, allowed unlimited generations and selective retention, and,
  in the strongest condition, small hand edits. Creation took about two hours.
  This establishes a strong co-creative ceiling, not one-shot blank-project
  generation.
- **Reported:** the authors had difficulty creating a proper drum part in one
  no-rhythm-control example. The v2.1.0 release says it alleviates but does not
  eliminate the repetition problem.

For the target story, CA2 is therefore **low-to-medium confidence as a
standalone blank-project beat generator**, **medium-to-high confidence for
bass or accompaniment against existing symbolic context**, and **high
confidence in interface fit for local track/bar revisions**. It belongs in
the experiment, but it earns a full-beat product role only by winning the
blank-project listening arm. Its more likely role is downstream of a DSL or
retrieved human drum seed.

## Candidate comparison

### Main experiments against the drum story

| Criterion | DSL + procedural | GMD retrieval + mutation | Composer's Assistant 2 |
|---|---|---|---|
| Expected aesthetic floor | Medium; depends on authored grammar and examples | **High** for feel because seeds are human performances | Low/unknown from blank; stronger when real or generated context already exists |
| Prompt expression | **High ceiling**; Claude maps language to explicit operations | Medium; bounded by indexed vocabulary and mutations | Low–medium; no text/style conditioning, only musical controls Claude must choose |
| Joint drum coherence | **Native** in one pattern/HVO score | **Native** in each retrieved performance | Plausible from blank; stronger for filling one part against unmasked context |
| Surgical editing | **Best**; edit source operations then recompile | Good for lane-local deterministic transforms; weaker for semantic rewrites | **Promising** track/measure infill and preservation interface |
| Performance feel | Must be authored or supplied by a groove template | **Already present** in source MIDI | Weak by construction unless a shared performance/Live-groove pass adds velocity and microtiming |
| Local/dependency fit | **Best**; pure Elixir is plausible | **Strong**; small indexed data + pure transforms | Python/PyTorch process and packaging burden |
| Licence position | Seshat-owned code/data | GMD CC-BY-4.0; attribution product story required | **Strong:** MIT software, explicit output-use statement, documented permissive training sources; verify exact release archive before redistribution |
| Interactive latency | Effectively instant | Effectively instant | Unmeasured on this Mac; kill above the ~10 s model budget |
| Main risk | “Correct but corny” genre grammar | Retrieval sameness and weak long-tail prompt alignment | Published co-creative quality does not transfer to one-shot modern drums; repetition and feel remain weak |
| Verdict | **Primary drum branch** | **Primary drum branch and aesthetic baseline** | **Specialist neural branch:** blank generation is a test; contextual infill/revision is the expected strength |

### Secondary candidates

| Candidate | Verdict |
|---|---|
| Anticipatory Music Transformer | **Bass/accompaniment branch only.** Apache-2.0 project with local infill, but no text front end and piano/general-MIDI priors. Test after fixing a drum score so it can answer “given these drums, write bass.” Verify the selected hosted weights separately. |
| Live MIDI Tools | **Reference baseline.** Audition Rhythm/Seed manually on the same prompts if practical. UI-only automation cost is disproportionate until the native output wins by ear. |
| Minimal Strudel adoption | **Defer.** Borrow mini-notation ideas, but a small Seshat grammar avoids a JavaScript runtime and an unnecessary semantic surface. Revisit only if the in-house grammar starts recreating Strudel. |
| Custom HVO model | **Later.** Potentially excellent long-term, especially for drums, but only after the experiment identifies what retrieval/procedural systems cannot do and supplies an evaluation set. |

### Candidates not worth a branch now

- **MIDI-GPT:** the interface is relevant, but the current weights are
  CC-BY-NC-4.0. A user-configured install avoids redistribution but does not
  make deliberately commercial inference safe, and there is no clear
  commercial-output grant. Measured local runs also produced zeroed
  velocities, ignored controls, implausible pitches, and sparse infills. Its
  MIT code licence does not change the weight licence. Permit only a bounded
  non-commercial benchmark that can justify licensing or clean retraining.
- **MIDI-LLM / text2midi:** already measured at 10.6–47.5 seconds with no
  final-MIDI evidence strong enough to offset their poor editing fit.
- **MIDILM / Agogic:** interesting watch items, but no runnable released
  checkpoint today.
- **GrooVAE:** technically attractive for humanization and measured locally,
  but the hosted checkpoints carry no explicit licence in their index or
  README. The archived dependency lineage adds a second product cost.
- **MIDI Agent and other prompt-to-MIDI products:** useful competitive
  references, not controllable or redistributable backends. Buying one may
  calibrate the baseline, but it does not replace an experiment branch.

## The branch experiment

### Shared base before branching

Commit one experiment contract first:

- `BeatPlan v0`: bars, tempo, time signature, requested roles, hard locks,
  style descriptors, density/variation/feel ranges, section shape;
- `SymbolicScore`: part/voice, pitch, beat-relative onset, duration, velocity,
  microtiming offset, provenance;
- a validator and normalizer;
- adapters from every candidate into that score;
- a fixed prompt/seed slate, fixed instruments, Live placement/read-back, and
  opaque clip labels for blind listening.

Then fork. Branching before this seam exists would compare different score
formats, validators, sounds, and renderers as well as different generators.

### Branch A — `experiment/midi-dsl-procedural`

Implement only enough grammar for kick, snare, closed/open hat, and
percussion:

- literal grid patterns plus named backbeat, Euclidean, ratchet, dropout,
  rotate, repeat/mutate, fill, density and A/A'/B operations;
- separate swing, accent contour, ghost-note and microtiming performance pass;
- Claude emits the plan and DSL once per fixed prompt; compile errors count as
  failures rather than hand-corrected generations.

**Kills the route if:** the grammar compiles reliably but blinded listeners
consistently call it mechanical/generic, or prompt pairs intended to differ do
not produce perceptibly different structures.

### Branch B — `experiment/midi-gmd-mutation`

Index GMD by tempo, genre, performer/session metadata, density, swing,
syncopation, beat/fill, and lane activity. Retrieve jointly, then apply the
same structural operations as Branch A without erasing source microtiming and
velocity.

**Kills the route if:** likely prompts regularly have no credible candidates,
different seeds sound like the same take, or mutations destroy more feel than
they add prompt alignment. Record CC-BY attribution requirements in the
prototype, not after selection.

### Branch C — `experiment/midi-composers-assistant`

The repository-level licence, disclaimer, output statement, and training-data
account are clean enough to justify the spike. First confirm that the exact
v2.1.0 archive carries those same documents, then isolate its local
server/inference path from REAPER and test three different product roles:

- **Standalone:** blank kick/snare/hat/bass generation from an empty
  multitrack score using only controls translated from the prompt.
- **Contextual accompaniment:** bass generation against fixed GMD and
  procedural drum scores.
- **Revision/mutation:** regenerate hats only; create a bar-8 fill while bars
  1–7 remain byte-equivalent after normalization; change density while locked
  snare notes remain unchanged.

Every output receives the same shared velocity/microtiming or Live-groove
comparison as the other branches; do not credit CA2 with feel supplied by a
different postprocessor.

**Kills the route before listening if:** the release archive contradicts the
repository's rights statements, the inference path cannot be separated
reasonably from REAPER, warm latency exceeds ten seconds, or locked-note
preservation fails. It advances as a full-beat backend only if the blank arm
beats Branch A or B. It may advance as a specialist if contextual bass or
revision quality wins materially even when blank drums lose.

### Branch D — `experiment/midi-amt-bass`

Hold the winning/representative drum slate fixed. Compare a bounded
rule-derived bass against **both CA2 and AMT** continuation/infill using
identical key, register, bar, and preservation constraints. This answers
whether either neural accompanist adds musical interaction beyond “bass
follows selected kicks.”

**Kills the route if:** the hosted weight licence is not selection-compatible,
register/harmony repairs dominate its output, or listeners prefer the bounded
rule baseline.

## Judging and decision rule

Use 8–12 prompts fixed before generation, three seeds/takes per backend, and
the same sounding Live instruments. Include:

- blank-project drum prompts across at least four styles;
- 4- and 8-bar form with a required fill or dropout;
- existing-MIDI context;
- “keep snare, change hats,” “only bar 8,” and “make it looser without
  changing hits” edits;
- combined drums+bass for the AMT comparison.

Score all fixed takes; do not let CA2 use unlimited retries or selective
track-measure retention in the primary round. A second co-creative round may
measure its published usage mode, but must report the number of generations,
retained measures, manual edits, and elapsed time rather than comparing that
curated result directly with another backend's first take.

Primary judging is blind, in Live, on rendered MIDI through the same devices.
Score keep/delete preference, groove, prompt match, cross-part coherence,
structural interest, and edit compliance. Symbolic checks are gates, not
quality scores: exact length, preserved notes, valid ranges, requested lane
separation, note-count bounds, and read-back agreement.

Run one extra controlled comparison on the **same skeleton**: raw velocities
and timing versus the shared performance layer versus an assigned Live groove.
That measures whether feel comes from composition, post-processing, or both.

Decision rule:

1. Remove any branch that fails licence, hard constraints, placement, or the
   roughly ten-second generator budget.
2. Pick the backend with the strongest blind final-MIDI ratings and edit
   compliance.
3. On a material tie, prefer DSL/procedural over retrieval, and retrieval over
   a model, because those choices reduce distribution and process/runtime
   surface.
4. Permit a hybrid only when a controlled comparison shows that the added
   stage contributes an audible benefit. “It might help later” is not enough.

## What remains unmeasured

- Whether Claude can emit the proposed minimal DSL reliably across the fixed
  prompt slate.
- Whether the procedural vocabulary sounds idiomatic rather than merely valid.
- GMD retrieval's long-tail prompt coverage and how much attribution must be
  surfaced when source performances are returned after mutation.
- Whether the exact Composer's Assistant 2 v2.1.0 archive repeats the public
  repository's licence/disclaimer terms; Apple Silicon latency; blank modern
  drum output; bass/context quality; and the cost of extracting inference from
  REAPER.
- AMT hosted-weight terms and bass quality against drum context.
- Whether assigning a stock Live groove improves or homogenizes each backend.
- Multi-listener agreement; one listener can rank personal usefulness but
  cannot establish general aesthetic quality.

## Sources

- The two consultant submissions:
  [midi-generation-strategies](1%20-%20midi-generation-strategies) and
  [competing-midi-strategies.md](2%20-%20competing-midi-strategies.md)
- [Existing measured MIDI options](midi-generation-options.md) ·
  [product acceptance](music-generation-user-stories.md) ·
  [Live-native inventory](live-native-options.md)
- [Ableton Live 12 release notes](https://www.ableton.com/en/release-notes/live-12/)
- [Decomposer paper](https://arxiv.org/abs/2607.01849)
- [MIDI-GPT code](https://github.com/Metacreation-Lab/MIDI-GPT) ·
  [weight/model card](https://huggingface.co/Metacreation/MIDI-GPT)
- [GigaMIDI dataset access terms](https://huggingface.co/datasets/Metacreation/GigaMIDI) ·
  [CC BY-NC 4.0 legal code](https://creativecommons.org/licenses/by-nc/4.0/legalcode.en) ·
  [Creative Commons NonCommercial FAQ](https://creativecommons.org/faq/)
- [Composer's Assistant 2](https://github.com/m-malandro/composers-assistant-REAPER)
  · [paper](https://arxiv.org/abs/2407.14700) ·
  [release](https://github.com/m-malandro/composers-assistant-REAPER/releases/tag/v2.1.0) ·
  [licence](https://github.com/m-malandro/composers-assistant-REAPER/blob/main/LICENSE) ·
  [output disclaimer](https://github.com/m-malandro/composers-assistant-REAPER/blob/main/disclaimer.txt) ·
  [training-data acknowledgments](https://github.com/m-malandro/composers-assistant-REAPER/blob/main/acknowledgments.html)
- [Anticipatory Music Transformer](https://github.com/jthickstun/anticipation)
- [Magenta.js hosted checkpoint index](https://github.com/magenta/magenta-js/blob/master/music/checkpoints/checkpoints.json) ·
  [checkpoint README](https://github.com/magenta/magenta-js/blob/master/music/checkpoints/README.md)
