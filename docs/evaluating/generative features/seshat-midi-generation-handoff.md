# Seshat MIDI Generation — Technical Handoff

**Status:** Research / architecture proposal  
**Feature:** Direct MIDI generation and composition  
**Primary user story:** Populate multiple MIDI tracks with a coherent, editable musical part from a natural-language instruction  
**Initial target:** Multi-track drum generation  
**Date:** 2026-08-30

---

## 1. Problem

Seshat needs to generate MIDI that is musically convincing enough to support instructions such as:

> Compose an 8-bar dark, glitchy hip-hop beat.

A session may already contain separate Ableton MIDI tracks for:

- Kick
- Snare
- Hi-hat
- Percussion

Seshat should populate each track with MIDI while treating the result as **one coordinated musical performance**.

The generated tracks must:

- fit together rhythmically,
- exhibit coherent groove and structure,
- respond meaningfully to descriptive language,
- remain individually editable,
- respect track roles and session constraints,
- support targeted regeneration,
- eventually cooperate with melodic/harmonic tracks,
- and preserve the fine-grained control that makes MIDI preferable to generated audio.

This is fundamentally different from generating a finished audio loop.

---

## 2. Previous Approach: Audio → MIDI

The original approach was:

```text
Natural-language prompt
        ↓
Stable Audio 3
        ↓
Generated audio
        ↓
Audio transcription
        ↓
MIDI
```

This has been abandoned as the primary strategy.

### Why

Audio generation gives strong high-level musical results but weak control over specific symbolic elements.

For example, Seshat needs to support instructions like:

- Keep the snare exactly the same.
- Make only the hats busier.
- Remove kicks from bar 4.
- Move the second snare slightly late.
- Double the hi-hat density in the last two bars.
- Replace the bass pattern without touching the drums.

Audio generation collapses those components into one waveform. Recovering them through transcription introduces ambiguity and destroys much of the controllability that MIDI provides.

Audio → MIDI may remain useful for other workflows, but it should not be the foundation of Seshat's composition system.

---

## 3. Current Experiment: LLM → Seshat MCP → Raw MIDI Operations

Seshat has already generated MIDI by allowing a general-purpose LLM such as Claude to manipulate Ableton through Seshat MCP.

The results have not been musically strong.

This does **not** necessarily mean LLMs are incapable of useful musical reasoning.

The problem is the abstraction.

A general-purpose LLM is effectively being asked to compose using operations like:

```text
add_note(track, pitch, start_time, duration, velocity)
add_note(...)
add_note(...)
```

This is similar to asking an image model to paint by issuing thousands of individual `set_pixel()` calls.

The LLM can reason about concepts such as:

- dark,
- glitchy,
- sparse,
- syncopated,
- halftime,
- dragging snare,
- rising intensity,

but it is poorly suited to directly choosing hundreds of low-level note events while preserving groove and long-range musical relationships.

---

# 4. Core Architectural Recommendation

## Do not make the LLM the MIDI generator.

Use the LLM as a **musical planner and intent interpreter**.

Use a dedicated symbolic music system to generate the actual note events.

The target architecture should be:

```text
USER
"Make an 8-bar dark glitchy hip-hop beat.
Sparse kick, fucked-up hats, snare should drag."
                  │
                  ▼
         ┌─────────────────┐
         │   Seshat LLM    │
         │ Musical Planner │
         └────────┬────────┘
                  │
                  ▼
          Structured BeatPlan
                  │
                  ▼
        ┌──────────────────┐
        │ Symbolic Groove  │
        │    Generator     │
        └────────┬─────────┘
                 │
                 ▼
        Joint drum performance
                 │
                 ▼
        ┌──────────────────┐
        │ MIDI Constraint /│
        │ Postprocess Layer│
        └────────┬─────────┘
                 │
       ┌─────────┼──────────┐
       ▼         ▼          ▼
     Kick      Snare      Hi-hat
     track      track       track
```

The key distinction is:

> **The tracks are separate in Ableton, but they should not be composed independently.**

The generator should compose the entire drum arrangement jointly and only split the result into Ableton tracks afterward.

---

# 5. Internal Representation: Joint Drum Score

Do not generate:

```text
kick → independent generation
snare → independent generation
hat → independent generation
```

Generate a shared rhythmic object:

```text
                    BAR 1                         BAR 2
            1e&a 2e&a 3e&a 4e&a          1e&a 2e&a 3e&a 4e&a

Kick        x..x .... x... ..x.           x... ...x x... ....
Snare       .... x... .... x...           .... x... .... x...
HiHat       x.x. x.x. xxxx x.x.           x.x. x.xx xxxx x.x.
Perc        .... .... ..x. ....           .... .x.. .... ..x.
```

This guarantees that the model can reason about relationships such as:

- kick/snare interplay,
- open space,
- accents,
- fills,
- hat density relative to kick density,
- structural development across bars,
- repeated motifs,
- tension/release.

After generation:

```text
Joint Drum Score
       ↓
Seshat Track Mapper
   ↙    ↓     ↘
Kick  Snare  HiHat
```

---

# 6. Recommended Musical Representation: HVO

For drums, use an HVO-style representation:

- **H** — hit
- **V** — velocity
- **O** — timing offset

For a fixed rhythmic grid:

```text
X[bar][step][voice]
```

Each cell contains approximately:

```json
{
  "hit": true,
  "velocity": 91,
  "offset": -0.018
}
```

Example voices:

```text
kick
snare
closed_hat
open_hat
tom
rim
clap
perc
```

An 8-bar beat on a 32nd-note grid with 4 voices is still a very small symbolic search space compared with audio generation.

This makes drum generation an unusually tractable machine-learning problem.

---

# 7. Separate Composition From Performance

Seshat should eventually treat these as two different stages.

## Pass A — Composition

Decide **what notes occur**.

Example:

```text
Kick:
1.1
1.3.75
2.2.5
...

Snare:
1.2
1.4
...

Hat:
1.1
1.1.5
1.2
...
```

## Pass B — Performance / Groove

Decide:

- velocity,
- swing,
- microtiming,
- lateness,
- accents,
- ghost-note strength,
- timing consistency,
- humanization.

This separation enables very useful future commands:

> Make this groove drunk.

> Tighten the drums.

> Keep the pattern but make the snare lazy.

> Quantize the kick but leave the hats loose.

> Make the hats robotic.

These operations should not require recomposing the rhythm.

---

# 8. The BeatPlan

The LLM should output a compact intermediate representation rather than raw notes.

Example:

```json
{
  "bars": 8,
  "tempo": 86,
  "style": [
    "hip-hop",
    "glitch"
  ],
  "mood": [
    "dark"
  ],
  "energy": 0.55,
  "groove": {
    "swing": 0.58,
    "humanization": 0.7,
    "syncopation": 0.72
  },
  "voices": {
    "kick": {
      "density": 0.35,
      "stability": 0.70
    },
    "snare": {
      "density": 0.22,
      "backbeat_strength": 0.85,
      "late_bias_ms": 14
    },
    "hihat": {
      "density": 0.72,
      "burstiness": 0.75,
      "preferred_subdivisions": [
        "1/16",
        "1/32"
      ]
    }
  },
  "structure": [
    "A",
    "A'",
    "B",
    "fill"
  ]
}
```

The exact schema should evolve.

The important point is that the LLM operates in a vocabulary that corresponds to musical intention rather than MIDI ticks.

---

# 9. Candidate Strategy A — MIDI-GPT

## Why it is interesting

MIDI-GPT is currently one of the most relevant existing symbolic-generation systems for Seshat.

Its architecture supports concepts close to Seshat's desired workflow:

- multitrack generation,
- bar-level generation,
- infilling,
- conditioning on existing musical context,
- configurable note density,
- configurable note duration,
- genre conditioning in newer models,
- velocity and microtiming in expressive models.

This is much closer to:

```text
"fill these 8 bars on these tracks while respecting everything around them"
```

than ordinary text-to-MIDI generation.

## Seshat use

The first prototype should treat a drum kit as a unified score.

Example:

```text
Kick + Snare + Hats + Percussion
            ↓
        MIDI-GPT
            ↓
  generated joint passage
            ↓
      split by role
```

## Strength

Strong candidate for testing:

- contextual generation,
- infilling,
- continuation,
- preserving existing material,
- track-aware editing.

## Weakness

Its pretrained musical distribution may not be ideal for modern production-oriented drum programming.

"Dark glitchy hip-hop" is a substantially different target from generic multitrack MIDI composition.

## Licensing warning

MIDI-GPT's code and pretrained weights may have different licenses.

The public pretrained models have been associated with non-commercial training sources / licenses.

Therefore:

> Treat MIDI-GPT as a research and prototype dependency until all model and training-data licenses are reviewed for commercial use.

### Sources

- https://github.com/Metacreation-Lab/MIDI-GPT

---

# 10. Candidate Strategy B — MIDI-LLM

MIDI-LLM demonstrates another important strategy.

Instead of asking a normal LLM to express music through tool calls, it gives the language model a dedicated symbolic MIDI vocabulary.

Its vocabulary includes musical tokens representing concepts such as:

- onset,
- duration,
- instrument,
- pitch.

The model then learns symbolic music directly through continued training.

## Why this matters

This explains a major limitation of the current Claude MCP experiment.

Claude primarily thinks in natural-language tokens.

MIDI-LLM learns a token language whose structure directly represents musical events.

## Strength

Very interesting for:

```text
natural language → symbolic composition
```

and potentially for future multi-instrument generation.

## Weakness

Its current paradigm is closer to:

```text
prompt → complete MIDI composition
```

than:

```text
session state
+ selected tracks
+ exact bar range
+ existing notes
+ hard constraints
→ targeted edit
```

That makes it less naturally aligned with Seshat's DAW-editing workflow than MIDI-GPT.

### Sources

- https://arxiv.org/abs/2511.03942
- https://huggingface.co/slseanwu/MIDI-LLM_Llama-3.2-1B

---

# 11. Candidate Strategy C — MIDILM

MIDILM is another recent text-to-MIDI model.

It uses a text encoder plus a symbolic music decoder and uses REMI-style MIDI tokenization.

It is worth including in benchmarks because it represents the current generation of text-conditioned symbolic music models.

However, it appears more useful as a:

```text
prompt → composition
```

model than a DAW-oriented surgical editing model.

### Source

- https://ojs.aaai.org/index.php/AAAI/article/view/39483

---

# 12. Candidate Strategy D — Custom Seshat Drum Model

This may ultimately be the highest-value path.

Drum generation is dramatically simpler than general music generation.

For example:

```text
8 bars
× 32 grid positions per bar
× 4 drum voices
```

is only:

```text
1024 possible hit locations
```

Each position then needs:

```text
hit probability
velocity
microtiming
```

A relatively small neural model could potentially learn this extremely well.

Possible architectures:

- Transformer
- VAE
- Transformer-VAE
- diffusion model over HVO tensors
- masked symbolic transformer
- autoregressive event model

The model does **not** need billions of parameters.

---

# 13. Useful Training Data

## Groove MIDI Dataset

Google's Groove MIDI Dataset contains human drum performances with:

- MIDI events,
- velocity,
- microtiming,
- BPM,
- performance metadata.

This is extremely valuable for learning human groove.

## Expanded Groove MIDI Dataset / E-GMD

E-GMD substantially expands the dataset and includes tens of thousands of performances.

The particularly important detail for Seshat is that it has been released under **CC BY 4.0**, making it much more attractive for a commercial product than many web-scraped MIDI datasets.

### Sources

- https://magenta.withgoogle.com/datasets/groove
- https://magenta.tensorflow.org/datasets/e-gmd

---

# 14. GrooveTransformer

GrooveTransformer is useful because it demonstrates an HVO-based neural representation for generating complete drum performances.

Rather than separately generating:

```text
kick
snare
hats
```

the model represents them together.

This is directly aligned with the proposed Seshat representation.

### Source

- https://github.com/behzadhaki/GrooveTransformer

---

# 15. Candidate Strategy E — BeatPlan + Procedural Composer

A surprisingly strong near-term approach may require **no generative ML for note placement**.

Instead:

```text
LLM
 ↓
BeatPlan
 ↓
Domain-specific drum composer
 ↓
MIDI
```

The drum composer would expose musical operations instead of low-level note commands.

Example vocabulary:

```text
establish_backbeat()
add_syncopation()
add_ghost_snare()
add_hat_burst()
drop_hit()
displace_hit()
repeat_fragment()
ratchet()
half_time()
double_time_hat()
mutate_last_half_bar()
increase_density()
decrease_density()
create_fill()
```

The LLM could create a plan such as:

```text
Bars 1-2
- sparse boom-bap base groove
- 58% swing
- stable snare

Bars 3-4
- keep snare
- mutate kick by ~30%
- introduce sparse 32nd-note hat bursts

Bars 5-6
- remove downbeat kick
- increase hat density
- add low-velocity ghost snare

Bar 7
- return toward original groove

Bar 8
- progressively fragment hats
- short dropout before loop restart
```

The procedural engine compiles that plan into MIDI.

## Advantages

- deterministic constraints,
- instant generation,
- excellent editability,
- no GPU,
- easy testing,
- easy regeneration,
- hard to produce structurally invalid output,
- easy to expose parameters,
- easy to reason about user instructions.

Most importantly:

> This would not be throwaway work.

The procedural engine can later become the constraint / transformation / postprocessing layer around a neural generator.

---

# 16. Candidate Strategy F — Retrieval + Mutation

Another promising hybrid:

```text
User prompt
    ↓
style interpretation
    ↓
retrieve compatible grooves
    ↓
select / combine structural seed
    ↓
variation model or procedural mutation
    ↓
new MIDI
```

A library could contain high-quality grooves labeled by:

- genre,
- BPM,
- density,
- syncopation,
- swing,
- energy,
- kit character,
- pattern structure.

Example categories:

```text
boom bap
glitch hop
trip hop
trap
industrial hip-hop
lo-fi
broken beat
electro
```

The retrieved pattern provides a strong musical prior.

A generative or procedural system then transforms the pattern enough to produce original output.

Possible transformations:

```text
velocity variation
timing variation
density adjustment
kick mutation
snare substitution
hat subdivision changes
fills
dropouts
structural recombination
```

This can dramatically improve baseline musicality because the system does not need to rediscover basic groove grammar from scratch.

---

# 17. Magenta MusicVAE / GrooveVAE

Magenta's MusicVAE work remains relevant primarily for:

- groove interpolation,
- variation,
- humanization,
- latent-space exploration,
- adding or transforming drum parts.

It may be more useful as a **variation/performance layer** than as the main text-conditioned generator.

### Source

- https://github.com/magenta/magenta/tree/main/magenta/models/music_vae

---

# 18. Recommended Seshat Architecture

Long-term:

```text
                    User Prompt
                         │
                         ▼
              ┌────────────────────┐
              │  Session Analyzer  │
              │                    │
              │ tempo              │
              │ time signature     │
              │ existing clips     │
              │ selected bars      │
              │ track roles        │
              └─────────┬──────────┘
                        │
                        ▼
              ┌────────────────────┐
              │   Seshat Planner   │
              │       LLM          │
              └─────────┬──────────┘
                        │
                        ▼
                 CompositionPlan
                        │
            ┌───────────┴────────────┐
            │                        │
            ▼                        ▼
      hard constraints          style parameters
            │                        │
            └───────────┬────────────┘
                        ▼
              ┌────────────────────┐
              │ Symbolic Generator │
              │                    │
              │ neural / procedural│
              │ / hybrid           │
              └─────────┬──────────┘
                        │
                        ▼
                Joint MIDI Object
                        │
                        ▼
              ┌────────────────────┐
              │ Groove / Performance│
              │ Layer               │
              └─────────┬──────────┘
                        │
                        ▼
              ┌────────────────────┐
              │ Constraint Validator│
              │ + Postprocessor     │
              └─────────┬──────────┘
                        │
                        ▼
                Ableton Track Mapper
              ↙         ↓          ↘
           Kick       Snare       Hats
```

---

# 19. Hard Constraints vs Soft Intent

This distinction should exist explicitly in the architecture.

## Hard constraints

Must never be violated.

Examples:

```text
bars = 8
time_signature = 4/4
selected_tracks = kick, snare, hats
preserve_snare = true
do_not_modify_bars = [1, 2]
maximum_pitch = ...
minimum_pitch = ...
```

## Soft intent

Interpretive targets.

Examples:

```text
dark
glitchy
lazy
aggressive
busy
minimal
unstable
human
mechanical
```

The generator should optimize for soft intent **inside** hard constraints.

This is particularly important for conversational editing.

---

# 20. Conversational Editing Model

The architecture should make commands like these cheap:

```text
"Make the hats crazier."
```

Changes:

```text
hat density
hat burstiness
hat subdivision
hat timing entropy
```

Preserves:

```text
kick
snare
structure
```

---

```text
"Keep everything but make it feel drunk."
```

Changes:

```text
timing offsets
velocity variation
swing
```

Preserves:

```text
hit locations
```

---

```text
"Give me a fill in bar 8."
```

Changes:

```text
bar 8 only
```

Preserves:

```text
bars 1-7
```

This is why session-aware symbolic generation is more important to Seshat than generic text-to-MIDI generation.

---

# 21. Future Multi-Instrument Generalization

The drum system should be designed so the same planner can later coordinate:

```text
drums
bass
chords
melody
arpeggios
percussion
```

Example:

```text
User:
"Make an 8-bar dark synthwave section."
```

Planner:

```text
Key: F minor
Tempo: 96 BPM

Harmony:
Fm | Db | Ab | Eb

Structure:
A A A' B

Rhythmic feel:
driving
straight 8ths
moderately human
```

Then specialist generators receive a shared plan:

```text
                   CompositionPlan
                        │
           ┌────────────┼────────────┐
           ▼            ▼            ▼
        drums          bass        synth
       generator     generator    generator
```

The generators can also condition on previously generated material.

Example:

```text
Bass generator receives:
- CompositionPlan
- chord progression
- generated drum score
```

This is how Seshat can maintain coherence across independently editable tracks.

---

# 22. Recommended Prototype Strategy

Do **not** initially choose one architecture.

Build three competing prototypes against the same prompts and evaluation harness.

---

## Prototype A — MIDI-GPT

Goal:

Determine how good an existing multitrack symbolic model is at Seshat-style generation and infilling.

Test:

```text
8-bar drum generation
4-bar continuation
bar-level infill
preserve existing track
regenerate hats only
increase density
decrease density
```

Questions:

- Does it understand modern drum syntax?
- Can it generate convincing hip-hop?
- Does it preserve coherent cross-track groove?
- Does infill work well enough for DAW editing?
- How controllable are repeated generations?
- What is inference latency?
- How large is the model/runtime?
- Can any pretrained checkpoint legally ship commercially?

---

## Prototype B — Text-to-MIDI Model

Start with MIDI-LLM and optionally MIDILM.

Goal:

Determine current best-case quality for direct:

```text
text → symbolic music
```

Use prompts such as:

> An 8-bar dark glitchy hip-hop drum loop with sparse kicks, dragging snares, rapid irregular hi-hat bursts and no melodic instruments.

Then:

- extract drum events,
- map them into Seshat tracks,
- compare quality with other systems.

This prototype primarily answers:

> How far have current symbolic foundation models gotten?

---

## Prototype C — Seshat BeatPlan + Procedural Drum Engine

Goal:

Create a controllable baseline.

Implement enough groove grammar to support:

```text
kick
snare
closed hat
open hat
basic percussion
```

Implement transforms such as:

```text
density
syncopation
swing
microtiming
velocity accents
ghost notes
hat bursts
fills
dropouts
pattern mutation
A/A'/B structure
```

This becomes the control baseline every neural system must beat.

---

# 23. Evaluation Harness

This is important.

Do not evaluate these systems by listening to a few lucky generations.

Create a fixed prompt suite.

Example prompts:

```text
1.
"8 bars of dark glitchy hip-hop.
Sparse kick, lazy snare, unstable hats."

2.
"Minimal boom-bap beat.
Very consistent snare.
Kick should evolve every two bars."

3.
"Mechanical industrial hip-hop.
Straight hats.
Heavy syncopated kick."

4.
"Loose drunken beat.
Late snare.
Low velocity ghost notes."

5.
"Very sparse first four bars,
then increase energy without changing tempo."
```

For every generator, create N generations per prompt.

Suggested:

```text
10 prompts
×
10 generations
=
100 clips per system
```

---

# 24. Evaluation Dimensions

Human ratings:

```text
Musicality
Groove
Prompt alignment
Cross-track coherence
Interestingness
Loop quality
Editability
```

Machine-readable metrics:

```text
note density
voice density
velocity distribution
timing offset distribution
syncopation
pattern repetition
bar similarity
structural variation
kick/snare collision patterns
```

Also test conversational edit compliance:

```text
"Keep the snare unchanged."

"Only modify bar 8."

"Double the hat density."

"Make it more human."

"Remove all kicks from bar 4."
```

This may matter more to Seshat than raw composition quality.

---

# 25. Suggested Initial BeatPlan Schema

Potential first version:

```typescript
type BeatPlan = {
  bars: number
  tempo: number
  timeSignature: [number, number]

  descriptors: string[]

  structure: {
    sections: Array<{
      startBar: number
      endBar: number
      role: "A" | "variation" | "fill" | "break"
    }>
  }

  groove: {
    swing: number
    humanization: number
    syncopation: number
  }

  voices: {
    kick?: DrumVoicePlan
    snare?: DrumVoicePlan
    closedHat?: DrumVoicePlan
    openHat?: DrumVoicePlan
    percussion?: DrumVoicePlan
  }
}

type DrumVoicePlan = {
  density: number
  variation: number
  velocityVariation: number
  timingVariation: number

  preserveExisting?: boolean

  preferredSubdivisions?: Array<
    "1/4" |
    "1/8" |
    "1/16" |
    "1/32"
  >
}
```

Do not overcommit to this schema before prototyping.

The schema should be derived from parameters that actually produce meaningful audible changes.

---

# 26. Suggested Internal Drum Event Model

Avoid tying the generator directly to Ableton APIs.

Example:

```typescript
type DrumEvent = {
  bar: number
  beat: number
  subdivision: number

  voice:
    | "kick"
    | "snare"
    | "closed_hat"
    | "open_hat"
    | "perc"

  velocity: number

  // relative to quantized position
  offsetTicks: number

  durationTicks?: number
}
```

Then:

```text
Generator
   ↓
Seshat internal symbolic score
   ↓
Ableton adapter
```

This allows the same engine to target:

- Ableton,
- MIDI files,
- test fixtures,
- future DAWs,
- visualization/debug tooling.

---

# 27. Suggested Module Boundaries

Conceptually:

```text
Seshat.Music.Intent
Seshat.Music.Plan
Seshat.Music.Score
Seshat.Music.Generator
Seshat.Music.Generator.Procedural
Seshat.Music.Generator.MidiGPT
Seshat.Music.Groove
Seshat.Music.Validation
Seshat.Music.AbletonMapper
```

Exact names should match existing repo conventions.

Critical rule:

> The Ableton integration should not contain composition logic.

---

# 28. MIDI Validation Layer

All generators should pass through the same validator.

Possible checks:

```text
events inside requested bar range
allowed track roles only
valid MIDI velocity
valid duration
no negative note positions
respect preserveExisting constraints
respect locked bars
respect allowed pitches
respect requested density bounds
prevent pathological event floods
```

The validator can also normalize model output.

This provides a deterministic safety boundary around stochastic generation.

---

# 29. Generation Interface

A useful abstraction could look like:

```typescript
interface SymbolicGenerator {
  generate(input: GenerationContext): Promise<SymbolicScore>
}
```

Where:

```typescript
type GenerationContext = {
  session: SessionMusicContext
  plan: CompositionPlan
  existingScore?: SymbolicScore
  target: GenerationTarget
  constraints: GenerationConstraints
}
```

This makes generators interchangeable:

```text
ProceduralGenerator
MidiGPTGenerator
MidiLLMGenerator
SeshatGrooveModel
```

The evaluation harness can run all of them through the same interface.

---

# 30. Licensing Requirements

Licensing must be evaluated independently for:

```text
source code
model architecture
model weights
training datasets
derived datasets
commercial inference
redistribution
```

Do not assume that an open-source repository means its pretrained model can be shipped commercially.

Important examples:

### E-GMD

Attractive because it is released under CC BY 4.0.

### GigaMIDI

Associated with non-commercial restrictions.

### MIDI-GPT

Repository source and pretrained weights/training lineage may have different licensing constraints.

Therefore:

> Existing pretrained models should initially be treated as benchmark / research tools unless commercial-use rights are confirmed.

---

# 31. What Not To Do

## Do not return to audio → MIDI as the primary architecture.

It sacrifices the exact controllability this feature is supposed to provide.

## Do not generate each Ableton track independently.

The musical relationship between kick/snare/hats needs to be generated jointly.

## Do not let the LLM emit hundreds of raw note tool calls.

That is the wrong abstraction.

## Do not couple the generator directly to Ableton.

Use an internal symbolic representation.

## Do not evaluate only full-generation quality.

Editing and constraint-following are core Seshat product requirements.

## Do not prematurely train a large model.

First determine what existing symbolic models and a simple domain engine can already do.

---

# 32. Recommended Development Order

## Phase 1 — Representation

Build:

```text
BeatPlan
SymbolicScore
DrumEvent / HVO representation
Ableton track-role mapping
MIDI validator
```

No ML required.

---

## Phase 2 — Procedural Baseline

Implement:

```text
basic groove generation
density
backbeat
syncopation
swing
velocity
microtiming
variation
fills
A/A' structure
```

Get the complete Seshat pipeline working end-to-end.

---

## Phase 3 — Existing Model Spike

Integrate MIDI-GPT behind the same generator interface.

Benchmark against procedural generation.

---

## Phase 4 — Text-to-MIDI Spike

Benchmark:

```text
MIDI-LLM
MIDILM
```

Measure:

```text
quality
control
latency
deployment complexity
licensing
```

---

## Phase 5 — Hybrid Generation

Potentially:

```text
BeatPlan
+
retrieved groove
+
neural variation
+
procedural constraint engine
```

This may outperform any single approach.

---

## Phase 6 — Seshat Groove Model

If usage warrants it:

Train a specialized drum generator.

Inputs:

```text
BeatPlan
existing MIDI context
style embedding
tempo
structure
locked events
```

Outputs:

```text
joint HVO drum performance
```

Start small.

The problem does not require an enormous model.

---

# 33. Suggested First Engineering Tickets

### MIDI-001 — Define SymbolicScore

Create DAW-independent internal representation for:

```text
bars
tracks / voices
notes
velocity
timing offsets
```

---

### MIDI-002 — Define Drum Track Roles

Map Ableton tracks to semantic roles:

```text
kick
snare
closed_hat
open_hat
perc
```

Track names alone should not eventually be the only signal.

---

### MIDI-003 — BeatPlan v0

Define a minimal schema supporting:

```text
bars
style descriptors
density
swing
syncopation
variation
voice-level settings
structure
```

---

### MIDI-004 — LLM → BeatPlan

Teach the Seshat planner to convert:

```text
"dark glitchy hip-hop"
```

into BeatPlan parameters.

---

### MIDI-005 — Procedural Drum Generator

Generate a joint multivoice drum score from BeatPlan.

---

### MIDI-006 — Ableton MIDI Writer

Convert SymbolicScore into MIDI clips/events on target tracks.

---

### MIDI-007 — Constraint Validator

Implement hard constraints and locked-event preservation.

---

### MIDI-008 — Evaluation Prompt Suite

Create fixed prompt corpus and scoring rubric.

---

### MIDI-009 — MIDI-GPT Spike

Wrap MIDI-GPT behind the SymbolicGenerator interface.

---

### MIDI-010 — MIDI-LLM Spike

Generate candidate MIDI and normalize into SymbolicScore.

---

### MIDI-011 — A/B Listening Harness

Quickly audition multiple generated variants from each backend.

---

### MIDI-012 — Edit Compliance Tests

Test:

```text
preserve snare
change hats only
modify bar 8
increase density
tighten timing
```

---

# 34. Primary Research Questions

The next spike should answer these questions rather than simply asking "does it sound good?"

### Quality

Can the generator consistently produce grooves that a musician would keep?

### Control

Can Seshat request specific changes without disturbing unrelated material?

### Context

Can the generator condition on existing session MIDI?

### Structure

Can it produce coherent development over 8 bars rather than one bar copied eight times?

### Performance

Can velocity and timing feel intentional?

### Style

Can natural-language descriptors cause reliably different results?

### Latency

Can generation feel interactive inside a DAW workflow?

### Deployment

Can the model run:

```text
locally
Seshat-hosted
third-party inference
```

and at what cost?

### Licensing

Can the system legally ship in a commercial product?

---

# 35. Decision Framework

A candidate generator should be scored approximately:

| Criterion | Weight |
|---|---:|
| Musical quality | 25% |
| Edit / constraint compliance | 25% |
| Cross-track coherence | 15% |
| Prompt alignment | 10% |
| Latency | 10% |
| Deployment complexity | 5% |
| Commercial licensing | 10% |

Seshat should **not** select a model based only on impressive full-song demos.

Constraint compliance should carry almost as much weight as musical quality.

---

# 36. Current Recommendation

The strongest current path is:

```text
Seshat LLM
    ↓
Composition / BeatPlan
    ↓
joint symbolic generator
    ↓
performance / groove layer
    ↓
constraint validator
    ↓
DAW-independent SymbolicScore
    ↓
Ableton track mapper
```

For the next implementation cycle:

1. Build the symbolic abstraction.
2. Build a small procedural drum generator.
3. Integrate MIDI-GPT as an experimental backend.
4. Benchmark MIDI-LLM / MIDILM separately.
5. Evaluate all systems using the same prompt and edit-compliance suite.
6. Use the results to decide whether a specialized Seshat groove model is justified.

---

# 37. Bottom Line

The failure of raw Claude → MCP MIDI generation should not be interpreted as evidence that direct MIDI generation is infeasible.

It indicates that Seshat currently asks the LLM to operate at too low a level.

The product should separate:

```text
intent
composition
performance
constraints
DAW execution
```

The LLM should understand the user and act like the **producer/composer directing the session**.

A symbolic music system should generate the actual performance.

Seshat should enforce deterministic constraints and map the resulting symbolic score into Ableton.

A useful shorthand:

> **Claude should be the producer, not the drummer.**

That architecture preserves exactly what makes the MIDI approach valuable: high-quality generative composition without surrendering fine-grained track-level control.
